import XCTest
@testable import UsageLimitsCore

final class AbacusParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testParsesComputePointsAndOptionalBilling() throws {
        let snapshot = AbacusParser.parse(results: [
            "compute_points": ProbeResult(status: 200, body: try fixture("abacus_compute_points")),
            "billing": ProbeResult(status: 200, body: try fixture("abacus_billing")),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertNil(snapshot.planExpiresAt)
        XCTAssertEqual(snapshot.metrics.count, 1)

        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.id, "compute_points")
        XCTAssertEqual(metric.label, "Compute Points")
        XCTAssertEqual(metric.usedPercent, 25)
        XCTAssertEqual(metric.remaining, 750)
        XCTAssertEqual(metric.total, 1000)
        XCTAssertEqual(metric.resetsAt, iso("2026-09-28T08:30:00.123Z"))
        XCTAssertEqual(metric.detail, "已用 250 / 1,000 points")
        XCTAssertEqual(metric.pinned, true)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testOverflowBillingDateIsDroppedWithoutPoisoningSnapshot() throws {
        let compute = try fixture("abacus_compute_points")
        for date in ["+010000-01-01T00:00:00Z", "1960-01-01T00:00:00Z", "10000-01-01T00:00:00Z"] {
            let billing = #"{"success":true,"result":{"nextBillingDate":"\#(date)","currentTier":"pro"}}"#
            let snapshot = parse(compute: compute, billing: billing)
            XCTAssertEqual(snapshot.status, .ok, date)
            XCTAssertEqual(snapshot.planName, "Pro", date)
            XCTAssertNil(snapshot.metrics.first?.resetsAt, date)
            XCTAssertNil(snapshot.persistenceValidationIssue, date)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot), date)
        }
    }

    func testBillingDateSupportsISOWithoutFractionalSecondsAndUnknownTierIsPreserved() throws {
        let billing = #"{"success":true,"result":{"nextBillingDate":"2026-10-01T00:00:00Z","currentTier":"  Research Preview  "}}"#
        let snapshot = parse(compute: try fixture("abacus_compute_points"), billing: billing)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Research Preview")
        XCTAssertEqual(snapshot.metrics.first?.resetsAt, iso("2026-10-01T00:00:00Z"))
    }

    func testOptionalBillingFailuresNeverSuppressValidCoreUsage() throws {
        let compute = try fixture("abacus_compute_points")
        let failures = [
            ProbeResult(status: 401, body: ""),
            ProbeResult(status: 503, body: ""),
            ProbeResult(status: -3, body: "timeout"),
            ProbeResult(status: 200, body: #"{"success":false,"error":"session expired"}"#),
            ProbeResult(status: 200, body: "not json"),
        ]

        for billing in failures {
            let snapshot = AbacusParser.parse(results: [
                "compute_points": ProbeResult(status: 200, body: compute),
                "billing": billing,
            ], now: now)
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertNil(snapshot.planName)
            XCTAssertNil(snapshot.metrics.first?.resetsAt)
        }
    }

    func testCoreHTTPAndEnvelopeAuthenticationFailuresNeedLogin() {
        for status in [401, 403] {
            XCTAssertEqual(parse(compute: "", status: status).status, .needsLogin)
        }

        for word in ["expired", "session", "login", "authenticate", "unauthorized", "unauthenticated", "forbidden"] {
            let body = "{\"success\":false,\"error\":\"Please \(word) again\"}"
            XCTAssertEqual(parse(compute: body).status, .needsLogin, word)
        }
    }

    func testAuthenticationMessageWinsWhenSuccessIsMissingOrMalformed() {
        let bodies = [
            #"{"error":"session expired"}"#,
            #"{"success":"false","error":"unauthorized"}"#,
            #"{"success":1,"error":"login required"}"#,
        ]

        for body in bodies {
            XCTAssertEqual(parse(compute: body).status, .needsLogin, body)
        }
    }

    func testOtherCoreFailuresAreErrorsNotLoginPrompts() {
        XCTAssertEqual(parse(compute: "", status: 503).status, .error("HTTP 503"))
        XCTAssertEqual(parse(compute: "timeout", status: -3).status, .error("请求超时"))

        let businessError = parse(compute: #"{"success":false,"error":"quota service unavailable"}"#)
        XCTAssertEqual(businessError.status, .error("Abacus 接口返回失败"))
        XCTAssertTrue(businessError.metrics.isEmpty)
    }

    func testSuccessEnvelopeMustUseBooleanTrueAndObjectResult() {
        let bodies = [
            "not json",
            "[]",
            #"{"success":1,"result":{"totalComputePoints":1,"computePointsLeft":0}}"#,
            #"{"success":"true","result":{"totalComputePoints":1,"computePointsLeft":0}}"#,
            #"{"success":true}"#,
            #"{"success":true,"result":[]}"#,
        ]

        for body in bodies {
            let snapshot = parse(compute: body)
            XCTAssertEqual(snapshot.status, .error("Abacus 响应格式异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testInvalidComputePointValuesAreRejectedWithoutClamping() throws {
        let results = [
            ["totalComputePoints": true, "computePointsLeft": 0],
            ["totalComputePoints": "100", "computePointsLeft": 0],
            ["totalComputePoints": 100, "computePointsLeft": false],
            ["totalComputePoints": 100, "computePointsLeft": "NaN"],
            ["totalComputePoints": 100, "computePointsLeft": "Infinity"],
            ["totalComputePoints": -1, "computePointsLeft": 0],
            ["totalComputePoints": 100, "computePointsLeft": -1],
            ["totalComputePoints": 100, "computePointsLeft": 101],
        ]

        for result in results {
            let data = try JSONSerialization.data(withJSONObject: ["success": true, "result": result])
            let body = String(decoding: data, as: UTF8.self)
            let snapshot = parse(compute: body)
            XCTAssertEqual(snapshot.status, .error("算力点数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testZeroTotalAndLeftIsValidPinnedMetric() {
        let snapshot = parse(compute: #"{"success":true,"result":{"totalComputePoints":0,"computePointsLeft":0}}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 0)
        XCTAssertEqual(snapshot.metrics.first?.remaining, 0)
        XCTAssertEqual(snapshot.metrics.first?.total, 0)
        XCTAssertEqual(snapshot.metrics.first?.pinned, true)
    }

    func testMissingCoreAndEmptyResultsAreExplicitErrors() {
        XCTAssertEqual(AbacusParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
        XCTAssertEqual(
            AbacusParser.parse(
                results: ["billing": ProbeResult(status: 200, body: #"{"success":true,"result":{}}"#)],
                now: now
            ).status,
            .error("未获取到算力点响应")
        )
    }

    func testProbeRunsCoreAndBillingConcurrentlyWithinOuterBudget() throws {
        let source = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static let abacus = probeHelper"))
        let end = try XCTUnwrap(source.range(of: "/// T3 Chat", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(block.contains("Promise.all(["), "必需与可选请求需并发，不能串行消耗外层 30 秒")
        XCTAssertTrue(block.contains("timeoutMs: 12000"), "核心一次重试的理论上限需低于外层 30 秒")
        XCTAssertTrue(block.contains("timeoutMs: 5000"))
        XCTAssertTrue(block.contains("retry: false"), "billing 只能尝试一次")
        XCTAssertTrue(block.contains("method: 'POST'"))
        XCTAssertTrue(block.contains("body: '{}'"))
        XCTAssertTrue(block.contains("'Accept': 'application/json'"))
        XCTAssertTrue(block.contains("'Content-Type': 'application/json'"))
        XCTAssertEqual(block.components(separatedBy: "noAuth: true").count - 1, 2)
    }

    private func parse(compute: String, status: Int = 200, billing: String? = nil) -> ProviderSnapshot {
        var results = ["compute_points": ProbeResult(status: status, body: compute)]
        if let billing {
            results["billing"] = ProbeResult(status: 200, body: billing)
        }
        return AbacusParser.parse(results: results, now: now)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func providerScriptsURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    private func iso(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

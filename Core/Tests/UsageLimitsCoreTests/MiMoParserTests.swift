import XCTest
@testable import UsageLimitsCore

final class MiMoParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesBalanceAndMonthlyPlan() throws {
        let snapshot = MiMoParser.parse(results: [
            "balance": ProbeResult(status: 200, body: try fixture("mimo_balance")),
            "plan_detail": ProbeResult(status: 200, body: try fixture("mimo_plan_detail")),
            "plan_usage": ProbeResult(status: 200, body: try fixture("mimo_plan_usage")),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Token Plan Standard")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["monthly", "balance"])

        let monthly = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(monthly.label, "月度额度")
        XCTAssertEqual(try XCTUnwrap(monthly.usedPercent), 5.05, accuracy: 0.0001)
        XCTAssertEqual(monthly.remaining, 189_899_842)
        XCTAssertEqual(monthly.total, 200_000_000)
        XCTAssertEqual(monthly.resetsAt, utc("2026-09-30 23:59:59"))
        XCTAssertEqual(monthly.detail, "已用 10.10M / 200.00M credits")
        XCTAssertEqual(monthly.pinned, true)

        let balance = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(balance.label, "余额")
        XCTAssertEqual(balance.amount, 50)
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.detail, "付费 $30.00 · 赠送 $20.00")
        XCTAssertEqual(balance.pinned, true)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testPublishedRatioUsesZeroToOneSemantics() throws {
        let balance = try fixture("mimo_balance")
        for (ratio, expected) in [(0.0, 0.0), (0.005, 0.5), (1.0, 100.0), (1.5, 100.0)] {
            let usage = #"{"code":0,"data":{"monthUsage":{"items":[{"name":"month_total_token","used":1,"limit":10,"percent":\#(ratio)}]}}}"#
            let snapshot = MiMoParser.parse(results: [
                "balance": ProbeResult(status: 200, body: balance),
                "plan_usage": ProbeResult(status: 200, body: usage),
            ], now: now)
            XCTAssertEqual(try XCTUnwrap(snapshot.metrics.first?.usedPercent), expected, accuracy: 0.0001)
        }
    }

    func testExpiredPlanDoesNotCreateCurrentUsage() throws {
        let snapshot = MiMoParser.parse(results: [
            "balance": ProbeResult(status: 200, body: try fixture("mimo_balance")),
            "plan_detail": ProbeResult(status: 200, body: try fixture("mimo_plan_expired")),
            "plan_usage": ProbeResult(status: 200, body: try fixture("mimo_plan_usage")),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["balance"])
    }

    func testOptionalFailuresDoNotSuppressValidBalance() throws {
        let balance = try fixture("mimo_balance")
        for optional in [
            ProbeResult(status: 403, body: ""),
            ProbeResult(status: 503, body: ""),
            ProbeResult(status: -3, body: "timeout"),
            ProbeResult(status: 200, body: #"{"code":401,"message":"expired"}"#),
        ] {
            let snapshot = MiMoParser.parse(results: [
                "balance": ProbeResult(status: 200, body: balance),
                "plan_detail": optional,
                "plan_usage": optional,
            ], now: now)
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertEqual(snapshot.metrics.map(\.id), ["balance"])
        }
    }

    func testBalanceHTTPAndEnvelopeAuthStatusTiers() {
        for status in [302, 307, 401, 403] {
            XCTAssertEqual(parseBalance("", status: status).status, .needsLogin)
        }
        for code in [302, 307, 401, 403] {
            XCTAssertEqual(parseBalance("{\"code\":\(code),\"message\":\"expired\"}").status, .needsLogin)
        }
        XCTAssertEqual(parseBalance("", status: 503).status, .error("HTTP 503"))
        XCTAssertEqual(parseBalance("timeout", status: -3).status, .error("请求超时"))
        XCTAssertEqual(parseBalance(#"{"code":500,"message":"temporary"}"#).status, .error("余额数据异常：temporary"))
    }

    func testMissingBalanceAndEmptyResultsAreErrors() {
        XCTAssertEqual(
            MiMoParser.parse(results: ["plan_usage": ProbeResult(status: 200, body: "{}")], now: now).status,
            .error("未获取到余额响应")
        )
        XCTAssertEqual(MiMoParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
    }

    func testInvalidRequiredBalanceIsRejectedAndEncodable() {
        let bodies = [
            "not json",
            #"{"code":0,"data":{"balance":"NaN","currency":"USD"}}"#,
            #"{"code":0,"data":{"balance":"Infinity","currency":"USD"}}"#,
            #"{"code":0,"data":{"balance":"-1","currency":"USD"}}"#,
            #"{"code":0,"data":{"balance":"1","currency":"   "}}"#,
            #"{"code":0,"data":null}"#,
            #"{"code":"NaN","data":{"balance":"1","currency":"USD"}}"#,
            #"{"code":"Infinity","data":{"balance":"1","currency":"USD"}}"#,
            #"{"code":1e308,"data":{"balance":"1","currency":"USD"}}"#,
            #"{"code":false,"data":{"balance":"1","currency":"USD"}}"#,
            #"{"code":0,"data":{"balance":true,"currency":"USD"}}"#,
            #"{"code":0,"data":{"balance":1,"currency":"USD"}}"#,
        ]
        for body in bodies {
            let snapshot = parseBalance(body)
            XCTAssertEqual(snapshot.status, .error("余额数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testInvalidOptionalBalanceComponentsAreOmitted() {
        let bodies = [
            #"{"code":0,"data":{"balance":"25.51","currency":"USD","cashBalance":"Infinity","giftBalance":"-1"}}"#,
            #"{"code":0,"data":{"balance":"25.51","currency":"USD","cashBalance":"1e308","giftBalance":"1e308"}}"#,
        ]
        for body in bodies {
            let snapshot = parseBalance(body)
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertNil(snapshot.metrics.first?.detail)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testInvalidOptionalUsageNeverLeaksNonFiniteValues() throws {
        let balance = try fixture("mimo_balance")
        let badUsages = [
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":"NaN","limit":10,"percent":0.5}]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":1,"limit":"Infinity","percent":0.5}]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":-1,"limit":10,"percent":0.5}]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":1,"limit":10,"percent":"Infinity"}]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":true,"limit":10,"percent":0.5}]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":1,"limit":true,"percent":0.5}]}}}"#,
            #"{"code":0,"data":{"monthUsage":{"items":[{"used":1,"limit":10,"percent":false}]}}}"#,
        ]
        for usage in badUsages {
            let snapshot = MiMoParser.parse(results: [
                "balance": ProbeResult(status: 200, body: balance),
                "plan_usage": ProbeResult(status: 200, body: usage),
            ], now: now)
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertEqual(snapshot.metrics.map(\.id), ["balance"])
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testNativeNumericOptionalBalanceComponentsDoNotMasqueradeAsContractStrings() {
        let body = #"{"code":0,"data":{"balance":"25.51","currency":"USD","cashBalance":20,"giftBalance":true}}"#
        let snapshot = parseBalance(body)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.metrics.first?.detail)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testProbeRunsOptionalRequestsConcurrentlyWithoutRetriesUnderThirtySecondBudget() throws {
        let source = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static let mimo = probeHelper"))
        let end = try XCTUnwrap(source.range(of: "/// Qoder", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(block.contains("Promise.all(["), "三条 MiMo 请求必须并发，避免可选项串行吃掉全局 30 秒")
        XCTAssertTrue(block.contains("timeoutMs: 12000"), "balance 两次尝试合计需留出全局超时余量")
        XCTAssertEqual(block.components(separatedBy: "timeoutMs: 8000").count - 1, 1, "可选请求共用 8 秒 SIDE 预算")
        XCTAssertEqual(block.components(separatedBy: "retry: false").count - 1, 1, "两个可选请求必须共用不重试的 SIDE 配置")
        XCTAssertTrue(block.contains("__probe('/api/v1/balance', CORE)"))
        XCTAssertTrue(block.contains("__probe('/api/v1/tokenPlan/detail', SIDE)"))
        XCTAssertTrue(block.contains("__probe('/api/v1/tokenPlan/usage', SIDE)"))
    }

    func testInvalidPlanDateIsDroppedWithoutUsingLocalTimezone() throws {
        let bodies = [
            #"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"Infinity","expired":false}}"#,
            #"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"0001-01-01 00:00:00","expired":false}}"#,
        ]
        for detail in bodies {
            let snapshot = MiMoParser.parse(results: [
                "balance": ProbeResult(status: 200, body: try fixture("mimo_balance")),
                "plan_detail": ProbeResult(status: 200, body: detail),
                "plan_usage": ProbeResult(status: 200, body: try fixture("mimo_plan_usage")),
            ], now: now)
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertNil(snapshot.metrics.first?.resetsAt)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    private func parseBalance(_ body: String, status: Int = 200) -> ProviderSnapshot {
        MiMoParser.parse(results: ["balance": ProbeResult(status: status, body: body)], now: now)
    }

    private func providerScriptsURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    private func utc(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

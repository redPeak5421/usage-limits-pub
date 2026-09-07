import XCTest
@testable import UsageLimitsCore

final class LongCatParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loggedIn(_ extras: [String: ProbeResult]) throws -> [String: ProbeResult] {
        var results = extras
        results["user"] = ProbeResult(status: 200, body: try fixture("longcat_user"))
        return results
    }

    func testParsesActiveTokenPackAndFuelInStableOrder() throws {
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 200, body: try fixture("longcat_token_packs")),
            "fuel": ProbeResult(status: 200, body: try fixture("longcat_fuel")),
        ]), now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["token_pack", "fuel_packages"])

        let pack = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(pack.label, "Token 包")
        XCTAssertEqual(pack.usedPercent ?? -1, 2.425152, accuracy: 0.000001)
        XCTAssertNotEqual(pack.usedPercent, 99, "consumedRatio 与绝对值冲突时必须忽略")
        XCTAssertEqual(pack.remaining, 48_787_424)
        XCTAssertEqual(pack.total, 50_000_000)
        XCTAssertEqual(pack.detail, "已用 1.21M / 50.00M tokens")
        XCTAssertEqual(pack.pinned, true)

        let fuel = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(fuel.usedPercent, 25)
        XCTAssertEqual(fuel.remaining, 750)
        XCTAssertEqual(fuel.total, 1000)
        XCTAssertEqual(fuel.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(fuel.amount)
    }

    func testActiveLotWinsOverStaleTokenUsage() throws {
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 200, body: try fixture("longcat_token_packs")),
            "token_usage": ProbeResult(status: 200, body: try fixture("longcat_token_usage")),
        ]), now: now)

        XCTAssertEqual(snapshot.metrics.count, 1)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.label, "Token 包")
        XCTAssertEqual(metric.total, 50_000_000)
    }

    func testInactivePackFallsBackToAggregateUsageWithSameID() throws {
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 200, body: try fixture("longcat_token_packs_inactive")),
            "token_usage": ProbeResult(status: 200, body: try fixture("longcat_token_usage")),
        ]), now: now)

        XCTAssertEqual(snapshot.status, .ok)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.id, "token_pack")
        XCTAssertEqual(metric.label, "Token 额度")
        XCTAssertEqual(metric.usedPercent, 24)
        XCTAssertEqual(metric.remaining, 380_000)
        XCTAssertEqual(metric.total, 500_000)
        XCTAssertEqual(metric.detail, "已用 120.0K / 500.0K tokens")
        XCTAssertEqual(metric.pinned, true)
    }

    func testFallbackAcceptsFlatShapeAndDerivesUsedFromAvailable() throws {
        let body = #"{"code":200,"data":{"totalToken":"1000","availableToken":"750"}}"#
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "token_usage": ProbeResult(status: 200, body: body),
        ]), now: now)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.usedPercent, 25)
        XCTAssertEqual(metric.remaining, 750)
    }

    func testFuelWithoutTotalKeepsRemainingAndParsesLegacyDate() throws {
        let body = #"{"data":{"list":[{"availableToken":40,"expireTime":"2026-09-01 00:00:00"},{"availableToken":60,"expireTime":"2026-10-01T00:00:00Z"}]}}"#
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "fuel": ProbeResult(status: 200, body: body),
        ]), now: now)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.id, "fuel_packages")
        XCTAssertNil(metric.usedPercent)
        XCTAssertEqual(metric.remaining, 100)
        XCTAssertNil(metric.total)
        XCTAssertEqual(metric.amount, 100)
        XCTAssertEqual(metric.detail, "剩余 100 tokens")
        XCTAssertEqual(metric.resetsAt, iso("2026-09-01T00:00:00Z"))
        XCTAssertTrue(metric.hasUsage)
    }

    func testEnvelopeFallsBackToRootWhenDataIsMissing() {
        let snapshot = LongCatParser.parse(results: [
            "user": ProbeResult(status: 200, body: #"{"code":0,"userId":1}"#),
            "token_usage": ProbeResult(
                status: 200,
                body: #"{"code":0,"totalToken":10,"usedToken":2}"#
            ),
        ], now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.total, 10)
    }

    func testEnvelopeCodeRejectsMaliciousNumbersWithoutTrap() {
        for raw in ["NaN", "Infinity", "-Infinity", "1e100", "9223372036854775808", "200.5"] {
            let parsed = LongCatParser.envelope(["code": raw, "data": ["value": 1]])
            XCTAssertNil(parsed.code, "非法 code \(raw) 不得转换为 Int")
            XCTAssertNil(parsed.data, "非法 code \(raw) 应使信封不可用")
        }
    }

    func testEnvelopeCodeStillAcceptsLegalIntegers() {
        for (raw, expected) in [("0", 0), ("200", 200), ("401", 401)] {
            let parsed = LongCatParser.envelope(["code": raw, "data": ["value": 1]])
            XCTAssertEqual(parsed.code, expected)
            XCTAssertNotNil(parsed.data)
        }
    }

    func testInvalidTokenNumbersDoNotProduceMetricsOrUnencodableSnapshots() throws {
        let bodies = [
            #"{"code":0,"data":{"currentLot":{"status":"ACTIVE","totalToken":"Infinity","consumedToken":1}}}"#,
            #"{"code":0,"data":{"currentLot":{"status":"ACTIVE","totalToken":100,"consumedToken":"NaN"}}}"#,
            #"{"code":0,"data":{"currentLot":{"status":"ACTIVE","totalToken":100,"consumedToken":-1}}}"#,
        ]
        for body in bodies {
            let snapshot = LongCatParser.parse(results: try loggedIn([
                "token_packs": ProbeResult(status: 200, body: body),
            ]), now: now)
            XCTAssertEqual(snapshot.status, .error("未获取到用量数据"))
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testOverconsumptionNeverCreatesNegativeRemaining() throws {
        let body = #"{"code":0,"data":{"currentLot":{"status":"ACTIVE","totalToken":100,"consumedToken":200}}}"#
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 200, body: body),
        ]), now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 100)
        XCTAssertEqual(snapshot.metrics.first?.remaining, 0)
    }

    func testInvalidFuelNumbersAreDropped() throws {
        for value in [#""Infinity""#, "-1"] {
            let body = "{\"code\":0,\"data\":{\"totalQuota\":100,\"list\":[{\"availableToken\":\(value)}]}}"
            let snapshot = LongCatParser.parse(results: try loggedIn([
                "fuel": ProbeResult(status: 200, body: body),
            ]), now: now)
            XCTAssertEqual(snapshot.status, .error("未获取到用量数据"))
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testFuelSumAboveTotalOrOverflowIsDropped() throws {
        let bodies = [
            #"{"code":0,"data":{"totalQuota":100,"list":[{"availableToken":60},{"availableToken":50}]}}"#,
            #"{"code":0,"data":{"totalQuota":1e308,"list":[{"availableToken":1e308},{"availableToken":1e308}]}}"#,
        ]
        for body in bodies {
            let snapshot = LongCatParser.parse(results: try loggedIn([
                "fuel": ProbeResult(status: 200, body: body),
            ]), now: now)
            XCTAssertEqual(snapshot.status, .error("未获取到用量数据"))
            XCTAssertTrue(snapshot.metrics.isEmpty)
        }
    }

    func testUserEnvelopeUnauthorizedAndRedirectNeedLogin() {
        let envelope = LongCatParser.parse(results: [
            "user": ProbeResult(status: 200, body: #"{"code":401,"message":"expired"}"#),
        ], now: now)
        XCTAssertEqual(envelope.status, .needsLogin)

        let redirect = LongCatParser.parse(results: [
            "user": ProbeResult(status: 302, body: ""),
        ], now: now)
        XCTAssertEqual(redirect.status, .needsLogin)
    }

    func testUserFailuresPreserveServerAndTimeoutStatus() {
        XCTAssertEqual(LongCatParser.parse(results: [
            "user": ProbeResult(status: 503, body: "busy"),
        ], now: now).status, .error("HTTP 503"))
        XCTAssertEqual(LongCatParser.parse(results: [
            "user": ProbeResult(status: -3, body: "timeout"),
        ], now: now).status, .error("请求超时"))
    }

    func testUserFailureDropsQuotaMetrics() throws {
        let snapshot = LongCatParser.parse(results: [
            "user": ProbeResult(status: 401, body: ""),
            "token_packs": ProbeResult(status: 200, body: try fixture("longcat_token_packs")),
            "fuel": ProbeResult(status: 200, body: try fixture("longcat_fuel")),
        ], now: now)
        XCTAssertEqual(snapshot.status, .needsLogin)
        XCTAssertTrue(snapshot.metrics.isEmpty, "user 失败不得附带额度数字")
    }

    func testFuelDateOutOfRangeIsDropped() throws {
        let body = #"{"code":0,"data":{"totalQuota":1000,"list":[{"availableToken":750,"expireTime":-1},{"availableToken":0,"expireTime":"0001-01-01 00:00:00"}]}}"#
        let snapshot = LongCatParser.parse(results: try loggedIn([
            "fuel": ProbeResult(status: 200, body: body),
        ]), now: now)
        let fuel = try XCTUnwrap(snapshot.metrics.first { $0.id == "fuel_packages" })
        XCTAssertNil(fuel.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testLoggedInWithoutMetricsUsesQuotaFailureOrEmptyDataError() throws {
        let unauthorized = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 403, body: ""),
        ]), now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let serverError = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 200, body: #"{"code":0,"data":{}}"#),
            "token_usage": ProbeResult(status: 500, body: "busy"),
        ]), now: now)
        XCTAssertEqual(serverError.status, .error("HTTP 500"))

        let empty = LongCatParser.parse(results: try loggedIn([
            "token_packs": ProbeResult(status: 200, body: #"{"code":0,"data":{}}"#),
            "token_usage": ProbeResult(status: 200, body: #"{"code":0,"data":{}}"#),
        ]), now: now)
        XCTAssertEqual(empty.status, .error("未获取到用量数据"))
    }

    func testEmptyResultsAreError() {
        XCTAssertEqual(LongCatParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
    }

    func testEnvelopeBusinessCodeDoesNotSurfaceRawServerMessage() throws {
        let snapshot = LongCatParser.parse(results: [
            "user": ProbeResult(status: 200, body: #"{"code":1001,"message":"user@example.com","data":{}}"#),
        ], now: now)
        XCTAssertEqual(snapshot.status, .error("LongCat code 1001"))
        if case .error(let raw) = snapshot.status {
            XCTAssertFalse(raw.contains("@"), "信封 message 不得成为错误文案")
        }
    }

    private func iso(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

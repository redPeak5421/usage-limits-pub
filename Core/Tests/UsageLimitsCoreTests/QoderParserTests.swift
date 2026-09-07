import XCTest
@testable import UsageLimitsCore

final class QoderParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesCamelCaseCredits() throws {
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("qoder_credits")),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.count, 1)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.id, "credits")
        XCTAssertEqual(metric.label, "Credits")
        XCTAssertEqual(metric.usedPercent, 25)
        XCTAssertEqual(metric.remaining, 375)
        XCTAssertEqual(metric.total, 500)
        XCTAssertEqual(metric.resetsAt, iso("2026-09-01T00:00:00Z"))
        XCTAssertEqual(metric.detail, "已用 125 / 500 credit")
        XCTAssertEqual(metric.pinned, true)
    }

    func testParsesSnakeCaseWithoutScalingPublishedPercent() throws {
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("qoder_credits_snake")),
        ], now: now)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.usedPercent, 0.5)
        XCTAssertEqual(metric.remaining, 199)
        XCTAssertEqual(metric.resetsAt, Date(timeIntervalSince1970: 1_788_220_800))
    }

    func testMergesSharedQuotaAndRecomputesPercent() throws {
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("qoder_credits_shared")),
        ], now: now)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.usedPercent, 68)
        XCTAssertEqual(metric.remaining, 800)
        XCTAssertEqual(metric.total, 2500)
        XCTAssertEqual(metric.detail, "已用 1700 / 2500 credit")
    }

    func testMergedZeroQuotaDefaultsToOneHundredIgnoringPoolPercentages() throws {
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("qoder_credits_shared_zero")),
        ], now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 100)
    }

    func testIntermediateEpochValueUsesQoderMillisecondThreshold() throws {
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("qoder_credits_epoch_millis")),
        ], now: now)
        XCTAssertEqual(snapshot.metrics.first?.resetsAt, Date(timeIntervalSince1970: 50_000_000))
    }

    func testNullSharedQuotaIsEquivalentToMissing() {
        let body = #"{"totalQuota":{"quotaSummary":{"usedValue":25,"limitValue":100,"remainingValue":75,"usagePercentage":25,"unit":"credit"}},"sharedQuota":null}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 25)
        XCTAssertEqual(snapshot.metrics.first?.total, 100)
    }

    func testZeroQuotaIsLegalAndDefaultsToExhausted() throws {
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("qoder_credits_zero")),
        ], now: now)
        XCTAssertEqual(snapshot.status, .ok)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.usedPercent, 100)
        XCTAssertEqual(metric.remaining, 0)
        XCTAssertEqual(metric.total, 0)
        XCTAssertTrue(metric.hasUsage)
    }

    func testMissingRemainingIsDerivedAndPositivePercentIsClamped() {
        let body = #"{"totalQuota":{"quotaSummary":{"usedValue":12,"limitValue":10,"usagePercentage":150}}}"#
        let snapshot = QoderParser.parse(results: [
            "credits": ProbeResult(status: 200, body: body),
        ], now: now)
        let metric = snapshot.metrics.first
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(metric?.remaining, 0)
        XCTAssertEqual(metric?.usedPercent, 100)
    }

    func testNegativeQuotaFieldsAreRejected() {
        for key in ["usedValue", "limitValue", "remainingValue"] {
            var summary = ["usedValue": 1.0, "limitValue": 10.0, "remainingValue": 9.0]
            summary[key] = -1
            let body = json(["totalQuota": ["quotaSummary": summary]])
            let snapshot = QoderParser.parse(results: [
                "credits": ProbeResult(status: 200, body: body),
            ], now: now)
            XCTAssertEqual(snapshot.status, .error("配额数据异常"), "\(key) 为负应失败")
            XCTAssertTrue(snapshot.metrics.isEmpty)
        }
    }

    func testNegativePercentAndInconsistentZeroLimitAreRejected() {
        let negativePercent = #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":10,"remainingValue":10,"usagePercentage":-1}}}"#
        XCTAssertEqual(parse(negativePercent).status, .error("配额数据异常"))

        let inconsistentZero = #"{"totalQuota":{"quotaSummary":{"usedValue":1,"limitValue":0,"remainingValue":0}}}"#
        XCTAssertEqual(parse(inconsistentZero).status, .error("配额数据异常"))
    }

    func testNonFiniteQuotaFieldsAreRejected() {
        let bodies = [
            #"{"totalQuota":{"quotaSummary":{"usedValue":"Infinity","limitValue":10,"remainingValue":0}}}"#,
            #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":"NaN","remainingValue":0}}}"#,
            #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":10,"remainingValue":"Infinity"}}}"#,
            #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":10,"remainingValue":10,"usagePercentage":"Infinity"}}}"#,
        ]
        for body in bodies {
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .error("配额数据异常"))
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testSharedPoolAdditionOverflowIsRejected() {
        let body = #"{"totalQuota":{"quotaSummary":{"usedValue":1e308,"limitValue":1e308,"remainingValue":0}},"sharedQuota":{"quotaSummary":{"usedValue":1e308,"limitValue":1e308,"remainingValue":0}}}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .error("配额数据异常"))
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testNonFiniteResetEpochIsDropped() {
        let body = #"{"nextResetAt":"Infinity","totalQuota":{"quotaSummary":{"usedValue":1,"limitValue":10,"remainingValue":9}}}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.metrics.first?.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testMalformedShapeIsQuotaError() {
        XCTAssertEqual(parse(#"{"totalQuota":{}}"#).status, .error("配额数据异常"))
        XCTAssertEqual(parse("<html>not json</html>").status, .error("配额数据异常"))
    }

    func testHTTPAndEmptyResultStatusTiers() {
        XCTAssertEqual(parse("", status: 401).status, .needsLogin)
        XCTAssertEqual(parse("", status: 503).status, .error("HTTP 503"))
        XCTAssertEqual(parse("timeout", status: -3).status, .error("请求超时"))
        XCTAssertEqual(QoderParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
    }

    private func parse(_ body: String, status: Int = 200) -> ProviderSnapshot {
        QoderParser.parse(results: ["credits": ProbeResult(status: status, body: body)], now: now)
    }

    private func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func iso(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

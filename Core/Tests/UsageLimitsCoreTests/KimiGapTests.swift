import XCTest
@testable import UsageLimitsCore

final class KimiGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    /// `enabled: false` 的 5h fallback 不能编造频限条。
    func testDisabledFiveHourFallbackIsIgnored() {
        let stats = #"{"ratelimitCode5h":{"enabled":false,"ratio":0.4,"resetTime":1766003600}}"#
        let snap = KimiParser.parse(results: ["stats": ProbeResult(status: 200, body: stats)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "five_hour" })
    }

    /// 缺 ratio / 重置时间时不能默认 0%。
    func testMissingFiveHourRatioDoesNotDefaultToZero() {
        let stats = #"{"ratelimitCode5h":{"enabled":true}}"#
        let snap = KimiParser.parse(results: ["stats": ProbeResult(status: 200, body: stats)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "five_hour" })
    }

    /// 有启用标记和 ratio 时才产出 5h。
    func testEnabledFiveHourFallbackKeepsRatio() {
        let stats = #"{"ratelimitCode5h":{"enabled":true,"ratio":0.25,"resetTime":1766003600}}"#
        let snap = KimiParser.parse(results: ["stats": ProbeResult(status: 200, body: stats)], now: now)
        let five = snap.metrics.first { $0.id == "five_hour" }
        XCTAssertEqual(five?.usedPercent, 25)
        XCTAssertNotNil(five?.resetsAt)
    }

    func testUserUnauthorizedDropsUsageMetrics() {
        let usages = #"{"usages":[{"scope":"CODING","detail":{"used":1,"remaining":9,"limit":10}}]}"#
        let stats = #"{"ratelimitCode5h":{"enabled":true,"ratio":0.4,"resetTime":1766003600}}"#
        let snap = KimiParser.parse(results: [
            "user": ProbeResult(status: 401, body: ""),
            "usages": ProbeResult(status: 200, body: usages),
            "stats": ProbeResult(status: 200, body: stats),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty, "user 401 即使 usages/stats 200 也须整轮 needsLogin，不得留下用量")
        XCTAssertNil(snap.metrics.first { $0.id == "five_hour" })
    }

}

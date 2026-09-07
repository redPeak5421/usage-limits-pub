import XCTest
@testable import UsageLimitsCore

final class MiniMaxGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testUnknownTextModelEmitsWeeklyFromFields() {
        let remains = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"custom-text-v1","current_interval_used_percent":"10%",
           "current_weekly_used_percent":"20%","weekly_end_time":1766600000}
        ]}
        """
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 200, body: remains)], now: now)
        XCTAssertNotNil(snap.metrics.first { $0.id == "model_custom_text_v1" })
        let weekly = snap.metrics.first { $0.id == "model_custom_text_v1_weekly" }
        XCTAssertEqual(weekly?.usedPercent, 20)
    }

    func testVideoChannelDoesNotEmitWeeklyEvenWithWeeklyFields() {
        let remains = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"video","current_interval_used_percent":"8%",
           "current_weekly_used_percent":"30%"}
        ]}
        """
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 200, body: remains)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id.contains("weekly") })
    }

    func testGlobalDoesNotApplyDomesticListPriceCycleOrHardcodedCNY() {
        let billing = #"{"todayTokens":0,"last30Tokens":0,"last30Cash":12.5}"#
        let remains = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_used_percent":"1%"}]}"#
        let snap = MiniMaxParser.parse(
            results: [
                "remains": ProbeResult(status: 200, body: remains),
                "billing": ProbeResult(status: 200, body: billing),
            ],
            now: now,
            provider: .minimaxGlobal
        )
        XCTAssertEqual(snap.provider, .minimaxGlobal)
        XCTAssertNil(snap.billingCycle, "国际站没有国内价目表，不得回填 monthly")
        XCTAssertEqual(snap.metrics.first { $0.id == "last_30d_cash" }?.currency, "USD")
    }

    func testWeeklyEndTimeAloneDoesNotInventWeeklyPercent() {
        let remains = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"minimax-m2","weekly_end_time":1766600000}
        ]}
        """
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 200, body: remains)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id.contains("weekly") }, "只有 weekly_end_time 不得编百分比")
    }

    func testWeeklyRemainsTimeSetsResetsAtWhenEndTimeMissing() {
        let remains = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"minimax-m2","current_weekly_used_percent":"20%","weekly_remains_time":3600000}
        ]}
        """
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 200, body: remains)], now: now)
        let weekly = snap.metrics.first { $0.id == "model_minimax_m2_weekly" }
        XCTAssertEqual(weekly?.usedPercent, 20)
        XCTAssertEqual(weekly?.resetsAt?.timeIntervalSince(now) ?? -1, 3600, accuracy: 1)
    }


    func testRemainsSessionExpiredDropsAlreadyParsedCreditMetrics() {
        let remains = #"{"base_resp":{"status_code":1004,"status_msg":"login required"}}"#
        let credit = #"{"base_resp":{"status_code":0},"remaining_credits":12,"total_credits":20,"used_credits":8}"#
        let billing = #"{"todayTokens":10,"last30Tokens":100,"last30Cash":12.5}"#
        let summary = #"{"total_token_consumed":"1.2k","active_days":3}"#
        let snap = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: remains),
            "credit": ProbeResult(status: 200, body: credit),
            "billing": ProbeResult(status: 200, body: billing),
            "usage_summary": ProbeResult(status: 200, body: summary),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty, "remains 1004 不得留下积分/账单/累计调用")
        XCTAssertNil(snap.metrics.first { $0.id == "credits" })
        XCTAssertNil(snap.metrics.first { $0.id == "lifetime_tokens" })
        XCTAssertNil(snap.metrics.first { $0.id == "last_30d_cash" })
    }

    func testRemainsHTTPUnauthorizedDropsAlreadyParsedCreditMetrics() {
        let credit = #"{"base_resp":{"status_code":0},"remaining_credits":12,"total_credits":20,"used_credits":8}"#
        let billing = #"{"todayTokens":10,"last30Tokens":100,"last30Cash":12.5}"#
        let summary = #"{"total_token_consumed":"1.2k","active_days":3}"#
        for status in [401, 403] {
            let snap = MiniMaxParser.parse(results: [
                "remains": ProbeResult(status: status, body: "unauthorized"),
                "credit": ProbeResult(status: 200, body: credit),
                "billing": ProbeResult(status: 200, body: billing),
                "usage_summary": ProbeResult(status: 200, body: summary),
            ], now: now)
            XCTAssertEqual(snap.status, .needsLogin, "remains HTTP \(status) 应赢 leftover")
            XCTAssertTrue(snap.metrics.isEmpty, "remains HTTP \(status) 不得留下积分/账单/累计调用")
        }
    }

    func testRemainsServerErrorKeepsSuccessfulCreditMetrics() {
        let credit = #"{"base_resp":{"status_code":0},"remaining_credits":12,"total_credits":20,"used_credits":8}"#
        let snap = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 500, body: "oops"),
            "credit": ProbeResult(status: 200, body: credit),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "remains 5xx 不是会话失效，合法 credit 仍可证明登录")
        XCTAssertNotNil(snap.metrics.first { $0.id == "credits" })
    }

    func testUnlimitedWindowOmitsZeroPercent() {
        let remains = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"minimax-m2","current_weekly_status":3,
           "current_weekly_remaining_percent":"100%","current_weekly_total_count":1}
        ]}
        """
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 200, body: remains)], now: now)
        let weekly = snap.metrics.first { $0.id.contains("weekly") }
        XCTAssertEqual(weekly?.detail, "无限制")
        XCTAssertNil(weekly?.usedPercent, "无限制不得画 0% 环")
    }

}

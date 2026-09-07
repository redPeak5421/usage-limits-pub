import XCTest
@testable import UsageLimitsCore

/// 对齐 CodexBar 的 Cursor 缺口：Total 抬头、个人上限 / 团队共享池 / 按需超额、
/// 美元口径、旧版请求制套餐切换、Grok Bot 窗口长度、套餐映射、状态分流。
final class CursorGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - C8 Total 抬头 + C6 美元 detail

    /// totalPercentUsed 在场时排第一条并作为折叠摘要；两个池条补「已用 $x / $y」。
    func testTotalHeadlineIsFirstAndCollapsedSummary() throws {
        let snap = CursorParser.parse(
            results: ["usage_summary": ProbeResult(status: 200, body: try fixture("cursor_usage_summary"))],
            now: now
        )
        let total = try XCTUnwrap(snap.metrics.first)
        XCTAssertEqual(total.id, "total")
        XCTAssertEqual(total.label, "Total")
        XCTAssertEqual(total.usedPercent, 1)
        XCTAssertEqual(total.pinned, true)
        XCTAssertNotNil(total.resetsAt)
        XCTAssertEqual(snap.collapsedMetric?.id, "total", "并列重置时间时折叠摘要取排在最前的 Total")
        XCTAssertEqual(snap.metrics.map(\.id), ["total", "cursor_models", "other_models"])
        // 249 分 = $2.49，20000 分 = $200.00
        XCTAssertEqual(snap.metrics.first { $0.id == "cursor_models" }?.detail, "已用 $2.49 / $200.00")
        XCTAssertEqual(snap.metrics.first { $0.id == "other_models" }?.detail, "已用 $2.49 / $200.00")
        XCTAssertNil(snap.metrics.first { $0.id == "cursor_models" }?.amount,
                     "百分比条不设 amount，避免改折叠卡摘要形状")
    }

    // MARK: - C3 / C4 / C5 / C7 团队与按需池

    /// Enterprise 成员：plan 池缺失 → Included 回落到 individualUsage.overall；
    /// 团队共享池单列；两条 on-demand 都是「无上限但花过钱」的形态，不能丢。
    func testTeamShapeFallsBackToOverallAndExposesPools() throws {
        let snap = CursorParser.parse(
            results: ["usage_summary": ProbeResult(status: 200, body: try fixture("cursor_usage_summary_team"))],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Cursor Enterprise")

        let included = try XCTUnwrap(snap.metrics.first { $0.id == "included" })
        XCTAssertEqual(included.usedPercent, 25, "1250 / 5000 分")
        XCTAssertEqual(included.detail, "已用 $12.50 / $50.00")

        let pooled = try XCTUnwrap(snap.metrics.first { $0.id == "team_pooled" })
        XCTAssertEqual(pooled.label, "Team pooled")
        XCTAssertEqual(pooled.usedPercent, 12)
        XCTAssertEqual(try XCTUnwrap(pooled.amount), 120, accuracy: 0.001)
        XCTAssertEqual(pooled.currency, "USD")
        XCTAssertEqual(pooled.detail, "上限 $1000.00")

        let onDemand = try XCTUnwrap(snap.metrics.first { $0.id == "on_demand" })
        XCTAssertNil(onDemand.usedPercent, "无上限就没有百分比可画")
        XCTAssertEqual(try XCTUnwrap(onDemand.amount), 6.4, accuracy: 0.001)
        XCTAssertEqual(onDemand.detail, "无上限")

        let teamOnDemand = try XCTUnwrap(snap.metrics.first { $0.id == "team_on_demand" })
        XCTAssertEqual(teamOnDemand.label, "Team on-demand")
        XCTAssertEqual(try XCTUnwrap(teamOnDemand.amount), 3.2, accuracy: 0.001)
        XCTAssertEqual(teamOnDemand.detail, "无上限")
    }

    /// 有上限的 on-demand 既出百分比也出金额。
    func testOnDemandWithLimitCarriesPercentAndAmount() throws {
        let body = #"""
        {"membershipType":"pro","billingCycleEnd":"2026-09-03T00:00:00.000Z",
         "individualUsage":{"plan":{"totalPercentUsed":80,"used":8,"limit":10},
                            "onDemand":{"enabled":true,"used":250,"limit":1000,"remaining":750}}}
        """#
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        let onDemand = try XCTUnwrap(snap.metrics.first { $0.id == "on_demand" })
        XCTAssertEqual(onDemand.usedPercent, 25)
        XCTAssertEqual(try XCTUnwrap(onDemand.amount), 2.5, accuracy: 0.001)
        XCTAssertEqual(onDemand.detail, "已用 $2.50 / $10.00")
        XCTAssertNil(snap.metrics.first { $0.id == "total" }, "池字段缺失时 Included 就是总量，不再重复出 Total")
    }

    // MARK: - C1 / C2 旧版请求制套餐

    /// /api/usage?user= 给出 maxRequestUsage → 整卡换成请求配额口径，
    /// 隐藏 token 计费的 Total / Cursor Models / Other Models / Grok Bot。
    func testLegacyRequestPlanSwitchesDisplay() throws {
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: try fixture("cursor_usage_summary")),
                "auth_me": ProbeResult(status: 200, body: try fixture("cursor_auth_me")),
                "request_usage": ProbeResult(status: 200, body: try fixture("cursor_request_usage")),
                "sand_usage_status": ProbeResult(status: 200, body: try fixture("cursor_sand_usage_status")),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        let requests = try XCTUnwrap(snap.metrics.first)
        XCTAssertEqual(requests.id, "requests")
        XCTAssertEqual(requests.label, "Requests")
        XCTAssertEqual(requests.usedPercent, 64)
        XCTAssertEqual(requests.remaining, 180)
        XCTAssertEqual(requests.total, 500)
        XCTAssertEqual(requests.detail, "320 / 500 requests")
        XCTAssertEqual(requests.pinned, true)
        XCTAssertNotNil(requests.resetsAt)
        for hidden in ["total", "cursor_models", "other_models", "grok_bot"] {
            XCTAssertNil(snap.metrics.first { $0.id == hidden }, "\(hidden) 是 token 计费口径，不该与请求配额并列")
        }
    }

    /// maxRequestUsage 为 null（现行套餐）时不切换口径。
    func testNullMaxRequestUsageKeepsTokenMetrics() throws {
        let legacy = #"{"gpt-4":{"numRequests":3,"maxRequestUsage":null},"startOfMonth":"2026-08-03T00:00:00.000Z"}"#
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: try fixture("cursor_usage_summary")),
                "request_usage": ProbeResult(status: 200, body: legacy),
            ],
            now: now
        )
        XCTAssertNil(snap.metrics.first { $0.id == "requests" })
        XCTAssertEqual(snap.metrics.first?.id, "total")
    }

    /// auth_me 只作登录佐证：sub 之外的身份字段一律不进快照。
    func testAuthMeOnlyProvesLoginAndLeaksNoIdentity() throws {
        let snap = CursorParser.parse(
            results: [
                "auth_me": ProbeResult(status: 200, body: try fixture("cursor_auth_me")),
                "usage_summary": ProbeResult(status: 500, body: "boom"),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName)
        let dumped = snap.metrics.map { "\($0.id)|\($0.label)|\($0.detail ?? "")" }.joined()
        XCTAssertFalse(dumped.contains("example.com"))
        XCTAssertFalse(dumped.contains("user_"))
    }

    // MARK: - C10 Grok Bot 窗口长度

    func testGrokBotWindowLengthInDetail() throws {
        let summary = #"{"membershipType":"ultra","individualUsage":{"plan":{"autoPercentUsed":5,"apiPercentUsed":76}}}"#
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: summary),
                "sand_usage_status": ProbeResult(status: 200, body: try fixture("cursor_sand_usage_status")),
            ],
            now: now
        )
        let bot = try XCTUnwrap(snap.metrics.first { $0.id == "grok_bot" })
        XCTAssertEqual(bot.detail, "7 天窗口")
    }

    // MARK: - C12 套餐映射

    func testPlanMappingsAddedFromCodexBar() {
        for (raw, expected) in [
            ("express", "Cursor Start"),
            ("hobby", "Cursor Hobby"),
            ("pro_student", "Cursor Pro"),
            ("ultra", "Cursor Ultra"),
        ] {
            let body = "{\"membershipType\":\"\(raw)\"}"
            let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
            XCTAssertEqual(snap.planName, expected, "membershipType=\(raw)")
        }
    }

    // MARK: - C14 状态分流

    func testUnauthorizedVersusServerError() {
        let unauthorized = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 403, body: "")], now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let serverError = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 500, body: "oops")], now: now)
        XCTAssertEqual(serverError.status, .error("HTTP 500"), "5xx 不该催用户重新登录")

        let timeout = CursorParser.parse(
            results: ["usage_summary": ProbeResult(status: -3, body: "timeout after 12000ms")], now: now
        )
        XCTAssertEqual(timeout.status, .error("请求超时"))
    }


    func testUsageSummaryUnauthorizedWinsOverAuthMe() {
        let snap = CursorParser.parse(
            results: [
                "auth_me": ProbeResult(status: 200, body: #"{"hasSub":true}"#),
                "usage_summary": ProbeResult(status: 401, body: "no"),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testNullPoolPercentsDoNotCountAsPools() {
        let body = """
        {"membershipType":"pro","individualUsage":{"plan":{
          "autoPercentUsed":null,"apiPercentUsed":null,"totalPercentUsed":12,"used":100,"limit":1000
        }}}
        """
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "cursor_models" })
        XCTAssertNil(snap.metrics.first { $0.id == "other_models" })
        XCTAssertEqual(snap.metrics.first { $0.id == "included" }?.usedPercent, 12)
    }

    func testDisabledOnDemandSpendIsDropped() {
        let body = """
        {"membershipType":"pro","individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":20},"onDemand":{"enabled":false,"used":500,"limit":1000}}}
        """
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "on_demand" })
        XCTAssertNotNil(snap.metrics.first { $0.id == "cursor_models" })
    }


    func testDisabledPlanPoolFallsBackToOverall() throws {
        let body = """
        {"membershipType":"pro","billingCycleEnd":"2026-09-03T00:00:00.000Z",
         "individualUsage":{
           "plan":{"enabled":false,"autoPercentUsed":10,"apiPercentUsed":20,"used":100,"limit":1000},
           "overall":{"enabled":true,"used":1250,"limit":5000}
         }}
        """
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "total" })
        XCTAssertNil(snap.metrics.first { $0.id == "cursor_models" })
        XCTAssertNil(snap.metrics.first { $0.id == "other_models" })
        let included = try XCTUnwrap(snap.metrics.first { $0.id == "included" })
        XCTAssertEqual(included.usedPercent, 25)
        XCTAssertEqual(included.detail, "已用 $12.50 / $50.00")
    }

}

import XCTest
@testable import UsageLimitsCore

/// 2026-08 对齐 CodexBar 的 claude.ai 补齐项：org 三级选择、/api/account 套餐档、
/// 别名窗口、未知窗口自适应、weekly_scoped 的全模型过滤与 model.id、
/// five_hour 钉住、Extra usage / 预充值金额、401 与 5xx 分级。
final class ClaudeGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 套餐档梯

    func testPlanLadderGenericMaxMultiplier() {
        func plan(_ tier: String) -> String? {
            ClaudeParser.planName(rateLimitTier: tier, billingType: nil, seatTier: nil, capabilities: [])
        }
        XCTAssertEqual(plan("default_claude_max_5x"), "Claude Max 5x")
        XCTAssertEqual(plan("max_20x"), "Claude Max 20x")
        // 官网将来加新档也不用改代码
        XCTAssertEqual(plan("default_claude_max_10x"), "Claude Max 10x")
        XCTAssertEqual(plan("claude_max"), "Claude Max", "没有倍率就是裸 Max")
        XCTAssertEqual(plan("default_claude_pro"), "Claude Pro")
        XCTAssertEqual(plan("claude_team"), "Claude Team")
        XCTAssertEqual(plan("enterprise_tier"), "Claude Enterprise")
        XCTAssertEqual(plan("claude_ultra"), "Claude Ultra")
        XCTAssertEqual(plan("free_tier"), "Claude Free")
        XCTAssertNil(plan(""), "拿不到 tier 时由调用方决定兜底")
    }

    func testPlanSeatTierRefinesTeam() {
        func plan(tier: String?, seat: String?) -> String? {
            ClaudeParser.planName(rateLimitTier: tier, billingType: nil, seatTier: seat, capabilities: [])
        }
        XCTAssertEqual(plan(tier: "claude_team", seat: "team_standard"), "Claude Team Standard")
        XCTAssertEqual(plan(tier: "claude_team", seat: "team_tier_1"), "Claude Team Premium")
        XCTAssertEqual(plan(tier: nil, seat: "team_standard"), "Claude Team Standard",
                       "tier 缺失也能靠 seat_tier 定档")
        XCTAssertEqual(plan(tier: "claude_max_5x", seat: "team_standard"), "Claude Max 5x",
                       "非 Team 的 tier 不得被 seat_tier 顶掉")
    }

    func testPlanStripeFallbackIsPro() {
        XCTAssertEqual(
            ClaudeParser.planName(rateLimitTier: "claude_something_new", billingType: "stripe",
                                  seatTier: nil, capabilities: []),
            "Claude Pro"
        )
        XCTAssertNil(
            ClaudeParser.planName(rateLimitTier: "something_new", billingType: "stripe",
                                  seatTier: nil, capabilities: []),
            "tier 里没有 claude 就不该硬猜成 Pro"
        )
    }

    func testTeamSeatPricesInCatalog() {
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Team Standard"), "$30")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Team Standard", billingCycle: .yearly), "$300")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Team Premium"), "$150")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Team Premium", billingCycle: .yearly), "$1500")
        XCTAssertNil(PlanCatalog.listPrice(planName: "Claude Enterprise"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "Claude Ultra"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "Claude Team"))
    }

    /// /api/account 的 membership 比 organizations 的 rate_limit_tier 更权威：
    /// fixture 里 organizations 是 max_5x，account 里同 uuid 的 org 是 max_20x。
    func testAccountMembershipOverridesOrganizationsPlan() throws {
        let snap = ClaudeParser.parse(
            results: [
                "organizations": ProbeResult(status: 200, body: try fixture("claude_organizations")),
                "account": ProbeResult(status: 200, body: try fixture("claude_account")),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Claude Max 20x")
    }

    /// 选不到同 uuid 的 membership 时取第一条（此处 seat_tier = team_standard）。
    func testAccountFallsBackToFirstMembership() throws {
        let snap = ClaudeParser.parse(
            results: ["account": ProbeResult(status: 200, body: try fixture("claude_account"))],
            now: now
        )
        XCTAssertEqual(snap.status, .ok, "account 2xx 且解析出 membership 也是登录证据")
        XCTAssertEqual(snap.planName, "Claude Team Standard")
    }

    // MARK: - org 选择

    /// 只有一个非 chat org 且它是纯 API 工作区时，必须跳过它选下一个，
    /// 否则 usage 探针会打到拿不到数据的 org 上。
    func testOrgSelectionSkipsAPIOnlyWorkspace() throws {
        let orgs = #"""
        [{"uuid":"api-org","name":"API","capabilities":["api"]},
         {"uuid":"real-org","name":"Personal","capabilities":["claude_pro"],"rate_limit_tier":"default_claude_pro"}]
        """#
        let snap = ClaudeParser.parse(results: ["organizations": ProbeResult(status: 200, body: orgs)], now: now)
        XCTAssertEqual(snap.planName, "Claude Pro", "选中的应是非纯 API 的那个 org")
        let picked = try XCTUnwrap(ClaudeParser.selectOrg(
            try XCTUnwrap(JSONHelp.array(orgs)).compactMap { $0 as? [String: Any] }
        ))
        XCTAssertEqual(picked["uuid"] as? String, "real-org")
    }

    func testOrgSelectionPrefersChatCapability() throws {
        let orgs = #"""
        [{"uuid":"api-org","capabilities":["api","claude_max"]},
         {"uuid":"chat-org","capabilities":["chat"],"rate_limit_tier":"claude_max_5x"}]
        """#
        let picked = try XCTUnwrap(ClaudeParser.selectOrg(
            try XCTUnwrap(JSONHelp.array(orgs)).compactMap { $0 as? [String: Any] }
        ))
        XCTAssertEqual(picked["uuid"] as? String, "chat-org")
    }

    // MARK: - 窗口

    func testRoutinesAndCoworkAliases() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_extra"))],
            now: now
        )
        let routines = try XCTUnwrap(snap.metrics.first { $0.id == "routines" })
        XCTAssertEqual(routines.label, "Daily Routines")
        XCTAssertEqual(routines.usedPercent, 12)
        let cowork = try XCTUnwrap(snap.metrics.first { $0.id == "cowork" })
        XCTAssertEqual(cowork.label, "Cowork")
        XCTAssertEqual(cowork.usedPercent, 3)
    }

    /// 别名列表按序取第一个存在的键，不重复产出两行。
    func testRoutinesAliasFirstKeyWins() {
        let usage = #"""
        {"seven_day_routines":{"utilization":9,"resets_at":"2026-08-19T08:59:59Z"},
         "claude_routines":{"utilization":77,"resets_at":"2026-08-19T08:59:59Z"},
         "routines":{"utilization":88,"resets_at":"2026-08-19T08:59:59Z"}}
        """#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.filter { $0.id == "routines" }.count, 1)
        XCTAssertEqual(snap.metrics.first { $0.id == "routines" }?.usedPercent, 9)
    }

    func testOAuthAppsAlias() {
        let usage = #"{"seven_day_oauth_apps":{"utilization":5,"resets_at":"2026-08-19T08:59:59Z"}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        let m = snap.metrics.first { $0.id == "oauth_apps" }
        XCTAssertEqual(m?.label, "OAuth apps")
        XCTAssertEqual(m?.usedPercent, 5)
    }

    /// 未知窗口自适应：{0%, resets_at: null} 是占位键要丢掉，
    /// {0%, 有 resets_at} 或 {>0%} 才是真窗口。
    func testUnknownWindowAdaptiveInclusion() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_extra"))],
            now: now
        )
        XCTAssertNil(snap.metrics.first { $0.id == "nimbus_quill" }, "0% + resets_at null 的占位键不得入表")
        let amber = try XCTUnwrap(snap.metrics.first { $0.id == "amber_ladder" })
        XCTAssertEqual(amber.label, "Amber ladder", "键名人类化：下划线转空格 + 首字母大写")
        XCTAssertEqual(amber.usedPercent, 0)
    }

    /// 原生 0...100：`1` / `0.5` 就是 1% / 0.5%，不能被 ratio 逻辑放大。

    func testLoneZeroUtilizationPlaceholderIsDroppedByFallback() {
        let usage = #"{"nimbus_quill":{"utilization":0,"resets_at":null}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "nimbus_quill" }, "单键 0% + null reset 兜底也不得入表")
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testNativeHundredPercentKeepsOneAndHalf() {
        let usage = #"{"five_hour":{"utilization":1,"resets_at":"2026-08-19T08:59:59Z"},"seven_day":{"utilization":0.5,"resets_at":"2026-08-26T08:59:59Z"}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.first { $0.id == "five_hour" }?.usedPercent, 1)
        XCTAssertEqual(snap.metrics.first { $0.id == "seven_day" }?.usedPercent, 0.5)
    }

    func testUnknownWindowWithUsageIsIncludedEvenWithoutReset() {
        let usage = #"{"tangelo":{"utilization":7,"resets_at":null}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.map(\.id), ["tangelo"])
        XCTAssertEqual(snap.metrics.first?.usedPercent, 7)
    }

    func testHumanizedStripsSevenDayPrefix() {
        XCTAssertEqual(ClaudeParser.humanized("seven_day_omelette"), "Omelette")
        XCTAssertEqual(ClaudeParser.humanized("nimbus_quill"), "Nimbus quill")
    }

    /// five_hour 存在即钉住：正在进行的会话窗口 0% 也要露出来。
    func testFiveHourPinnedEvenAtZero() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_extra"))],
            now: now
        )
        let five = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(five.usedPercent, 0)
        XCTAssertEqual(five.pinned, true)
        XCTAssertTrue(five.hasUsage, "钉住的窗口必须能出现在首页")
    }

    /// five_hour: null（企业 / 纯额度账号）→ 完全不产出会话行，
    /// 与「真 0%」区分开。
    func testNullFiveHourProducesNoSessionMetric() {
        let usage = #"{"five_hour":null,"seven_day":{"utilization":30,"resets_at":"2026-08-19T08:59:59Z"}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(snap.metrics.map(\.id), ["seven_day"])
    }

    // MARK: - weekly_scoped

    /// scope.model 是「全模型」时必须丢弃，否则与顶层 seven_day 重复成两行。
    func testWeeklyScopedAllModelsFiltered() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_extra"))],
            now: now
        )
        XCTAssertNil(snap.metrics.first { $0.id.hasPrefix("weekly_scoped_all") })
        XCTAssertNil(snap.metrics.first { $0.label == "All models" && $0.id != "seven_day" })
    }

    func testWeeklyScopedUsesModelIDSlug() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_extra"))],
            now: now
        )
        let scoped = try XCTUnwrap(snap.metrics.first { $0.id.hasPrefix("weekly_scoped_") })
        XCTAssertEqual(scoped.id, "weekly_scoped_claude-opus-4-6", "id 走 model.id 的 slug，展示名改了也不漂")
        XCTAssertEqual(scoped.label, "Claude Opus 4.6")
        XCTAssertEqual(scoped.usedPercent, 44)
    }

    /// 现网 model.id 为 null 时回落 display_name（保持既有 fixture 的 weekly_scoped_fable）。
    func testWeeklyScopedFallsBackToDisplayNameSlug() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_limits"))],
            now: now
        )
        XCTAssertNotNil(snap.metrics.first { $0.id == "weekly_scoped_fable" })
    }

    func testWeeklyScopedAllModelsFilteredByIDSuffix() {
        let usage = #"""
        {"limits":[{"kind":"weekly_scoped","group":"weekly","percent":50,"resets_at":"2026-08-19T08:59:59Z",
          "scope":{"model":{"id":"claude-4-all-models","display_name":"Everything"}}}]}
        """#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertTrue(snap.metrics.isEmpty, "model.id 以 -all-models 结尾的也要丢")
    }

    // MARK: - 金额

    func testInlineExtraUsageMetric() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_extra"))],
            now: now
        )
        let extra = try XCTUnwrap(snap.metrics.first { $0.id == "extra_usage" })
        XCTAssertEqual(extra.label, "Extra usage")
        XCTAssertEqual(extra.usedPercent, 25, "utilization 为 null 时按 used/limit 算")
        XCTAssertEqual(extra.amount, 10, "1000 分 = $10")
        XCTAssertEqual(extra.currency, "USD")
        XCTAssertEqual(extra.detail, "上限 $40")
    }

    /// 现网 fixture 里 extra_usage.is_enabled = false，不得产出金额行。
    func testDisabledExtraUsageProducesNothing() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_limits"))],
            now: now
        )
        XCTAssertNil(snap.metrics.first { $0.id == "extra_usage" })
    }

    /// usage 里没有 extra_usage 对象时才用 overage 探针补。
    func testOverageProbeFillsExtraUsage() throws {
        let snap = ClaudeParser.parse(
            results: [
                "usage": ProbeResult(status: 200, body: #"{"seven_day":{"utilization":10,"resets_at":"2026-08-19T08:59:59Z"}}"#),
                "overage": ProbeResult(status: 200, body: try fixture("claude_overage")),
            ],
            now: now
        )
        let extra = try XCTUnwrap(snap.metrics.first { $0.id == "extra_usage" })
        XCTAssertEqual(extra.usedPercent, 25)
        XCTAssertEqual(extra.amount, 12.5)
        XCTAssertEqual(extra.detail, "上限 $50")
    }

    /// usage 已经内联 extra_usage（哪怕是关闭态）时，overage 探针不参与，避免两个来源打架。
    func testInlineExtraUsageWinsOverOverageProbe() throws {
        let snap = ClaudeParser.parse(
            results: [
                "usage": ProbeResult(status: 200, body: try fixture("claude_usage_limits")),
                "overage": ProbeResult(status: 200, body: try fixture("claude_overage")),
            ],
            now: now
        )
        XCTAssertNil(snap.metrics.first { $0.id == "extra_usage" })
    }

    func testPrepaidCreditsMetric() throws {
        let snap = ClaudeParser.parse(
            results: [
                "organizations": ProbeResult(status: 200, body: try fixture("claude_organizations")),
                "prepaid": ProbeResult(status: 200, body: try fixture("claude_prepaid")),
            ],
            now: now
        )
        let credit = try XCTUnwrap(snap.metrics.first { $0.id == "prepaid_credits" })
        XCTAssertEqual(credit.label, "Usage credits")
        XCTAssertEqual(credit.amount, 25)
        XCTAssertEqual(credit.currency, "USD")
    }

    func testUnauthorizedIsNeedsLoginButServerErrorIsNot() {
        let unauthorized = ClaudeParser.parse(
            results: ["organizations": ProbeResult(status: 401, body: "no")],
            now: now
        )
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let server = ClaudeParser.parse(
            results: ["organizations": ProbeResult(status: 503, body: "down")],
            now: now
        )
        XCTAssertEqual(server.status, .error("HTTP 503"))
    }
}


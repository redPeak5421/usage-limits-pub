import XCTest
@testable import UsageLimitsCore

final class ParserTests: XCTestCase {
    /// 固定时间，保证断言可复现。
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Claude

    func testClaudeParsesUsageAndPlan() throws {
        let results: [String: ProbeResult] = [
            "organizations": ProbeResult(status: 200, body: try fixture("claude_organizations")),
            "usage": ProbeResult(status: 200, body: try fixture("claude_usage")),
        ]
        let snap = ClaudeParser.parse(results: results, now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Claude Max 5x")
        XCTAssertEqual(snap.billingCycle, .monthly)
        XCTAssertEqual(snap.metrics.count, 3)
        let fiveHour = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(fiveHour.usedPercent, 34)
        XCTAssertEqual(fiveHour.label, "Current session")
        XCTAssertNotNil(fiveHour.resetsAt)
    }

    /// 2026-08-16 真机报文：limits[] 里官网「Weekly limits」分 All models（weekly_all）
    /// 与按模型（weekly_scoped，scope.model.display_name = Fable）两条，须分开展示，
    /// 且 session / weekly_all 不得与顶层 five_hour / seven_day 重复；
    /// resets_at 为 6 位微秒小数，必须能解析出重置时间。
    func testClaudeLimitsSplitAllModelsAndScopedFable() throws {
        let snap = ClaudeParser.parse(
            results: ["usage": ProbeResult(status: 200, body: try fixture("claude_usage_limits"))],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.count, 3)
        let five = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(five.usedPercent, 18)
        XCTAssertNotNil(five.resetsAt, "微秒级 resets_at 应能截断解析")
        let weekly = try XCTUnwrap(snap.metrics.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.usedPercent, 22)
        XCTAssertEqual(weekly.label, "All models")
        let fable = try XCTUnwrap(snap.metrics.first { $0.id == "weekly_scoped_fable" })
        XCTAssertEqual(fable.usedPercent, 44)
        XCTAssertEqual(fable.label, "Fable")
        XCTAssertNotNil(fable.resetsAt)
    }

    /// iOS 内购订阅（billing 字段值含 apple/iap）应标记 billingSource=app_store，
    /// 卡片据此显示内购价（Max 20x $249.99 而非官网 $200）。
    func testClaudeAppStoreBillingDetected() {
        let orgs = #"[{"uuid":"u1","capabilities":["chat"],"rate_limit_tier":"claude_max_20x","billing_type":"apple_iap"}]"#
        let snap = ClaudeParser.parse(results: ["organizations": ProbeResult(status: 200, body: orgs)], now: now)
        XCTAssertEqual(snap.planName, "Claude Max 20x")
        XCTAssertEqual(snap.billingSource, "app_store")
    }

    func testClaudeWebBillingHasNoSource() {
        let orgs = #"[{"uuid":"u1","capabilities":["chat"],"rate_limit_tier":"claude_max_20x","billing_type":"stripe"}]"#
        let snap = ClaudeParser.parse(results: ["organizations": ProbeResult(status: 200, body: orgs)], now: now)
        XCTAssertNil(snap.billingSource)
    }

    /// 原生 0–100：`0.42` 就是 0.42%，不得再当 0–1 比例放大成 42%。
    func testClaudeFractionUtilizationStaysNativeHundred() {
        let usage = #"{"five_hour":{"utilization":0.42,"resets_at":"2026-08-16T12:30:00Z"}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.first?.usedPercent, 0.42)
    }

    /// 0–100 口径下 utilization=1 表示 1%，不得放大成 100%（订阅后 Current session 闪 100% 的根因）。
    func testClaudeUtilizationOneIsOnePercent() {
        let usage = #"{"five_hour":{"utilization":1,"resets_at":"2026-08-16T12:30:00Z"}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.first?.usedPercent, 1)
    }

    /// limits[].percent 同样是 0–100 整数；1 → 1%，与 utilization 同口径。
    func testClaudeLimitsPercentOneIsOnePercent() {
        let usage = #"""
        {"limits":[{"kind":"session","group":"session","percent":1,"resets_at":"2026-08-16T12:30:00Z","scope":null}]}
        """#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        let five = snap.metrics.first { $0.id == "five_hour" }
        XCTAssertEqual(five?.usedPercent, 1)
    }

    func testClaudeEpochResetTimestamp() {
        let usage = #"{"five_hour":{"utilization":10,"resets_at":1766007200}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.first?.resetsAt, Date(timeIntervalSince1970: 1_766_007_200))
    }

    func testClaudeUnknownWindowKeysStillParsed() {
        let usage = #"{"three_hour":{"utilization":55,"resets_at":"2026-08-16T12:30:00Z"}}"#
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: usage)], now: now)
        XCTAssertEqual(snap.metrics.count, 1)
        XCTAssertEqual(snap.metrics.first?.usedPercent, 55)
    }

    func testClaude401NeedsLogin() {
        let snap = ClaudeParser.parse(results: ["organizations": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testClaudeGarbageBodyDoesNotCrash() {
        let snap = ClaudeParser.parse(results: ["usage": ProbeResult(status: 200, body: "<html>not json</html>")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testClaudeEmptyResultsIsError() {
        let snap = ClaudeParser.parse(results: [:], now: now)
        if case .error = snap.status {} else {
            XCTFail("空结果应为 error，实际 \(snap.status)")
        }
    }

    // MARK: - OpenAI

    func testOpenAIPlanAndCodexWindows() throws {
        let results: [String: ProbeResult] = [
            "session": ProbeResult(status: 200, body: try fixture("openai_session")),
            "accounts_check": ProbeResult(status: 200, body: try fixture("openai_accounts_check")),
            "wham_usage": ProbeResult(status: 200, body: try fixture("openai_wham_usage")),
        ]
        let snap = OpenAIParser.parse(results: results, now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "ChatGPT Plus")
        XCTAssertEqual(snap.billingCycle, .monthly)
        let primary = try XCTUnwrap(snap.metrics.first { $0.id == "primary" })
        XCTAssertEqual(primary.usedPercent, 42)
        XCTAssertEqual(primary.label, "Codex 5 小时窗口")
        XCTAssertEqual(primary.resetsAt, now.addingTimeInterval(5400))
        let secondary = try XCTUnwrap(snap.metrics.first { $0.id == "secondary" })
        XCTAssertEqual(secondary.usedPercent, 18)
        XCTAssertEqual(secondary.label, "Codex 周窗口")
        // 订阅状态不再单列一行（套餐徽章+价格已表达，与其他服务商保持一致）
        XCTAssertNil(snap.metrics.first { $0.id == "subscription" })
    }

    /// 2026-08-26 $100 Pro 真机：wham 现网形状 rate_limits.primary_window 只有一个周窗口
    ///（limit_window_seconds=604800，已用 100%），必须按时长判成周窗口，不能因为叫 primary 就当 5 小时。
    func testOpenAIWhamLabelsByDurationNotByPathName() throws {
        let wham = #"""
        {"plan_type":"pro","rate_limits":{"allowed":false,"limit_reached":true,
          "primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":300000,"reset_at":1790000000}},
         "code_review_rate_limits":{"primary_window":{"used_percent":3,"limit_window_seconds":18000,"reset_after_seconds":1000}}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "wham_usage": ProbeResult(status: 200, body: wham),
            ],
            now: now
        )
        let codex = snap.metrics.filter { !$0.id.hasPrefix("code_review") }
        XCTAssertEqual(codex.count, 1, "只有一个 Codex 窗口，不得凭空多出 5 小时窗口")
        XCTAssertEqual(codex.first?.label, "Codex 周窗口")
        XCTAssertEqual(codex.first?.usedPercent, 100)
        XCTAssertEqual(codex.first?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        let review = try XCTUnwrap(snap.metrics.first { $0.id == "code_review.primary_window" })
        XCTAssertEqual(review.label, "Codex 代码审查 5 小时窗口")
        XCTAssertEqual(review.usedPercent, 3)
    }

    /// 两个周级窗口来自不同分组时按分组名区分；新旧字段重复的同一窗口只留一条（DEVLOG #49）。
    func testOpenAIWhamDistinguishesGroupsAndDedupesDuplicates() {
        let wham = #"""
        {"rate_limits":{"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":300000}},
         "rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":300000}},
         "cloud_task_rate_limits":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":300000}}}
        """#
        let snap = OpenAIParser.parse(results: ["wham_usage": ProbeResult(status: 200, body: wham)], now: now)
        XCTAssertEqual(snap.metrics.map(\.label), ["Codex 周窗口", "Codex cloud task 周窗口"])
        XCTAssertEqual(snap.metrics.map(\.id), ["primary_window", "cloud_task_rate_limits.primary_window"])
        XCTAssertEqual(snap.metrics[0].usedPercent, 100)
        XCTAssertEqual(snap.metrics[1].usedPercent, 0)
        XCTAssertEqual(OpenAIParser.groupPrefix(path: "code_review_rate_limits.primary_window"), "Codex 代码审查")
        XCTAssertEqual(OpenAIParser.groupPrefix(path: "rate_limits.secondary_window"), "Codex")
    }

    /// 2026-08-26 $100 Pro 真机完整形状：主额度 `rate_limit` 99%，`additional_rate_limits[]` 里的
    /// GPT-5.3-Codex-Spark 两窗口 0%。主额度不得被附加限额同名顶掉；附加限额按 limit_name 命名。
    func testOpenAIWhamKeepsMainLimitAndNamesAdditionalLimits() throws {
        let wham = #"""
        {"account_id":"","additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,
           "primary_window":{"limit_window_seconds":18000,"reset_after_seconds":18000,"used_percent":0},
           "secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":604800,"used_percent":0}}}],
         "code_review_rate_limit":null,"credits":{"balance":"0","has_credits":false},"plan_type":"prolite",
         "rate_limit":{"allowed":false,"limit_reached":true,
           "primary_window":{"limit_window_seconds":18000,"reset_after_seconds":12000,"used_percent":99},
           "secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":500000,"used_percent":99}}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "wham_usage": ProbeResult(status: 200, body: wham),
            ],
            now: now
        )
        XCTAssertEqual(snap.metrics.map(\.id), [
            "primary_window", "secondary_window",
            "additional.GPT-5.3-Codex-Spark.primary_window", "additional.GPT-5.3-Codex-Spark.secondary_window",
        ])
        XCTAssertEqual(snap.metrics.map(\.label), [
            "Codex 5 小时窗口", "Codex 周窗口",
            "GPT-5.3-Codex-Spark 5 小时窗口", "GPT-5.3-Codex-Spark 周窗口",
        ])
        XCTAssertEqual(snap.metrics.map { $0.usedPercent ?? -1 }, [99, 99, 0, 0])
        XCTAssertEqual(snap.activeMetrics.map(\.id), ["primary_window", "secondary_window"], "0% 的附加限额默认不露出")
    }

    /// 时长缺失时按距重置时间推断，仍不看路径名。
    func testOpenAIWhamFallsBackToResetDistance() {
        let wham = #"{"rate_limits":{"primary_window":{"used_percent":80,"reset_after_seconds":500000},"secondary_window":{"used_percent":10,"reset_after_seconds":3600}}}"#
        let snap = OpenAIParser.parse(
            results: ["wham_usage": ProbeResult(status: 200, body: wham)],
            now: now
        )
        XCTAssertEqual(snap.metrics.first { $0.id == "primary_window" }?.label, "Codex 周窗口")
        XCTAssertEqual(snap.metrics.first { $0.id == "secondary_window" }?.label, "Codex 5 小时窗口")
        XCTAssertEqual(OpenAIParser.durationText(minutes: 300), "5 小时")
        XCTAssertEqual(OpenAIParser.durationText(minutes: 10080), "周")
        XCTAssertEqual(OpenAIParser.durationText(minutes: 4320), "3 天")
    }

    func testOpenAISessionOnlyStillLoggedIn() throws {
        let snap = OpenAIParser.parse(
            results: ["session": ProbeResult(status: 200, body: try fixture("openai_session"))],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "ChatGPT")
    }

    func testOpenAILoggedOut() {
        let snap = OpenAIParser.parse(
            results: ["session": ProbeResult(status: 200, body: "{}")],
            now: now
        )
        XCTAssertEqual(snap.status, .needsLogin)
    }

    /// 2026-08-16 模拟器实测：chatgpt.com 对匿名访客返回 200 的 session（含游客 user，
    /// 甚至带游客 accessToken），只要没有邮箱就不得判为已登录。
    func testOpenAIAnonymousSessionNeedsLogin() {
        let body = #"{"user":{"id":"guest-abc","name":null},"accessToken":"guest-token-xyz","expires":"2026-09-16T00:00:00.000Z"}"#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: body),
                "accounts_check": ProbeResult(status: 401, body: #"{"detail":"Unauthorized"}"#),
                "wham_usage": ProbeResult(status: 401, body: #"{"detail":"Unauthorized"}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertNil(snap.planName)
    }

    /// 2026-08-16 模拟器实测第二层：游客 accessToken 还能让 accounts_check 返回 200（plan 为空），
    /// 只要 session 无邮箱，仍必须判为未登录。
    func testOpenAIGuestTokenUnlockedAccountsCheckStillNeedsLogin() {
        let session = #"{"user":{"id":"guest-abc"},"accessToken":"guest-token","expires":"2026-09-16T00:00:00.000Z"}"#
        let check = #"{"accounts":{"default":{"account":{"plan_type":null,"account_id":"guest"}}}}"#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: check),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .needsLogin)
    }

    /// 2026-08-16 真机实测：免费版账号的 accounts_check 里残留已到期的 Pro 订阅
    ///（subscription_plan 仍是 chatgptproplan、has_active_subscription 为 false、
    /// expires_at 在过去），不得再当成现行套餐，应回落到 account.plan_type。
    func testOpenAIExpiredProSubscriptionFallsBackToPlanType() {
        let session = #"{"user":{"id":"u1","email":"me@example.com"},"accessToken":"tok","expires":"2026-09-16T00:00:00.000Z"}"#
        let check = #"""
        {"accounts":{"default":{
            "account":{"plan_type":"free","account_id":"acct-real"},
            "entitlement":{"subscription_plan":"chatgptproplan","has_active_subscription":false,"expires_at":"2025-10-01T00:00:00Z"}
        }}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: check),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "ChatGPT Free")
        XCTAssertNil(snap.metrics.first { $0.id == "subscription" }, "过期订阅不应再显示「订阅状态」指标")
    }

    /// 订阅标记 active 但 expires_at 已过期（续费失败等形态）同样不算现行套餐。
    func testOpenAIActiveFlagButExpiredDateIgnored() {
        let session = #"{"user":{"id":"u1","email":"me@example.com"},"accessToken":"tok","expires":"2026-09-16T00:00:00.000Z"}"#
        let check = #"""
        {"accounts":{"default":{
            "account":{"plan_type":"free","account_id":"acct-real"},
            "entitlement":{"subscription_plan":"chatgptplusplan","has_active_subscription":true,"expires_at":"2025-01-01T00:00:00Z"}
        }}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: check),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "ChatGPT Free")
    }

    /// session 探针整体缺失（形状漂移）时，accounts_check 的有效套餐信息可以兜底判登录。
    func testOpenAIFallbackToAccountsCheckWhenSessionMissing() throws {
        let snap = OpenAIParser.parse(
            results: ["accounts_check": ProbeResult(status: 200, body: try fixture("openai_accounts_check"))],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "ChatGPT Plus")
    }

    /// Pro $100 = 5x Plus：subscription_plan 含 5x 须映射为 ChatGPT Pro 5x，不得落到 $200 的 plain Pro。
    func testOpenAIPro5xPlanMappedSeparately() {
        let session = #"{"user":{"id":"u1","email":"me@example.com"},"accessToken":"tok","expires":"2026-09-16T00:00:00.000Z"}"#
        let check = #"""
        {"accounts":{"default":{
            "account":{"plan_type":"pro","account_id":"acct-pro5x"},
            "entitlement":{"subscription_plan":"chatgptpro5xplan","has_active_subscription":true,"expires_at":"2027-01-01T00:00:00Z"}
        }}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: check),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "ChatGPT Pro 5x")
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName), "$100")
    }

    /// 现网 $100 档实际值 chatgptprolite（Pro Lite）须识别为 Pro 5x（$100），不得落到 $200。
    func testOpenAIProLitePlanMappedToPro5x() {
        let body = """
        {"accounts":{"default":{
            "account":{"plan_type":"pro_lite","account_id":"acct-prolite"},
            "entitlement":{"subscription_plan":"chatgptprolite","has_active_subscription":true,"expires_at":"2027-01-01T00:00:00Z"}
        }}}
        """
        let results: [String: ProbeResult] = [
            "session": ProbeResult(status: 200, body: #"{"user":{"email":"u@example.com"},"accessToken":"t"}"#),
            "accounts_check": ProbeResult(status: 200, body: body),
        ]
        let snap = OpenAIParser.parse(results: results, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snap.planName, "ChatGPT Pro 5x")
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName), "$100")
    }

    /// 下划线形态 chatgpt_pro_5x 同样识别为 Pro 5x。
    func testOpenAIPro5xUnderscorePlanMapped() {
        let session = #"{"user":{"id":"u1","email":"me@example.com"},"accessToken":"tok","expires":"2026-09-16T00:00:00.000Z"}"#
        let check = #"""
        {"accounts":{"default":{
            "entitlement":{"subscription_plan":"chatgpt_pro_5x","has_active_subscription":true,"expires_at":"2027-01-01T00:00:00Z"}
        }}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: check),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "ChatGPT Pro 5x")
    }

    /// plain chatgptproplan 仍为 ChatGPT Pro（$200 / 20x Plus）。
    func testOpenAIPlainProPlanStillChatGPTPro() {
        let session = #"{"user":{"id":"u1","email":"me@example.com"},"accessToken":"tok","expires":"2026-09-16T00:00:00.000Z"}"#
        let check = #"""
        {"accounts":{"default":{
            "entitlement":{"subscription_plan":"chatgptproplan","has_active_subscription":true,"expires_at":"2027-01-01T00:00:00Z"}
        }}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: check),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "ChatGPT Pro")
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName), "$200")
    }

    // MARK: - Cursor

    /// 社区逆向端点 GET /api/usage-summary（cursor-usage 工具真实样本口径）：
    /// 官网 Spending 页两个池 = autoPercentUsed（Cursor Models）+ apiPercentUsed（Other Models），
    /// 均为 0–100 整数百分比，重置时间取 billingCycleEnd。
    func testCursorPoolsSplitCursorModelsAndOtherModels() throws {
        let snap = CursorParser.parse(
            results: ["usage_summary": ProbeResult(status: 200, body: try fixture("cursor_usage_summary"))],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Cursor Ultra")
        XCTAssertEqual(snap.billingCycle, .monthly)
        let cursorModels = try XCTUnwrap(snap.metrics.first { $0.id == "cursor_models" })
        XCTAssertEqual(cursorModels.usedPercent, 1)
        XCTAssertEqual(cursorModels.label, "Cursor Models")
        XCTAssertNotNil(cursorModels.resetsAt)
        let otherModels = try XCTUnwrap(snap.metrics.first { $0.id == "other_models" })
        XCTAssertEqual(otherModels.usedPercent, 2)
        XCTAssertEqual(otherModels.label, "Other Models")
        XCTAssertNil(snap.metrics.first { $0.id == "included" }, "池字段在场时不再展示总量 Included")
        XCTAssertNil(snap.metrics.first { $0.id == "on_demand" }, "limit 为 null 的 On-demand 不应入列")
    }

    /// 老形状（无池字段）回落到 totalPercentUsed 的 Included 总量。
    func testCursorLegacyShapeFallsBackToIncluded() {
        let body = #"""
        {"membershipType":"pro","billingCycleEnd":"2026-09-03T00:00:00.000Z",
         "individualUsage":{"plan":{"totalPercentUsed":25,"used":249,"limit":1000}}}
        """#
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.planName, "Cursor Pro")
        let included = snap.metrics.first { $0.id == "included" }
        XCTAssertEqual(included?.usedPercent, 25)
        XCTAssertEqual(included?.label, "Included")
    }

    /// Grok Bot 周额度字段名尚无样本，按键名含 grok 的子对象防御式探测。
    func testCursorGrokBotSweptDefensively() {
        let body = #"""
        {"membershipType":"ultra",
         "individualUsage":{"plan":{"autoPercentUsed":1,"apiPercentUsed":2}},
         "grokBotUsage":{"percentUsed":1,"resetsAt":"2026-08-20T00:00:00.000Z"}}
        """#
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        let bot = snap.metrics.first { $0.id == "grok_bot" }
        XCTAssertEqual(bot?.usedPercent, 1)
        XCTAssertEqual(bot?.label, "Grok Bot")
        XCTAssertNotNil(bot?.resetsAt)
    }

    /// Grok Bot 对象可能不在顶层：嵌套在 individualUsage 等容器下也要能递归找到；
    /// 数值再包一层（weekly 子对象）与「reset 名字段」同样要能提取。
    func testCursorGrokBotFoundNestedAndWrapped() {
        let body = #"""
        {"membershipType":"ultra","billingCycleEnd":"2026-09-13T00:00:00.000Z",
         "individualUsage":{
           "plan":{"autoPercentUsed":5,"apiPercentUsed":76},
           "grokBot":{"weekly":{"percentUsed":7,"resetDate":"2026-08-27T00:00:00.000Z"}}}}
        """#
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        let bot = snap.metrics.first { $0.id == "grok_bot" }
        XCTAssertEqual(bot?.usedPercent, 7)
        XCTAssertNotNil(bot?.resetsAt)
    }

    /// 候选专用探针（grok_bot_usage）命中时：summary 里没有 grok 字段也能出指标；
    /// 探针 404 时不产生指标、不影响登录判定。
    func testCursorGrokBotDedicatedProbe() throws {
        let summary = #"{"membershipType":"ultra","individualUsage":{"plan":{"autoPercentUsed":5,"apiPercentUsed":76}}}"#
        let botBody = #"{"weeklyUsage":{"usedPercent":7,"resetsAt":"2026-08-27T00:00:00.000Z"}}"#
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: summary),
                "grok_bot_usage": ProbeResult(status: 200, body: botBody),
            ],
            now: now
        )
        let bot = try XCTUnwrap(snap.metrics.first { $0.id == "grok_bot" })
        XCTAssertEqual(bot.usedPercent, 7)
        XCTAssertNotNil(bot.resetsAt)

        let miss = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: summary),
                "grok_bot_usage": ProbeResult(status: 404, body: "not found"),
            ],
            now: now
        )
        XCTAssertEqual(miss.status, .ok)
        XCTAssertNil(miss.metrics.first { $0.id == "grok_bot" })
    }

    /// Spending 页真实端点 get-sand-usage-status（SAND = Grok Bot，2026-08-21 真机样本）。
    func testCursorGrokBotFromSandUsageStatus() throws {
        let summary = #"{"membershipType":"ultra","individualUsage":{"plan":{"autoPercentUsed":5,"apiPercentUsed":76}}}"#
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: summary),
                "sand_usage_status": ProbeResult(status: 200, body: try fixture("cursor_sand_usage_status")),
            ],
            now: now
        )
        let bot = try XCTUnwrap(snap.metrics.first { $0.id == "grok_bot" })
        XCTAssertEqual(bot.usedPercent, 10.324473)
        XCTAssertEqual(bot.label, "Grok Bot")
        XCTAssertEqual(bot.resetsAt, JSONHelp.date("2026-08-27T18:27:53.116Z"))
    }

    /// 未开通 Grok Bot 的账号：接口回 0% + hasAvailableUsage=false，不画空行。
    func testCursorSandUsageUnavailableDoesNotInventMetric() {
        let summary = #"{"membershipType":"ultra","individualUsage":{"plan":{"autoPercentUsed":5,"apiPercentUsed":76}}}"#
        let sand = #"{"usagePercent":0,"hasAvailableUsage":false,"hasNonZeroIncludedLimit":false}"#
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: summary),
                "sand_usage_status": ProbeResult(status: 200, body: sand),
            ],
            now: now
        )
        XCTAssertNil(snap.metrics.first { $0.id == "grok_bot" })
        XCTAssertEqual(snap.metrics.first { $0.id == "cursor_models" }?.usedPercent, 5)
    }

    /// sand 响应只有剩余毫秒、没有绝对 reset 时，也能换算 resetsAt。
    func testCursorGrokBotSandRemainingMs() throws {
        let summary = #"{"membershipType":"ultra","individualUsage":{"plan":{"autoPercentUsed":5,"apiPercentUsed":76}}}"#
        let sand = #"{"usagePercent":7,"remainingMs":604800000}"#
        let snap = CursorParser.parse(
            results: [
                "usage_summary": ProbeResult(status: 200, body: summary),
                "sand_usage_status": ProbeResult(status: 200, body: sand),
            ],
            now: now
        )
        let bot = try XCTUnwrap(snap.metrics.first { $0.id == "grok_bot" })
        XCTAssertEqual(bot.usedPercent, 7)
        let resets = try XCTUnwrap(bot.resetsAt)
        XCTAssertEqual(resets.timeIntervalSince(now), 604800, accuracy: 1)
    }

    func testCursorGrokBotUtilizationIsAlreadyHundred() {
        let body = #"""
        {"membershipType":"ultra",
         "grokBotUsage":{"utilization":1,"resetsAt":"2026-08-20T00:00:00.000Z"}}
        """#
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.metrics.first { $0.id == "grok_bot" }?.usedPercent, 1)
        let mid = #"""
        {"membershipType":"ultra",
         "grokBotUsage":{"utilization":50,"resetsAt":"2026-08-20T00:00:00.000Z"}}
        """#
        let midSnap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: mid)], now: now)
        XCTAssertEqual(midSnap.metrics.first { $0.id == "grok_bot" }?.usedPercent, 50)
    }

    func testCursorOnDemandWithLimitListed() {
        let body = #"""
        {"membershipType":"pro","billingCycleEnd":"2026-09-03T00:00:00.000Z",
         "individualUsage":{"plan":{"totalPercentUsed":80,"used":8,"limit":10},
                            "onDemand":{"enabled":true,"used":250,"limit":1000,"remaining":750}}}
        """#
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: body)], now: now)
        let onDemand = snap.metrics.first { $0.id == "on_demand" }
        XCTAssertEqual(onDemand?.usedPercent, 25)
        XCTAssertEqual(onDemand?.label, "On-demand")
    }

    func testCursor401NeedsLogin() {
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testCursorGarbageBodyDoesNotCrash() {
        let snap = CursorParser.parse(results: ["usage_summary": ProbeResult(status: 200, body: "<html>not json</html>")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    // MARK: - Grok

    func testGrokRateLimitsAndPlan() throws {
        let results: [String: ProbeResult] = [
            "rate_limits": ProbeResult(status: 200, body: try fixture("grok_rate_limits")),
            "subscriptions": ProbeResult(status: 200, body: try fixture("grok_subscriptions")),
        ]
        let snap = GrokParser.parse(results: results, now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "SuperGrok")
        XCTAssertEqual(snap.billingCycle, .monthly)
        // 付费套餐与官网一致：不展示 /rest/rate-limits 的 2 小时次数。
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    /// 2026-08-16 模拟器实测：grok.com 未登录也返回游客额度（rate-limits 200、subscriptions 空），
    /// 应展示数据但标注游客，保留登录入口。
    func testGrokAnonymousQuotaLabeled() {
        let rate = #"{"results":[{"modelName":"grok-4","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":14400,"remainingQueries":2,"totalQueries":2}}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "subscriptions": ProbeResult(status: 200, body: #"{"subscriptions":[]}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "游客额度")
        XCTAssertNil(snap.billingCycle)
        XCTAssertEqual(snap.isAnonymous, true)
        XCTAssertEqual(snap.metrics.first?.detail, "4 小时短期限流")
    }

    func testGrok403NeedsLogin() {
        let snap = GrokParser.parse(results: ["rate_limits": ProbeResult(status: 403, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testGrokPartialFailureKeepsGoodResults() {
        let body = #"{"results":[{"modelName":"grok-4","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":5,"totalQueries":20}},{"modelName":"grok-3","requestKind":"DEFAULT","status":404,"body":{}}]}"#
        let snap = GrokParser.parse(results: ["rate_limits": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.metrics.count, 1)
        XCTAssertEqual(snap.metrics.first?.usedPercent, 75)
    }

    /// 订阅枚举 Subscription_Tier_Grok_Pro 是内部名，对外应显示 SuperGrok；
    /// 档位是 auto/fast/expert/heavy，不再展示 grok-4/grok-3。
    func testGrokProEnumMapsToSuperGrokAndCurrentModes() {
        let rate = #"{"results":[{"modelName":"auto","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":50,"totalQueries":50}},{"modelName":"fast","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":140,"totalQueries":140}},{"modelName":"expert","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":20,"totalQueries":20}},{"modelName":"heavy","requestKind":"DEFAULT","status":403,"body":{}}]}"#
        let subs = #"{"subscriptions":[{"tier":"Subscription_Tier_Grok_Pro","status":"ACTIVE"}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "subscriptions": ProbeResult(status: 200, body: subs),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "SuperGrok")
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    /// 游客额度仍展示短期限流档位（官网 Usage 页对未登录不可用）。
    func testGrokGuestCurrentModesStillShown() {
        let rate = #"{"results":[{"modelName":"auto","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":50,"totalQueries":50}},{"modelName":"fast","requestKind":"DEFAULT","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":140,"totalQueries":140}}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "subscriptions": ProbeResult(status: 200, body: #"{"subscriptions":[]}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "游客额度")
        XCTAssertEqual(snap.isAnonymous, true)
        XCTAssertEqual(snap.metrics.map(\.label), ["自动", "快速"])
    }

    /// 真机 SuperGrok Heavy：自动 150、快速 400。即使订阅枚举仍是 Grok_Pro，也按额度形态显示 Heavy。
    func testGrokInfersHeavyFromQuotaShape() {
        let rate = #"{"results":[{"modelName":"auto","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":150,"totalQueries":150}},{"modelName":"fast","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":400,"totalQueries":400}},{"modelName":"expert","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":140,"totalQueries":140}},{"modelName":"heavy","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":20,"totalQueries":20}}]}"#
        let subs = #"{"subscriptions":[{"tier":"Subscription_Tier_Grok_Pro","status":"ACTIVE"}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "subscriptions": ProbeResult(status: 200, body: subs),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "SuperGrok Heavy")
    }

    /// 官网 Settings → Usage 是共享周额度；有周额度时不再用 2 小时短期限流当主界面。
    func testGrokWeeklyPoolPreferredOverRateLimits() throws {
        let weeklyJSON = #"{"usagePercent":12.5,"resetsAt":"2026-08-23T06:00:00Z","products":[{"code":4,"usagePercent":8},{"code":5,"usagePercent":3}]}"#
        let rate = #"{"results":[{"modelName":"auto","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":150,"totalQueries":150}}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "weekly": ProbeResult(status: 200, body: weeklyJSON),
                "subscriptions": ProbeResult(status: 200, body: #"{"subscriptions":[{"tier":"Subscription_Tier_Grok_Pro"}]}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "SuperGrok Heavy")
        XCTAssertEqual(snap.metrics.first?.id, "weekly")
        XCTAssertEqual(snap.metrics.first?.label, "本周限额")
        XCTAssertEqual(snap.metrics.first?.usedPercent, 12.5)
        XCTAssertEqual(snap.metrics.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-08-23T06:00:00Z"))
        XCTAssertFalse(snap.metrics.contains { $0.id == "auto" })
        XCTAssertEqual(snap.metrics.map(\.label), ["本周限额", "Chat", "Imagine"])
    }

    /// code 7 = App Builder（网页 Usage 页名；iOS「应用构建器」是本地化），不得再落到「分类 7」；
    /// 按名匹配时 "App Builder" 不能被 BUILD 误判成 Grok Build。
    func testGrokWeeklyProductCode7IsAppBuilder() {
        XCTAssertEqual(GrokWeeklyProduct(code: 7, usagePercent: 12).label, "App Builder")
        XCTAssertEqual(GrokWeeklyProduct.label(forName: "App Builder"), "App Builder")
        XCTAssertEqual(GrokWeeklyProduct.label(forName: "应用构建器"), "App Builder")
        XCTAssertEqual(GrokWeeklyProduct.code(forName: "app_builder"), 7)
        XCTAssertEqual(GrokWeeklyProduct.label(forName: "Grok Build"), "Grok Build")
        XCTAssertEqual(GrokWeeklyProduct.code(forName: "Grok Build"), 2)
        XCTAssertEqual(GrokWeeklyProduct(code: 8, usagePercent: 1).label, "分类 8")
    }

    /// 与 grok.com Settings → Usage 同一套维度：每周限额百分比 + Grok Build / Imagine。
    func testGrokOfficialUsagePageDimensions() {
        let credits = #"{"subscription_tier":"SuperGrok Heavy","config":{"creditUsagePercent":3,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-08-21T07:52:00Z"},"productUsage":[{"product":"PRODUCT_GROK_BUILD","usagePercent":2},{"product":"PRODUCT_IMAGINE","usagePercent":1}]}}"#
        let rate = #"{"results":[{"modelName":"auto","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":150,"totalQueries":150}},{"modelName":"fast","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":400,"totalQueries":400}}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "credits": ProbeResult(status: 200, body: credits),
                "subscriptions": ProbeResult(status: 200, body: #"{"subscriptions":[{"tier":"Subscription_Tier_Grok_Pro"}]}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "SuperGrok Heavy")
        XCTAssertEqual(snap.metrics.map(\.label), ["本周限额", "Grok Build", "Imagine"])
        XCTAssertEqual(snap.metrics.map(\.usedPercent), [3, 2, 1])
        XCTAssertTrue(snap.metrics.allSatisfy { $0.remaining == nil && $0.total == nil })
        XCTAssertEqual(snap.metrics.first?.detail, "已使用")
        XCTAssertEqual(snap.metrics.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-08-21T07:52:00Z"))
    }

    func testGrokWeeklyParserReadsCapturedGrpcPayload() throws {
        let hex = "0a3f0d7f6a9c3f12001a002206088097f3d0062a060880b191d2063a07080215a9389b3f3a07080115d6ea183c421208011206088097f3d0061a060880b191d206"
        let data = Data(hex.compactMap { $0.hexDigitValue }.enumerated().reduce(into: [UInt8]()) { acc, item in
            if item.offset % 2 == 0 {
                acc.append(UInt8(item.element << 4))
            } else {
                acc[acc.count - 1] |= UInt8(item.element)
            }
        })
        let weekly = try XCTUnwrap(GrokWeeklyParser.parse(data: data))
        XCTAssertEqual(try XCTUnwrap(weekly.usagePercent), 1.222, accuracy: 0.001)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_782_864_000))
    }

    // MARK: - DeepSeek

    func testDeepSeekPrepaidBalanceAndPeriods() throws {
        let results: [String: ProbeResult] = [
            "current": ProbeResult(status: 200, body: try fixture("deepseek_current")),
            "summary": ProbeResult(status: 200, body: try fixture("deepseek_summary")),
            "api_keys": ProbeResult(status: 200, body: try fixture("deepseek_api_keys")),
            "usage_periods": ProbeResult(status: 200, body: try fixture("deepseek_usage_periods")),
        ]
        let snap = DeepSeekParser.parse(results: results, now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "DeepSeek 无月订阅套餐，不应产出套餐名")
        XCTAssertEqual(snap.currency, "CNY")
        let balance = try XCTUnwrap(snap.metrics.first { $0.id == "balance" })
        XCTAssertEqual(balance.label, "重置余额")
        XCTAssertEqual(balance.amount ?? 0, 54.48446148, accuracy: 0.0001)
        XCTAssertEqual(balance.currency, "CNY")
        XCTAssertNil(balance.usedPercent)
        let spent = try XCTUnwrap(snap.metrics.first { $0.id == "total_spent" })
        XCTAssertEqual(spent.label, "累计消费金额")
        XCTAssertEqual(spent.amount ?? 0, 95.65256092, accuracy: 0.0001)
        let periods = try XCTUnwrap(snap.timeBreakdowns)
        XCTAssertEqual(periods.map(\.id), ["today", "yesterday", "last_7d", "last_30d", "this_month", "last_month"])
        let month = try XCTUnwrap(periods.first { $0.id == "this_month" })
        XCTAssertNotNil(month.cost)
        XCTAssertNotNil(month.requests)
        XCTAssertNotNil(month.tokens)
        XCTAssertFalse(month.series.isEmpty)
        let keys = try XCTUnwrap(snap.keyBreakdowns)
        XCTAssertEqual(Set(keys.map(\.id)), ["key-a", "key-b"])
        XCTAssertTrue(keys.contains { $0.requests != nil || $0.tokens != nil || $0.cost != nil })
        // api_keys 只补已有用量 key 的 name / lastUsed，不得把闲置 key 做成鬼行
        XCTAssertFalse(keys.contains { $0.id == "key-c" || $0.id == "key-d" })
        XCTAssertTrue(keys.allSatisfy { $0.lastUsed == nil })
    }

    func testDeepSeek401NeedsLogin() {
        let snap = DeepSeekParser.parse(results: ["current": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    /// 官网已登录但探针没带 Token：接口仍 200，body 是 Missing Token，不得判已登录。
    func testDeepSeekMissingTokenIsNeedsLogin() {
        let body = #"{"code":40002,"msg":"Missing Token","data":null}"#
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: body),
            "summary": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    /// 探针脚本必须从本机 localStorage / Cookie 取出官网 Token 再打用量接口，
    /// 否则 WKWebView 里 Cookie-only fetch 会得到 Missing Token / 未授权。
    func testShippedProbeScriptsAttachOfficialTokens() throws {
        let src = try shippedProbeSources()
        XCTAssertTrue(src.contains("userToken"), "DeepSeek 官网 Token 在 localStorage.userToken")
        XCTAssertTrue(src.contains("bigmodel_token_production"), "智谱 Authorization 来自 Cookie bigmodel_token_production")
        XCTAssertTrue(src.contains("kimi-auth"), "Kimi Bearer 须优先 Cookie kimi-auth")
        XCTAssertTrue(src.contains("connect-protocol-version"), "Kimi apiv2 要 Connect-RPC 版本头")
        XCTAssertTrue(src.contains("r-timezone"), "Kimi 时区须运行时读取")
        XCTAssertTrue(src.contains("Authorization"), "探针必须带 Authorization")
        XCTAssertTrue(src.contains("minimax_current_group_id"), "MiniMax 请求带 x-group-id")
        let scripts = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        guard let cursorStart = scripts.range(of: "static let cursor"),
              let cursorEnd = scripts.range(of: "static let grok") else {
            return XCTFail("missing cursor script bounds")
        }
        let cursor = scripts[cursorStart.lowerBound..<cursorEnd.lowerBound]
        XCTAssertTrue(cursor.contains("noAuth: true"), "Cursor 官网纯 Cookie，探针不得注入 Bearer")
        XCTAssertGreaterThanOrEqual(cursor.components(separatedBy: "noAuth: true").count - 1, 4)
        guard let mmStart = scripts.range(of: "static let minimax"),
              let mmEnd = scripts.range(of: "static let jimeng") else {
            return XCTFail("missing minimax script bounds")
        }
        let minimax = scripts[mmStart.lowerBound..<mmEnd.lowerBound]
        XCTAssertGreaterThanOrEqual(
            minimax.components(separatedBy: "noAuth: true").count - 1, 2,
            "MiniMax 纯 Cookie，remains/credit/combo/billing 不得注入 Bearer"
        )
        guard let mimoStart = scripts.range(of: "static let mimo"),
              let mimoEnd = scripts.range(of: "static let qoder") else {
            return XCTFail("missing mimo script bounds")
        }
        let mimo = scripts[mimoStart.lowerBound..<mimoEnd.lowerBound]
        XCTAssertGreaterThanOrEqual(
            mimo.components(separatedBy: "noAuth: true").count - 1, 2,
            "MiMo 纯 Cookie，三条探针都要 noAuth"
        )
        guard let openaiStart = scripts.range(of: "static let openai"),
              let openaiEnd = scripts.range(of: "static let cursor") else {
            return XCTFail("missing openai script bounds")
        }
        let openai = scripts[openaiStart.lowerBound..<openaiEnd.lowerBound]
        XCTAssertGreaterThanOrEqual(
            openai.components(separatedBy: "noAuth: true").count - 1, 4,
            "ChatGPT session / backend-api 不得注入 leftover Bearer"
        )
        guard let grokStart = scripts.range(of: "static let grok"),
              let grokEnd = scripts.range(of: "static let deepseek") else {
            return XCTFail("missing grok script bounds")
        }
        let grok = scripts[grokStart.lowerBound..<grokEnd.lowerBound]
        XCTAssertGreaterThanOrEqual(
            grok.components(separatedBy: "noAuth: true").count - 1, 3,
            "Grok REST + weekly 都要 noAuth"
        )
        guard let pplxStart = scripts.range(of: "static let perplexity"),
              let pplxEnd = scripts.range(of: "static let augment") else {
            return XCTFail("missing perplexity script bounds")
        }
        let pplx = scripts[pplxStart.lowerBound..<pplxEnd.lowerBound]
        XCTAssertTrue(pplx.contains("noAuth: true"), "Perplexity credits 纯 Cookie，禁止 leftover Bearer")
        XCTAssertTrue(
            openai.contains("const skip = ['guest', 'free', 'go', 'plus', 'pro']"),
            "spend_monthly 门控是精确相等，prolite / chatgptplusplan 不在 skip 里"
        )
        XCTAssertTrue(openai.contains("skip.indexOf(plan) < 0"))
        guard let ocStart = scripts.range(of: "static let opencode"),
              let ocEnd = scripts.range(of: "static let longcat") else {
            return XCTFail("missing opencode script bounds")
        }
        let opencode = scripts[ocStart.lowerBound..<ocEnd.lowerBound]
        XCTAssertGreaterThanOrEqual(
            opencode.components(separatedBy: "noAuth: true").count - 1, 3,
            "OpenCode status / _server / HTML 纯 Cookie，禁止 leftover Bearer"
        )
    }

    /// 用量必须走具名官方接口（一探针名 → 一条 URL），禁止抓 Usage 页 HTML/DOM 再抽字段。
    func testShippedProbeScriptsAreNamedEndpointsNotPageScrapes() throws {
        let src = try shippedProbeSources()
        for marker in ["innerHTML", "outerHTML", "document.body", "document.documentElement",
                       "querySelectorAll", "innerText"] {
            XCTAssertFalse(src.contains(marker), "探针脚本不得抓页面 DOM：发现 \(marker)")
        }
        XCTAssertTrue(src.contains("async function __probe(url, options)"), "数据请求必须走 __probe(url)")
        XCTAssertTrue(src.contains("getElementById('client-bootstrap')"), "ChatGPT 只许读具名 bootstrap JSON，不得扫 Usage 页")
        XCTAssertTrue(src.contains("el.textContent"), "bootstrap 只读 script JSON 文本")
        let named: [(String, [String])] = [
            ("claude", ["probes.organizations", "probes.usage"]),
            ("openai", ["probes.session", "probes.accounts_check", "probes.wham_usage", "probes.identity"]),
            ("cursor", ["probes.usage_summary", "probes.sand_usage_status", "probes.auth_me"]),
            ("grok", ["probes.rate_limits", "probes.subscriptions", "probes.credits", "probes.weekly"]),
            ("deepseek", ["probes.current", "probes.summary", "probes.api_keys", "probes.usage_periods"]),
            ("zhipu", ["probes.customer", "probes.subscription", "probes.quota", "probes.model_usage"]),
            ("kimi", ["probes.user", "probes.subscriptions", "probes.subscription", "probes.usages", "probes.stats"]),
            ("minimax", ["probes.remains", "probes.credit", "probes.usage_summary", "probes.combo"]),
            ("jimeng", ["probes.credit", "probes.history", "probes.user", "probes.page"]),
            ("opencode", ["probes.status", "probes.billing", "probes.lite"]),
            ("longcat", ["probes.fuel", "probes.token_packs", "probes.token_usage", "probes.user"]),
            ("mimo", ["probes.balance", "probes.plan_detail", "probes.plan_usage"]),
            ("qoder", ["probes.credits"]),
            ("perplexity", ["probes.credits"]),
            ("augment", ["probes.credits", "probes.subscription"]),
            ("abacus", ["probes.billing", "probes.compute_points"]),
            ("t3chat", ["probes.customer"]),
            ("notion", ["probes.spaces", "probes.credit_limit"]),
            ("ollama", ["probes.settings"]),
            ("stepfun", ["probes.rate_limit", "probes.plan_status"]),
            ("copilot", ["probes.budgets"]),
            ("gemini", ["probes.quota"]),
            ("antigravity", ["probes.quota"]),
            ("kiro", ["probes.usage"]),
        ]
        XCTAssertEqual(named.count, ProviderID.allCases.count - 1, "独立脚本数 = ProviderID 减去复用 minimax 的国际站")
        XCTAssertTrue(src.contains("case .minimaxGlobal: return minimax"), "国际站必须复用国内站脚本")
        for (script, probes) in named {
            XCTAssertTrue(src.contains("static let \(script)") || src.contains("enum \(script.prefix(1).uppercased() + script.dropFirst())ProbeScript") || src.contains("enum \(Self.probeScriptTypeName(script))"), "缺少 \(script) 探针脚本")
            for probe in probes {
                XCTAssertTrue(src.contains(probe), "\(script) 必须产出具名探针 \(probe)")
            }
        }
        let jimeng = jimengScript(from: src)
        XCTAssertFalse(jimeng.contains("probes.identity"), "即梦 sec_uid/user_id 原值不得跨过 JS→Swift 边界")
        XCTAssertTrue(src.contains("/api/v0/usage/by_api_key/cost?"), "DeepSeek 时段必须打 cost 接口")
        XCTAssertTrue(src.contains("/api/v0/usage/by_api_key/amount?"), "DeepSeek 时段必须打 amount 接口")
        XCTAssertTrue(src.contains("cycle_audio_resource_package?biz_line=2&cycle_type=3"), "MiniMax combo 年卡是具名 query")
        XCTAssertTrue(src.contains("cycle_audio_resource_package?biz_line=2&cycle_type=1"), "MiniMax combo 月卡是具名 query")
        XCTAssertTrue(src.contains("GetGrokCreditsConfig"), "Grok 周额度是具名 gRPC 方法")
        XCTAssertTrue(src.contains("/commerce/v1/benefits/user_credit?"), "即梦额度是具名 commerce 接口")
        XCTAssertTrue(src.contains("/commerce/v1/benefits/user_credit_history?"), "即梦流水是具名 commerce 接口")
        XCTAssertTrue(src.contains("probes.credit = await __jimengProbe"), "即梦额度必须走不带 Authorization 的独立探针")
        XCTAssertTrue(src.contains("x-tt-passport-csrf-token"), "有 CSRF cookie 时要带给额度接口")
        XCTAssertTrue(src.contains("typeof csrf"), "HttpOnly CSRF 必须能吃 native 注入的 csrf 参数")
        XCTAssertTrue(src.contains("typeof msToken"), "msToken 必须运行时注入，禁止写死")
        XCTAssertTrue(src.contains("typeof uifid"), "Cookie 库里的 uifid 必须运行时注入，禁止写死")
        XCTAssertTrue(src.contains("encodeURIComponent(ms)"), "commerce query 可带运行时 msToken")
        XCTAssertTrue(src.contains("window._secsdk_uifid"), "uifid 必须运行时从 secsdk 读")
        XCTAssertTrue(src.contains("webSignBody"), "额度 POST 必须走官网 secsdk 签名")
        XCTAssertTrue(src.contains("__jimengWaitSigner"), "签名器未就绪时必须等待")
        XCTAssertTrue(src.contains("__jimengWaitHomeReady"), "commerce 前必须等 __isLogined，不能只等 webSignBody")
        XCTAssertTrue(src.contains("__jimengOfficialCredit"), "hasSigner=false 时先读官网自己的积分 store，禁止发明 a_bogus")
        XCTAssertFalse(src.contains("a_bogus"), "禁止手写 a_bogus")
        XCTAssertTrue(src.contains("i < 32"), "签名器最多等约 8s（32×250ms）")
        XCTAssertTrue(src.contains("__probeBackoff(250)"), "签名等待必须走共享 backoff，不得自建裸 setTimeout")
        XCTAssertTrue(src.contains("window.__isLogined"), "必须读官网首页 SSR 登录标志")
        XCTAssertTrue(src.contains("window.__userInfo"), "必须读官网注入的 __userInfo")
        XCTAssertTrue(src.contains("\"ret\":\"1014\""), "额度 1014 系统繁忙必须重试")
        XCTAssertEqual(
            src.components(separatedBy: "/commerce/v1/benefits/user_credit_history?").count - 1, 1,
            "流水只打 history_type=0 一次，不要为全部/消耗/获得打 3 遍"
        )
        XCTAssertTrue(src.contains("count: 20, cursor: '', history_type: 0"), "v1 只拉全部一页，count 用官网默认 20")
        XCTAssertFalse(src.contains("history_type: 1"), "不要单独打获得流水")
        XCTAssertFalse(src.contains("history_type: 2"), "不要单独打消耗流水")
        XCTAssertFalse(src.contains("MS4wLjABAAAAQK8f6uOrt6"), "禁止写死用户贴的 sec_uid")
        XCTAssertFalse(src.contains("12de0401577618"), "禁止写死抓包里的 uifid")
    }

    private func jimengScript(from src: String) -> String {
        guard let start = src.range(of: "static let jimeng") else { return "" }
        let from = src[start.lowerBound...]
        if let end = from.range(of: "\n    static let ", range: from.index(after: from.startIndex)..<from.endIndex) {
            return String(from[..<end.lowerBound])
        }
        return String(from)
    }

    private static func probeScriptTypeName(_ script: String) -> String {
        switch script {
        case "notion": return "NotionProbeScript"
        case "ollama": return "OllamaProbeScript"
        case "stepfun": return "StepFunProbeScript"
        default: return ""
        }
    }

    private func shippedProbeSources() throws -> String {
        let scriptsURL = providerScriptsURL()
        let scripts = try String(contentsOf: scriptsURL, encoding: .utf8)
        let core = scriptsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Sources/UsageLimitsCore")
        let extras = [
            "ProviderProbeScript.swift",
            "NotionProbeScript.swift",
            "OllamaProbeScript.swift",
            "StepFunProbeScript.swift",
            "CopilotProbeScript.swift",
            "GeminiProbeScript.swift",
            "AntigravityProbeScript.swift",
            "KiroProbeScript.swift",
        ]
        let extraText = try extras.map {
            try String(contentsOf: core.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        return scripts + "\n" + extraText
    }

    private func providerScriptsURL() -> URL {
        // Core/Tests/UsageLimitsCoreTests/ThisFile.swift → repo/App/Networking/ProviderScripts.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UsageLimitsCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // repo
            .appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    func testDeepSeekGarbageBodyDoesNotCrash() {
        let snap = DeepSeekParser.parse(results: ["summary": ProbeResult(status: 200, body: "<html>nope</html>")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    // MARK: - 智谱

    func testZhipuCodingPlanWindows() throws {
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: try fixture("zhipu_customer")),
            "subscription": ProbeResult(status: 200, body: try fixture("zhipu_subscription")),
            "quota": ProbeResult(status: 200, body: try fixture("zhipu_quota_limit")),
            "model_usage": ProbeResult(status: 200, body: try fixture("zhipu_model_usage")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Coding Plan Pro")
        XCTAssertEqual(snap.billingCycle, .yearly)
        XCTAssertEqual(snap.planProductID, "product-733034")
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName, billingCycle: snap.billingCycle, productID: snap.planProductID), "¥2,400")
        let five = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(five.usedPercent, 1)
        XCTAssertNotNil(five.resetsAt)
        XCTAssertNotNil(snap.metrics.first { $0.id == "seven_day" })
        XCTAssertNotNil(snap.metrics.first { $0.id == "mcp_monthly" })
        XCTAssertTrue(snap.metrics.contains { $0.label.contains("GLM-5") })
        let ids = snap.metrics.map(\.id)
        let fiveIdx = try XCTUnwrap(ids.firstIndex(of: "five_hour"))
        let mcpIdx = try XCTUnwrap(ids.firstIndex(of: "mcp_monthly"))
        XCTAssertLessThan(fiveIdx, mcpIdx)
        XCTAssertEqual(snap.collapsedMetric?.id, "five_hour")
        XCTAssertNotEqual(snap.collapsedMetric?.id, "mcp_monthly")
    }

    func testZhipuCollapsedPrefersFiveHourOverLaterMCPReset() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snap = ProviderSnapshot(
            provider: .zhipu,
            metrics: [
                UsageMetric(id: "mcp_monthly", label: "MCP 每月额度", usedPercent: 40,
                            resetsAt: now.addingTimeInterval(20 * 86400)),
                UsageMetric(id: "five_hour", label: "每 5 小时", usedPercent: 12,
                            resetsAt: now.addingTimeInterval(3 * 3600)),
            ],
            fetchedAt: now,
            status: .ok
        )
        XCTAssertEqual(snap.collapsedMetric?.id, "mcp_monthly", "折叠跟展开顺序第一位，不再特判 5h")
        XCTAssertEqual(snap.longestWindowMetric?.id, "mcp_monthly")
        XCTAssertEqual(ZhipuParser.orderedMetrics(snap.metrics).map(\.id), ["five_hour", "mcp_monthly"])
    }

    func testZhipuProductIdMapsYearlyWithoutBillingCycleField() {
        let body = #"""
        {"code":200,"data":[{"productId":"product-733034","productName":"GLM Coding Pro","status":"VALID",
         "valid":"2027-01-24 10:00:00-2028-01-24 10:00:00"}]}
        """#
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: #"{"data":{"customerNumber":"10001"}}"#),
            "subscription": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.planName, "Coding Plan Pro")
        XCTAssertEqual(snap.billingCycle, .yearly)
        XCTAssertEqual(snap.billingCycle?.tag, "年")
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName, billingCycle: snap.billingCycle, productID: snap.planProductID), "¥2,400")
    }

    func testZhipu401NeedsLogin() {
        let snap = ZhipuParser.parse(results: ["customer": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testZhipuMissingAuthorizationIsNeedsLogin() {
        let body = #"{"code":1001,"msg":"Header中未收到Authorization参数，无法进行身份验证。","success":false}"#
        let snap = ZhipuParser.parse(results: ["customer": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testZhipuGarbageBodyDoesNotCrash() {
        let snap = ZhipuParser.parse(results: ["quota": ProbeResult(status: 200, body: "not-json")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    // MARK: - Kimi

    func testKimiCodePlanWindows() throws {
        let snap = KimiParser.parse(results: [
            "user": ProbeResult(status: 200, body: try fixture("kimi_user")),
            "subscription": ProbeResult(status: 200, body: try fixture("kimi_subscription")),
            "usages": ProbeResult(status: 200, body: try fixture("kimi_usages")),
            "stats": ProbeResult(status: 200, body: try fixture("kimi_stats")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Kimi Code Allegretto")
        XCTAssertEqual(snap.billingCycle, .yearly)
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName, billingCycle: snap.billingCycle), "¥1,908")
        let weekly = try XCTUnwrap(snap.metrics.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.usedPercent, 1)
        XCTAssertNotNil(weekly.resetsAt)
        let five = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(five.usedPercent, 0)
        XCTAssertNotNil(five.resetsAt)
    }

    func testKimi401NeedsLogin() {
        let snap = KimiParser.parse(results: ["user": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testKimiEmptySubscriptionJSONIsNotLogin() {
        let snap = KimiParser.parse(results: [
            "subscription": ProbeResult(status: 200, body: "{}"),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testKimiGarbageBodyDoesNotCrash() {
        let snap = KimiParser.parse(results: ["usages": ProbeResult(status: 200, body: "<html>")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    // MARK: - MiniMax

    func testMiniMaxTokenPlanWindows() throws {
        let snap = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: try fixture("minimax_remains")),
            "credit": ProbeResult(status: 200, body: try fixture("minimax_credit")),
            "usage_summary": ProbeResult(status: 200, body: try fixture("minimax_usage_summary")),
            "combo": ProbeResult(status: 200, body: try fixture("minimax_combo")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Token Plan Max")
        XCTAssertEqual(snap.billingCycle, .yearly)
        XCTAssertEqual(snap.billingCycle?.tag, "年")
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName, billingCycle: snap.billingCycle), "¥1,190")
        let five = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(five.usedPercent, 0)
        XCTAssertEqual(five.pinned, true)
        XCTAssertEqual(five.displayValue, "0%/100%")
        XCTAssertNil(five.remaining, "5h 共享额度 count=-1 不得展示成 剩 -1/-1")
        XCTAssertNil(five.total)
        XCTAssertNotNil(five.resetsAt)
        let weekly = try XCTUnwrap(snap.metrics.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.detail, "无限制")
        XCTAssertEqual(weekly.pinned, true)
        XCTAssertNil(weekly.resetsAt, "官网周限额无限制不展示重置倒计时")
        let video = try XCTUnwrap(snap.metrics.first { $0.id == "video_gift" })
        XCTAssertEqual(video.pinned, true)
        XCTAssertEqual(Set(snap.activeMetrics.map(\.id)).isSuperset(of: ["five_hour", "seven_day", "video_gift"]), true)
        XCTAssertEqual(snap.collapsedMetric?.id, "five_hour")
        XCTAssertNotNil(snap.metrics.first { $0.id == "credits" })
    }

    func testMiniMaxAnnualMemberTitleIsYearly() {
        let combo = #"""
        {"cycle_resource_packages":[
          {"title":"TokenPlanPlus-月度会员","button_text":"立即订阅","combo_id":"1","cycle_type":1},
          {"title":"TokenPlanMax-年度会员","button_text":"续订套餐","combo_id":"311003","cycle_type":3,
           "price_data":{"price_tag":"1190"},"price_desc":"每年，按年订阅"}
        ]}
        """#
        let snap = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: #"{"model_remains":[{"model_name":"general","current_interval_used_percent":"0%","current_interval_status":1}]}"#),
            "combo": ProbeResult(status: 200, body: combo),
        ], now: now)
        XCTAssertEqual(snap.planName, "Token Plan Max")
        XCTAssertEqual(snap.billingCycle, .yearly)
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName, billingCycle: snap.billingCycle), "¥1,190")
    }

    func testMiniMax401NeedsLogin() {
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testMiniMaxGarbageBodyDoesNotCrash() {
        let snap = MiniMaxParser.parse(results: ["remains": ProbeResult(status: 200, body: "oops")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    // MARK: - 即梦

    func testJimengCreditSplitAndRemainingSum() throws {
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: try fixture("jimeng_credit")),
            "history": ProbeResult(status: 200, body: try fixture("jimeng_history")),
            "user": ProbeResult(status: 200, body: try fixture("jimeng_user")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "即梦是积分、无订阅标价")
        XCTAssertNil(PlanCatalog.listPrice(planName: snap.planName))
        let remain = try XCTUnwrap(snap.metrics.first { $0.id == "remaining" })
        let vip = try XCTUnwrap(snap.metrics.first { $0.id == "subscription" })
        let recharge = try XCTUnwrap(snap.metrics.first { $0.id == "recharge" })
        let gift = try XCTUnwrap(snap.metrics.first { $0.id == "gift" })
        XCTAssertEqual(remain.amount, 179)
        XCTAssertEqual(vip.amount, 0)
        XCTAssertEqual(recharge.amount, 149)
        XCTAssertEqual(gift.amount, 30)
        XCTAssertEqual(remain.amount, (vip.amount ?? 0) + (recharge.amount ?? 0) + (gift.amount ?? 0))
        XCTAssertNil(remain.usedPercent, "积分禁止走百分比口径")
        XCTAssertNil(remain.detail, "折叠摘要不露流水")
        XCTAssertEqual(remain.pinned, true)
        XCTAssertEqual(vip.pinned, true)
        XCTAssertEqual(snap.collapsedMetric?.id, "remaining")
        XCTAssertEqual(snap.weeklySummaryMetric?.id, "remaining")
        let ledger = try XCTUnwrap(snap.creditHistory)
        XCTAssertEqual(ledger.count, 4)
        XCTAssertEqual(ledger[0].id, "1001")
        XCTAssertEqual(ledger[0].title, "每日免费积分")
        XCTAssertEqual(ledger[0].amount, 30)
        XCTAssertEqual(ledger[0].historyType, 1)
        XCTAssertTrue(ledger[0].isGain)
        XCTAssertEqual(ledger[0].signedAmount, 30)
        XCTAssertEqual(ledger[1].historyType, 2)
        XCTAssertEqual(ledger[1].signedAmount, -80)
        XCTAssertEqual(ledger[2].title, "Seedance2.5")
        XCTAssertEqual(ledger[3].title, "失败返还")
        XCTAssertNil(snap.metrics.first { $0.id == "history_1001" }, "流水不进指标行")
    }

    func testJimengPurchaseCreditIsRawFieldNotDerived() throws {
        let credit = """
        {"ret":"0","errmsg":"success","data":{"total_credit":999,"credit":{"vip_credit":10,"purchase_credit":149,"gift_credit":20}}}
        """
        let history = """
        {"ret":"0","data":{"total_credit":999,"records":[]}}
        """
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: credit),
            "history": ProbeResult(status: 200, body: history),
        ], now: now)
        XCTAssertEqual(snap.metrics.first { $0.id == "recharge" }?.amount, 149,
                       "149 必须是 purchase_credit 原值")
        XCTAssertEqual(snap.metrics.first { $0.id == "remaining" }?.amount, 179,
                       "剩余可用订阅+充值+赠送校验，不得把 history.total_credit=999 当充值")
        XCTAssertNotEqual(
            snap.metrics.first { $0.id == "recharge" }?.amount,
            999 - 10 - 20,
            "禁止用剩余−订阅−赠送反推充值"
        )
        XCTAssertNil(snap.creditHistory)
    }

    func testJimengSkipsMalformedHistoryRows() {
        let body = """
        {"ret":"0","data":{"total_credit":10,"records":[
          {"amount":30,"create_time":1787494919,"title":"每日免费积分","history_type":1,"history_id":"ok1"},
          {"amount":1,"create_time":1787494919,"title":"坏类型","history_type":9,"history_id":"bad-type"},
          {"create_time":1787494919,"title":"无金额","history_type":2,"history_id":"bad-amt"},
          {"amount":2,"title":"无时间","history_type":1,"history_id":"bad-time"}
        ]}}
        """
        let snap = JimengParser.parse(results: [
            "history": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.creditHistory?.map(\.id), ["ok1"])
    }

    func testJimengHistoryOnlyFallsBackToTotalCredit() throws {
        let snap = JimengParser.parse(results: [
            "history": ProbeResult(status: 200, body: try fixture("jimeng_history")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.first { $0.id == "remaining" }?.amount, 179)
        XCTAssertNil(snap.metrics.first { $0.id == "subscription" })
    }

    func testJimengDoesNotUsePercentHelperOnCredits() {
        XCTAssertEqual(JimengParser.intAmount(30), 30)
        XCTAssertEqual(JimengParser.intAmount("149"), 149)
        XCTAssertNotEqual(JimengParser.intAmount(0.3), 30, "不得把积分当 0…1 百分比放大")
    }

    func testJimengSystemBusyIsNotNeedsLogin() {
        let busy = #"{"ret":"1014","errmsg":"system busy"}"#
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: busy),
            "history": ProbeResult(status: 200, body: busy),
        ], now: now)
        if case .error(let message) = snap.status {
            XCTAssertTrue(message.contains("繁忙"), "1014 是系统繁忙，不能当成未登录：\(message)")
        } else {
            XCTFail("1014 应为 error，实际 \(snap.status)")
        }
    }

    func testJimengSystemBusyStillLoggedInWhenPageSaysSo() {
        let busy = #"{"ret":"1014","errmsg":"system busy"}"#
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: busy),
            "page": ProbeResult(status: 200, body: #"{"isLogined":true,"hasUserInfo":false}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "官网已登录时，额度 1014 不能把状态打回未登录")
        XCTAssertEqual(snap.metrics.first { $0.id == "remaining" }?.displayValue, "—")
    }

    func testJimengSessionCookiePlusBusyIsLoggedIn() {
        let busy = #"{"ret":"1014","errmsg":"system busy"}"#
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: busy),
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#),
            "session": ProbeResult(status: 200, body: #"{"hasSession":true}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "本机会话已在时，额度 1014 + 匿名 SSR 仍算已登录")
        let remaining = snap.metrics.first { $0.id == "remaining" }
        XCTAssertEqual(remaining?.amount, nil, "1014 没有积分数字")
        XCTAssertEqual(remaining?.displayValue, "—")
        XCTAssertEqual(remaining?.detail, JimengParser.unavailableDetail)
        XCTAssertEqual(remaining?.pinned, true)
        XCTAssertFalse(RefreshPolicy.hasNumericUsage(snap), "占位不得当成已拿到积分")
    }

    func testJimengNoSessionPlusBusyIsSystemBusy() {
        let busy = #"{"ret":"1014","errmsg":"system busy"}"#
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: busy),
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#),
            "session": ProbeResult(status: 200, body: #"{"hasSession":false}"#),
        ], now: now)
        if case .error(let message) = snap.status {
            XCTAssertTrue(message.contains("繁忙"), "无会话时 1014 仍是系统繁忙：\(message)")
        } else {
            XCTFail("无会话 + 1014 应为 error，实际 \(snap.status)")
        }
    }

    func testJimengBusyCreditIgnoresHistoryLeftover() {
        let busy = #"{"ret":"1014","errmsg":"system busy"}"#
        let history = #"{"ret":"0","errmsg":"success","data":{"total_credit":99,"records":[{"title":"赠送","amount":10,"history_type":1,"create_time":1700000000,"history_id":"h1"}]}}"#
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: busy),
            "history": ProbeResult(status: 200, body: history),
            "session": ProbeResult(status: 200, body: #"{"hasSession":true}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.creditHistory, "额度 1014 时 leftover 流水不得进快照")
        XCTAssertNil(snap.metrics.first { $0.id == "remaining" }?.amount, "不得用流水 total_credit 冒充本轮积分")
        XCTAssertEqual(snap.metrics.first { $0.id == "remaining" }?.displayValue, "—")
        XCTAssertFalse(RefreshPolicy.hasNumericUsage(snap))
    }

    func testJimeng401NeedsLogin() {
        let snap = JimengParser.parse(results: ["credit": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testJimengCreditServerErrorIsNotNeedsLogin() {
        let snap = JimengParser.parse(results: ["credit": ProbeResult(status: 503, body: "busy")], now: now)
        XCTAssertEqual(snap.status, .error("HTTP 503"))
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testJimengCreditTimeoutIsNotNeedsLogin() {
        let snap = JimengParser.parse(results: ["credit": ProbeResult(status: -3, body: "timeout")], now: now)
        XCTAssertEqual(snap.status, .error("请求超时"))
    }


    func testJimengCreditUnauthorizedDropsHistoryAndPassport() throws {
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 401, body: ""),
            "user": ProbeResult(status: 200, body: try fixture("jimeng_user")),
            "history": ProbeResult(status: 200, body: try fixture("jimeng_history")),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
        XCTAssertNil(snap.creditHistory)
    }

    func testJimengCreditLoginEnvelopeDropsPassportMetrics() throws {
        let snap = JimengParser.parse(results: [
            "credit": ProbeResult(status: 200, body: #"{"ret":"0","errmsg":"not login"}"#),
            "user": ProbeResult(status: 200, body: try fixture("jimeng_user")),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testJimengGarbageBodyDoesNotCrash() {
        let snap = JimengParser.parse(results: ["credit": ProbeResult(status: 200, body: "<html>")], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testJimengEmptyResultsIsError() {
        let snap = JimengParser.parse(results: [:], now: now)
        if case .error = snap.status {} else {
            XCTFail("空结果应为 error，实际 \(snap.status)")
        }
    }

    func testJimengPassportUserAloneIsLoggedIn() throws {
        let snap = JimengParser.parse(results: [
            "user": ProbeResult(status: 200, body: try fixture("jimeng_user")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "通行证返回账号 id 即已登录，不能等额度探针")
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testJimengOfficialPageFlagAloneIsLoggedIn() {
        let snap = JimengParser.parse(results: [
            "page": ProbeResult(status: 200, body: #"{"isLogined":true,"hasUserInfo":false}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "官网 window.__isLogined=true 即已登录")
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testJimengOfficialUserInfoFlagAloneIsLoggedIn() {
        let snap = JimengParser.parse(results: [
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":true}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "官网注入了 __userInfo 即已登录")
    }

    func testJimengAnonymousPageFlagIsNotLoggedIn() {
        let snap = JimengParser.parse(results: [
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testJimengLocalIdentityAloneIsNotLoggedIn() {
        let identity = """
        {"sec_uid":"MS4wLjABAAAAEXAMPLE_NOT_A_REAL_USER","user_id":"1","source":"cookie.uid_tt"}
        """
        let snap = JimengParser.parse(results: [
            "identity": ProbeResult(status: 200, body: identity),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin, "本地拼装的 identity 不能单独当作已登录")
    }

    // MARK: - OpenCode

    func testOpenCodeGoWindowsAndZenBalance() throws {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status")),
            "billing": ProbeResult(status: 200, body: try fixture("opencode_billing")),
            "lite": ProbeResult(status: 200, body: try fixture("opencode_lite")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "OpenCode Go")
        XCTAssertEqual(snap.billingCycle, .monthly)
        XCTAssertEqual(PlanCatalog.listPrice(planName: snap.planName, billingCycle: snap.billingCycle), "$10")
        XCTAssertEqual(snap.metrics.map(\.id), ["weekly", "five_hour", "monthly", "balance", "monthly_limit"])
        let weekly = try XCTUnwrap(snap.metrics.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.usedPercent, 40)
        XCTAssertEqual(weekly.pinned, true)
        XCTAssertEqual(weekly.resetsAt, now.addingTimeInterval(302_400))
        let rolling = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(rolling.usedPercent, 12.3)
        XCTAssertEqual(rolling.resetsAt, now.addingTimeInterval(9_800))
        XCTAssertNil(rolling.pinned)
        let balance = try XCTUnwrap(snap.metrics.first { $0.id == "balance" })
        XCTAssertEqual(balance.amount ?? 0, 12.3456789, accuracy: 0.0000001, "balance ÷ 1e8 = 美元")
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.pinned, true)
        XCTAssertNil(balance.usedPercent, "余额禁止走百分比口径")
        let limit = try XCTUnwrap(snap.metrics.first { $0.id == "monthly_limit" })
        XCTAssertEqual(limit.amount ?? 0, 0, "fixture 的 timeMonthlyUsageUpdated 不在 now 当月，按 0")
        XCTAssertEqual(limit.usedPercent, 0)
        XCTAssertEqual(snap.collapsedMetric?.id, "weekly")
        XCTAssertEqual(snap.weeklySummaryMetric?.id, "weekly")
    }

    func testOpenCodeMonthlyUsageCountsOnlyCurrentMonth() throws {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let sameMonth = iso.string(from: now.addingTimeInterval(-3600))
        let body = """
        {"balance":500000000,"monthlyLimit":50,"monthlyUsage":2500000000,"timeMonthlyUsageUpdated":"\(sameMonth)"}
        """
        let snap = OpenCodeParser.parse(results: [
            "billing": ProbeResult(status: 200, body: body),
            "lite": ProbeResult(status: 200, body: "null"),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "只有 Zen 余额时是预充值卡，无套餐")
        XCTAssertNil(snap.billingCycle)
        let limit = try XCTUnwrap(snap.metrics.first { $0.id == "monthly_limit" })
        XCTAssertEqual(limit.amount, 25)
        XCTAssertEqual(limit.usedPercent, 50)
        XCTAssertEqual(limit.detail, "上限 $50.00")
        XCTAssertEqual(snap.collapsedMetric?.id, "balance")
        XCTAssertNil(snap.metrics.first { $0.id == "weekly" }, "lite 为 null 表示未订阅 Go")
    }

    func testOpenCodeBlackHidesGoWindows() throws {
        let billing = """
        {"balance":0,"subscriptionID":"sub_black","subscriptionPlan":"Black 100","timeSubscriptionBooked":"2026-08-01T00:00:00.000Z"}
        """
        let snap = OpenCodeParser.parse(results: [
            "billing": ProbeResult(status: 200, body: billing),
            "lite": ProbeResult(status: 200, body: try fixture("opencode_lite")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "OpenCode Black")
        XCTAssertNil(PlanCatalog.listPrice(planName: snap.planName), "Black 档不收录标价")
        XCTAssertNil(snap.billingCycle)
        XCTAssertTrue(snap.metrics.allSatisfy { $0.usedPercent == nil }, "官网 Black 时不显示 Go 用量")
        XCTAssertEqual(snap.metrics.first { $0.id == "balance" }?.amount, 0)
    }

    func testOpenCodeOtherMembersGoSubscriptionIsNotMine() throws {
        let lite = """
        {"mine":false,"rollingUsage":{"usagePercent":90,"resetInSec":100},"weeklyUsage":{"usagePercent":90,"resetInSec":100},"monthlyUsage":{"usagePercent":90,"resetInSec":100}}
        """
        let snap = OpenCodeParser.parse(results: [
            "billing": ProbeResult(status: 200, body: try fixture("opencode_billing")),
            "lite": ProbeResult(status: 200, body: lite),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName)
        XCTAssertNil(snap.metrics.first { $0.id == "weekly" })
    }

    func testOpenCodeLoggedOutStatusNeedsLogin() {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: "{}"),
            "billing": ProbeResult(status: 401, body: "no workspace in path"),
            "lite": ProbeResult(status: 401, body: "no workspace in path"),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testOpenCodeRuntimeChunkMissingIsErrorNotLogout() throws {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status")),
            "billing": ProbeResult(status: -2, body: "server-runtime chunk unavailable"),
            "lite": ProbeResult(status: -2, body: "server-runtime chunk unavailable"),
        ], now: now)
        if case .error = snap.status {} else {
            XCTFail("已登录但控制台脚本失效应是 error，不是 needsLogin：\(snap.status)")
        }
    }

    func testOpenCodeGarbageBodiesDoNotCrash() {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: "<html>"),
            "billing": ProbeResult(status: 200, body: "{\"balance\":\"abc\",\"monthlyLimit\":true,\"timeSubscriptionBooked\":{}}"),
            "lite": ProbeResult(status: 200, body: "{\"rollingUsage\":[],\"weeklyUsage\":{\"usagePercent\":\"x\"}}"),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.metrics.first { $0.id == "balance" })
        XCTAssertNil(snap.metrics.first { $0.id == "weekly" })
    }

    func testShippedOpenCodeProbeSelfCalibratesServerIDs() throws {
        let src = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        XCTAssertTrue(src.contains("/auth/status"), "登录判定走 /auth/status")
        XCTAssertTrue(src.contains("server-runtime-"), "必须用页面自带的 server-runtime chunk 反序列化 seroval")
        XCTAssertTrue(src.contains(#"'billing\\.get'"#), "billing id 必须从 common chunk 正则校准")
        XCTAssertTrue(src.contains(#"'lite\\.subscription\\.get'"#), "lite id 必须从 go chunk 正则校准")
        XCTAssertTrue(src.contains("wrk_[A-Za-z0-9]+"), "workspaceID 运行时从路径取")
        XCTAssertTrue(src.contains("location.hostname === 'opencode.ai'"), "落到 auth.opencode.ai 时直接判未登录")
        XCTAssertFalse(src.contains("/zen/go/v1/usage"), "不走需要 API key 的公开端点")
    }
}

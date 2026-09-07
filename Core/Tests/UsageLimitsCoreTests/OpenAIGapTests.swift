import XCTest
@testable import UsageLimitsCore

/// 2026-08 对齐 CodexBar 的 chatgpt.com 补齐项：credits 余额、美元额度池、
/// 套餐档覆盖面、subscriptions 续费/到期、client-bootstrap 登录证据、401 与 5xx 分级。
final class OpenAIGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - credits

    func testCreditsBalanceParsed() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "wham_usage": ProbeResult(status: 200, body: try fixture("openai_wham_credits")),
            ],
            now: now
        )
        let credits = try XCTUnwrap(snap.metrics.first { $0.id == "credits" })
        XCTAssertEqual(credits.label, "Codex credits")
        XCTAssertEqual(credits.amount, 12.5, "balance 是字符串也要认")
        XCTAssertEqual(credits.currency, "USD")
        XCTAssertNil(credits.pinned, "有余额的 credits 不钉住，靠 hasUsage 决定露不露")
        // 主额度窗口不能被 credits 顶掉
        XCTAssertNotNil(snap.metrics.first { $0.id == "primary_window" })
    }

    func testUnlimitedCreditsShownAsInfinity() {
        let wham = #"{"credits":{"balance":0,"has_credits":false,"unlimited":true}}"#
        let snap = OpenAIParser.parse(results: ["wham_usage": ProbeResult(status: 200, body: wham)], now: now)
        let credits = snap.metrics.first { $0.id == "credits" }
        XCTAssertEqual(credits?.displayValue, "∞")
        XCTAssertEqual(credits?.pinned, true)
        XCTAssertNil(credits?.amount)
    }

    func testZeroCreditsProducesNothing() {
        let wham = #"{"credits":{"balance":"0","has_credits":false,"unlimited":false}}"#
        let snap = OpenAIParser.parse(results: ["wham_usage": ProbeResult(status: 200, body: wham)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "credits" })
    }

    /// has_credits=true 但余额为 0：产出计量但 hasUsage 为假，首页默认藏起来。
    func testHasCreditsWithZeroBalanceIsHiddenNotDropped() {
        let wham = #"{"credits":{"balance":0,"has_credits":true,"unlimited":false}}"#
        let snap = OpenAIParser.parse(results: ["wham_usage": ProbeResult(status: 200, body: wham)], now: now)
        let credits = snap.metrics.first { $0.id == "credits" }
        XCTAssertEqual(credits?.amount, 0)
        XCTAssertEqual(credits?.hasUsage, false)
    }

    // MARK: - 美元额度池

    func testSpendControlPoolBecomesMetricAndNotAWindow() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "wham_usage": ProbeResult(status: 200, body: try fixture("openai_wham_spend_control")),
            ],
            now: now
        )
        let pool = try XCTUnwrap(snap.metrics.first { $0.id == "spend_limit" })
        XCTAssertEqual(pool.label, "Monthly spend limit")
        XCTAssertEqual(pool.usedPercent, 25, "remaining_percent 是剩余语义，要换算成已用")
        XCTAssertEqual(pool.amount, 125)
        XCTAssertEqual(pool.currency, "USD")
        XCTAssertEqual(pool.detail, "上限 $500")
        XCTAssertEqual(pool.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        // 额度池不得被窗口递归当成第二条 5 小时 / 周窗口
        XCTAssertEqual(snap.metrics.filter { $0.usedPercent != nil }.count, 2,
                       "只有主窗口和额度池两条带百分比的计量")
        XCTAssertNil(snap.metrics.first { $0.id.contains("individual_limit") })
    }

    func testSpendPoolDerivesPercentFromUsedWhenRemainingMissing() {
        let wham = #"{"individual_limit":{"limit":200,"used":50}}"#
        let snap = OpenAIParser.parse(results: ["wham_usage": ProbeResult(status: 200, body: wham)], now: now)
        let pool = snap.metrics.first { $0.id == "spend_limit" }
        XCTAssertEqual(pool?.usedPercent, 25)
        XCTAssertEqual(pool?.amount, 50)
    }

    /// wham 里没有额度池时才用 spend_monthly 探针（美元，非分）。
    func testSpendMonthlyProbeFallback() {
        let monthly = #"""
        {"current_month_usage":30,"effective_monthly_limit":{"limit":120,"enforcement_mode":"hard","limit_mode":"monthly"}}
        """#
        let snap = OpenAIParser.parse(
            results: [
                "wham_usage": ProbeResult(status: 200, body: #"{"plan_type":"business"}"#),
                "spend_monthly": ProbeResult(status: 200, body: monthly),
            ],
            now: now
        )
        let pool = snap.metrics.first { $0.id == "spend_limit" }
        XCTAssertEqual(pool?.usedPercent, 25)
        XCTAssertEqual(pool?.amount, 30)
        XCTAssertEqual(pool?.detail, "上限 $120")
    }

    func testSpendMonthlyIgnoredWhenEnforcementDisabled() {
        let monthly = #"{"current_month_usage":30,"effective_monthly_limit":{"limit":120,"enforcement_mode":"none"}}"#
        let snap = OpenAIParser.parse(
            results: ["spend_monthly": ProbeResult(status: 200, body: monthly)], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "spend_limit" })
    }

    // MARK: - 套餐名

    func testPlanLabelCoversNewTiers() {
        XCTAssertEqual(OpenAIParser.planLabel("go"), "ChatGPT Go")
        XCTAssertEqual(OpenAIParser.planLabel("chatgptgoplan"), "ChatGPT Go")
        XCTAssertEqual(OpenAIParser.planLabel("business"), "ChatGPT Business")
        XCTAssertEqual(OpenAIParser.planLabel("education"), "ChatGPT Edu")
        XCTAssertEqual(OpenAIParser.planLabel("edu"), "ChatGPT Edu")
        XCTAssertEqual(OpenAIParser.planLabel("k12"), "ChatGPT K12")
        XCTAssertEqual(OpenAIParser.planLabel("quorum"), "ChatGPT Quorum")
        XCTAssertEqual(OpenAIParser.planLabel("free_workspace"), "ChatGPT Free Workspace")
    }

    /// 既有优先级不能被新档位打乱。
    func testPlanLabelKeepsExistingPrecedence() {
        XCTAssertEqual(OpenAIParser.planLabel("chatgptprolite"), "ChatGPT Pro 5x")
        XCTAssertEqual(OpenAIParser.planLabel("chatgptproplan"), "ChatGPT Pro")
        XCTAssertEqual(OpenAIParser.planLabel("chatgptplusplan"), "ChatGPT Plus")
        XCTAssertEqual(OpenAIParser.planLabel("team"), "ChatGPT Team")
        XCTAssertEqual(OpenAIParser.planLabel("enterprise"), "ChatGPT Enterprise")
        XCTAssertEqual(OpenAIParser.planLabel("free"), "ChatGPT Free")
        XCTAssertEqual(OpenAIParser.planLabel("gov_pilot"), "ChatGPT（gov_pilot）",
                       "go 用词元匹配，gov 不得被误判成 Go")
    }

    func testChatGPTGoHasNoListPrice() {
        XCTAssertNil(PlanCatalog.listPrice(planName: "ChatGPT Go"), "Go 分地区定价，不进标价表")
        XCTAssertNil(PlanCatalog.listPrice(planName: "ChatGPT Business"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "ChatGPT Edu"))
    }

    // MARK: - 订阅续费 / 到期

    /// will_renew = true：会自动续费，必须清掉 accounts_check 的 expires_at，
    /// 否则到期提醒会对着续费日误报。
    func testWillRenewClearsPlanExpiry() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "accounts_check": ProbeResult(status: 200, body: try fixture("openai_accounts_check")),
                "subscriptions": ProbeResult(status: 200, body: try fixture("openai_subscriptions")),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "ChatGPT Plus")
        XCTAssertNil(snap.planExpiresAt)
    }

    func testWillNotRenewUsesActiveUntil() throws {
        let subs = #"{"active_until":"2026-12-01T00:00:00Z","will_renew":false}"#
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "accounts_check": ProbeResult(status: 200, body: try fixture("openai_accounts_check")),
                "subscriptions": ProbeResult(status: 200, body: subs),
            ],
            now: now
        )
        XCTAssertEqual(snap.planExpiresAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testMissingSubscriptionsProbeKeepsAccountsCheckExpiry() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "accounts_check": ProbeResult(status: 200, body: try fixture("openai_accounts_check")),
                "subscriptions": ProbeResult(status: 500, body: "oops"),
            ],
            now: now
        )
        XCTAssertEqual(snap.planExpiresAt, ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
    }

    // MARK: - bootstrap 登录证据

    /// session 漂移成没有邮箱时，页内 client-bootstrap 的 authStatus 顶上来。
    func testBootstrapLoggedInIsSecondaryEvidence() {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: #"{"user":{"id":"u1"}}"#),
                "bootstrap": ProbeResult(status: 200, body: #"{"authStatus":"logged_in","hasEmail":true}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "ChatGPT")
    }

    func testBootstrapHasEmailWithoutAuthStatusIsLoggedIn() {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: #"{"user":{"id":"u1"}}"#),
                "bootstrap": ProbeResult(status: 200, body: #"{"hasEmail":true}"#),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "ChatGPT")
    }

    func testBootstrapLoggedOutForcesNeedsLogin() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: #"{"user":{"id":"guest"}}"#),
                "bootstrap": ProbeResult(status: 200, body: #"{"authStatus":"logged_out","hasEmail":false}"#),
                "wham_usage": ProbeResult(status: 200, body: try fixture("openai_wham_usage")),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty, "logged_out 必须清掉游客 token 解锁的 wham leftover")
        XCTAssertNil(snap.planName)
    }

    /// 有邮箱就是最硬的证据，bootstrap 读不出来也不影响。
    func testEmailStillWinsWithoutBootstrap() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: try fixture("openai_session")),
                "bootstrap": ProbeResult(status: 204, body: "{}"),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
    }

    /// 原生 0...100：`1` / `0.5` 就是 1% / 0.5%，不能被 JSONHelp.percent 放大。
    func testUsedPercentKeepsNativeHundredths() {
        let wham = #"{"rate_limits":{"primary_window":{"used_percent":1,"limit_window_seconds":18000},"secondary_window":{"used_percent":0.5,"limit_window_seconds":604800}}}"#
        let snap = OpenAIParser.parse(results: ["wham_usage": ProbeResult(status: 200, body: wham)], now: now)
        XCTAssertEqual(snap.metrics.first { $0.id == "primary_window" }?.usedPercent, 1)
        XCTAssertEqual(snap.metrics.first { $0.id == "secondary_window" }?.usedPercent, 0.5)
    }

    // MARK: - 状态分级

    func testUnauthorizedIsNeedsLoginButServerErrorIsNot() {
        let unauthorized = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 401, body: ""),
                "wham_usage": ProbeResult(status: 401, body: ""),
            ],
            now: now
        )
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let serverError = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 500, body: "oops"),
                "wham_usage": ProbeResult(status: 500, body: "oops"),
            ],
            now: now
        )
        XCTAssertEqual(serverError.status, .error("HTTP 500"), "5xx 不该让用户白登录一次")

        let timedOut = OpenAIParser.parse(
            results: ["session": ProbeResult(status: -3, body: "timeout after 12000ms")], now: now)
        XCTAssertEqual(timedOut.status, .error("请求超时"))
    }

    func testSessionUnauthorizedDropsWhamMetrics() throws {
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 401, body: ""),
                "wham_usage": ProbeResult(status: 200, body: try fixture("openai_wham_usage")),
                "accounts_check": ProbeResult(status: 200, body: try fixture("openai_accounts_check")),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
        XCTAssertNil(snap.planName)
    }
}

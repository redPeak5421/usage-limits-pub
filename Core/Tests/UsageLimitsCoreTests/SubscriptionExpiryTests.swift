import XCTest
@testable import UsageLimitsCore

/// 订阅过期判定：站点在订阅结束后仍会列出历史 / 失效记录，套餐名不得从这些记录里取。
/// 2026-09-14 Grok 真机日志：`subscriptions` 全部 INACTIVE、`rate_limits` 只是免费档，
/// 仍被解析成 `ok / SuperGrok Heavy / 本周限额 0%`，刷新多少次都一样。
final class SubscriptionExpiryTests: XCTestCase {
    /// 2025-12-17T18:13:20Z，与 ParserTests 同一基准。
    let now = Date(timeIntervalSince1970: 1_766_000_000)
    let past = "2025-12-01T00:00:00Z"
    let future = "2026-06-01T00:00:00Z"

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Grok

    /// 免费登录档（真机 2026-09-14）：auto / fast / expert 按天，heavy 20 次 2 小时——游客态同样带 heavy 档。
    private let grokFreeTierRateLimits = #"""
    {"results":[
      {"modelName":"auto","requestKind":"DEFAULT","status":200,"body":{"remainingQueries":7,"totalQueries":7,"windowSizeSeconds":86400}},
      {"modelName":"fast","requestKind":"DEFAULT","status":200,"body":{"remainingQueries":30,"totalQueries":30,"windowSizeSeconds":86400}},
      {"modelName":"expert","requestKind":"DEFAULT","status":200,"body":{"remainingQueries":7,"totalQueries":7,"windowSizeSeconds":86400}},
      {"modelName":"heavy","requestKind":"DEFAULT","status":200,"body":{"remainingQueries":20,"totalQueries":20,"windowSizeSeconds":7200}}
    ]}
    """#

    func testGrokInactiveSubscriptionsFallBackToFreeTier() {
        let subs = #"""
        {"subscriptions":[
          {"apple":{"autoRenewOn":false},"billingInterval":"BILLING_INTERVAL_MONTHLY","cancelAtPeriodEnd":false,
           "status":"SUBSCRIPTION_STATUS_INACTIVE","tier":"SUBSCRIPTION_TIER_GROK_PRO"},
          {"billingInterval":"BILLING_INTERVAL_MONTHLY","billingPeriodEnd":"\#(past)","cancelAtPeriodEnd":true,
           "status":"SUBSCRIPTION_STATUS_INACTIVE","tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO"}
        ]}
        """#
        // 过期账号的周额度报文只剩周期、没有百分比；不得再补成 0% 挤掉免费档次数。
        let credits = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2025-12-20T00:00:00Z"}}}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: subs),
            "credits": ProbeResult(status: 200, body: credits),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "INACTIVE 记录不能当现行套餐")
        XCTAssertNil(snap.billingCycle)
        XCTAssertNil(snap.isAnonymous, "有订阅记录说明已登录，不是游客")
        XCTAssertEqual(snap.metrics.map(\.id), ["auto", "fast", "expert", "heavy"], "没有订阅就展示免费档短期次数")
    }

    func testGrokHeavyModePresenceDoesNotUpgradePlan() {
        let subs = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE"}]}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: subs),
        ], now: now)
        XCTAssertEqual(snap.planName, "SuperGrok", "heavy 档人人都有，不能据此升成 Heavy")
    }

    func testGrokActiveSubscriptionPastPeriodEndIsExpired() {
        let subs = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","billingPeriodEnd":"\#(past)"}]}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: subs),
        ], now: now)
        XCTAssertNil(snap.planName)
    }

    func testGrokCancelledButUnexpiredSubscriptionStillNamesPlan() {
        let subs = #"""
        {"subscriptions":[
          {"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_INACTIVE"},
          {"tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","cancelAtPeriodEnd":true,"billingPeriodEnd":"\#(future)"}
        ]}
        """#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: subs),
        ], now: now)
        XCTAssertEqual(snap.planName, "SuperGrok Heavy", "跳过失效记录后取仍有效的那条")
        XCTAssertEqual(snap.billingCycle, .monthly)
        XCTAssertTrue(snap.metrics.isEmpty, "付费套餐不展示短期次数")
    }

    func testGrokExpiredSubscriptionVetoesCreditsTier() {
        let subs = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_INACTIVE"}]}"#
        let credits = #"{"subscription_tier":"SuperGrok Heavy","config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2025-12-20T00:00:00Z"}}}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: subs),
            "credits": ProbeResult(status: 200, body: credits),
        ], now: now)
        XCTAssertNil(snap.planName, "订阅明确失效时，credits 里残留的 subscription_tier 不能把套餐捞回来")
        XCTAssertEqual(snap.metrics.map(\.id), ["auto", "fast", "expert", "heavy"])
    }

    func testGrokZeroPercentProductsDoNotDisplaceFreeTierCounts() {
        let credits = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2025-12-20T00:00:00Z"},"productUsage":[{"code":4,"usagePercent":0}]}}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: #"{"subscriptions":[]}"#),
            "credits": ProbeResult(status: 200, body: credits),
        ], now: now)
        XCTAssertEqual(snap.planName, "游客额度")
        XCTAssertEqual(snap.metrics.map(\.id), ["auto", "fast", "expert", "heavy"], "全 0% 的产品占比不算线上给了用量")
    }

    func testGrokCanceledStatusWithFuturePeriodEndStillNamesPlan() {
        let subs = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_CANCELED","billingPeriodEnd":"\#(future)"}]}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grokFreeTierRateLimits),
            "subscriptions": ProbeResult(status: 200, body: subs),
        ], now: now)
        XCTAssertEqual(snap.planName, "SuperGrok Heavy", "已取消但账期未到仍可用")
    }

    // MARK: - 智谱

    func testZhipuExpiredRowDoesNotNamePlan() throws {
        let body = #"""
        {"code":200,"data":[{"productId":"product-733034","productName":"GLM Coding Pro","status":"EXPIRED",
         "valid":"2024-01-24 10:00:00-2025-01-24 10:00:00"}]}
        """#
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: #"{"data":{"customerNumber":"10001"}}"#),
            "subscription": ProbeResult(status: 200, body: body),
            "model_usage": ProbeResult(status: 200, body: try fixture("zhipu_model_usage")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "没有 VALID 记录时不得回落到第一条")
        XCTAssertNil(snap.planProductID)
        XCTAssertNil(snap.planExpiresAt)
    }

    func testZhipuRowWithoutStatusUsesValidEnd() {
        func parse(_ valid: String) -> ProviderSnapshot {
            ZhipuParser.parse(results: [
                "customer": ProbeResult(status: 200, body: #"{"data":{"customerNumber":"10001"}}"#),
                "subscription": ProbeResult(status: 200, body: #"{"code":200,"data":[{"productId":"product-733034","valid":"\#(valid)"}]}"#),
            ], now: now)
        }
        XCTAssertNil(parse("2024-01-24 10:00:00-2025-01-24 10:00:00").planName, "没有 status 字段但有效期已过")
        XCTAssertEqual(parse("2025-06-24 10:00:00-2026-06-24 10:00:00").planName, "Coding Plan Pro")
    }

    func testZhipuQuotaPlanNameDoesNotResurrectExpiredSubscription() {
        let sub = #"{"code":200,"data":[{"productId":"product-733034","productName":"GLM Coding Pro","status":"EXPIRED"}]}"#
        let quota = #"{"code":200,"data":{"planName":"GLM Coding Pro","limits":[]}}"#
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: #"{"data":{"customerNumber":"10001"}}"#),
            "subscription": ProbeResult(status: 200, body: sub),
            "quota": ProbeResult(status: 200, body: quota),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "订阅接口有记录但全部失效时，quota 的套餐名字段不再兜底")
    }

    func testZhipuUnknownStatusIsJudgedByValidEnd() {
        func parse(_ status: String, _ valid: String) -> ProviderSnapshot {
            ZhipuParser.parse(results: [
                "customer": ProbeResult(status: 200, body: #"{"data":{"customerNumber":"10001"}}"#),
                "subscription": ProbeResult(status: 200, body: #"{"code":200,"data":[{"productId":"product-733034","status":"\#(status)","valid":"\#(valid)"}]}"#),
            ], now: now)
        }
        XCTAssertEqual(parse("NORMAL", "2025-06-24 10:00:00-2026-06-24 10:00:00").planName, "Coding Plan Pro", "未知状态不当失效，按有效期判")
        XCTAssertEqual(parse("", "2025-06-24 10:00:00-2026-06-24 10:00:00").planName, "Coding Plan Pro", "空串状态等于没有状态")
        XCTAssertNil(parse("VALID", "2024-01-24 10:00:00-2025-01-24 10:00:00").planName, "VALID 但有效期已过也不算现行")
        XCTAssertNil(parse("INVALID", "2025-06-24 10:00:00-2026-06-24 10:00:00").planName)
        XCTAssertEqual(parse("CANCELED", "2025-06-24 10:00:00-2026-06-24 10:00:00").planName, "Coding Plan Pro", "取消续费但期内仍可用，与 Grok / Kimi 同规则")
    }

    // MARK: - Kimi

    func testKimiEndedSubscriptionDoesNotNamePlan() throws {
        let sub = #"""
        {"subscription":{"subscriptionId":"sub-demo","goods":{"title":"Allegretto","billingCycle":{"duration":1,"timeUnit":"TIME_UNIT_YEAR"}},
         "currentEndTime":"\#(past)","nextBillingTime":"\#(past)","status":"SUBSCRIPTION_STATUS_CANCEL"}}
        """#
        let snap = KimiParser.parse(results: [
            "user": ProbeResult(status: 200, body: try fixture("kimi_user")),
            "subscription": ProbeResult(status: 200, body: sub),
            "usages": ProbeResult(status: 200, body: try fixture("kimi_usages")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "currentEndTime 已过就是没有现行套餐；CANCEL 本身不算（续费关闭但仍在期内）")
        XCTAssertNil(snap.billingCycle)
        XCTAssertNil(snap.planExpiresAt)
    }

    func testKimiSubscriptionListSkipsEndedRows() {
        let list = #"""
        {"subscriptions":[
          {"goods":{"title":"Allegretto"},"currentEndTime":"\#(past)"},
          {"goods":{"title":"Moderato","billingCycle":{"duration":1,"timeUnit":"TIME_UNIT_MONTH"}},"currentEndTime":"\#(future)"}
        ]}
        """#
        let snap = KimiParser.parse(results: [
            "subscriptions": ProbeResult(status: 200, body: list),
        ], now: now)
        XCTAssertEqual(snap.planName, "Kimi Code Moderato")
        XCTAssertEqual(snap.planExpiresAt, JSONHelp.date(future))
    }

    // MARK: - T3 Chat

    func testT3ChatEndedSubscriptionDoesNotNamePlan() {
        let line = #"{"json":[2,0,[[{"subTier":"pro","usageBand":"max","usageFourHourPercentage":12.5,"usageFourHourNextResetAt":1779366216920,"subscription":{"productName":"pro","currentPeriodEnd":1764000000000}}]]]}"#
        let snap = T3ChatParser.parse(results: ["customer": ProbeResult(status: 200, body: line)], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "currentPeriodEnd 已过，subTier 也是残留")
        XCTAssertEqual(snap.metrics.first?.id, "four_hour")
    }

    // MARK: - Augment

    func testAugmentPastBillingPeriodEndDoesNotNamePlan() throws {
        let snap = AugmentParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("augment_credits")),
            "subscription": ProbeResult(status: 200, body: #"{"planName":"Developer","billingPeriodEnd":"\#(past)"}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName)
        XCTAssertEqual(snap.metrics.first?.id, "credits")
    }

    // MARK: - Abacus

    func testAbacusPastNextBillingDateDoesNotNamePlan() throws {
        let snap = AbacusParser.parse(results: [
            "compute_points": ProbeResult(status: 200, body: try fixture("abacus_compute_points")),
            "billing": ProbeResult(status: 200, body: #"{"success":true,"result":{"currentTier":"pro","nextBillingDate":"\#(past)"}}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName)
        XCTAssertEqual(snap.metrics.first?.id, "compute_points")
    }
}

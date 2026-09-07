import XCTest
@testable import UsageLimitsCore

/// DeepSeek 补齐项：钱包按币种分组、充值 / 赠送拆分、token 分类、按模型维度、业务错误码。
final class DeepSeekGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 钱包按币种分组

    /// 同时持有 USD + CNY 钱包时绝不能横加：选中的是「有钱的 USD」，
    /// 余额 = USD 充值 12.5 + USD 赠送 2.5 = 15，CNY 的 30 不参与。
    func testMultiCurrencyWalletsAreNotSummedTogether() throws {
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: try fixture("deepseek_current")),
            "summary": ProbeResult(status: 200, body: try fixture("deepseek_summary_multi_currency")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.currency, "USD")
        let balance = try XCTUnwrap(snap.metrics.first { $0.id == "balance" })
        XCTAssertEqual(balance.amount ?? 0, 15.0, accuracy: 0.0001)
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertNotEqual(balance.amount ?? 0, 45.0, "USD 与 CNY 余额不得相加")
        // 累计消费同样只取选中币种，不把 ¥100 混进 $ 里。
        let spent = try XCTUnwrap(snap.metrics.first { $0.id == "total_spent" })
        XCTAssertEqual(spent.amount ?? 0, 8.0, accuracy: 0.0001)
        XCTAssertEqual(spent.currency, "USD")
    }

    /// 单币种（官网常态）：口径与旧行为一致，充值 + 赠送合并成「重置余额」。
    func testSingleCurrencyWalletKeepsCombinedBalance() throws {
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: try fixture("deepseek_current")),
            "summary": ProbeResult(status: 200, body: try fixture("deepseek_summary")),
        ], now: now)
        XCTAssertEqual(snap.currency, "CNY")
        let balance = try XCTUnwrap(snap.metrics.first { $0.id == "balance" })
        XCTAssertEqual(balance.amount ?? 0, 54.48446148, accuracy: 0.0001)
    }

    /// 只有 CNY 有钱时选 CNY；USD 空钱包不抢先。
    func testCurrencyPickerPrefersFundedOverEmptyUSD() {
        let body = """
        {"code":0,"data":{"biz_data":{
          "normal_wallets":[{"currency":"USD","balance":"0"},{"currency":"CNY","balance":"12.00"}],
          "bonus_wallets":[],
          "total_costs":[{"currency":"CNY","amount":"3.00"}]}}}
        """
        let snap = DeepSeekParser.parse(results: [
            "summary": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.currency, "CNY")
        XCTAssertEqual(snap.metrics.first { $0.id == "balance" }?.amount ?? 0, 12.0, accuracy: 0.0001)
    }

    // MARK: - 充值 / 赠送拆分

    func testPaidAndGrantedBalancesAreSplitOut() throws {
        let snap = DeepSeekParser.parse(results: [
            "summary": ProbeResult(status: 200, body: try fixture("deepseek_summary_multi_currency")),
        ], now: now)
        let paid = try XCTUnwrap(snap.metrics.first { $0.id == "balance_paid" })
        XCTAssertEqual(paid.label, "充值余额")
        XCTAssertEqual(paid.amount ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertEqual(paid.currency, "USD")
        let granted = try XCTUnwrap(snap.metrics.first { $0.id == "balance_granted" })
        XCTAssertEqual(granted.label, "赠送余额")
        XCTAssertEqual(granted.amount ?? 0, 2.5, accuracy: 0.0001)
        // 折叠态两条金额仍排在最前，不打乱预充值卡布局。
        XCTAssertEqual(Array(snap.metrics.prefix(2).map(\.id)), ["balance", "total_spent"])
    }

    /// 赠送钱包为 0（官网常态）时不产出「赠送余额」，避免堆一条 ¥0.00。
    func testZeroGrantedWalletProducesNoMetric() throws {
        let snap = DeepSeekParser.parse(results: [
            "summary": ProbeResult(status: 200, body: try fixture("deepseek_summary")),
        ], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "balance_granted" })
        XCTAssertNotNil(snap.metrics.first { $0.id == "balance_paid" })
    }

    // MARK: - token 分类与按模型维度

    func testTokenCategoriesAndModelBreakdowns() throws {
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: try fixture("deepseek_current")),
            "usage_periods": ProbeResult(status: 200, body: try fixture("deepseek_usage_periods_models")),
        ], now: now)
        let period = try XCTUnwrap(snap.timeBreakdowns?.first { $0.id == "last_7d" })
        XCTAssertEqual(period.cacheHitTokens ?? 0, 9500, accuracy: 0.1)
        XCTAssertEqual(period.cacheMissTokens ?? 0, 2500, accuracy: 0.1)
        XCTAssertEqual(period.outputTokens ?? 0, 1500, accuracy: 0.1)
        // tokens 仍是三类之和，折叠数字口径不变。
        XCTAssertEqual(period.tokens ?? 0, 13500, accuracy: 0.1)
        XCTAssertEqual(period.requests ?? 0, 15, accuracy: 0.1)

        let models = try XCTUnwrap(snap.modelBreakdowns)
        // 消耗金额多的排前面：reasoner ¥4 > v4-flash ¥1
        XCTAssertEqual(models.map(\.id), ["deepseek-reasoner", "deepseek-v4-flash"])
        let flash = try XCTUnwrap(models.first { $0.id == "deepseek-v4-flash" })
        XCTAssertEqual(flash.cost ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(flash.requests ?? 0, 10, accuracy: 0.1)
        XCTAssertEqual(flash.tokens ?? 0, 11000, accuracy: 0.1)
    }

    /// 旧 fixture（单模型）也要有按模型维度，且不影响既有的按 Key 维度。
    func testSingleModelStillProducesModelBreakdown() throws {
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: try fixture("deepseek_current")),
            "usage_periods": ProbeResult(status: 200, body: try fixture("deepseek_usage_periods")),
        ], now: now)
        let models = try XCTUnwrap(snap.modelBreakdowns)
        XCTAssertEqual(models.map(\.id), ["deepseek-v4-flash"])
        XCTAssertFalse(try XCTUnwrap(snap.keyBreakdowns).isEmpty)
    }

    /// modelBreakdowns 是 optional Codable 字段：老快照没有它也能解出来。
    func testSnapshotDecodesWithoutModelBreakdowns() throws {
        let snap = ProviderSnapshot(
            provider: .deepseek, fetchedAt: now, status: .ok,
            modelBreakdowns: [UsageBreakdown(id: "m", label: "m", cost: 1, cacheHitTokens: 2)]
        )
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
        XCTAssertEqual(back.modelBreakdowns?.first?.id, "m")
        XCTAssertEqual(back.modelBreakdowns?.first?.cacheHitTokens, 2)

        // 老快照（没有 modelBreakdowns 键）必须照常解出来，字段为 nil。
        let legacy = ProviderSnapshot(provider: .deepseek, fetchedAt: now, status: .ok)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyText = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        XCTAssertFalse(legacyText.contains("modelBreakdowns"), "字段为 nil 时不落盘")
        XCTAssertNil(try JSONDecoder().decode(ProviderSnapshot.self, from: legacyData).modelBreakdowns)
    }

    // MARK: - 业务错误码与状态

    /// 40002 Missing Token / 40003 会话过期：HTTP 仍 200，必须判 needsLogin。
    func testBusinessCode40003IsNeedsLogin() {
        let body = #"{"code":40003,"msg":"Token expired","data":null}"#
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    /// 其它业务码进错误文案，排障时能直接看到码与 msg。
    func testOtherBusinessCodeSurfacesInError() {
        let body = #"{"code":50001,"msg":"internal error","data":null}"#
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: body),
            "summary": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.status, .error("DeepSeek code 50001: internal error"))
    }

    /// biz_code 也算业务错误（外层 code 为 0 时）。
    func testBizCodeSurfacesInError() {
        let body = #"{"code":0,"msg":"","data":{"biz_code":40105,"biz_msg":"biz down"}}"#
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.status, .error("DeepSeek code 40105: biz down"))
    }

    /// 401 → needsLogin；500 → error("HTTP 500")，不误报"请重新登录"。
    func testUnauthorizedVsServerError() {
        let unauthorized = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 403, body: ""),
        ], now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let serverError = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 500, body: "boom"),
        ], now: now)
        XCTAssertEqual(serverError.status, .error("HTTP 500"))

        let timeout = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ], now: now)
        XCTAssertEqual(timeout.status, .error("请求超时"))
    }

    /// 合成 usage_periods 壳永远 200；子探针 401/5xx 即使带用量形状也不得进 today/本月。
    func testFailedUsagePeriodChildrenDoNotContributeQuota() throws {
        let poison = #"{"code":0,"data":{"biz_data":{"data":[{"series":[{"model":"deepseek-v4-flash","buckets":[{"cost":99.0}]}]}]}}}"#
        let good = #"{"code":0,"data":{"biz_data":{"data":[{"series":[{"model":"deepseek-v4-flash","buckets":[{"cost":1.5}]}]}]}}}"#
        let periods: [String: Any] = [
            "today": [
                "start": 1, "end": 2,
                "cost": ["status": 401, "body": poison],
            ],
            "this_month": [
                "start": 1, "end": 2,
                "cost": ["status": 200, "body": good],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: periods)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: #"{"code":0,"data":{"id":"u1","currency":"CNY"}}"#),
            "usage_periods": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.timeBreakdowns?.first { $0.id == "today" }?.cost)
        XCTAssertEqual(
            try XCTUnwrap(snap.timeBreakdowns?.first { $0.id == "this_month" }).cost ?? 0,
            1.5,
            accuracy: 0.0001
        )
    }

    /// 业务码不得盖掉已经解出的用量：能解出余额就是已登录。
    func testBusinessCodeDoesNotOverrideParsedUsage() throws {
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: #"{"code":40002,"msg":"Missing Token","data":null}"#),
            "summary": ProbeResult(status: 200, body: try fixture("deepseek_summary")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
    }

    func testEmptyUsagePeriodBlocksDoNotEmitBlankCharts() {
        let body = """
        {"today":{"cost":{"status":200,"body":"{}"},"amount":{"status":200,"body":"{}"}},
         "this_month":{"cost":{"status":200,"body":"{}"},"amount":{"status":200,"body":"{}"}}}
        """
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: #"{"code":0,"data":{"id":"u1"}}"#),
            "usage_periods": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertNil(snap.timeBreakdowns, "空子探针不得产出空白图表")
    }

    /// api_keys 200 但 usage 为空时不得产出只有 lastUsed 的 ¥0 key 行。
    func testApiKeysWithoutUsageDoNotEmitGhostKeyBreakdowns() {
        let keys = #"{"code":0,"data":{"biz_data":{"api_keys":[{"tracking_id":"k1","name":"prod","last_used":1700000000}]}}}"#
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: #"{"code":0,"data":{"id":"u1"}}"#),
            "usage_periods": ProbeResult(status: 200, body: """
            {"today":{"cost":{"status":200,"body":"{}"},"amount":{"status":200,"body":"{}"}}}
            """),
            "api_keys": ProbeResult(status: 200, body: keys),
        ], now: now)
        XCTAssertNil(snap.timeBreakdowns)
        XCTAssertNil(snap.keyBreakdowns, "没有用量派生的 key 行时 api_keys 不得补鬼行")
    }

    /// 已有用量 key 时 api_keys 只补显示名 / lastUsed，不得插入从未消耗的 key。
    func testApiKeysEnrichExistingUsageKeyBreakdowns() throws {
        let cost = #"{"code":0,"data":{"biz_data":{"data":[{"series":[{"api_key":{"tracking_id":"k1","name":"old"},"model":"deepseek-v4-flash","buckets":[{"cost":1.5}]}]}]}}}"#
        let keys = #"{"code":0,"data":{"biz_data":{"api_keys":[{"tracking_id":"k1","name":"prod","last_used":1700000000},{"tracking_id":"k2","name":"idle","last_used":1700000001}]}}}"#
        let periods: [String: Any] = [
            "this_month": [
                "start": 1, "end": 2,
                "cost": ["status": 200, "body": cost],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: periods)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: #"{"code":0,"data":{"id":"u1"}}"#),
            "usage_periods": ProbeResult(status: 200, body: body),
            "api_keys": ProbeResult(status: 200, body: keys),
        ], now: now)
        let rows = try XCTUnwrap(snap.keyBreakdowns)
        XCTAssertEqual(rows.map(\.id), ["k1"])
        XCTAssertEqual(rows[0].label, "prod")
        XCTAssertEqual(rows[0].cost ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(rows[0].lastUsed, Date(timeIntervalSince1970: 1_700_000_000))
    }

}

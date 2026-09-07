import XCTest
@testable import UsageLimitsCore

/// 智谱补齐项：`unit` 窗口映射（周额度不再被吞）、CREDIT_LIMIT、百分比细化、
/// 信封校验、套餐名字段覆盖面、高峰 / 低谷时段、MCP 按工具明细。
final class ZhipuGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func quotaSnapshot() throws -> ProviderSnapshot {
        ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: try fixture("zhipu_customer")),
            "quota": ProbeResult(status: 200, body: try fixture("zhipu_quota_limit_units")),
        ], now: now)
    }

    // MARK: - 窗口映射（G-ZP-1 / G-ZP-2）

    /// 5 小时与每周都是 TOKENS_LIMIT：按 windowMinutes 升序，最短→five_hour、最长→seven_day。
    /// 修复前两条都会变成 id `five_hour`，周额度被彻底吞掉。
    func testWeeklyTokensLimitIsNoLongerSwallowedByFiveHour() throws {
        let snap = try quotaSnapshot()
        XCTAssertEqual(snap.status, .ok)
        let five = try XCTUnwrap(snap.metrics.first { $0.id == "five_hour" })
        XCTAssertEqual(five.label, "每 5 小时")
        XCTAssertEqual(five.usedPercent, 1)
        XCTAssertEqual(five.pinned, true)
        let weekly = try XCTUnwrap(snap.metrics.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.label, "每周")
        XCTAssertNotNil(weekly.resetsAt)
        XCTAssertEqual(snap.metrics.filter { $0.id == "five_hour" }.count, 1)
    }

    /// 中间窗口（这里是 CREDIT_LIMIT 的每天）独立成条，标签带「（积分）」。
    func testCreditLimitGetsChineseLabelAndMiddleWindowID() throws {
        let snap = try quotaSnapshot()
        let credit = try XCTUnwrap(snap.metrics.first { $0.id == "window_1440" })
        XCTAssertEqual(credit.label, "每天（积分）")
        XCTAssertEqual(credit.usedPercent ?? 0, 20, accuracy: 0.001)
        XCTAssertFalse(snap.metrics.contains { $0.label == "CREDIT_LIMIT" }, "不得产出英文兜底标签")
    }

    /// 排序按窗口时长升序：5 小时 → 每天 → 每周。
    func testQuotaFamilySortedByWindowLength() {
        let rows: [[String: Any]] = [
            ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 10],
            ["type": "CREDIT_LIMIT", "unit": 1, "number": 1, "percentage": 20],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 30],
        ]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertEqual(metrics.map(\.id), ["five_hour", "window_1440", "seven_day", "rate_period"])
    }

    /// 只有一条 5 小时 TOKENS_LIMIT 时保持 `five_hour`。
    func testSingleTokensLimitStaysFiveHour() {
        let rows: [[String: Any]] = [["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 7]]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertEqual(metrics.map(\.id), ["five_hour"])
    }

    /// 缺 unit/number 时整条丢掉，不得因数组位置猜成 5h / 每周。
    func testMissingDurationDoesNotGuessFiveHourOrWeekly() {
        let rows: [[String: Any]] = [
            ["type": "TOKENS_LIMIT", "percentage": 10],
            ["type": "TOKENS_LIMIT", "percentage": 20],
        ]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertFalse(metrics.contains { $0.id == "five_hour" || $0.id == "seven_day" || $0.id.hasPrefix("window_") })
    }

    /// 只有一条每周窗口时必须按时长识别为 `seven_day`，不能因为是数组第一项就标成 5h。
    func testSingleWeeklyTokensLimitIsSevenDay() {
        let rows: [[String: Any]] = [["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 11]]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertEqual(metrics.map(\.id), ["seven_day"])
        XCTAssertEqual(metrics.first?.label, "每周")
        XCTAssertNil(metrics.first?.pinned)
    }

    /// 先出现的业务信封不能盖掉后面的登录信封。
    func testLoginEnvelopeWinsOverEarlierBusinessEnvelope() {
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: #"{"code":500,"msg":"boom","success":false}"#),
            "quota": ProbeResult(status: 200, body: #"{"code":401,"msg":"unauthorized","success":false}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    /// 窗口时长不是 5 小时 / 1 周时，标签用真实时长而不是硬写「每 5 小时」。
    func testWindowLabelUsesRealDuration() {
        XCTAssertEqual(ZhipuParser.windowLabel(300), "每 5 小时")
        XCTAssertEqual(ZhipuParser.windowLabel(180), "每 3 小时")
        XCTAssertEqual(ZhipuParser.windowLabel(10080), "每周")
        XCTAssertEqual(ZhipuParser.windowLabel(20160), "每 2 周")
        XCTAssertEqual(ZhipuParser.windowLabel(43200), "每 30 天")
        XCTAssertEqual(ZhipuParser.windowLabel(1440), "每天")
        XCTAssertEqual(ZhipuParser.windowLabel(nil), "限额")
    }

    /// 未知 type 直接丢弃，不再产出英文标签的兜底指标。
    func testUnknownTypeIsDropped() {
        let rows: [[String: Any]] = [["type": "SOMETHING_NEW", "unit": 3, "number": 1, "percentage": 50]]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertTrue(metrics.isEmpty)
    }

    // MARK: - 百分比细化（G-ZP-9）

    /// usage>0 时用 used = max(usage - remaining, currentValue) 重算：
    /// max(200-50, 120) = 150 → 75%，比整数 percentage(60) 精细。
    func testPercentRefinedFromUsageAndRemaining() throws {
        let snap = try quotaSnapshot()
        let weekly = try XCTUnwrap(snap.metrics.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.usedPercent ?? 0, 75, accuracy: 0.001)
    }

    /// 没有 usage 时回退到 percentage（已是 0–100，不得再乘 100）。
    func testPercentFallsBackToPercentageWithoutScaling() {
        let rows: [[String: Any]] = [["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 1]]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertEqual(metrics.first?.usedPercent ?? 0, 1, accuracy: 0.001)
    }

    /// 已用超出总量（官网偶发）时钳到 100，不产出 120%。
    func testPercentIsClamped() {
        let rows: [[String: Any]] = [
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5,
             "usage": 100, "currentValue": 130, "remaining": 0, "percentage": 99],
        ]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertEqual(metrics.first?.usedPercent ?? 0, 100, accuracy: 0.001)
    }

    // MARK: - 信封校验（G-ZP-8）与状态

    func testEnvelopeFailureSurfacesMessage() {
        let body = #"{"code":500,"msg":"系统异常，请稍后重试","success":false}"#
        let snap = ZhipuParser.parse(results: ["quota": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.status, .error("智谱接口失败 code 500"))
        XCTAssertEqual(snap.status.displayText(.en), L10n.trError("智谱接口失败 code 500", .en))
        XCTAssertFalse(snap.status.displayText(.en).contains("系统异常"))
    }

    func testEnvelopeLoginFailureIsNeedsLogin() {
        let body = #"{"code":401,"msg":"unauthorized","success":false}"#
        let snap = ZhipuParser.parse(results: ["quota": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    /// 能解出用量时信封里的历史错误不该盖掉 ok。
    func testEnvelopeFailureDoesNotOverrideParsedQuota() throws {
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: #"{"code":500,"msg":"boom","success":false}"#),
            "quota": ProbeResult(status: 200, body: try fixture("zhipu_quota_limit_units")),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
    }

    /// 403 → needsLogin；503 → error("HTTP 503")。
    func testUnauthorizedVsServerError() {
        XCTAssertEqual(
            ZhipuParser.parse(results: ["customer": ProbeResult(status: 403, body: "")], now: now).status,
            .needsLogin
        )
        XCTAssertEqual(
            ZhipuParser.parse(results: ["customer": ProbeResult(status: 503, body: "")], now: now).status,
            .error("HTTP 503")
        )
    }

    // MARK: - 套餐名字段（G-ZP-7）

    /// 没有 subscription 时用 quota 的 planName（优先于 level）。
    func testPlanNameKeyIsUsedWhenSubscriptionMissing() throws {
        let snap = try quotaSnapshot()
        XCTAssertEqual(snap.planName, "Coding Plan Max")
    }

    func testPlanKeysFallbackOrder() {
        for key in ["planName", "plan", "plan_type", "packageName", "level"] {
            let body = "{\"code\":200,\"success\":true,\"data\":{\"limits\":[],\"\(key)\":\"GLM Coding Lite\"}}"
            let snap = ZhipuParser.parse(results: ["quota": ProbeResult(status: 200, body: body)], now: now)
            XCTAssertEqual(snap.planName, "Coding Plan Lite", "\(key) 应能解出套餐名")
        }
    }

    // MARK: - MCP 按工具明细（G-ZP-3）

    func testMCPMetricCarriesTopTools() throws {
        let snap = try quotaSnapshot()
        let mcp = try XCTUnwrap(snap.metrics.first { $0.id == "mcp_monthly" })
        XCTAssertEqual(mcp.label, "MCP 每月额度")
        XCTAssertEqual(mcp.detail, "search-prime 12 · web-reader 3")
    }

    func testMCPDetailKeepsAtMostFiveToolsSortedByUsage() {
        let details: [(code: String, usage: Double)] = [
            ("a", 1), ("b", 6), ("c", 5), ("d", 4), ("e", 3), ("f", 2),
        ]
        XCTAssertEqual(ZhipuParser.topToolsDetail(details), "b 6 · c 5 · d 4 · e 3 · f 2")
        XCTAssertNil(ZhipuParser.topToolsDetail([("a", 0), ("b", 0)]), "全 0 时不编造明细")
    }

    // MARK: - 高峰 / 低谷（G-ZP-10）

    /// 高峰 = 周一至周五 UTC 06:00–10:00（UTC+8 的 14:00–18:00）。
    func testPeakWindowAtFixedInstants() {
        // 2026-08-26 是周三。UTC 07:00 在高峰内，下次切换是当天 10:00。
        let inPeak = ZhipuParser.peakWindow(now: iso("2026-08-26T07:00:00Z"))
        XCTAssertTrue(inPeak.isPeak)
        XCTAssertEqual(inPeak.nextSwitch, iso("2026-08-26T10:00:00Z"))

        // 同日 11:00 已过高峰：下次高峰是明天（周四）06:00。
        let afterPeak = ZhipuParser.peakWindow(now: iso("2026-08-26T11:00:00Z"))
        XCTAssertFalse(afterPeak.isPeak)
        XCTAssertEqual(afterPeak.nextSwitch, iso("2026-08-27T06:00:00Z"))

        // 同日 03:00 尚未进入：下次切换是当天 06:00。
        let beforePeak = ZhipuParser.peakWindow(now: iso("2026-08-26T03:00:00Z"))
        XCTAssertFalse(beforePeak.isPeak)
        XCTAssertEqual(beforePeak.nextSwitch, iso("2026-08-26T06:00:00Z"))

        // 边界：06:00 已算高峰，10:00 已不算。
        XCTAssertTrue(ZhipuParser.peakWindow(now: iso("2026-08-26T06:00:00Z")).isPeak)
        XCTAssertFalse(ZhipuParser.peakWindow(now: iso("2026-08-26T10:00:00Z")).isPeak)
    }

    /// 周末全天低谷，下一次高峰跳过周六周日直接落到周一 06:00。
    func testWeekendIsAlwaysOffPeak() {
        // 2026-08-29 周六 08:00 —— 落在 06–10 但不是工作日。
        let saturday = ZhipuParser.peakWindow(now: iso("2026-08-29T08:00:00Z"))
        XCTAssertFalse(saturday.isPeak)
        XCTAssertEqual(saturday.nextSwitch, iso("2026-08-31T06:00:00Z"))

        // 周五 11:00 之后同样要跳过周末。
        let friday = ZhipuParser.peakWindow(now: iso("2026-08-28T11:00:00Z"))
        XCTAssertFalse(friday.isPeak)
        XCTAssertEqual(friday.nextSwitch, iso("2026-08-31T06:00:00Z"))
    }

    /// 只有积分计划（存在 CREDIT_LIMIT）才产出计费时段行。
    func testRatePeriodMetricOnlyForCreditPlans() throws {
        let snap = try quotaSnapshot()
        let rate = try XCTUnwrap(snap.metrics.first { $0.id == "rate_period" })
        XCTAssertEqual(rate.label, "计费时段")
        XCTAssertTrue(["高峰 1x", "低谷 0.5x"].contains(rate.displayValue ?? ""))
        XCTAssertNotNil(rate.resetsAt)

        let tokenRows: [[String: Any]] = [["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 1]]
        let tokenOnly = ZhipuParser.quotaMetrics(tokenRows, now: now)
        XCTAssertFalse(tokenOnly.contains { $0.id == "rate_period" }, "纯 token 套餐没有高峰倍率")
    }

    // MARK: - 与 model-usage 的 id 冲突

    /// quota 已产出周窗口时，近 7 天 Token 换 id，避免两条 seven_day。
    func testWeeklyTokensMetricDoesNotCollideWithQuotaWindow() throws {
        let snap = ZhipuParser.parse(results: [
            "quota": ProbeResult(status: 200, body: try fixture("zhipu_quota_limit_units")),
            "model_usage": ProbeResult(status: 200, body: try fixture("zhipu_model_usage")),
        ], now: now)
        XCTAssertEqual(snap.metrics.filter { $0.id == "seven_day" }.count, 1)
        let tokens = try XCTUnwrap(snap.metrics.first { $0.id == "seven_day_tokens" })
        XCTAssertEqual(tokens.label, "近 7 天 Token")
    }

    func testZhipuMdIdsAreDurationOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let md = try String(
            contentsOf: root.appendingPathComponent("providers/zhipu.md"), encoding: .utf8
        )
        XCTAssertTrue(md.contains("id 只看窗口时长"), "目录须锁 duration-based family id")
        XCTAssertFalse(
            md.contains("最短的一条 → id `five_hour`"),
            "禁止再按数组位次/最短最长猜 5h/周"
        )
    }

    private func iso(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text) ?? .distantPast
    }

    func testCustomerLoginEnvelopeWinsOverSuccessfulQuota() throws {
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 200, body: #"{"code":1001,"msg":"unauthorized","success":false}"#),
            "quota": ProbeResult(status: 200, body: try fixture("zhipu_quota_limit_units")),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty, "登录信封赢整轮，quota 数字不得留下")
    }

    func testCustomerHTTPUnauthorizedWinsOverSuccessfulQuota() throws {
        let snap = ZhipuParser.parse(results: [
            "customer": ProbeResult(status: 401, body: ""),
            "quota": ProbeResult(status: 200, body: try fixture("zhipu_quota_limit_units")),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty, "customer HTTP 401 赢整轮，quota leftover 不得留下")
    }

}

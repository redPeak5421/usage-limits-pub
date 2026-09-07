import XCTest
@testable import UsageLimitsCore

/// OpenCode 补齐项：`_server` GET 腿的 seroval 解码规则、SSR 兜底载荷、解析器的边界口径。
/// 规则原文见 `providers/opencode.md`。
final class OpenCodeGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "缺少 fixture: \(name).\(ext)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func providerScriptsURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UsageLimitsCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // repo
            .appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    // MARK: - seroval 解码

    func testSerovalReadsRealBillingStream() throws {
        let text = try fixture("opencode_billing_seroval", "txt")
        XCTAssertEqual(OpenCodeSeroval.string(text, field: "customerID"), "cus_TEST")
        XCTAssertEqual(OpenCodeSeroval.number(text, field: "balance"), 1_250_000_000)
        XCTAssertEqual(OpenCodeSeroval.number(text, field: "monthlyLimit"), 20)
        XCTAssertEqual(OpenCodeSeroval.number(text, field: "monthlyUsage"), 1_500_000_000)
        XCTAssertEqual(OpenCodeSeroval.bool(text, field: "reload"), true, "!0 是 true")
        XCTAssertEqual(
            OpenCodeSeroval.string(text, field: "timeMonthlyUsageUpdated"), "2026-07-29T14:45:11.000Z",
            "必须剥掉 new Date(\"…\") 包装"
        )
        XCTAssertNil(OpenCodeSeroval.string(text, field: "subscriptionID"), "subscriptionID 是 null，不能取到值")
        XCTAssertEqual(
            OpenCodeSeroval.string(text, field: "liteSubscriptionID"), "sub_TEST",
            "liteSubscriptionID 与 subscriptionID 必须靠左边界区分开"
        )
        XCTAssertFalse(OpenCodeSeroval.isExplicitNull(text))
    }

    /// 解出来的 JSON 必须能直接喂给 `OpenCodeParser`，与页面 runtime 腿产出同一份形状。
    func testSerovalBillingJSONFeedsParserUnchanged() throws {
        let text = try fixture("opencode_billing_seroval", "txt")
        let body = try XCTUnwrap(OpenCodeSeroval.billingJSON(text))
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status", "json")),
            "billing": ProbeResult(status: 200, body: body),
            "lite": ProbeResult(status: 200, body: "null"),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName, "subscriptionID / timeSubscriptionBooked 都是 null，不是 Black")
        let balance = try XCTUnwrap(snap.metrics.first { $0.id == "balance" })
        XCTAssertEqual(balance.amount ?? 0, 12.5, accuracy: 0.000001)
        let limit = try XCTUnwrap(snap.metrics.first { $0.id == "monthly_limit" })
        XCTAssertEqual(limit.detail, "上限 $20.00")
    }

    /// customerID 守卫：无关载荷（错误页 / 别的函数返回值）里就算有 balance 也不许信。
    func testSerovalBillingRequiresCustomerIDGuard() {
        XCTAssertNil(OpenCodeSeroval.billingJSON("{\"balance\":999999999999}"))
        XCTAssertNotNil(OpenCodeSeroval.billingJSON("{\"customerID\":\"cus_x\",\"balance\":100000000}"))
    }

    /// 显式 null 尾巴：函数返回 null 时不许再换腿重试（POST 会被官网回 500）。
    func testSerovalExplicitNullTail() {
        let tail = ";0x0000001f;((self.$R=self.$R||{})[\"server-fn:00000000-0000-4000-8000-000000000000\"]=[],null)"
        XCTAssertTrue(OpenCodeSeroval.isExplicitNull(tail))
        XCTAssertTrue(OpenCodeSeroval.isExplicitNull("  null \n"))
        XCTAssertFalse(OpenCodeSeroval.isExplicitNull("{\"mine\":true}"))
        XCTAssertEqual(OpenCodeSeroval.billingJSON(tail), "null")
        XCTAssertEqual(OpenCodeSeroval.windowsJSON(tail), "null")
    }

    func testSerovalFirstWorkspaceID() {
        XCTAssertEqual(
            OpenCodeSeroval.firstWorkspaceID("($R=>$R[0]=[$R[1]={id:\"wrk_first\",name:\"A\"},$R[2]={id:\"wrk_second\"}])"),
            "wrk_first"
        )
        XCTAssertEqual(OpenCodeSeroval.firstWorkspaceID("[{\"id\":\"wrk_json\"}]"), "wrk_json")
        XCTAssertEqual(OpenCodeSeroval.firstWorkspaceID("prefix wrk_bare tail"), "wrk_bare")
        XCTAssertNil(OpenCodeSeroval.firstWorkspaceID("{\"error\":\"unauthorized\"}"))
    }

    // MARK: - SSR HTML 兜底

    func testSSRHydrationPayloadBecomesLiteProbeBody() throws {
        let html = try fixture("opencode_go_ssr", "html")
        let body = try XCTUnwrap(OpenCodeSeroval.windowsJSON(html, source: "ssr-html"))
        let root = try XCTUnwrap(JSONHelp.object(body))
        XCTAssertEqual(root["source"] as? String, "ssr-html", "兜底腿必须打标记，诊断里能看出数据来路")
        XCTAssertEqual(root["mine"] as? Bool, true)
        XCTAssertEqual(root["useBalance"] as? Bool, false)
        XCTAssertEqual(root["renewAt"] as? String, "2026-09-26T00:00:00.000Z")
        let rolling = try XCTUnwrap(root["rollingUsage"] as? [String: Any])
        XCTAssertEqual(rolling["usagePercent"] as? Double, 17)
        XCTAssertEqual(rolling["resetInSec"] as? Double, 5944)
        XCTAssertEqual(rolling["status"] as? String, "ok")

        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status", "json")),
            "billing": ProbeResult(status: -2, body: "seroval decode failed (0 bytes)"),
            "lite": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snap.status, .ok, "余额腿失败但窗口拿到了，仍是 ok")
        XCTAssertEqual(snap.planName, "OpenCode Go")
        XCTAssertEqual(snap.billingCycle, .monthly)
        XCTAssertEqual(snap.planExpiresAt, JSONHelp.date("2026-09-26T00:00:00.000Z"), "renewAt → planExpiresAt")
        XCTAssertEqual(snap.metrics.first { $0.id == "five_hour" }?.usedPercent, 17)
        XCTAssertEqual(snap.metrics.first { $0.id == "weekly" }?.usedPercent, 1.5)
        XCTAssertEqual(
            snap.metrics.first { $0.id == "monthly" }?.detail, "状态 degraded",
            "窗口 status 非 ok 要落进 detail"
        )
        XCTAssertNil(snap.metrics.first { $0.id == "weekly" }?.detail, "status 为 ok 时不加噪音")
    }

    func testSerovalWindowsNeedsAtLeastOneWindow() {
        XCTAssertNil(OpenCodeSeroval.windowsJSON("<html><body>signed out</body></html>"))
        XCTAssertNil(OpenCodeSeroval.windowsJSON("{}"))
    }

    // MARK: - 解析器边界

    /// `lite` 为 `{}`（seroval 里出现过）与 `null` 一样表示没订 Go。
    func testLiteEmptyObjectMeansNoSubscription() throws {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status", "json")),
            "billing": ProbeResult(status: 200, body: try fixture("opencode_billing", "json")),
            "lite": ProbeResult(status: 200, body: "{}"),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertNil(snap.planName)
        XCTAssertNil(snap.billingCycle)
        XCTAssertNil(snap.planExpiresAt)
        XCTAssertEqual(snap.metrics.map(\.id), ["balance", "monthly_limit"])
    }

    /// `resetInSec` 缺失时退 `resetsAt`（ISO 绝对时间）。
    func testResetsAtIsUsedWhenResetInSecMissing() throws {
        let lite = """
        {"mine":true,"rollingUsage":{"usagePercent":5,"resetsAt":"2026-08-28T12:00:00.000Z"},\
        "weeklyUsage":{"usagePercent":10,"resetInSec":0,"resetsAt":"2026-09-01T00:00:00.000Z"}}
        """
        let snap = OpenCodeParser.parse(results: [
            "billing": ProbeResult(status: 200, body: "{}"),
            "lite": ProbeResult(status: 200, body: lite),
        ], now: now)
        XCTAssertEqual(snap.planName, "OpenCode Go")
        XCTAssertEqual(
            snap.metrics.first { $0.id == "five_hour" }?.resetsAt,
            JSONHelp.date("2026-08-28T12:00:00.000Z")
        )
        XCTAssertEqual(
            snap.metrics.first { $0.id == "weekly" }?.resetsAt,
            JSONHelp.date("2026-09-01T00:00:00.000Z"),
            "resetInSec 为 0 也要退到 resetsAt"
        )
    }

    func testRenewAtSnakeCaseAlsoMapsToPlanExpiry() {
        let lite = """
        {"mine":true,"renew_at":"2026-10-01T00:00:00.000Z","monthlyUsage":{"usagePercent":3,"resetInSec":100}}
        """
        let snap = OpenCodeParser.parse(results: [
            "lite": ProbeResult(status: 200, body: lite),
        ], now: now)
        XCTAssertEqual(snap.planExpiresAt, JSONHelp.date("2026-10-01T00:00:00.000Z"))
    }

    /// 共享数字入口必须直接拒绝 Bool，各解析器不得靠局部特判才安全。
    func testBooleansAreNeverReadAsNumbers() {
        XCTAssertNil(JSONHelp.double(true))
        XCTAssertNil(OpenCodeParser.number(true))
        XCTAssertNil(OpenCodeParser.number(false))
        XCTAssertEqual(OpenCodeParser.number(1), 1)
        XCTAssertEqual(OpenCodeParser.number(0.5), 0.5)

        let billing = "{\"customerID\":\"cus_x\",\"balance\":true,\"monthlyLimit\":true,\"monthlyUsage\":true}"
        let lite = "{\"mine\":true,\"rollingUsage\":{\"usagePercent\":true,\"resetInSec\":true}}"
        let snap = OpenCodeParser.parse(results: [
            "billing": ProbeResult(status: 200, body: billing),
            "lite": ProbeResult(status: 200, body: lite),
        ], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertTrue(snap.metrics.isEmpty, "布尔不得被当成余额 / 上限 / 百分比")
        XCTAssertNil(snap.planName)
    }

    /// 两条腿都空手时的分档：401/403 判凭据失效，5xx 报官网故障，脚本失效仍是「控制台接口无响应」。
    func testConsoleFailureStatusDistinguishesAuthFromServerError() throws {
        let loggedIn = try fixture("opencode_status", "json")
        let unauthorized = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: loggedIn),
            "billing": ProbeResult(status: 401, body: "unauthorized"),
            "lite": ProbeResult(status: 401, body: "unauthorized"),
        ], now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let serverError = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: loggedIn),
            "billing": ProbeResult(status: 500, body: "internal error"),
            "lite": ProbeResult(status: 500, body: "internal error"),
        ], now: now)
        XCTAssertEqual(serverError.status, .error("HTTP 500"))

        let scriptDead = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: loggedIn),
            "billing": ProbeResult(status: -2, body: "no workspace"),
            "lite": ProbeResult(status: -2, body: "no workspace"),
        ], now: now)
        XCTAssertEqual(scriptDead.status, .error("控制台接口无响应"))
    }

    /// 只有余额没有窗口、只有窗口余额失败，都不该降级。
    func testPartialPayloadsStayOK() throws {
        let balanceOnly = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status", "json")),
            "billing": ProbeResult(status: 200, body: try fixture("opencode_billing", "json")),
            "lite": ProbeResult(status: 500, body: "internal error"),
        ], now: now)
        XCTAssertEqual(balanceOnly.status, .ok)

        let windowsOnly = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: try fixture("opencode_status", "json")),
            "billing": ProbeResult(status: 500, body: "internal error"),
            "lite": ProbeResult(status: 200, body: try fixture("opencode_lite", "json")),
        ], now: now)
        XCTAssertEqual(windowsOnly.status, .ok)
        XCTAssertEqual(windowsOnly.planName, "OpenCode Go")
    }

    // MARK: - 两侧规则一致性

    /// JS 解码器与 `OpenCodeSeroval` 必须用同一套正则：Swift 字符串转义回 JS 源码形态后必须能在探针脚本里找到。
    func testProbeScriptSerovalRegexMatchesSwiftMirror() throws {
        let src = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        func escaped(_ pattern: String) -> String { pattern.replacingOccurrences(of: "\\", with: "\\\\") }
        XCTAssertTrue(src.contains("const OC_BOUNDARY = '\(OpenCodeSeroval.boundary)';"), "字段左边界必须一致")
        XCTAssertTrue(src.contains("const OC_NUMBER = '\(escaped(OpenCodeSeroval.numberValue))';"), "数字子式必须一致")
        XCTAssertTrue(src.contains("const OC_BOOL = '\(escaped(OpenCodeSeroval.boolValue))';"), "布尔子式必须一致")
        XCTAssertTrue(src.contains("const OC_STRING = '\(escaped(OpenCodeSeroval.stringValue))';"), "字符串子式必须一致")
    }

    /// 三条腿都必须在脚本里，且不得引入需要 API key 的端点或 DOM 抓取。
    func testProbeScriptShipsAllThreeLegs() throws {
        let src = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        XCTAssertTrue(src.contains("server-runtime-"), "腿 1：页面 runtime 动态 import")
        XCTAssertTrue(src.contains("ORIGIN + '/_server?id=' + encodeURIComponent(id)"), "腿 2：GET /_server")
        XCTAssertTrue(src.contains("'X-Server-Id': id"), "GET 腿必须带 X-Server-Id")
        XCTAssertTrue(src.contains("'server-fn:' + uuid"), "X-Server-Instance 用随机 uuid")
        XCTAssertTrue(src.contains("'/workspace/' + wid + '/go'"), "腿 3：SSR HTML 兜底")
        XCTAssertTrue(src.contains("'ssr-html'"), "SSR 兜底必须打 source 标记")
        XCTAssertTrue(
            src.contains("def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"),
            "路径里没有 wrk_ 时用 workspaces() 兜底"
        )
        XCTAssertFalse(src.contains("method: 'POST'\n        }, '/_server'"), "禁止 POST /_server 重试（官网回 500）")
        XCTAssertFalse(src.contains("/zen/go/v1/usage"), "不走需要 API key 的公开端点")
        XCTAssertFalse(
            src.contains("7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"),
            "subscription.get 只登记在目录里，未验证前不调用"
        )
    }

    func testLiteOnlyServerErrorSurfacesHTTPStatus() throws {
        let loggedIn = try fixture("opencode_status", "json")
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: loggedIn),
            "lite": ProbeResult(status: 503, body: "unavailable"),
        ], now: now)
        XCTAssertEqual(snap.status, .error("HTTP 503"))

        let unauthorized = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 200, body: loggedIn),
            "lite": ProbeResult(status: 401, body: "unauthorized"),
        ], now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)
    }

    func testStatusUnauthorizedDropsBillingMetrics() throws {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 401, body: "unauthorized"),
            "billing": ProbeResult(status: 200, body: try fixture("opencode_billing", "json")),
            "lite": ProbeResult(status: 200, body: try fixture("opencode_lite", "json")),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
        XCTAssertNil(snap.planName)
    }

    func testStatusServerErrorIsNotNeedsLogin() {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: 500, body: "internal error"),
        ], now: now)
        XCTAssertEqual(snap.status, .error("HTTP 500"))
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testStatusTimeoutIsNotNeedsLogin() {
        let snap = OpenCodeParser.parse(results: [
            "status": ProbeResult(status: -3, body: "timeout"),
        ], now: now)
        XCTAssertEqual(snap.status, .error("请求超时"))
    }

}

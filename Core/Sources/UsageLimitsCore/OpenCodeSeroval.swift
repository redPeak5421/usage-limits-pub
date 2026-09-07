import Foundation

/// opencode.ai `_server` GET 腿返回的 **seroval 流**文本解码规则。
///
/// 这是探针 JS（`ProviderScripts.opencode` 的 `__ocFieldRe` / `__ocSeroval` 一族）的 Swift 镜像：
/// 真正跑在站点源里的是 JS，这里存放同一套正则与同一套语义，好让规则能被 `swift test` 覆盖。
/// **两侧必须逐字一致，改一处必须同时改另一处**（规则原文见 `providers/opencode.md`「seroval 最小解码器」）。
///
/// 载荷形如：
/// ```
/// ;0x000002b9;((self.$R=self.$R||{})["server-fn:<uuid>"]=[],($R=>$R[0]={
///   customerID:"cus_…",balance:1250000000,reload:!0,
///   timeMonthlyUsageUpdated:$R[1]=new Date("2026-07-29T14:45:11.000Z"),lite:$R[2]={}
/// })($R["server-fn:<uuid>"]))
/// ```
/// 十六进制长度前缀 + `$R[n]=` 引用 + `!0`/`!1` 布尔 + `new Date(...)` 让 `JSON.parse` 必然失败，
/// 因此只按字段名正则取值，不做完整反序列化。
public enum OpenCodeSeroval {
    /// 字段名左边界：不能是标识符字符，否则 `subscriptionID` 会命中 `liteSubscriptionID` 的尾巴。
    static let boundary = "(?:^|[^A-Za-z0-9_$])"

    /// 兼容式：同时吃 JSON（`"f": v`）与 seroval 的引用赋值（`f:$R[3]=v`）。
    ///     (?:^|[^A-Za-z0-9_$])(?:"字段"|字段)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?<值>
    static func fieldPattern(_ field: String, value: String) -> String {
        boundary + "(?:\"\(field)\"|\(field))\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?" + value
    }

    /// 作用域式：嵌套窗口对象只在同一层大括号内找字段（`[^}]*?` 保证不跨出该对象）。
    ///     <窗口键>[^}]*?<兼容式>
    static func scopedPattern(_ key: String, field: String, value: String) -> String {
        boundary + key + "[^}]*?" + fieldPattern(field, value: value)
    }

    static let numberValue = "(-?[0-9]+(?:\\.[0-9]+)?)"
    static let boolValue = "(!0|!1|true|false)"
    /// 字符串兼容 `new Date("…")` 包装。
    static let stringValue = "(?:new\\s+Date\\(\\s*)?\"([^\"]*)\""

    // MARK: - 取值

    public static func number(_ text: String, field: String) -> Double? {
        firstCapture(fieldPattern(field, value: numberValue), in: text).flatMap(Double.init)
    }

    public static func string(_ text: String, field: String) -> String? {
        firstCapture(fieldPattern(field, value: stringValue), in: text)
    }

    /// seroval 布尔是 `!0` / `!1`；JSON 形态是 `true` / `false`。
    public static func bool(_ text: String, field: String) -> Bool? {
        guard let raw = firstCapture(fieldPattern(field, value: boolValue), in: text) else { return nil }
        return raw == "!0" || raw == "true"
    }

    /// 「函数返回 null」：正文就是 `null`，或带 seroval 的显式 null 尾巴 `…["server-fn:<uuid>"]=[],null)`。
    /// 认出它就不再重试 —— 对无订阅 workspace 做 POST 重试会被 opencode.ai 回 HTTP 500。
    public static func isExplicitNull(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("null") == .orderedSame { return true }
        return trimmed.range(
            of: "\\]\\s*=\\s*\\[\\s*\\]\\s*,\\s*null\\s*\\)\\s*$",
            options: .regularExpression
        ) != nil
    }

    /// 单个用量窗口（`rollingUsage` / `weeklyUsage` / `monthlyUsage`）。没有 `usagePercent` 就当没有这个窗口。
    public static func window(_ text: String, key: String) -> [String: Any]? {
        guard let percent = firstCapture(scopedPattern(key, field: "usagePercent", value: numberValue), in: text)
            .flatMap(Double.init) else { return nil }
        var out: [String: Any] = ["usagePercent": percent]
        if let seconds = firstCapture(scopedPattern(key, field: "resetInSec", value: numberValue), in: text)
            .flatMap(Double.init) {
            out["resetInSec"] = seconds
        }
        if let status = firstCapture(scopedPattern(key, field: "status", value: stringValue), in: text) {
            out["status"] = status
        }
        if let resetsAt = firstCapture(scopedPattern(key, field: "resetsAt", value: stringValue), in: text) {
            out["resetsAt"] = resetsAt
        }
        return out
    }

    // MARK: - 组装成解析器认识的 JSON

    /// `billing.get` → 与页面 runtime 腿同形状的 JSON。
    /// **`customerID` 守卫**：没匹配到就一个数字都不信，避免把错误页 / 别的函数返回值解成假余额。
    /// 返回 nil = 解不出来（应换下一条腿）；返回 `"null"` = 函数确实返回了 null。
    public static func billingJSON(_ text: String) -> String? {
        if isExplicitNull(text) { return "null" }
        guard let customer = string(text, field: "customerID"), !customer.isEmpty else { return nil }
        var out: [String: Any] = [:]
        for field in ["balance", "monthlyLimit", "monthlyUsage"] {
            if let value = number(text, field: field) { out[field] = value }
        }
        for field in ["timeMonthlyUsageUpdated", "subscriptionID", "timeSubscriptionBooked", "liteSubscriptionID"] {
            if let value = string(text, field: field), !value.isEmpty { out[field] = value }
        }
        return json(out)
    }

    /// `lite.subscription.get`（或 `/workspace/<wid>/go` 的 SSR 载荷）→ 同形状的 JSON。
    /// `source` 非空时写进 `source` 标记字段（SSR 兜底传 `"ssr-html"`），便于诊断区分是哪条腿产的。
    public static func windowsJSON(_ text: String, source: String? = nil) -> String? {
        if isExplicitNull(text) { return "null" }
        var out: [String: Any] = [:]
        var produced = 0
        for key in ["rollingUsage", "weeklyUsage", "monthlyUsage"] {
            if let value = window(text, key: key) {
                out[key] = value
                produced += 1
            }
        }
        guard produced > 0 else { return nil }
        out["mine"] = bool(text, field: "mine") ?? true
        if let useBalance = bool(text, field: "useBalance") { out["useBalance"] = useBalance }
        if let renew = string(text, field: "renewAt") ?? string(text, field: "renew_at"), !renew.isEmpty {
            out["renewAt"] = renew
        }
        if let source, !source.isEmpty { out["source"] = source }
        return json(out)
    }

    /// `workspaces()` 的返回里取第一个 workspace id。
    public static func firstWorkspaceID(_ text: String) -> String? {
        if let id = firstCapture("id\"?\\s*:\\s*\"(wrk_[^\"]+)\"", in: text) { return id }
        guard let range = text.range(of: "wrk_[A-Za-z0-9]+", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // MARK: - 内部

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

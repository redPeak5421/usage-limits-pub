import Foundation
import CoreFoundation

/// 解析智谱 Coding Plan CN（open.bigmodel.cn/coding-plan/personal/usage）。
/// 官网定义窗口：每 5 小时积分 + 每周积分；页面另有 MCP 每月额度与按模型 token。
public enum ZhipuParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        var plan: String?
        var planExpiresAt: Date?
        var billingCycle: BillingCycle?
        var planProductID: String?
        var metrics: [UsageMetric] = []
        var loggedIn = false
        // 信封按探针隔离：登录态信封优先，不让先出现的业务 500 盖掉后面的 401。
        var envelopes: [(name: String, error: (code: Int?, msg: String))] = []
        for name in ["customer", "subscription", "quota", "model_usage"] {
            guard let probe = results[name],
                  let root = JSONHelp.object(probe.body),
                  let error = envelopeError(root) else { continue }
            envelopes.append((name, error))
        }
        let envelope = envelopes.first(where: { envelopeNeedsLogin($0.error) })?.error
            ?? envelopes.first(where: { $0.name == "quota" })?.error
            ?? envelopes.first?.error

        if let customer = results["customer"], customer.isOK,
           let root = JSONHelp.object(customer.body),
           envelopeError(root) == nil,
           let data = root["data"] as? [String: Any],
           JSONHelp.string(data["customerNumber"]) != nil || data["id"] != nil {
            loggedIn = true
        }

        if let sub = results["subscription"], sub.isOK,
           let root = JSONHelp.object(sub.body), envelopeError(root) == nil {
            let rows: [[String: Any]]
            if let arr = root["data"] as? [[String: Any]] {
                rows = arr
            } else if let data = root["data"] as? [String: Any] {
                rows = (data["records"] as? [[String: Any]]) ?? (data["list"] as? [[String: Any]]) ?? []
            } else {
                rows = []
            }
            if let item = rows.first(where: { statusValid($0["status"]) }) ?? rows.first {
                loggedIn = true
                planProductID = JSONHelp.string(item["productId"]) ?? JSONHelp.string(item["product_id"])
                let sku = PlanCatalog.zhipuSKU(planProductID)
                plan = sku?.plan ?? planLabel(JSONHelp.string(item["productName"]) ?? JSONHelp.string(item["name"]))
                planExpiresAt = parseValidEnd(JSONHelp.string(item["valid"]))
                    ?? JSONHelp.date(item["nextRenewTime"])
                    ?? JSONHelp.date(item["expireTime"])
                let validStart = parseValidStart(JSONHelp.string(item["valid"]))
                    ?? JSONHelp.date(item["currentRenewTime"])
                    ?? JSONHelp.date(item["purchaseTime"])
                billingCycle = BillingCycle.parse(JSONHelp.string(item["billingCycle"]))
                    ?? sku?.cycle
                    ?? BillingCycle.parse(JSONHelp.string(item["productName"]))
                    ?? BillingCycle.resolve(explicit: nil, periodStart: validStart, periodEnd: planExpiresAt)
            }
        }

        if let quota = results["quota"], quota.isOK,
           let root = JSONHelp.object(quota.body),
           envelopeError(root) == nil,
           let data = root["data"] as? [String: Any] {
            loggedIn = true
            // 套餐名字段覆盖面：planName / plan / plan_type / packageName / level 五选一。
            if plan == nil, let raw = planNameValue(data) {
                plan = planLabel(raw)
            }
            metrics.append(contentsOf: quotaMetrics(data["limits"], now: now))
        }

        if let usage = results["model_usage"], usage.isOK,
           let root = JSONHelp.object(usage.body),
           envelopeError(root) == nil,
           let data = root["data"] as? [String: Any] {
            let total = data["totalUsage"] as? [String: Any]
            let tokens = JSONHelp.double(total?["totalTokensUsage"])
                ?? JSONHelp.double(data["totalTokensUsage"])
            if let tokens {
                // quota 已经产出真正的周额度窗口时，近 7 天 Token 换个 id，避免两条 seven_day。
                let taken = metrics.contains { $0.id == "seven_day" }
                metrics.append(UsageMetric(
                    id: taken ? "seven_day_tokens" : "seven_day",
                    label: "近 7 天 Token",
                    detail: formatTokens(tokens),
                    amount: tokens
                ))
            }
            let summaries = (total?["modelSummaryList"] as? [[String: Any]])
                ?? (data["modelSummaryList"] as? [[String: Any]])
                ?? []
            for row in summaries {
                let name = JSONHelp.string(row["modelName"]) ?? JSONHelp.string(row["model"]) ?? "model"
                let tok = JSONHelp.double(row["totalTokens"]) ?? JSONHelp.double(row["tokens"])
                guard let tok, tok > 0 else { continue }
                metrics.append(UsageMetric(
                    id: "model_\(slug(name))",
                    label: name,
                    detail: formatTokens(tok),
                    amount: tok
                ))
            }
        }

        let status: SnapshotStatus
        if results["customer"]?.isUnauthorized == true || (envelope.map { envelopeNeedsLogin($0) } ?? false) {
            metrics = []
            status = .needsLogin
        } else if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let envelope {
            if envelopeNeedsLogin(envelope) {
                status = .needsLogin
            } else if envelope.msg == "智谱响应状态码异常" {
                status = .error("智谱响应状态码异常")
            } else {
                // 业务失败只报本地化前缀 + code，不把接口原文带上界面。
                status = .error("智谱接口失败" + (envelope.code.map { " code \($0)" } ?? ""))
            }
        } else if let probe = results["customer"] ?? results["quota"], !probe.isOK {
            // 401 / 403 → needsLogin；其它非 2xx / 网络层 → error。
            status = probe.failureStatus
        } else {
            status = .needsLogin
        }

        billingCycle = BillingCycle.resolve(explicit: billingCycle)
        if billingCycle == nil, PlanCatalog.hasListPrice(plan) { billingCycle = .monthly }
        metrics = Self.orderedMetrics(metrics)
        return ProviderSnapshot(
            provider: .zhipu,
            planName: plan,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            billingCycle: billingCycle,
            planProductID: planProductID,
            planExpiresAt: planExpiresAt
        )
    }

    private static func statusValid(_ any: Any?) -> Bool {
        let s = (JSONHelp.string(any) ?? "").uppercased()
        return s == "VALID" || s == "ACTIVE" || s == "SUCCESS"
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("lite") { return "Coding Plan Lite" }
        if lower.contains("max") { return "Coding Plan Max" }
        if lower.contains("pro") { return "Coding Plan Pro" }
        if lower == "coding plan lite" || lower == "coding plan pro" || lower == "coding plan max" {
            return raw
        }
        return raw.contains("Coding") ? raw : "Coding Plan \(raw.capitalized)"
    }

    /// 一条 `limits[]` 的归一化结果。
    struct ParsedLimit {
        var type: String
        var percent: Double?
        /// 窗口时长（分钟）。`unit` 乘数表：1=天 1440、3=小时 60、5=分钟 1、6=周 10080。
        var windowMinutes: Double?
        var resets: Date?
        var details: [(code: String, usage: Double)]
        var isCredit: Bool { type == "CREDIT_LIMIT" }
    }

    /// `unit` → 分钟乘数。官网真实枚举，勿凭猜测扩充。
    private static let unitMinutes: [Int: Double] = [1: 1440, 3: 60, 5: 1, 6: 10080]

    /// `limits[]` → 指标。TOKENS_LIMIT 与 CREDIT_LIMIT 同一批按窗口时长升序：
    /// 最短的是会话窗口（官网 5 小时），最长的是周窗口；中间的按分钟数单独成条。
    /// TIME_LIMIT 走 MCP 泳道，不与积分窗口混排；未知 type 直接丢弃（不产出英文标签）。
    static func quotaMetrics(_ any: Any?, now: Date) -> [UsageMetric] {
        let rows = (any as? [[String: Any]]) ?? []
        let parsed = rows.compactMap { parseLimit($0) }
        let family = parsed
            .filter { $0.type == "TOKENS_LIMIT" || $0.type == "CREDIT_LIMIT" }
            .sorted { ($0.windowMinutes ?? .greatestFiniteMagnitude) < ($1.windowMinutes ?? .greatestFiniteMagnitude) }

        var metrics: [UsageMetric] = []
        let dated = family.filter { $0.windowMinutes.flatMap(JSONHelp.intRounded) != nil }
        for (index, limit) in dated.enumerated() {
            guard limit.percent != nil || limit.resets != nil else { continue }
            let id = familyMetricID(limit, index: index, familyCount: dated.count)
            var label = windowLabel(limit.windowMinutes)
            if limit.isCredit { label += "（积分）" }
            metrics.append(UsageMetric(
                id: id, label: label, usedPercent: limit.percent,
                resetsAt: limit.resets,
                pinned: id == "five_hour" ? true : nil
            ))
        }

        if let mcp = parsed.last(where: { $0.type == "TIME_LIMIT" }),
           mcp.percent != nil || mcp.resets != nil {
            metrics.append(UsageMetric(
                id: "mcp_monthly", label: "MCP 每月额度",
                usedPercent: mcp.percent,
                resetsAt: mcp.resets,
                detail: topToolsDetail(mcp.details)
            ))
        }

        // 积分计费才有高峰 / 低谷倍率；纯 token 套餐是模型固定价，不产出这条。
        if family.contains(where: { $0.isCredit }) {
            let window = peakWindow(now: now)
            metrics.append(UsageMetric(
                id: "rate_period", label: "计费时段",
                resetsAt: window.nextSwitch,
                displayValue: window.isPeak ? "高峰 1x" : "低谷 0.5x"
            ))
        }
        return metrics
    }

    private static func parseLimit(_ raw: [String: Any]) -> ParsedLimit? {
        var type = (JSONHelp.string(raw["type"]) ?? "").uppercased()
        let details: [(code: String, usage: Double)] = ((raw["usageDetails"] as? [[String: Any]]) ?? [])
            .compactMap {
                guard let code = JSONHelp.string($0["modelCode"]), !code.isEmpty else { return nil }
                return (code, JSONHelp.double($0["usage"]) ?? 0)
            }
        let looksMCP = details.contains {
            let code = $0.code.lowercased()
            return code.contains("search") || code.contains("reader")
                || code.contains("zread") || code.contains("mcp")
        }
        if !["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type) {
            if type.contains("TIME") { type = "TIME_LIMIT" }
            else if type.contains("CREDIT") { type = "CREDIT_LIMIT" }
            else if type.contains("TOKEN") { type = "TOKENS_LIMIT" }
            else if looksMCP { type = "TIME_LIMIT" }
            else { return nil }
        }

        let usage = JSONHelp.double(raw["usage"])
        let current = JSONHelp.double(raw["currentValue"])
        let remaining = JSONHelp.double(raw["remaining"])
        // 官网 percentage 已是 0–100 整数（1 = 1%）。不能走 JSONHelp.percent
        //（它会把 ≤1 的值当 0–1 口径放大 100 倍）。
        var percent = JSONHelp.double(raw["percentage"]).map { min(max($0, 0), 100) }
        // 有额度总量时用 used = max(usage - remaining, currentValue) 重算，比整数 percentage 精细。
        if let usage, usage > 0 {
            var used: Double?
            if let remaining {
                used = max(usage - remaining, current ?? (usage - remaining))
            } else if let current {
                used = current
            }
            if let used {
                percent = min(max(min(max(used, 0), usage) / usage * 100, 0), 100)
            }
        }
        if percent == nil {
            percent = ratio(used: current ?? usage,
                            total: {
                                if let remaining, let used = current ?? usage { return used + remaining }
                                return JSONHelp.double(raw["limit"]) ?? JSONHelp.double(raw["quota"])
                            }())
        }

        let unit = JSONHelp.intExactly(raw["unit"])
        let number = JSONHelp.double(raw["number"]) ?? 0
        var windowMinutes: Double?
        if number > 0, let unit, let mult = unitMinutes[unit] {
            let computed = number * mult
            if computed.isFinite { windowMinutes = computed }
        }
        // TIME_LIMIT + unit==5 && number==1 是官网的「月度 MCP」标记，不是 1 分钟窗口。
        if type == "TIME_LIMIT", unit == 5, number == 1 { windowMinutes = 30 * 24 * 60 }

        let resets = JSONHelp.date(raw["nextResetTime"]) ?? JSONHelp.date(raw["resetTime"])
        return ParsedLimit(type: type, percent: percent, windowMinutes: windowMinutes,
                           resets: resets, details: details)
    }

    /// 窗口时长 → 中文标签。300 分钟即官网的「每 5 小时」。
    static func windowLabel(_ minutes: Double?) -> String {
        guard let minutes, minutes > 0, let mins = JSONHelp.intRounded(minutes) else { return "限额" }
        if mins % 10080 == 0 {
            let weeks = mins / 10080
            return weeks == 1 ? "每周" : "每 \(weeks) 周"
        }
        if mins % 1440 == 0 {
            let days = mins / 1440
            return days == 1 ? "每天" : "每 \(days) 天"
        }
        if mins % 60 == 0 { return "每 \(mins / 60) 小时" }
        return "每 \(mins) 分钟"
    }

    /// MCP 用量最高的前 5 个工具：`search-prime 12 · web-reader 3`。全为 0 时不编造文案。
    static func topToolsDetail(_ details: [(code: String, usage: Double)]) -> String? {
        let used = details.filter { $0.usage > 0 && JSONHelp.intTruncating($0.usage) != nil }
            .sorted { $0.usage > $1.usage }.prefix(5)
        guard !used.isEmpty else { return nil }
        return used.compactMap { item in
            JSONHelp.intTruncating(item.usage).map { "\(item.code) \($0)" }
        }.joined(separator: " · ")
    }

    /// 按窗口时长识别周期：300 分钟 → 5h，10080 分钟 → 每周。缺时长时用 window_N，不用数组位置猜 5h/周。
    private static func familyMetricID(_ limit: ParsedLimit, index: Int, familyCount: Int) -> String {
        if let mins = limit.windowMinutes.flatMap(JSONHelp.intRounded) {
            if mins == 300 { return "five_hour" }
            if mins == 10080 { return "seven_day" }
            return "window_\(mins)"
        }
        return "window_\(index + 1)"
    }

    /// 高峰 = 周一至周五 UTC 06:00–10:00（UTC+8 的 14:00–18:00）。周末全天低谷。
    static func peakWindow(now: Date) -> (isPeak: Bool, nextSwitch: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let weekday = cal.component(.weekday, from: now)
        let isWeekday = (2...6).contains(weekday)
        let start = cal.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now
        let end = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        if isWeekday, now >= start, now < end {
            return (true, end)
        }
        if isWeekday, now < start {
            return (false, start)
        }
        var day = cal.startOfDay(for: now)
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: day) {
            day = tomorrow
        }
        for _ in 0..<8 {
            let wd = cal.component(.weekday, from: day)
            if (2...6).contains(wd),
               let next = cal.date(bySettingHour: 6, minute: 0, second: 0, of: day),
               next > now {
                return (false, next)
            }
            guard let nextDay = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return (false, now.addingTimeInterval(24 * 3600))
    }

    static func envelopeError(_ root: [String: Any]) -> (code: Int?, msg: String)? {
        let msg = JSONHelp.string(root["msg"]) ?? JSONHelp.string(root["message"]) ?? ""
        if let raw = root["code"] {
            if isBoolean(raw) {
                return (nil, "智谱响应状态码异常")
            }
            guard let code = JSONHelp.intExactly(raw) else {
                return (nil, "智谱响应状态码异常")
            }
            if code != 200 {
                return (code, msg)
            }
        }
        if let success = boolValue(root["success"]), success == false {
            return (JSONHelp.intExactly(root["code"]), msg)
        }
        return nil
    }

    static func envelopeNeedsLogin(_ envelope: (code: Int?, msg: String)) -> Bool {
        if let code = envelope.code, [401, 403, 1001].contains(code) { return true }
        let lower = envelope.msg.lowercased()
        return lower.contains("authorization")
            || lower.contains("token")
            || lower.contains("登录")
            || lower.contains("身份验证")
            || lower.contains("未授权")
            || lower.contains("unauthorized")
    }

    static func orderedMetrics(_ metrics: [UsageMetric]) -> [UsageMetric] {
        func rank(_ id: String) -> Int {
            switch id {
            case "five_hour": return 0
            case "seven_day": return 1
            case "mcp_monthly": return 80
            default: return 40
            }
        }
        return metrics.enumerated().sorted { lhs, rhs in
            let a = rank(lhs.element.id)
            let b = rank(rhs.element.id)
            if a != b { return a < b }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func planNameValue(_ data: [String: Any]) -> String? {
        for key in ["planName", "plan", "plan_type", "packageName", "level"] {
            if let value = JSONHelp.string(data[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func parseValidStart(_ raw: String?) -> Date? {
        parseValidPart(raw, takeEnd: false)
    }

    private static func parseValidEnd(_ raw: String?) -> Date? {
        parseValidPart(raw, takeEnd: true)
    }

    private static func parseValidPart(_ raw: String?, takeEnd: Bool) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let pattern = #"\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex?.matches(in: raw, range: range) ?? []
        let picked = takeEnd ? matches.last : matches.first
        guard let picked, let swiftRange = Range(picked.range, in: raw) else {
            return zhipuDate(raw)
        }
        return zhipuDate(String(raw[swiftRange]))
    }

    private static func zhipuDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed), JSONHelp.isSafeDate(date) { return date }
        }
        return JSONHelp.date(trimmed)
    }

    private static func ratio(used: Double?, total: Double?) -> Double? {
        guard let used, let total, total > 0, used.isFinite, total.isFinite else { return nil }
        return min(max(used / total * 100, 0), 100)
    }

    private static func formatTokens(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM tokens", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK tokens", n / 1_000) }
        return String(format: "%.0f tokens", n)
    }

    private static func slug(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    private static func isBoolean(_ any: Any?) -> Bool {
        guard let any else { return false }
        if let number = any as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return any is Bool
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if isBoolean(any), let number = any as? NSNumber { return number.boolValue }
        if let value = any as? Bool { return value }
        return nil
    }
}

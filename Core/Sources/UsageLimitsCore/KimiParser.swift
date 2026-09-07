import Foundation

/// 解析 Kimi Code Plan（www.kimi.com/code/console）。
/// 官网定义窗口：月度总用量池 + 每 7 天额度 + 每 5 小时滚动频限。
public enum KimiParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        var plan: String?
        var planExpiresAt: Date?
        var billingCycle: BillingCycle?
        var metrics: [UsageMetric] = []
        var loggedIn = false

        if let user = results["user"], user.isOK,
           let root = JSONHelp.object(user.body) {
            let u = (root["user"] as? [String: Any]) ?? root
            if JSONHelp.string(u["id"]) != nil || JSONHelp.string(u["nickname"]) != nil {
                loggedIn = true
            }
        }

        if let sub = results["subscription"], sub.isOK,
           let root = JSONHelp.object(sub.body) {
            let node = (root["subscription"] as? [String: Any]) ?? (root["purchaseSubscription"] as? [String: Any])
            let goods = node?["goods"] as? [String: Any]
            if node != nil || goods != nil {
                loggedIn = true
                plan = planLabel(JSONHelp.string(goods?["title"]) ?? JSONHelp.string(goods?["membershipLevel"]))
                planExpiresAt = JSONHelp.date(node?["currentEndTime"]) ?? JSONHelp.date(node?["nextBillingTime"])
                billingCycle = cycleFromGoods(goods)
            }
        }

        if plan == nil, let list = results["subscriptions"], list.isOK,
           let root = JSONHelp.object(list.body),
           let rows = root["subscriptions"] as? [[String: Any]],
           let first = rows.first {
            loggedIn = true
            let goods = first["goods"] as? [String: Any]
            plan = planLabel(JSONHelp.string(goods?["title"]))
            planExpiresAt = JSONHelp.date(first["currentEndTime"])
            if billingCycle == nil { billingCycle = cycleFromGoods(goods) }
        }

        if let usages = results["usages"], usages.isOK,
           let root = JSONHelp.object(usages.body) {
            let rows = (root["usages"] as? [[String: Any]]) ?? []
            if !rows.isEmpty { loggedIn = true }
            let coding = rows.first { JSONHelp.string($0["scope"])?.contains("CODING") == true } ?? rows.first
            if let coding {
                let detail = (coding["detail"] as? [String: Any]) ?? coding
                let weekly = counts(
                    used: JSONHelp.double(detail["used"]),
                    remaining: JSONHelp.double(detail["remaining"]),
                    limit: JSONHelp.double(detail["limit"])
                )
                if let m = metric(id: "seven_day", label: "本周用量", counts: weekly, reset: resetDate(detail)) {
                    metrics.append(m)
                }
                let limits = (coding["limits"] as? [[String: Any]]) ?? []
                for (index, limit) in limits.enumerated() {
                    let inner = (limit["detail"] as? [String: Any]) ?? limit
                    let c = counts(
                        used: JSONHelp.double(inner["used"]),
                        remaining: JSONHelp.double(inner["remaining"]),
                        limit: JSONHelp.double(inner["limit"])
                    )
                    // 计数不可信时不按窗口分钟数猜标签：一条读不懂的额度不该冒充 5 小时频限。
                    let minutes = c.trustworthy ? minutesOf(limit["window"] as? [String: Any]) : nil
                    let naming = windowNaming(minutes: minutes, position: index + 1)
                    if let m = metric(id: naming.id, label: naming.label, counts: c, reset: resetDate(inner)) {
                        metrics.append(m)
                    }
                }
            }
        }

        if let stats = results["stats"], stats.isOK,
           let root = JSONHelp.object(stats.body) {
            // 月度总用量池：额度跨功能共享，官网「Total usage」那条就是它。
            // 用 amountUsedRatio（不是 kimiCodeUsedRatio），ratio 是 0–1 小数。
            if let balance = root["subscriptionBalance"] as? [String: Any] {
                let feature = JSONHelp.string(balance["feature"])
                let type = JSONHelp.string(balance["type"])
                if feature == nil || feature == "FEATURE_OMNI", type == nil || type == "SUBSCRIPTION" {
                    let ratio = JSONHelp.percent(balance["amountUsedRatio"])
                    let expires = JSONHelp.date(balance["expireTime"])
                    if ratio != nil || expires != nil {
                        loggedIn = true
                        metrics.insert(UsageMetric(id: "monthly", label: "总用量",
                                                   usedPercent: ratio, resetsAt: expires,
                                                   pinned: true), at: 0)
                    }
                }
            }
            if let code7d = root["ratelimitCode7d"] as? [String: Any], boolValue(code7d["enabled"]) != false {
                let ratio = JSONHelp.percent(code7d["ratio"])
                let reset = resetDate(code7d)
                if ratio != nil || reset != nil,
                   !isSameWindow(percent: ratio, reset: reset, as: metrics.first { $0.id == "seven_day" }) {
                    metrics.append(UsageMetric(id: "code_7d", label: "Code 7 天",
                                               usedPercent: ratio, resetsAt: reset))
                }
            }
            if metrics.contains(where: { $0.id == "five_hour" }) == false,
               let five = root["ratelimitCode5h"] as? [String: Any],
               boolValue(five["enabled"]) != false {
                let ratio = JSONHelp.percent(five["ratio"])
                let reset = resetDate(five)
                if ratio != nil || reset != nil {
                    metrics.append(UsageMetric(id: "five_hour", label: "频限明细",
                                               usedPercent: ratio, resetsAt: reset))
                }
            }
        }

        let status: SnapshotStatus
        if let failed = failedProbe(results), failed.isUnauthorized {
            metrics = []
            status = .needsLogin
        } else if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let failed = failedProbe(results) {
            status = failed.failureStatus
        } else {
            status = .needsLogin
        }

        billingCycle = BillingCycle.resolve(explicit: billingCycle)
        if billingCycle == nil, PlanCatalog.hasListPrice(plan) { billingCycle = .monthly }
        return ProviderSnapshot(
            provider: .kimi,
            planName: plan,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            billingCycle: billingCycle,
            planExpiresAt: planExpiresAt
        )
    }

    /// 401 / 403 要提示重新登录，5xx / 网络层不该。
    private static func failedProbe(_ results: [String: ProbeResult]) -> ProbeResult? {
        for key in ["user", "usages", "stats", "subscription", "subscriptions"] {
            if let r = results[key], !r.isOK { return r }
        }
        return results.keys.sorted().compactMap { results[$0] }.first { !$0.isOK }
    }

    private static func cycleFromGoods(_ goods: [String: Any]?) -> BillingCycle? {
        let cycle = goods?["billingCycle"] as? [String: Any]
        return BillingCycle.parse(JSONHelp.string(cycle?["timeUnit"]))
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("moderato") { return "Kimi Code Moderato" }
        if lower.contains("allegretto") || lower.contains("intermediate") { return "Kimi Code Allegretto" }
        if lower.contains("allegro") { return "Kimi Code Allegro" }
        if lower.contains("vivace") { return "Kimi Code Vivace" }
        if raw.hasPrefix("Kimi Code") { return raw }
        return "Kimi Code \(raw)"
    }

    /// 一个窗口的计数解读结果。
    private struct WindowCounts {
        var usedPercent: Double?
        var remaining: Double?
        var total: Double?
        var detail: String?
        var displayValue: String?
        /// 数字自洽、窗口身份可信。false 时不按分钟数贴「5 小时频限」这类标签。
        var trustworthy: Bool
        /// 有任何可展示的数值。
        var hasValue: Bool
    }

    /// `used` 是权威值（允许超额），`remaining` 只在 `0...limit` 内才采信；
    /// `remaining < 0` 是共享 / 无限额度哨兵，不能算成「已用满」。
    private static func counts(used: Double?, remaining: Double?, limit: Double?) -> WindowCounts {
        var c = WindowCounts(usedPercent: nil, remaining: nil, total: nil,
                             detail: nil, displayValue: nil, trustworthy: false, hasValue: false)
        let total = (limit ?? 0) > 0 ? limit : nil
        c.total = total

        if let used, let total {
            c.usedPercent = min(max(used / total * 100, 0), 100)
            if used > total {
                c.detail = "已用 \(formatCount(used)) / \(formatCount(total))（超额）"
            }
            if let remaining, remaining >= 0 { c.remaining = remaining }
            c.trustworthy = true
        } else if let remaining, remaining < 0 {
            c.displayValue = "∞"
            c.trustworthy = true
        } else if let remaining, let total, remaining <= total {
            c.usedPercent = min(max((total - remaining) / total * 100, 0), 100)
            c.remaining = remaining
            c.trustworthy = true
        } else if let remaining {
            // remaining > limit，或压根没有 limit：数字不自洽，只原样展示剩余数。
            c.remaining = remaining
        }

        c.hasValue = c.usedPercent != nil || c.remaining != nil || c.displayValue != nil
        return c
    }

    private static func metric(id: String, label: String, counts c: WindowCounts, reset: Date?) -> UsageMetric? {
        guard c.hasValue || reset != nil else { return nil }
        return UsageMetric(
            id: id, label: label,
            usedPercent: c.usedPercent,
            remaining: c.remaining, total: c.total,
            resetsAt: reset,
            detail: c.detail,
            displayValue: c.displayValue
        )
    }

    private static func windowNaming(minutes: Double?, position: Int) -> (id: String, label: String) {
        guard let minutes, minutes.isFinite, minutes > 0,
              let minuteCount = JSONHelp.intTruncating(minutes) else {
            return ("window_\(position)", "配额")
        }
        if minutes >= 240, minutes <= 360 { return ("five_hour", "频限明细") }
        if minutes >= 60, let hours = JSONHelp.intTruncating(minutes / 60) {
            return ("window_\(minuteCount)", "窗口 \(hours) 小时")
        }
        return ("window_\(minuteCount)", "窗口 \(minuteCount) 分钟")
    }

    /// `resetTime` 的 4 个别名；值可以是 ISO8601、epoch 数字或数字字符串。
    private static func resetDate(_ dict: [String: Any]) -> Date? {
        for key in ["resetTime", "resetAt", "reset_time", "reset_at"] {
            if let d = JSONHelp.date(dict[key]) { return d }
        }
        return nil
    }

    /// `ratelimitCode7d` 与 `GetUsages` 的周窗口是否同一份配额：百分比差 ≤1 且重置时间差 ≤5 分钟。
    private static func isSameWindow(percent: Double?, reset: Date?, as other: UsageMetric?) -> Bool {
        guard let other,
              let percent, let otherPercent = other.usedPercent,
              let reset, let otherReset = other.resetsAt else { return false }
        return abs(percent - otherPercent) <= 1 && abs(reset.timeIntervalSince(otherReset)) <= 300
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = JSONHelp.double(any) { return n != 0 }
        if let s = JSONHelp.string(any) { return s.lowercased() == "true" }
        return nil
    }

    private static func formatCount(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }

    /// `TIME_UNIT_MINUTE/HOUR/DAY/WEEK`。未知单位返回 nil——当成分钟会把 `TIME_UNIT_WEEK: 1` 算成 1 分钟。
    private static func minutesOf(_ window: [String: Any]?) -> Double? {
        guard let window else { return nil }
        guard let duration = JSONHelp.double(window["duration"]) ?? JSONHelp.double(window["value"]) else { return nil }
        let unit = (JSONHelp.string(window["timeUnit"]) ?? JSONHelp.string(window["unit"]) ?? "").uppercased()
        let minutes: Double?
        if unit.contains("MINUTE") { minutes = duration }
        else if unit.contains("HOUR") { minutes = duration * 60 }
        else if unit.contains("WEEK") { minutes = duration * 10080 }
        else if unit.contains("DAY") { minutes = duration * 1440 }
        else { minutes = nil }
        guard let minutes, minutes.isFinite else { return nil }
        return minutes
    }
}

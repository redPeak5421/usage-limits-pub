import Foundation

/// 解析 OpenCode（opencode.ai）控制台：Zen 预充值余额 + OpenCode Go 订阅三窗口。
/// 探针：`status`（/auth/status）、`billing`（server fn billing.get）、`lite`（server fn lite.subscription.get）。
/// `billing` / `lite` 可能来自三条腿（页面 runtime `import()` / `_server` GET + seroval 解码 / Go 页 SSR 载荷），
/// 三条腿产出同名探针与同形状 JSON，解析器不感知。接口目录见 `providers/opencode.md`。
public enum OpenCodeParser {
    /// 官网 `formatBalance`：微分单位 ÷ 1e8 = 美元。
    static let balanceDivisor: Double = 100_000_000

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        if results["status"]?.isUnauthorized == true {
            return ProviderSnapshot(
                provider: .opencode, metrics: [], fetchedAt: now, status: .needsLogin
            )
        }

        var loggedIn = false
        var metrics: [UsageMetric] = []
        var plan: String?
        var billingCycle: BillingCycle?
        var planExpiresAt: Date?
        var isBlack = false
        var hadPayload = false

        if let status = results["status"], status.isOK, let root = JSONHelp.object(status.body) {
            if let account = root["account"] as? [String: Any], !account.isEmpty {
                loggedIn = true
            } else if let current = JSONHelp.string(root["current"]), !current.isEmpty {
                loggedIn = true
            }
        }

        if let billing = results["billing"], billing.isOK, let root = JSONHelp.object(billing.body) {
            loggedIn = true
            hadPayload = true
            isBlack = indicatesBlack(root)
            if isBlack {
                plan = "OpenCode Black"
            }
            if let raw = number(root["balance"]) {
                metrics.append(UsageMetric(
                    id: "balance", label: "Zen 余额",
                    amount: raw / balanceDivisor, currency: "USD", pinned: true
                ))
            }
            if let limit = number(root["monthlyLimit"]), limit > 0 {
                let used = monthlyUsageUSD(root, now: now)
                metrics.append(UsageMetric(
                    id: "monthly_limit", label: "Zen 月上限",
                    usedPercent: min(max(used / limit * 100, 0), 100),
                    detail: "上限 " + MoneyFormat.string(limit, currency: "USD"),
                    amount: used, currency: "USD", pinned: true
                ))
            }
        }

        // `lite` 为 `null`（真机确认）或 `{}`（seroval 里出现过）都表示没有 Go 订阅：拿不到窗口就什么都不产。
        if !isBlack, let lite = results["lite"], lite.isOK, let root = JSONHelp.object(lite.body) {
            loggedIn = true
            hadPayload = true
            let mine = (root["mine"] as? Bool) ?? true
            if mine {
                let windows: [(key: String, id: String, label: String, pinned: Bool)] = [
                    ("rollingUsage", "five_hour", "5 小时窗口", false),
                    ("weeklyUsage", "weekly", "每周窗口", true),
                    ("monthlyUsage", "monthly", "每月窗口", false),
                ]
                var produced = 0
                for window in windows {
                    guard let usage = root[window.key] as? [String: Any],
                          let percent = number(usage["usagePercent"]) else { continue }
                    var resetsAt: Date?
                    if let seconds = number(usage["resetInSec"]), seconds > 0 {
                        resetsAt = JSONHelp.date(byAdding: seconds, to: now)
                    } else {
                        // REST / SSR 形态可能只给绝对时间 `resetsAt`（ISO 字符串）。
                        resetsAt = JSONHelp.date(usage["resetsAt"])
                    }
                    metrics.append(UsageMetric(
                        id: window.id, label: window.label,
                        usedPercent: min(max(percent, 0), 100),
                        resetsAt: resetsAt,
                        detail: windowStateDetail(usage["status"]),
                        pinned: window.pinned ? true : nil
                    ))
                    produced += 1
                }
                if produced > 0 {
                    plan = "OpenCode Go"
                    billingCycle = .monthly
                    planExpiresAt = JSONHelp.date(root["renewAt"] ?? root["renew_at"])
                }
            }
        }

        // Go 窗口排在余额前面：折叠摘要与 2×4 总览都按 weekly 优先。
        metrics.sort { order($0.id) < order($1.id) }

        let status: SnapshotStatus
        if loggedIn, hadPayload || !metrics.isEmpty {
            status = .ok
        } else if loggedIn {
            status = consoleFailureStatus(results["billing"], results["lite"], results["status"])
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let statusProbe = results["status"], !statusProbe.isOK {
            status = statusProbe.failureStatus
        } else {
            status = .needsLogin
        }

        if billingCycle == nil, PlanCatalog.hasListPrice(plan) { billingCycle = .monthly }
        return ProviderSnapshot(
            provider: .opencode,
            planName: plan,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            billingCycle: billingCycle,
            planExpiresAt: planExpiresAt
        )
    }

    /// 已登录但 `billing` / `lite` 都没产出时的分档：
    /// 401 / 403（凭据失效）与 5xx（官网故障）用探针自己的口径，其余（脚本失效 `-2`、超时…）仍报「控制台接口无响应」。
    static func consoleFailureStatus(_ probes: ProbeResult?...) -> SnapshotStatus {
        for probe in probes {
            guard let probe, !probe.isOK else { continue }
            if probe.isUnauthorized || probe.status >= 500 { return probe.failureStatus }
        }
        return .error("控制台接口无响应")
    }

    /// 每个窗口带 `status`（正常为 `"ok"`）。异常态拼进 `detail` 供诊断，不据此隐藏指标。
    static func windowStateDetail(_ any: Any?) -> String? {
        guard let state = JSONHelp.string(any) else { return nil }
        let trimmed = state.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "ok" else { return nil }
        return "状态 " + trimmed
    }

    /// 官网 `isBlack`：`subscriptionID` 或 `timeSubscriptionBooked` 任一非空。
    static func indicatesBlack(_ root: [String: Any]) -> Bool {
        if let id = JSONHelp.string(root["subscriptionID"]), !id.isEmpty { return true }
        if let booked = root["timeSubscriptionBooked"], !(booked is NSNull) {
            if let s = booked as? String { return !s.isEmpty }
            return true
        }
        return false
    }

    /// 官网只在 `timeMonthlyUsageUpdated` 属于当月（UTC）时显示 `monthlyUsage`，否则按 0。
    static func monthlyUsageUSD(_ root: [String: Any], now: Date) -> Double {
        guard let raw = number(root["monthlyUsage"]) else { return 0 }
        guard let updated = JSONHelp.date(root["timeMonthlyUsageUpdated"]) else { return raw / balanceDivisor }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let a = cal.dateComponents([.year, .month], from: updated)
        let b = cal.dateComponents([.year, .month], from: now)
        return (a.year == b.year && a.month == b.month) ? raw / balanceDivisor : 0
    }

    /// 布尔不是数值：JSON / seroval 里的 `true` 经 `JSONHelp.double` 会变成 `1.0`
    /// （`monthlyLimit:true` 会被误当成「上限 $1」，`reload:!0` 同理），这里先把布尔挡掉。
    static func number(_ any: Any?) -> Double? {
        guard !isBoolean(any) else { return nil }
        return JSONHelp.double(any)
    }

    static func isBoolean(_ any: Any?) -> Bool {
        guard let any else { return false }
        // JSONSerialization 把 true/false 解成 __NSCFBoolean，它同时能桥成 Bool 与 Double，只能靠 CFTypeID 区分。
        if let number = any as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return any is Bool
    }

    private static func order(_ id: String) -> Int {
        switch id {
        case "weekly": return 0
        case "five_hour": return 1
        case "monthly": return 2
        case "balance": return 3
        case "monthly_limit": return 4
        default: return 9
        }
    }
}

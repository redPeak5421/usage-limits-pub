import Foundation

/// 解析 cursor.com 探针结果。
/// `GET /api/usage-summary`：套餐、Total / Cursor Models / Other Models、个人上限、团队共享池、按需超额。
/// `POST /api/dashboard/get-sand-usage-status`：Grok Bot 周额度（SAND 是内部代号）。
/// `GET /api/auth/me`：只取稳定账号 ID `sub`（拼 `request_usage` 用，不落盘、不展示身份字段）。
/// `GET /api/usage?user=<sub>`：旧版「按请求数」计费套餐的用量。
/// 端点是社区逆向的仪表盘接口，形状随时可能漂移，全程防御式取值。
public enum CursorParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        if results["usage_summary"]?.isUnauthorized == true {
            return ProviderSnapshot(
                provider: .cursor, metrics: [], fetchedAt: now, status: .needsLogin
            )
        }

        var plan: String?
        var metrics: [UsageMetric] = []
        var loggedIn = false
        var billingCycle: BillingCycle?

        // /api/auth/me 只用于确认已登录（sub 存在）。email / name / picture 一概不读。
        if let me = results["auth_me"], me.isOK, let dict = JSONHelp.object(me.body) {
            if let sub = JSONHelp.string(dict["sub"]), !sub.isEmpty {
                loggedIn = true
            } else if dict["hasSub"] as? Bool == true {
                loggedIn = true
            } else if let fp = JSONHelp.string(dict["identityFingerprint"]), !fp.isEmpty {
                loggedIn = true
            }
        }
        // 旧版请求制套餐：检测到就整卡换口径（token 计量的几条并列展示会误导）。
        let legacy = legacyRequests(results)

        if let summary = results["usage_summary"], summary.isOK,
           let dict = JSONHelp.object(summary.body) {
            if let membership = JSONHelp.string(dict["membershipType"]), !membership.isEmpty {
                loggedIn = true
                plan = planLabel(membership)
            }
            let cycleStart = JSONHelp.date(dict["billingCycleStart"])
            let cycleEnd = JSONHelp.date(dict["billingCycleEnd"])
            billingCycle = BillingCycle.resolve(
                explicit: nil, periodStart: cycleStart, periodEnd: cycleEnd
            )
            let individual = dict["individualUsage"] as? [String: Any]
            let team = dict["teamUsage"] as? [String: Any]
            let planUsage = individual?["plan"] as? [String: Any]
            // Enterprise / Team 成员的个人上限与团队共享池，单位同样是分。
            let overall = individual?["overall"] as? [String: Any]
            let pooled = team?["pooled"] as? [String: Any]
            // plan.enabled == false 时套餐池关掉，和 on-demand 一样整段丢掉。
            let planEnabled = boolFlag(planUsage?["enabled"]) != false
            // 百分比条的美元 detail：优先本人套餐池，再退到个人上限、团队共享池。
            let usdDetail = (planEnabled ? usdRange(planUsage) : nil) ?? usdRange(overall) ?? usdRange(pooled)

            if let legacy {
                let usedCount = JSONHelp.intTruncating(legacy.used)
                let limitCount = JSONHelp.intTruncating(legacy.limit)
                metrics.append(UsageMetric(
                    id: "requests", label: "Requests",
                    usedPercent: min(max(legacy.used / legacy.limit * 100, 0), 100),
                    remaining: Swift.max(legacy.limit - legacy.used, 0),
                    total: legacy.limit,
                    resetsAt: cycleEnd,
                    detail: usedCount.flatMap { used in
                        limitCount.map { "\(used) / \($0) requests" }
                    },
                    pinned: true
                ))
                loggedIn = true
            }

            let hasPools = planEnabled
                && (hasPresent(planUsage?["autoPercentUsed"]) || hasPresent(planUsage?["apiPercentUsed"]))
            if hasPools {
                loggedIn = true
                // 旧版请求制套餐下这三条是 token 计费口径，和请求配额并列没有意义，整体隐藏。
                if legacy == nil {
                    // 官网 Spending 页的两个池（2026-06 改版）：autoPercentUsed → Cursor Models
                    //（Cursor Grok + Composer，改版前叫 Auto），apiPercentUsed → Other Models
                    //（第三方模型按 API 价）。百分比是 0–100 整数，不能走 JSONHelp.percent
                    //（它会把 ≤1 的值当 0–1 口径放大 100 倍）。
                    // totalPercentUsed 在场时作为 Total 抬头排第一：它与两个池共用 billingCycleEnd，
                    // longestWindowMetric 并列取靠前一条，折叠摘要因此自然落到 Total。
                    if let total = percent100(planUsage?["totalPercentUsed"]) {
                        metrics.append(UsageMetric(id: "total", label: "Total",
                                                   usedPercent: total, resetsAt: cycleEnd, pinned: true))
                    }
                    metrics.append(UsageMetric(id: "cursor_models", label: "Cursor Models",
                                               usedPercent: percent100(planUsage?["autoPercentUsed"]),
                                               resetsAt: cycleEnd, detail: usdDetail))
                    metrics.append(UsageMetric(id: "other_models", label: "Other Models",
                                               usedPercent: percent100(planUsage?["apiPercentUsed"]),
                                               resetsAt: cycleEnd, detail: usdDetail))
                }
            } else {
                // 池字段缺失（老响应形状 / Enterprise 成员）时回落到总量：
                // plan 的总百分比 → plan 用量比 → 个人上限 → 团队共享池。
                let percent = (planEnabled
                    ? (percent100(planUsage?["totalPercentUsed"])
                        ?? ratioPercent(used: planUsage?["used"], limit: planUsage?["limit"]))
                    : nil)
                    ?? ratioPercent(used: overall?["used"], limit: overall?["limit"])
                    ?? ratioPercent(used: pooled?["used"], limit: pooled?["limit"])
                if percent != nil || (planEnabled && planUsage != nil && cycleEnd != nil) {
                    metrics.append(UsageMetric(id: "included", label: "Included",
                                               usedPercent: percent, resetsAt: cycleEnd,
                                               detail: usdDetail))
                    loggedIn = true
                }
            }

            // 团队共享池：开通且有上限就总是展示一条（成员看得到团队还剩多少）。
            if let pooled, (pooled["enabled"] as? Bool) == true,
               let limit = JSONHelp.double(pooled["limit"]), limit > 0 {
                let used = JSONHelp.double(pooled["used"]) ?? 0
                metrics.append(UsageMetric(
                    id: "team_pooled", label: "Team pooled",
                    usedPercent: min(max(used / limit * 100, 0), 100),
                    resetsAt: cycleEnd,
                    detail: "上限 \(money(limit))",
                    amount: used / 100, currency: "USD"
                ))
                loggedIn = true
            }
            // On-demand 常见形态就是「无上限但已花了 $X」，不能因为 limit 为 null 就整条丢掉。
            if let metric = spendMetric(individual?["onDemand"] as? [String: Any],
                                        id: "on_demand", label: "On-demand", resetsAt: cycleEnd) {
                metrics.append(metric)
            }
            if let metric = spendMetric(team?["onDemand"] as? [String: Any],
                                        id: "team_on_demand", label: "Team on-demand", resetsAt: cycleEnd) {
                metrics.append(metric)
            }
            // Grok Bot 周额度：官网 Spending 页独立区块「Grok Bot · Weekly usage」。
            // 字段名尚无社区样本，在整棵响应里递归找键名含 grok 的子对象（可能挂在
            // 顶层，也可能在 individualUsage 之类的容器下），真机日志校准后收紧。
            if legacy == nil, let bot = findGrokObject(in: dict, depth: 0),
               let metric = grokMetric(from: bot, now: now) {
                metrics.append(metric)
            }
        }
        // Grok Bot 周额度：Spending 页走 get-sand-usage-status（SAND = Grok Bot）。
        // 整段响应都是 Bot 用量，可直接当候选对象；旧的 grok_bot_usage / 含 grok 子树
        // 仍保留作回落。
        if legacy == nil, !metrics.contains(where: { $0.id == "grok_bot" }) {
            for name in ["sand_usage_status", "grok_bot_usage"] {
                guard let probe = results[name], probe.isOK,
                      let dict = JSONHelp.object(probe.body) else { continue }
                if name == "sand_usage_status", !isSandUsageAvailable(dict) { continue }
                let candidate = findGrokObject(in: dict, depth: 0) ?? dict
                if let metric = grokMetric(from: candidate, now: now) {
                    metrics.append(metric)
                    loggedIn = true
                    break
                }
            }
        }

        let status: SnapshotStatus
        if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let summary = results["usage_summary"], !summary.isOK {
            // 401/403 → 重新登录；5xx / 超时 / 网络层不该催用户登录。
            status = summary.failureStatus
        } else {
            status = .needsLogin
        }

        if billingCycle == nil, PlanCatalog.hasListPrice(plan) { billingCycle = .monthly }
        return ProviderSnapshot(
            provider: .cursor, planName: plan, metrics: metrics, fetchedAt: now,
            status: status, billingCycle: billingCycle
        )
    }

    /// 旧版按请求数计费的套餐（`/api/usage?user=` 的 `gpt-4.maxRequestUsage` 非空即判定）。
    private struct LegacyRequests {
        var used: Double
        var limit: Double
    }

    private static func legacyRequests(_ results: [String: ProbeResult]) -> LegacyRequests? {
        guard let probe = results["request_usage"], probe.isOK,
              let dict = JSONHelp.object(probe.body),
              let gpt4 = dict["gpt-4"] as? [String: Any],
              let limit = JSONHelp.double(gpt4["maxRequestUsage"]), limit > 0 else { return nil }
        let used = JSONHelp.double(gpt4["numRequests"]) ?? 0
        guard JSONHelp.intTruncating(limit) != nil, JSONHelp.intTruncating(used) != nil else { return nil }
        return LegacyRequests(used: used, limit: limit)
    }

    /// `{enabled, used, limit, remaining}`（单位分）→ 金额指标。
    /// limit > 0 出百分比 + 金额；无上限但花过钱只出金额 + 「无上限」；都没有就不入列。
    private static func spendMetric(
        _ pool: [String: Any]?, id: String, label: String, resetsAt: Date?
    ) -> UsageMetric? {
        guard let pool else { return nil }
        if boolFlag(pool["enabled"]) == false { return nil }
        let used = JSONHelp.double(pool["used"]) ?? 0
        let limit = JSONHelp.double(pool["limit"]) ?? 0
        if limit > 0 {
            return UsageMetric(
                id: id, label: label,
                usedPercent: min(max(used / limit * 100, 0), 100),
                resetsAt: resetsAt,
                detail: "已用 \(money(used)) / \(money(limit))",
                amount: used / 100, currency: "USD"
            )
        }
        if used > 0 {
            return UsageMetric(
                id: id, label: label, resetsAt: resetsAt, detail: "无上限",
                amount: used / 100, currency: "USD"
            )
        }
        return nil
    }

    private static func hasPresent(_ any: Any?) -> Bool {
        guard let any else { return false }
        return !(any is NSNull)
    }

    private static func boolFlag(_ any: Any?) -> Bool? {
        if let value = any as? Bool { return value }
        return nil
    }

    /// `used` / `limit` 是分，展示成美元。
    private static func money(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    private static func usdRange(_ pool: [String: Any]?) -> String? {
        guard let pool, let used = JSONHelp.double(pool["used"]),
              let limit = JSONHelp.double(pool["limit"]), limit > 0 else { return nil }
        return "已用 \(money(used)) / \(money(limit))"
    }

    /// 套餐没有 Grok Bot 周额度时（免费号 / 未开通），接口仍可能回 0%，不能画空行。
    private static func isSandUsageAvailable(_ dict: [String: Any]) -> Bool {
        if let hasLimit = dict["hasNonZeroIncludedLimit"] as? Bool, hasLimit == false { return false }
        if let hasUsage = dict["hasAvailableUsage"] as? Bool, hasUsage == false { return false }
        return true
    }

    /// 0–100 口径的百分比字段，仅做区间钳制。
    private static func percent100(_ any: Any?) -> Double? {
        JSONHelp.double(any).map { min(max($0, 0), 100) }
    }

    /// 递归找键名含 grok 的子对象（深度限 4 防环；键排序保证确定性）。
    private static func findGrokObject(in dict: [String: Any], depth: Int) -> [String: Any]? {
        guard depth <= 4 else { return nil }
        for key in dict.keys.sorted() {
            guard let sub = dict[key] as? [String: Any] else { continue }
            if key.lowercased().contains("grok") { return sub }
            if let found = findGrokObject(in: sub, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 从候选对象提取 Grok Bot 周额度：先在对象本身取，取不到再下探一层子对象
    /// （形如 { weeklyUsage: { percentUsed, resetDate } } 的包裹）。
    private static func grokMetric(from bot: [String: Any], now: Date) -> UsageMetric? {
        var candidates: [[String: Any]] = [bot]
        for key in bot.keys.sorted() {
            if let sub = bot[key] as? [String: Any] { candidates.append(sub) }
        }
        for c in candidates {
            let percent = percent100(c["percentUsed"])
                ?? percent100(c["totalPercentUsed"])
                ?? percent100(c["usedPercent"])
                ?? percent100(c["usagePercent"])
                ?? percent100(c["percent"])
                ?? percent100(c["percentageUsed"])
                ?? ratioPercent(used: c["used"], limit: c["limit"])
                ?? percent100(c["utilization"])
            var resets: Date?
            for key in c.keys.sorted() {
                let lower = key.lowercased()
                if lower.contains("reset") || lower.contains("periodend")
                    || lower.hasSuffix("atms") || lower.contains("endms") {
                    if let date = JSONHelp.date(c[key]) { resets = date; break }
                }
                if resets == nil,
                   (lower.contains("remaining") || lower.contains("until") || lower.contains("left")),
                   lower.contains("ms") || lower.contains("millis") || lower.contains("time"),
                   let milliseconds = JSONHelp.double(c[key]),
                   milliseconds > 0, milliseconds < 366 * 24 * 3600 * 1000 {
                    resets = JSONHelp.date(byAdding: milliseconds / 1000, to: now)
                    break
                }
            }
            if percent == nil && resets == nil { continue }
            if percent == 0 && resets == nil { continue }
            return UsageMetric(id: "grok_bot", label: "Grok Bot",
                               usedPercent: percent, resetsAt: resets,
                               detail: windowDetail(from: c, resets: resets))
        }
        return nil
    }

    /// 窗口长度：currentPeriodStart → 重置时间，写成「7 天窗口」（不足一天按小时）。
    private static func windowDetail(from dict: [String: Any], resets: Date?) -> String? {
        guard let resets else { return nil }
        var start: Date?
        for key in dict.keys.sorted() where key.lowercased().contains("start") {
            if let date = JSONHelp.date(dict[key]) { start = date; break }
        }
        guard let start else { return nil }
        let seconds = resets.timeIntervalSince(start)
        guard seconds > 0 else { return nil }
        if seconds >= 86400 {
            return JSONHelp.intRounded(seconds / 86400).map { "\($0) 天窗口" }
        }
        return JSONHelp.intRounded(seconds / 3600).map { "\($0) 小时窗口" }
    }

    private static func ratioPercent(used: Any?, limit: Any?) -> Double? {
        guard let u = JSONHelp.double(used), let l = JSONHelp.double(limit), l > 0 else { return nil }
        return min(max(u / l * 100, 0), 100)
    }

    private static func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "free": return "Cursor Free"
        case "free_trial", "trial": return "Cursor Free Trial"
        case "express", "start": return "Cursor Start"
        case "hobby": return "Cursor Hobby"
        case "pro", "pro_student", "pro-student": return "Cursor Pro"
        case "pro_plus", "pro-plus", "proplus": return "Cursor Pro+"
        case "ultra": return "Cursor Ultra"
        case "team", "teams", "business": return "Cursor Teams"
        case "enterprise": return "Cursor Enterprise"
        default: return "Cursor（\(raw)）"
        }
    }
}

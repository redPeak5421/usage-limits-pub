import Foundation

/// 解析 chatgpt.com 探针结果（session / accounts_check / wham_usage /
/// bootstrap / subscriptions / spend_monthly）。后三个是尽力而为的补充探针。
public enum OpenAIParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        if results["session"]?.isUnauthorized == true {
            return ProviderSnapshot(
                provider: .openai, metrics: [], fetchedAt: now, status: .needsLogin
            )
        }

        var plan: String?
        var planExpiresAt: Date?
        var metrics: [UsageMetric] = []

        // chatgpt.com 对匿名访客也返回 200 的 session，甚至带游客 accessToken，
        // 且该游客 token 还能让部分 backend-api 探针返回 200（2026-08-16 模拟器实测）。
        // 因此：只要 session 探针在场，user.email 非空就是主要登录证据；
        // session 401/403 赢整轮；accounts_check / wham 仅在 session 缺失或 5xx/超时时才作兜底。
        var sessionSeen = false
        var emailPresent = false
        if let session = results["session"], session.isOK,
           let dict = JSONHelp.object(session.body) {
            sessionSeen = true
            let user = dict["user"] as? [String: Any]
            emailPresent = !(JSONHelp.string(user?["email"]) ?? "").isEmpty
        }

        // 页内内嵌 JSON（#client-bootstrap / __NEXT_DATA__）里的 authStatus：
        // session 接口漂移时的登录态第二证据，logged_out 则是最硬的反证。
        var bootstrapLoggedIn: Bool?
        if let boot = results["bootstrap"], boot.isOK, let dict = JSONHelp.object(boot.body) {
            switch (JSONHelp.string(dict["authStatus"]) ?? "").lowercased() {
            case "logged_in": bootstrapLoggedIn = true
            case "logged_out": bootstrapLoggedIn = false
            default:
                // 只回传了「页面里有邮箱」也算已登录证据（脚本不回传邮箱本身）
                if (dict["hasEmail"] as? Bool) == true { bootstrapLoggedIn = true }
            }
        }

        var accountEvidence = false
        if let check = results["accounts_check"], check.isOK, let dict = JSONHelp.object(check.body) {
            // 免费版账号的响应里会残留已到期的历史订阅记录（subscription_plan 仍写着
            // pro/plus，2026-08-16 真机实测）：只有 has_active_subscription 非 false
            // 且未过有效期的记录才算现行套餐，否则回落到 account.plan_type。
            let current = JSONHelp.dictsContainingKey("subscription_plan", in: dict).first { _, ent in
                if (ent["has_active_subscription"] as? Bool) == false { return false }
                if let expires = JSONHelp.date(ent["expires_at"]), expires <= now { return false }
                return true
            }
            // 只取套餐名，不再单列「订阅状态」行——套餐徽章+价格已表达订阅信息，
            // 且其他服务商无此维度（2026-08-16 用户确认去掉）。
            if let ent = current?.dict {
                plan = planLabel(JSONHelp.string(ent["subscription_plan"]))
                // 现行订阅的到期/续费时间（到期提醒用；缺失或形状漂移则为 nil）
                planExpiresAt = JSONHelp.date(ent["expires_at"])
            }
            if plan == nil, let acct = JSONHelp.dictsContainingKey("plan_type", in: dict).first?.dict {
                plan = planLabel(JSONHelp.string(acct["plan_type"]))
            }
            accountEvidence = plan != nil
        }

        // Codex 用量窗口（wham/usage）：主额度 rate_limit(s) → 代码审查 → additional_rate_limits[]（按 limit_name 命名）
        // → 其它未知分组递归兜底。各分组 id 互不相同，主额度绝不会被附加限额顶掉（DEVLOG #49）。
        var whamEvidence = false
        var spendPool: [String: Any]?
        if let wham = results["wham_usage"], wham.isOK, let dict = JSONHelp.object(wham.body) {
            // credits / individual_limit / spend_control 是金额池，字段是 remaining_percent
            // 而不是 used_percent，绝不能被当成额度窗口再列一行（各自有专属解析）。
            var consumed = Set<String>(["credits", "individual_limit", "individualLimit", "spend_control"])
            func appendWindows(in container: Any, prefix: String, idPrefix: String) {
                let windows = JSONHelp.dictsContainingKey("used_percent", in: container).sorted { $0.path < $1.path }
                for (path, w) in windows {
                    guard !path.lowercased().contains("individual_limit"),
                          !path.lowercased().contains("spend_control") else { continue }
                    guard let percent = JSONHelp.percentAlreadyHundred(w["used_percent"]) else { continue }
                    var resets = JSONHelp.date(w["resets_at"]) ?? JSONHelp.date(w["reset_at"])
                    if resets == nil,
                       let secs = JSONHelp.double(w["resets_in_seconds"]) ?? JSONHelp.double(w["reset_after_seconds"]) {
                        resets = JSONHelp.date(byAdding: secs, to: now)
                    }
                    let minutes = windowMinutes(w)
                    let windowKey = path.split(separator: ".").last.map(String.init) ?? "primary"
                    let label = windowLabel(prefix: prefix, path: path, minutes: minutes, resetsAt: resets, now: now)
                    let id = idPrefix.isEmpty ? windowKey : "\(idPrefix).\(windowKey)"
                    metrics.append(UsageMetric(id: id, label: label, usedPercent: percent, resetsAt: resets))
                    whamEvidence = true
                }
            }
            for key in ["rate_limits", "rate_limit", "usage"] where dict[key] != nil {
                appendWindows(in: dict[key]!, prefix: "Codex", idPrefix: "")
                consumed.insert(key)
            }
            for key in ["code_review_rate_limits", "code_review_rate_limit"] where dict[key] != nil {
                appendWindows(in: dict[key]!, prefix: "Codex 代码审查", idPrefix: "code_review")
                consumed.insert(key)
            }
            if let extras = dict["additional_rate_limits"] as? [Any] {
                for (index, raw) in extras.enumerated() {
                    guard let entry = raw as? [String: Any] else { continue }
                    let name = JSONHelp.string(entry["limit_name"]) ?? JSONHelp.string(entry["metered_feature"]) ?? "附加 \(index + 1)"
                    appendWindows(in: entry, prefix: name, idPrefix: "additional.\(name)")
                }
                consumed.insert("additional_rate_limits")
            }
            for key in dict.keys.sorted() where !consumed.contains(key) {
                guard let value = dict[key], value is [String: Any] || value is [Any] else { continue }
                // 未知分组：只在里面真有窗口时才列出，标签带分组名
                appendWindows(in: value, prefix: groupPrefix(path: "\(key).x"), idPrefix: key)
            }
            if metrics.isEmpty {
                appendWindows(in: dict, prefix: "Codex", idPrefix: "")
            }

            // Codex credits 余额（美元 credits，不是分）。unlimited 要一直露出来。
            if let credits = dict["credits"] as? [String: Any] {
                let unlimited = (credits["unlimited"] as? Bool) ?? false
                let hasCredits = (credits["has_credits"] as? Bool) ?? false
                let balance = JSONHelp.double(credits["balance"])
                if unlimited {
                    metrics.append(UsageMetric(id: "credits", label: "Codex credits",
                                               pinned: true, displayValue: "∞"))
                    whamEvidence = true
                } else if hasCredits || (balance ?? 0) > 0 {
                    metrics.append(UsageMetric(id: "credits", label: "Codex credits",
                                               amount: balance ?? 0, currency: "USD"))
                    whamEvidence = true
                }
            }

            // 美元额度池（spend controls）：wham 里按序找，都没有再用 spend_monthly 探针。
            spendPool = (dict["individual_limit"] as? [String: Any])
                ?? (dict["individualLimit"] as? [String: Any])
                ?? ((dict["rate_limit"] as? [String: Any])?["individual_limit"] as? [String: Any])
                ?? ((dict["spend_control"] as? [String: Any])?["individual_limit"] as? [String: Any])
        }

        if let m = spendLimitMetric(pool: spendPool, monthly: results["spend_monthly"]) {
            metrics.append(m)
            whamEvidence = true
        }

        // 订阅续费 / 到期：会自动续费的订阅不该触发到期提醒，
        // 所以 will_renew == true 时清掉 accounts_check 给的 expires_at。
        if let subs = results["subscriptions"], subs.isOK, let dict = JSONHelp.object(subs.body) {
            let node = dict["will_renew"] != nil
                ? dict
                : JSONHelp.dictsContainingKey("will_renew", in: dict).first?.dict
            if let node, let willRenew = node["will_renew"] as? Bool {
                if willRenew {
                    planExpiresAt = nil
                } else if let activeUntil = JSONHelp.date(node["active_until"]) {
                    planExpiresAt = activeUntil
                }
            }
        }

        let loggedIn: Bool
        if emailPresent {
            loggedIn = true
        } else if bootstrapLoggedIn == false {
            loggedIn = false
        } else if bootstrapLoggedIn == true {
            loggedIn = true
        } else if sessionSeen {
            loggedIn = false
        } else {
            loggedIn = accountEvidence || whamEvidence
        }

        var seen = Set<String>()
        metrics = metrics.filter { seen.insert($0.id).inserted }
        // 新旧字段并存时同一窗口会出现两次（标签、百分比、重置时间都一样）：只留第一条
        var uniq: [UsageMetric] = []
        for m in metrics {
            let dup = uniq.contains { o in
                o.label == m.label && o.usedPercent == m.usedPercent
                    && abs((o.resetsAt?.timeIntervalSince1970 ?? 0) - (m.resetsAt?.timeIntervalSince1970 ?? 0)) < 60
            }
            if !dup { uniq.append(m) }
        }
        metrics = uniq

        if !loggedIn {
            // 游客 session / bootstrap logged_out 也能让 wham / accounts 回 200。
            // 未登录不得留下 leftover 数字或套餐名。
            metrics = []
            plan = nil
            planExpiresAt = nil
        }

        let status: SnapshotStatus
        if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let failing = [results["session"], results["wham_usage"]]
            .compactMap({ $0 }).first(where: { !$0.isOK }) {
            // 401 / 403 才提示重新登录；5xx / 超时如实报站点错误
            status = failing.failureStatus
        } else {
            status = .needsLogin
        }

        var snapshot = ProviderSnapshot(
            provider: .openai, planName: plan, metrics: metrics,
            fetchedAt: now, status: status,
            planExpiresAt: planExpiresAt
        )
        if snapshot.planName == nil, loggedIn { snapshot.planName = "ChatGPT" }
        if loggedIn {
            snapshot.openAIResetCredits = OpenAIResetCredits.parse(results: results, now: now)
        }
        if PlanCatalog.hasListPrice(snapshot.planName) {
            snapshot.billingCycle = .monthly
        }
        return snapshot
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        // Official Pro tiers (Apr 2026): Pro $100 = 5x Plus, Pro $200 = 20x Plus.
        // chatgpt.com 前端把 $100 档标成 "Pro Lite"（subscription_plan = chatgptprolite /
        // plan_type = pro_lite，2026-08-26 真机 $100 账号显示成 $200 后校准）。
        // Match lite / 5x before plain "pro" so these ≠ ChatGPT Pro ($200).
        if raw.contains("pro"), raw.contains("lite") || raw.contains("5x") { return "ChatGPT Pro 5x" }
        if raw.contains("pro") { return "ChatGPT Pro" }
        if raw.contains("plus") { return "ChatGPT Plus" }
        if raw.contains("team") { return "ChatGPT Team" }
        if raw.contains("enterprise") { return "ChatGPT Enterprise" }
        if raw.contains("business") { return "ChatGPT Business" }
        // education 含 edu，一条就够
        if raw.contains("edu") { return "ChatGPT Edu" }
        if raw.contains("k12") { return "ChatGPT K12" }
        if raw.contains("quorum") { return "ChatGPT Quorum" }
        // free_workspace 含 free，必须排在 free 前面
        if raw.contains("workspace"), raw.contains("free") { return "ChatGPT Free Workspace" }
        if raw.contains("free") { return "ChatGPT Free" }
        // go 用词元匹配而不是裸子串，免得将来的 gov 一类档位被误判成 Go
        let words = Set(raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if words.contains("go") || raw.contains("chatgptgo") { return "ChatGPT Go" }
        return "ChatGPT（\(raw)）"
    }

    /// 美元额度池 → 单行计量。优先用 wham 里的池子，没有再用 spend_monthly 探针。
    /// `remaining_percent` 是**剩余**语义，要换算成已用。
    static func spendLimitMetric(pool: [String: Any]?, monthly: ProbeResult?) -> UsageMetric? {
        if let pool, let limit = JSONHelp.double(pool["limit"]), limit > 0 {
            let remainingPercent = JSONHelp.double(pool["remaining_percent"])
                ?? JSONHelp.double(pool["remainingPercent"])
            let used = JSONHelp.double(pool["used"])
                ?? remainingPercent.map { limit * (100 - $0) / 100 }
            var percent: Double?
            if let remainingPercent {
                percent = min(max(100 - remainingPercent, 0), 100)
            } else if let used {
                percent = min(max(used / limit * 100, 0), 100)
            }
            let resets = JSONHelp.date(pool["resets_at"]) ?? JSONHelp.date(pool["resetsAt"])
                ?? JSONHelp.date(pool["reset_at"])
            return spendMetric(usedAmount: used, limit: limit, percent: percent, resetsAt: resets)
        }
        guard let monthly, monthly.isOK, let dict = JSONHelp.object(monthly.body) else { return nil }
        let limitDict = dict["effective_monthly_limit"] as? [String: Any]
        guard let limit = JSONHelp.double(limitDict?["limit"]), limit > 0 else { return nil }
        // 未启用限额的模式不产出（照抄 CodexBar 的 inactiveEnforcementModes）
        let mode = (JSONHelp.string(limitDict?["enforcement_mode"]) ?? "").lowercased()
        guard !["none", "off", "disabled", "no_limit"].contains(mode) else { return nil }
        let used = max(0, JSONHelp.double(dict["current_month_usage"]) ?? 0)
        return spendMetric(usedAmount: used, limit: limit,
                           percent: min(max(used / limit * 100, 0), 100), resetsAt: nil)
    }

    private static func spendMetric(usedAmount: Double?, limit: Double, percent: Double?,
                                    resetsAt: Date?) -> UsageMetric {
        UsageMetric(
            id: "spend_limit",
            label: "Monthly spend limit",
            usedPercent: percent,
            resetsAt: resetsAt,
            detail: "上限 \(moneyUSD(limit))",
            amount: usedAmount,
            currency: "USD"
        )
    }

    static func moneyUSD(_ value: Double) -> String {
        if let integer = JSONHelp.intExactly(value) { return "$\(integer)" }
        guard value.isFinite, JSONHelp.intTruncating(value) != nil else { return "$—" }
        return String(format: "$%.2f", value)
    }

    /// 窗口时长（分钟）。现网 wham 用 `limit_window_seconds`（2026-08-26 $100 Pro 真机），
    /// 旧形状 `window_minutes` / `window_duration_minutes`；都兼容。
    static func windowMinutes(_ w: [String: Any]) -> Double? {
        if let m = JSONHelp.double(w["window_minutes"]) ?? JSONHelp.double(w["window_duration_minutes"])
            ?? JSONHelp.double(w["limit_window_minutes"]) {
            return m
        }
        if let s = JSONHelp.double(w["limit_window_seconds"]) ?? JSONHelp.double(w["window_seconds"])
            ?? JSONHelp.double(w["window_duration_seconds"]) {
            return s / 60
        }
        return nil
    }

    /// 窗口类型**只按时长判定**，拿不到时长再按「距重置还有多久」推断；
    /// 绝不按 primary / secondary 路径名硬猜——$100 Pro 只有周额度，且它就放在 `primary_window`。
    static func windowLabel(prefix: String, path: String, minutes: Double?, resetsAt: Date?, now: Date) -> String {
        if let minutes, minutes > 0 {
            return "\(prefix) \(durationText(minutes: minutes))窗口"
        }
        let lowerPath = path.lowercased()
        if lowerPath.contains("week") || lowerPath.contains("7d") || lowerPath.contains("daily") {
            return "\(prefix) 周窗口"
        }
        if lowerPath.contains("hour") || lowerPath.contains("5h") {
            return "\(prefix) 5 小时窗口"
        }
        if let resetsAt {
            // 距重置超过 6 小时的只可能是天 / 周级窗口
            let remaining = resetsAt.timeIntervalSince(now) / 60
            return remaining > 360 ? "\(prefix) 周窗口" : "\(prefix) 5 小时窗口"
        }
        return "\(prefix) 窗口"
    }

    /// 兼容旧签名（测试 / 其它调用方）。
    static func windowLabel(path: String, minutes: Double?, resetsAt: Date?, now: Date) -> (String, String) {
        (idFrom(path: path), windowLabel(prefix: groupPrefix(path: path), path: path, minutes: minutes, resetsAt: resetsAt, now: now))
    }

    static func durationText(minutes: Double) -> String {
        guard minutes.isFinite, minutes > 0 else { return "未知时长" }
        if minutes >= 1440 {
            let days = (minutes / 1440).rounded()
            guard let whole = JSONHelp.intTruncating(days) else { return "未知时长" }
            return whole == 7 ? "周" : "\(whole) 天"
        }
        let hours = minutes / 60
        if hours == hours.rounded() {
            guard let whole = JSONHelp.intTruncating(hours) else { return "未知时长" }
            return "\(whole) 小时"
        }
        return String(format: "%.1f 小时", hours)
    }

    /// 窗口所属分组名（父级键）：`rate_limits` → Codex 主额度；`code_review_rate_limits` → 代码审查；
    /// 其它 `<x>_rate_limits` / 未知分组按键名人类化，避免不同分组的周窗口都叫「Codex 周窗口」（DEVLOG #49）。
    static func groupKey(path: String) -> String {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return "" }
        return parts[parts.count - 2]
    }

    static func groupPrefix(path: String) -> String {
        let group = groupKey(path: path).lowercased()
        if group.isEmpty || group == "rate_limits" || group == "rate_limit" || group == "usage" { return "Codex" }
        if group.contains("code_review") { return "Codex 代码审查" }
        var name = group
        for suffix in ["_rate_limits", "_rate_limit", "rate_limits", "rate_limit", "_limits", "_limit"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)); break }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .replacingOccurrences(of: "_", with: " ")
        return name.isEmpty ? "Codex" : "Codex \(name)"
    }

    private static func idFrom(path: String) -> String {
        let parts = path.split(separator: ".").map(String.init)
        guard let last = parts.last else { return "primary" }
        let group = groupKey(path: path).lowercased()
        if group.contains("code_review") { return "code_review.\(last)" }
        if group.isEmpty || group == "rate_limits" || group == "rate_limit" || group == "usage" { return last }
        return "\(group).\(last)"
    }
}

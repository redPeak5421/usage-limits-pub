import Foundation

/// 解析 claude.ai 探针结果（organizations / usage / account / overage / prepaid）。
/// account / overage / prepaid 是尽力而为的补充探针：缺失、超时、非 2xx 都只是少一项数据。
public enum ClaudeParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        var plan: String?
        var metrics: [UsageMetric] = []
        var loggedIn = false
        var billing: String?
        var orgUUID: String?

        if let orgs = results["organizations"], orgs.isOK, let arr = JSONHelp.array(orgs.body) {
            let dicts = arr.compactMap { $0 as? [String: Any] }
            if let org = selectOrg(dicts) {
                loggedIn = true
                orgUUID = JSONHelp.string(org["uuid"])
                plan = planName(from: org)
                billing = billingSource(from: org)
            }
        }

        // /api/account 是比 organizations 更权威的套餐源（带 seat_tier / billing_type）。
        // 邮箱一律不取、不落盘。
        if let account = results["account"], account.isOK, let dict = JSONHelp.object(account.body),
           let membership = selectMembership(dict, orgUUID: orgUUID) {
            loggedIn = true
            let org = membership["organization"] as? [String: Any]
            if let name = planName(
                rateLimitTier: JSONHelp.string(org?["rate_limit_tier"]),
                billingType: JSONHelp.string(org?["billing_type"]),
                seatTier: JSONHelp.string(membership["seat_tier"]),
                capabilities: []
            ) {
                plan = name
            }
        }

        var extraUsageMetric: UsageMetric?
        var sawExtraUsageObject = false

        if let usage = results["usage"], usage.isOK, let dict = JSONHelp.object(usage.body) {
            // 这些键有专属处理，不能再被「未知窗口」规则扫一遍
            var handled: Set<String> = ["limits", "extra_usage", "spend", "member_dashboard_available"]

            // 计量名一律用官网 Settings → Usage 的原名（Current session / All models / 模型名），
            // 不自造名称。
            let known: [(key: String, label: String)] = [
                ("five_hour", "Current session"),
                ("seven_day", "All models"),
                ("seven_day_opus", "Opus"),
                ("seven_day_sonnet", "Sonnet"),
                ("session", "Current session"),
                ("weekly", "All models"),
            ]
            for entry in known {
                handled.insert(entry.key)
                guard let w = dict[entry.key] as? [String: Any],
                      var m = windowMetric(id: entry.key, label: entry.label, window: w) else { continue }
                // 正在进行的会话窗口即使 0% 也要露出来；five_hour 为 null 则整行不产出，
                // 这样「真 0%」与「没有会话窗口」不再混为一谈。
                if entry.key == "five_hour" || entry.key == "session" { m.pinned = true }
                metrics.append(m)
                loggedIn = true
            }

            // 别名窗口：官网同一个窗口在不同版本报文里换过好几个键名，首个存在的键胜出。
            for group in aliasWindows {
                for key in group.keys { handled.insert(key) }
                for key in group.keys {
                    guard let w = dict[key] as? [String: Any] else { continue }
                    if let m = windowMetric(id: group.id, label: group.label, window: w) {
                        metrics.append(m)
                        loggedIn = true
                    }
                    break
                }
            }

            // limits[] 是官网 Settings → Usage 的权威口径（2026-08-16 真机报文），
            // 其中 weekly_scoped（按模型的本周限额）是顶层窗口键没有的维度。
            // session / weekly_all 与顶层 five_hour / seven_day 同源，按 id 归一去重。
            if let limitsArr = dict["limits"] as? [Any] {
                for (i, item) in limitsArr.enumerated() {
                    guard let l = item as? [String: Any],
                          let kind = JSONHelp.string(l["kind"]) else { continue }
                    let percent = claudePercent(l["percent"])
                    let resets = JSONHelp.date(l["resets_at"])
                    guard percent != nil || resets != nil else { continue }
                    let model = (l["scope"] as? [String: Any])?["model"] as? [String: Any]
                    let display = JSONHelp.string(model?["display_name"])
                    let id: String, label: String
                    var pinned: Bool?
                    switch kind {
                    case "session": (id, label, pinned) = ("five_hour", "Current session", true)
                    case "weekly_all": (id, label) = ("seven_day", "All models")
                    case "weekly_scoped":
                        // 「全模型」的 scoped 条目与顶层 seven_day 同源，收进来会多出重复的一行
                        guard !isAllModelsScope(modelID: JSONHelp.string(model?["id"]), modelName: display) else { continue }
                        // id 优先用 model.id：同名模型不撞 id，官网改展示名也不会让
                        // 持久化的 SharedStore.metricOrder 失效
                        let identity = JSONHelp.string(model?["id"]) ?? display ?? "scoped \(i)"
                        let s = slug(identity)
                        guard !s.isEmpty else { continue }
                        (id, label) = ("weekly_scoped_\(s)", display ?? identity)
                    default:
                        (id, label) = (kind, display ?? kind)
                    }
                    guard !metrics.contains(where: { $0.id == id }) else { continue }
                    metrics.append(UsageMetric(id: id, label: label, usedPercent: percent,
                                               resetsAt: resets, pinned: pinned))
                    loggedIn = true
                }
            }

            // 未知顶层窗口的自适应规则：含 utilization 的子对象，只有 resets_at 非空
            // 或 utilization > 0 才算真窗口（nimbus_quill 这类 {0, null} 占位键要丢掉）。
            for key in dict.keys.sorted() where !handled.contains(key) {
                guard let w = dict[key] as? [String: Any], w["utilization"] != nil else { continue }
                let percent = claudePercent(w["utilization"])
                let resets = JSONHelp.date(w["resets_at"])
                guard resets != nil || (percent ?? 0) > 0 else { continue }
                if let m = windowMetric(id: key, label: humanized(key), window: w) {
                    metrics.append(m)
                    loggedIn = true
                }
            }

            // 键名漂移兜底：上面一条都没命中时，任何长得像限额窗口的子对象都收进来
            if metrics.isEmpty {
                for (k, v) in dict {
                    if let w = v as? [String: Any],
                       w["utilization"] != nil || w["resets_at"] != nil,
                       let m = windowMetric(id: k, label: k, window: w) {
                        metrics.append(m)
                        loggedIn = true
                    }
                }
            }

            if let extra = dict["extra_usage"] as? [String: Any] {
                sawExtraUsageObject = true
                extraUsageMetric = extraUsage(from: extra)
            }
        }

        // usage 里没有 extra_usage 时才用 overage_spend_limit 探针补（探针脚本同样有这个门控）
        if extraUsageMetric == nil, !sawExtraUsageObject,
           let overage = results["overage"], overage.isOK, let dict = JSONHelp.object(overage.body) {
            extraUsageMetric = extraUsage(from: dict)
        }
        if let extraUsageMetric { metrics.append(extraUsageMetric) }

        if let prepaid = results["prepaid"], prepaid.isOK, let dict = JSONHelp.object(prepaid.body),
           let m = prepaidCredits(from: dict) {
            metrics.append(m)
        }

        let status: SnapshotStatus
        if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let orgs = results["organizations"], !orgs.isOK {
            // 401 / 403 才提示重新登录；5xx / 超时如实报站点错误
            status = orgs.failureStatus
        } else {
            status = .needsLogin
        }

        let cycle: BillingCycle? = PlanCatalog.hasListPrice(plan) ? .monthly : nil
        return ProviderSnapshot(provider: .claude, planName: plan, metrics: metrics, fetchedAt: now,
                                status: status, billingSource: billing, billingCycle: cycle)
    }

    // MARK: - org / membership 选择

    /// chat 能力 → 第一个「非纯 API」org → 第一个 org。
    /// 第二级是必要的：账号里唯一的非 chat org 是 API 工作区时，选中它拿不到任何 usage。
    /// 顺序必须与 `ProviderScripts.claude` 的探针脚本一致。
    static func selectOrg(_ orgs: [[String: Any]]) -> [String: Any]? {
        func caps(_ o: [String: Any]) -> [String] {
            ((o["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []).map { $0.lowercased() }
        }
        if let chat = orgs.first(where: { caps($0).contains("chat") }) { return chat }
        if let notAPI = orgs.first(where: { let c = caps($0); return !(c.count == 1 && c[0] == "api") }) { return notAPI }
        return orgs.first
    }

    private static func selectMembership(_ account: [String: Any], orgUUID: String?) -> [String: Any]? {
        let memberships = (account["memberships"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        if let orgUUID, let match = memberships.first(where: {
            JSONHelp.string(($0["organization"] as? [String: Any])?["uuid"]) == orgUUID
        }) {
            return match
        }
        return memberships.first
    }

    // MARK: - 计费渠道

    /// 订阅计费来源探测：iOS 内购的标价与官网不同（Max 20x $249.99 vs $200）。
    /// billing 字段名尚无真机样本，先按「billing/payment/platform 相关键的字符串值
    /// 含 apple/ios/iap」防御式探测，拿到真机 organizations 报文后收紧。
    private static func billingSource(from org: [String: Any]) -> String? {
        for (key, value) in org {
            let k = key.lowercased()
            guard k.contains("billing") || k.contains("payment") || k.contains("platform")
                || k.contains("subscription") else { continue }
            if let s = (value as? String)?.lowercased(),
               s.contains("apple") || s.contains("ios") || s.contains("iap") || s.contains("app_store") {
                return "app_store"
            }
        }
        return nil
    }

    // MARK: - 窗口

    private static let aliasWindows: [(id: String, label: String, keys: [String])] = [
        ("routines", "Daily Routines",
         ["seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines", "routine"]),
        ("cowork", "Cowork", ["seven_day_cowork", "cowork"]),
        ("oauth_apps", "OAuth apps", ["seven_day_oauth_apps"]),
    ]

    private static func windowMetric(id: String, label: String, window: [String: Any]) -> UsageMetric? {
        let percent = claudePercent(window["utilization"])
        let resets = JSONHelp.date(window["resets_at"])
        // 与自适应规则同口径：0% + 空 reset 是占位键，兜底也不能产出。
        guard resets != nil || (percent ?? 0) > 0 else { return nil }
        return UsageMetric(id: id, label: label, usedPercent: percent, resetsAt: resets)
    }

    /// 未知窗口键的人类化标签：去掉 seven_day_ 前缀、下划线转空格、首字母大写。
    static func humanized(_ key: String) -> String {
        var name = key
        if name.hasPrefix("seven_day_") { name = String(name.dropFirst("seven_day_".count)) }
        name = name.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return key }
        return String(first).uppercased() + name.dropFirst()
    }

    /// 小写 + 非字母数字转 `-` + 首尾去 `-`（与 CodexBar 的 scoped-limit slug 同口径）。
    static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isAllModelsScope(modelID: String?, modelName: String?) -> Bool {
        if let modelName, slug(modelName) == "all-models" { return true }
        guard let modelID, !modelID.isEmpty else { return false }
        let s = slug(modelID)
        return s == "all-models" || s.hasSuffix("-all-models")
    }

    /// Claude usage 的 utilization / limits[].percent 是原生 0–100 口径
    ///（真机 18.0、34、整数 1=1%、小数 0.5=0.5%）。
    /// 不能走 `JSONHelp.percent`（`v <= 1` 会把 1% 放大成 100%、0.5% 放大成 50%）。
    private static func claudePercent(_ any: Any?) -> Double? {
        JSONHelp.percentAlreadyHundred(any)
    }

    // MARK: - 金额

    /// Extra usage（官网 Settings → Usage 的 Extra usage）。
    /// `extra_usage`（内联）与 `overage_spend_limit`（独立探针）形状一致，只有上限字段名不同。
    /// 金额单位是 minor units（分），按 decimal_places 换算，缺省 2。
    static func extraUsage(from dict: [String: Any]) -> UsageMetric? {
        guard (dict["is_enabled"] as? Bool) == true else { return nil }
        guard let limit = JSONHelp.double(dict["monthly_limit"] ?? dict["monthly_credit_limit"]),
              limit > 0 else { return nil }
        let used = JSONHelp.double(dict["used_credits"]) ?? 0
        let divisor = minorUnitDivisor(dict["decimal_places"])
        let percent = claudePercent(dict["utilization"]) ?? min(max(used / limit * 100, 0), 100)
        let currency = (JSONHelp.string(dict["currency"])?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0.uppercased()
        } ?? "USD"
        return UsageMetric(
            id: "extra_usage",
            label: "Extra usage",
            usedPercent: percent,
            detail: "上限 \(money(limit / divisor, currency: currency))",
            amount: used / divisor,
            currency: currency
        )
    }

    /// 预充值的 Usage credits 余额（`{amount, currency}`，分）。

    static func prepaidCredits(from dict: [String: Any]) -> UsageMetric? {
        guard let amount = JSONHelp.double(dict["amount"]), amount > 0 else { return nil }
        let divisor = minorUnitDivisor(dict["decimal_places"])
        let currency = (JSONHelp.string(dict["currency"])?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0.uppercased()
        } ?? "USD"
        return UsageMetric(
            id: "prepaid_credits",
            label: "Usage credits",
            amount: amount / divisor,
            currency: currency
        )
    }

    private static func minorUnitDivisor(_ any: Any?) -> Double {
        if let places = JSONHelp.intExactly(any), (0...6).contains(places) {
            return pow(10, Double(places))
        }
        return 100
    }

    static func money(_ value: Double, currency: String) -> String {
        let symbol = currency.uppercased() == "USD" ? "$" : "\(currency) "
        if let integer = JSONHelp.intExactly(value) { return "\(symbol)\(integer)" }
        guard value.isFinite, JSONHelp.intTruncating(value) != nil else { return "\(symbol)—" }
        return String(format: "\(symbol)%.2f", value)
    }

    // MARK: - 套餐名

    static func planName(from org: [String: Any]) -> String? {
        planName(
            rateLimitTier: JSONHelp.string(org["rate_limit_tier"]),
            billingType: JSONHelp.string(org["billing_type"]),
            seatTier: nil,
            capabilities: (org["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }

    static func planName(
        rateLimitTier: String?,
        billingType: String?,
        seatTier: String?,
        capabilities: [String]
    ) -> String? {
        let tier = (rateLimitTier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seat = (seatTier ?? "").lowercased()
        let billing = (billingType ?? "").lowercased()

        if !tier.isEmpty {
            if let max = maxPlan(from: tier) { return max }
            if tier.contains("ultra") { return "Claude Ultra" }
            if tier.contains("enterprise") { return "Claude Enterprise" }
            if tier.contains("team") { return teamPlan(seat: seat) ?? "Claude Team" }
            if tier.contains("pro") { return "Claude Pro" }
            if tier.contains("free") { return "Claude Free" }
            if tier.contains("claude"), billing.contains("stripe") { return "Claude Pro" }
            return nil
        }
        if let team = teamPlan(seat: seat) { return team }
        let caps = capabilities.map { $0.lowercased() }
        if caps.contains(where: { $0.contains("claude_max") }) { return "Claude Max" }
        if caps.contains(where: { $0.contains("claude_pro") }) { return "Claude Pro" }
        return nil
    }

    private static func maxPlan(from tier: String) -> String? {
        guard tier.contains("max") else { return nil }
        if let range = tier.range(of: #"(\d+)\s*x"#, options: .regularExpression) {
            let digits = tier[range].filter(\.isNumber)
            if let n = JSONHelp.intExactly(digits), n > 0 { return "Claude Max \(n)x" }
        }
        return "Claude Max"
    }

    private static func teamPlan(seat: String) -> String? {
        if seat.contains("standard") { return "Claude Team Standard" }
        if seat.contains("tier_1") || seat.contains("premium") { return "Claude Team Premium" }
        return nil
    }
}

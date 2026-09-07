import Foundation

/// 自定义字段的语义角色。只影响展示（主指标、进度条、格式），
/// 不产生 `usedPercent` 阈值提醒；余额提醒优先 `remaining` 角色，再回退 id / 各语言展示名。
public enum CustomFieldRole: String, Codable, CaseIterable, Sendable {
    /// 已消耗（金额 / token / 次数）
    case used
    /// 剩余 / 余额 / 可用
    case remaining
    /// 总额 / 上限 / 配额
    case limit
    /// 0…100 的百分比（已用占比）
    case percent
    /// 计数（请求数、token 数）
    case count
    /// 到期 / 重置时间（Unix 秒或毫秒）
    case timestamp
    /// 未识别
    case other

    /// 向导默认展示名。无语言参数时保持中文，避免旧模板/测试漂移。
    public var defaultLabel: String { defaultLabel(.zh) }

    public func defaultLabel(_ language: AppLanguage) -> String {
        switch self {
        case .other: return ""
        case .percent: return L10n.tr("custom.role.percent.default", language)
        case .count: return L10n.tr("custom.role.count.default", language)
        case .timestamp: return L10n.tr("custom.role.timestamp.default", language)
        default: return L10n.tr(localizationKey, language)
        }
    }

    public var localizationKey: String { "custom.role.\(rawValue)" }
}

/// 一条叶子的推断结果。`score` 越高越像用户想看的字段（向导默认勾选前几条）。
public struct CustomFieldHint: Equatable, Sendable {
    public var role: CustomFieldRole
    public var currency: String?
    public var score: Int
    /// 原始字符串带 `%`、或键名含 percent/pct 时为真，展示成百分比。
    public var isPercentString: Bool

    public init(role: CustomFieldRole, currency: String? = nil, score: Int = 0, isPercentString: Bool = false) {
        self.role = role
        self.currency = currency
        self.score = score
        self.isPercentString = isPercentString
    }
}

/// 从键名 / 数值 / 兄弟字段推断字段语义。纯启发式，猜不准就 `.other`，
/// 展示层按 `.other` 当普通数字处理，绝不编造已用 / 余额。
public enum CustomFieldSemantics {
    static let usedWords = ["used", "usage", "spent", "consumed", "cost", "charged", "expense", "已用", "消耗", "使用"]
    /// `usable` 给 `usable_requests` 这类「可用次数」；`credit(s)` 单独才是余额，`credits_used` 走已用。
    /// `unused` / `unspent` / `unconsumed` 必须先于 `used`/`spent` 子串，否则 unused_credits 会被判成已用。
    static let remainingWords = ["balance", "remain", "remaining", "left", "available", "avail", "usable", "unused", "unspent", "unconsumed", "credit", "credits", "quota_left", "余额", "剩余", "可用", "未用"]
    static let limitWords = ["total", "limit", "max", "quota", "cap", "allowance", "granted", "总额", "上限", "总量", "配额"]
    /// `rate` 单独不进这里：`rate_limit` 是上限，`usage_rate` 才当百分比。
    static let percentWords = ["percent", "percentage", "pct", "ratio", "占比", "百分比"]
    static let timestampWords = ["expire", "expiry", "expires", "expiration", "reset", "renew", "valid_until", "validuntil", "deadline", "end_time", "endtime", "period_end", "ends_at", "endsat", "cycle_end", "window_end", "billing_end", "next_", "到期", "重置"]
    static let countWords = ["token", "tokens", "request", "requests", "call", "calls", "count", "num", "次数"]
    static let currencyByWord: [String: String] = [
        "usd": "USD", "dollar": "USD", "dollars": "USD",
        "cny": "CNY", "rmb": "CNY", "yuan": "CNY", "人民币": "CNY",
        "eur": "EUR", "euro": "EUR", "gbp": "GBP", "jpy": "JPY",
    ]
    static let knownCurrencyCodes: Set<String> = ["USD", "CNY", "EUR", "GBP", "JPY", "HKD", "TWD", "KRW", "SGD", "AUD", "CAD", "RMB"]

    /// 推断一条叶子。`rawText` 是 JSON 原始字符串（可含 `$` / `¥` / `%`），
    /// `siblings` 是同级对象（用于读 `currency` / `unit` 之类的字符串字段）。
    public static func infer(
        path: String,
        value: Double,
        rawText: String?,
        siblings: [String: Any]? = nil
    ) -> CustomFieldHint {
        let key = lastKey(of: path)
        let words = tokens(of: key)
        let parentWords = tokens(of: parentKey(of: path))
        let all = words + parentWords
        let joined = words.joined(separator: "_")

        var currency = currencyFromText(rawText)
        if currency == nil {
            currency = words.compactMap { currencyByWord[$0] }.first
        }
        if currency == nil, let siblings {
            currency = currencyFromSiblings(siblings)
        }

        let percentText = (rawText?.trimmingCharacters(in: .whitespaces).hasSuffix("%") ?? false)
        let hasLimitWord = words.contains(where: limitWords.contains)
            || joined.contains("total") || joined.contains("limit") || joined.contains("quota")
        let hasPercentWord = words.contains(where: percentWords.contains)
            || joined.contains("percent")
            || (words.contains("rate") && !hasLimitWord)

        // ISO 字符串不是宽松数字，按时间戳角色露出，供账期结束等 ISO 时间戳字段勾选。
        if let rawText, lenientNumber(rawText) == nil, JSONHelp.date(rawText) != nil {
            return CustomFieldHint(role: .timestamp, score: 30)
        }

        // 时间戳：键名有到期 / 重置语义，且数值像 epoch。
        // period_end 在拆词后是 current + period + end，必须连写检查。
        let timestampHit = all.contains(where: { w in timestampWords.contains(where: { w.contains($0) }) })
            || timestampWords.contains(where: { joined.contains($0) })
        if timestampHit, looksLikeEpoch(value) {
            return CustomFieldHint(role: .timestamp, score: 30)
        }
        // remaining_percent / remaining.percent / available.pct 是剩余占比，不能先被 percent 抢成已用%。
        // 末段 used.percent 必须仍走已用%；unused 是独立 token，不会被 used 误伤。
        let remainingPercentTokens: Set<String> = [
            "remain", "remaining", "left", "available", "avail", "usable",
            "unused", "unspent", "unconsumed", "余额", "剩余", "可用", "未用",
        ]
        let usedLeadTokens: Set<String> = ["used", "usage", "spent", "consumed", "已用", "消耗"]
        let parentJoined = parentWords.joined(separator: "_")
        let remainingPercentHit = (
            all.contains(where: remainingPercentTokens.contains)
            || ["remain", "available", "usable", "unused", "unspent", "unconsumed"].contains(where: {
                joined.contains($0) || parentJoined.contains($0)
            })
        ) && !words.contains(where: usedLeadTokens.contains)
        if percentText || hasPercentWord, value >= 0, value <= 100 || (percentText && value <= 100) {
            if remainingPercentHit {
                return CustomFieldHint(role: .remaining, currency: currency, score: 90, isPercentString: true)
            }
            return CustomFieldHint(role: .percent, score: 70, isPercentString: true)
        }
        if let role = roleFromTokens(words, joined: joined) {
            return CustomFieldHint(role: role, currency: currency, score: score(for: role))
        }
        // usage.amount / quota.value：末段只是 amount/value 时看父键。
        if isGenericValueLeaf(words),
           let role = roleFromTokens(parentWords, joined: parentWords.joined(separator: "_")) {
            return CustomFieldHint(role: role, currency: currency, score: score(for: role))
        }
        if currency != nil {
            return CustomFieldHint(role: .other, currency: currency, score: 35)
        }
        // 深层 id / 时间 / 版本号之类的字段分数最低
        let noise = ["id", "code", "status", "version", "ver", "type", "page", "size", "offset", "ts", "time", "timestamp"]
        if words.contains(where: noise.contains) || looksLikeEpoch(value) {
            return CustomFieldHint(role: .other, score: 0)
        }
        return CustomFieldHint(role: .other, score: 10)
    }

    /// 向导默认勾选：按分数取前 `limit` 条（同分保持原顺序），只勾 ≥ 40 分的。
    /// 已用 / 余额 / 总额同一对象内优先成对。
    public static func suggestedPaths(_ leaves: [(path: String, hint: CustomFieldHint)], limit: Int = 4) -> [String] {
        let ranked = leaves.enumerated()
            .filter { $0.element.hint.score >= 40 }
            .sorted { lhs, rhs in
                if lhs.element.hint.score != rhs.element.hint.score {
                    return lhs.element.hint.score > rhs.element.hint.score
                }
                return lhs.offset < rhs.offset
            }
        var picked: [String] = []
        var rolesSeen: [CustomFieldRole: Int] = [:]
        for item in ranked where picked.count < limit {
            let role = item.element.hint.role
            // 同一角色最多两条，避免四条全是不同层级的 balance
            if rolesSeen[role, default: 0] >= 2 { continue }
            rolesSeen[role, default: 0] += 1
            picked.append(item.element.path)
        }
        return picked
    }

    /// 向导默认展示名：末段只是泛化角色词（`balance` / `credits`）时用角色名；
    /// `cash_balance` / `prepaid_credits` / `usable_requests` 这类多余额保留路径末段，避免全叫「余额」。
    public static func defaultDisplayName(
        path: String,
        role: CustomFieldRole,
        language: AppLanguage = .zh
    ) -> String {
        let last = CustomUsageTemplate.defaultDisplayName(for: path)
        let label = role.defaultLabel(language)
        if label.isEmpty { return last }
        return isGenericRoleKey(tokens(of: last), role: role) ? label : last
    }

    static func score(for role: CustomFieldRole) -> Int {
        switch role {
        case .remaining: return 90
        case .used: return 80
        case .limit: return 60
        case .count: return 40
        case .percent: return 70
        case .timestamp: return 30
        case .other: return 10
        }
    }

    static let genericValueLeaves: Set<String> = ["amount", "value", "qty", "quantity", "amt", "val"]

    /// `usage.amount` / `quota.value`：末段只是泛化数值词（可带币种）时看父键角色。
    static func isGenericValueLeaf(_ words: [String]) -> Bool {
        let generics = words.filter { genericValueLeaves.contains($0) }
        let extra = words.filter { word in
            !genericValueLeaves.contains(word)
                && currencyByWord[word] == nil
                && !knownCurrencyCodes.contains(word.uppercased())
        }
        return extra.isEmpty && generics.count == 1
    }

    /// 键名拆词后的角色。强剩余 / 强已用优先于上限，避免 `remainingQuota` 变 limit、`credits_used` 变 remaining。
    /// `usage` 弱于 limit（`usage_limit`），`credit(s)` 弱于 usage（`credit_usage`）。
    static func roleFromTokens(_ words: [String], joined: String) -> CustomFieldRole? {
        let remainingWeak: Set<String> = ["credit", "credits", "balance"]
        let usedWeak: Set<String> = ["usage"]
        let remainingStrong = Set(remainingWords).subtracting(remainingWeak)
        let usedStrong = Set(usedWords).subtracting(usedWeak)
        let limit = Set(limitWords)
        let count = Set(countWords)
        func has(_ set: Set<String>) -> Bool {
            words.contains(where: set.contains)
        }
        if has(remainingStrong)
            || joined.contains("remain")
            || joined.contains("available")
            || joined.contains("usable")
            || joined.contains("unused")
            || joined.contains("unspent")
            || joined.contains("unconsumed") {
            return .remaining
        }
        // cost_limit / spent_limit：末段是上限词时不得被 cost/spent 抢成已用。
        // total_used 末段是 used，仍走下面的已用。
        if let last = words.last, limit.contains(last) {
            // used_quota：已用额度。cost_limit / spent_limit 末段是 limit，仍走上限。
            let usedLead = words.contains(where: { $0 == "used" || $0 == "已用" })
            if !(usedLead && (last == "quota" || last == "配额")) {
                return .limit
            }
        }
        if has(usedStrong)
            || joined.contains("used")
            || joined.contains("spent")
            || joined.contains("consum") {
            return .used
        }
        // total_tokens / total_requests：total + 计数词是用量计数，不是上限。
        if has(count) {
            let limitHits = Set(words.filter { limit.contains($0) })
            if limitHits == ["total"] {
                return .count
            }
        }
        if has(limit)
            || joined.contains("total")
            || joined.contains("limit")
            || joined.contains("quota") {
            return .limit
        }
        if has(usedWeak) {
            return .used
        }
        if has(remainingWeak) || joined.contains("balance") {
            return .remaining
        }
        // requests_plan / max_requests：次数词 + 套餐/上限词 = 配额，不是计数
        if has(count) && (words.contains("plan") || words.contains("cap") || words.contains("max")) {
            return .limit
        }
        if has(count) {
            return .count
        }
        return nil
    }

    /// 只有一个角色词（可带币种）才用角色默认名；两个剩余词（`available_balance`）算具体字段。
    static func isGenericRoleKey(_ words: [String], role: CustomFieldRole) -> Bool {
        let generic: Set<String>
        switch role {
        case .remaining:
            generic = [
                "balance", "remaining", "remain", "left", "available", "avail", "usable",
                "credit", "credits", "余额", "剩余", "可用",
            ]
        case .used:
            generic = ["used", "usage", "spent", "consumed", "已用", "消耗", "使用"]
        case .limit:
            generic = ["total", "limit", "max", "quota", "cap", "总额", "上限", "总量", "配额"]
        case .count:
            generic = ["count", "request", "requests", "token", "tokens", "次数"]
        case .percent:
            generic = ["percent", "percentage", "pct", "ratio", "rate", "占比", "百分比"]
        case .timestamp:
            generic = ["expire", "expiry", "expires", "reset", "到期", "重置"]
        case .other:
            return true
        }
        let roleWords = words.filter { generic.contains($0) }
        let extra = words.filter { word in
            !generic.contains(word)
                && currencyByWord[word] == nil
                && !knownCurrencyCodes.contains(word.uppercased())
        }
        return extra.isEmpty && roleWords.count == 1
    }

    // MARK: - 解析辅助

    /// 宽松数字：去掉货币符号、千分位、百分号与空白后再解析。
    public static func lenientNumber(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for symbol in ["$", "¥", "￥", "€", "£", "%", ","] {
            s = s.replacingOccurrences(of: symbol, with: "")
        }
        for code in knownCurrencyCodes {
            if s.uppercased().hasSuffix(code) { s = String(s.dropLast(code.count)) }
            if s.uppercased().hasPrefix(code) { s = String(s.dropFirst(code.count)) }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return JSONHelp.double(s)
    }

    public static func currencyFromText(_ text: String?) -> String? {
        guard let text else { return nil }
        if text.contains("$") { return "USD" }
        if text.contains("¥") || text.contains("￥") { return "CNY" }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        let upper = text.uppercased()
        return knownCurrencyCodes.first { upper.hasSuffix($0) || upper.hasPrefix($0) }
    }

    static func currencyFromSiblings(_ siblings: [String: Any]) -> String? {
        for (key, value) in siblings {
            let k = key.lowercased()
            guard k == "currency" || k == "unit" || k == "currency_code" || k == "currencycode" else { continue }
            guard let text = value as? String else { continue }
            let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
            if knownCurrencyCodes.contains(upper) { return upper == "RMB" ? "CNY" : upper }
            if let mapped = currencyFromText(text) { return mapped }
        }
        return nil
    }

    static func looksLikeEpoch(_ value: Double) -> Bool {
        // 2001-09 … 2286-11（秒）或对应毫秒
        (value > 1_000_000_000 && value < 10_000_000_000) || (value > 1_000_000_000_000 && value < 10_000_000_000_000)
    }

    public static func lastKey(of path: String) -> String {
        var s = path
        // 去掉尾部数组下标
        while s.hasSuffix("]"), let open = s.lastIndex(of: "[") {
            s = String(s[..<open])
        }
        if let dot = s.lastIndex(of: ".") {
            return String(s[s.index(after: dot)...])
        }
        return s
    }

    static func parentKey(of path: String) -> String {
        var s = path
        while s.hasSuffix("]"), let open = s.lastIndex(of: "[") {
            s = String(s[..<open])
        }
        guard let dot = s.lastIndex(of: ".") else { return "" }
        return lastKey(of: String(s[..<dot]))
    }

    /// `usedAmountUSD` / `used_amount_usd` / `UsedAmount` → ["used","amount","usd"]
    static func tokens(of key: String) -> [String] {
        guard !key.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""
        var previousWasLower = false
        for ch in key {
            if ch == "_" || ch == "-" || ch == " " || ch == "." {
                if !current.isEmpty { parts.append(current); current = "" }
                previousWasLower = false
                continue
            }
            if ch.isUppercase, previousWasLower, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current.append(ch)
            previousWasLower = ch.isLowercase || ch.isNumber
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }
}

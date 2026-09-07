import Foundation

/// App 显示语言。system 表示跟随系统；系统语言不在支持列表时用英语。
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case zh
    case en
    case ja
    case fr
    case ru

    public var id: String { rawValue }

    /// 语言选项自身的展示名（各语言用其母语写法，不随界面语言变化）。
    public var displayName: String {
        switch self {
        case .system: return L10n.tr("settings.language.system", self)
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .fr: return "Français"
        case .ru: return "Русский"
        }
    }

    /// 解析成具体语言：system 按系统首选语言匹配，匹配不上用英语。
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] where preferred.hasPrefix(lang.rawValue) {
            return lang
        }
        return .en
    }
}

/// App 外观主题。system 表示跟随系统深浅色。
public enum AppTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

/// 首页主题（布局）：平铺（原列表）/ 轮盘（card-roulette 场景）/ 螺旋（glass-helix 场景）。
/// 三种都跟随外观设置的深浅色；只在 App 进程用。
public enum DashboardTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case flat
    case roulette
    case helix

    public var id: String { rawValue }

    /// 设置页分段控件文案键。
    public var titleKey: String {
        switch self {
        case .flat: return "settings.dashboardTheme.flat"
        case .roulette: return "settings.dashboardTheme.roulette"
        case .helix: return "settings.dashboardTheme.helix"
        }
    }
}

/// 轻量字符串表。不走系统 .strings（App 内即时切换语言，无需重启）。
public enum L10n {
    private static let extrasLock = NSLock()
    private static var extraTables: [[String: [AppLanguage: String]]] = []

    public static func register(table extra: [String: [AppLanguage: String]]) {
        extrasLock.lock()
        extraTables.append(extra)
        extrasLock.unlock()
    }

    public static func tr(_ key: String, _ language: AppLanguage, _ args: CVarArg...) -> String {
        let lang = language.resolved
        let format = lookup(key, lang)
        return args.isEmpty ? format : String(format: format, arguments: args)
    }

    private static func lookup(_ key: String, _ lang: AppLanguage) -> String {
        if let format = table[key]?[lang] ?? table[key]?[.en] {
            return format
        }
        extrasLock.lock()
        defer { extrasLock.unlock() }
        for extra in extraTables {
            if let format = extra[key]?[lang] ?? extra[key]?[.en] {
                return format
            }
        }
        return key
    }

    /// 解析器标签是中文源文案；已知 provider+id 走稳定键，其余再按原文查表。
    public static func metricLabel(
        provider: ProviderID,
        id: String,
        fallback: String,
        language: AppLanguage
    ) -> String {
        if let key = metricKey(provider: provider, id: id) {
            return tr(key, language)
        }
        if fallback.hasSuffix("（积分）"), fallback.count > 4 {
            let head = String(fallback.dropLast("（积分）".count))
            return metricLabel(provider: provider, id: id, fallback: head, language: language)
                + tr("（积分）", language)
        }
        if fallback.hasSuffix("（周）"), fallback.count > 3 {
            return tr("metric.weeklyService", language, tr(String(fallback.dropLast(3)), language))
        }
        if let rolling = rollingWindowLabel(fallback, language) {
            return rolling
        }
        if let classified = classifiedLabel(fallback, language) {
            return classified
        }
        if let composed = composedWindowLabel(fallback, language) {
            return composed
        }
        if let every = everyWindowLabel(fallback, language) {
            return every
        }
        return tr(fallback, language)
    }

    /// 解析器把中文源文案当 error 键；带 code / 站点短消息的串按已知前缀本地化。
    public static func trError(_ raw: String, _ language: AppLanguage) -> String {
        if table[raw] != nil { return tr(raw, language) }
        let prefixes = ["余额数据异常", "智谱接口失败", "DeepSeek code", "LongCat code", "HTTP"]
        for prefix in prefixes {
            guard raw.hasPrefix(prefix) else { continue }
            var rest = String(raw.dropFirst(prefix.count))
            if rest.hasPrefix("：") { rest = ": " + rest.dropFirst() }
            return tr(prefix, language) + rest
        }
        return tr(raw, language)
    }

    /// 解析器写在 metric.detail 里的中文源文案：精确键、无上限、已用/上限/剩余前缀、积分/天后缀。
    public static func trDetail(_ raw: String, _ language: AppLanguage) -> String {
        if raw == "无上限" { return tr("无限制", language) }
        if raw.hasSuffix("（超额）") {
            let head = String(raw.dropLast("（超额）".count)).trimmingCharacters(in: .whitespaces)
            return trDetail(head, language) + tr("（超额）", language)
        }
        if raw.hasSuffix("短期限流") {
            let head = String(raw.dropLast("短期限流".count)).trimmingCharacters(in: .whitespaces)
            let window = head.isEmpty ? "" : trDetail(head, language)
            return window.isEmpty ? tr("短期限流", language) : window + tr("短期限流", language)
        }
        if table[raw] != nil { return tr(raw, language) }
        if raw.hasPrefix("Base - ") {
            return tr("Base", language) + " - " + raw.dropFirst(7)
        }
        let expirySeparator = " · 最近到期 "
        if let range = raw.range(of: expirySeparator) {
            let head = String(raw[..<range.lowerBound])
            let date = String(raw[range.upperBound...])
            return trDetail(head, language) + " · " + tr("最近到期", language) + " " + date
        }
        if raw.hasPrefix("付费 "), let giftRange = raw.range(of: " · 赠送 ") {
            let cashStart = raw.index(raw.startIndex, offsetBy: "付费 ".count)
            let cash = String(raw[cashStart..<giftRange.lowerBound])
            let gift = String(raw[giftRange.upperBound...])
            return tr("付费", language) + " " + cash + " · " + tr("赠送", language) + " " + gift
        }
        for prefix in ["已用 ", "上限 ", "剩余 ", "已使用 ", "状态 "] {
            guard raw.hasPrefix(prefix) else { continue }
            return tr(String(prefix.dropLast()), language) + " " + raw.dropFirst(prefix.count)
        }
        for suffix in [" 积分", " 小时", " 分钟", " 天"] {
            guard raw.hasSuffix(suffix) else { continue }
            return String(raw.dropLast(suffix.count)) + " " + tr(String(suffix.dropFirst()), language)
        }
        return raw
    }

    /// ChatGPT 等解析器把品牌前缀和窗口时长拼成一条中文源文案；按最长后缀拆开再分别查表。
    private static let windowSuffixes: [(suffix: String, key: String)] = [
        (" 5 小时窗口", "5 小时窗口"),
        (" 周窗口", "周窗口"),
    ]

    private static func composedWindowLabel(_ fallback: String, _ language: AppLanguage) -> String? {
        for item in windowSuffixes {
            if let composed = splitWindowLabel(fallback, suffix: item.suffix, window: tr(item.key, language), language: language) {
                return composed
            }
        }
        if let numbered = numberedWindowLabel(fallback, language) {
            return numbered
        }
        return splitWindowLabel(fallback, suffix: " 窗口", window: tr("窗口", language), language: language)
    }

    /// `Codex 3 天窗口` / `Codex 2.5 小时窗口` 必须先于通用「 窗口」拆开，否则英文会留下「3 天」。
    private static func numberedWindowLabel(_ fallback: String, _ language: AppLanguage) -> String? {
        if let split = splitTrailingNumber(fallback, suffix: " 天窗口") {
            guard let days = Int(split.number), String(days) == split.number else { return nil }
            return joinWindowPrefix(split.prefix, window: tr("%d 天窗口", language, days), language: language)
        }
        if let split = splitTrailingNumber(fallback, suffix: " 小时窗口") {
            return joinWindowPrefix(split.prefix, window: tr("%@ 小时窗口", language, split.number), language: language)
        }
        if fallback.hasPrefix("窗口 ") {
            if fallback.hasSuffix(" 小时") {
                let mid = String(fallback.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespaces)
                if let hours = Int(mid), String(hours) == mid {
                    return tr("窗口 %d 小时", language, hours)
                }
            }
            if fallback.hasSuffix(" 分钟") {
                let mid = String(fallback.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespaces)
                if let minutes = Int(mid), String(minutes) == mid {
                    return tr("窗口 %d 分钟", language, minutes)
                }
            }
        }
        return nil
    }

    /// `Rolling（6 小时）` 是 Notion 按时长拼的源文案，不能整串查表。
    private static func rollingWindowLabel(_ fallback: String, _ language: AppLanguage) -> String? {
        if fallback == "Rolling" { return tr("Rolling", language) }
        let prefix = "Rolling（"
        guard fallback.hasPrefix(prefix), fallback.hasSuffix("）") else { return nil }
        let inner = String(fallback.dropFirst(prefix.count).dropLast())
        let units: [(suffix: String, key: String)] = [
            (" 小时", "Rolling（%d 小时）"),
            (" 分钟", "Rolling（%d 分钟）"),
            (" 天", "Rolling（%d 天）"),
            (" 周", "Rolling（%d 周）"),
        ]
        for item in units {
            guard inner.hasSuffix(item.suffix) else { continue }
            let number = String(inner.dropLast(item.suffix.count))
            guard let value = Int(number), String(value) == number else { return nil }
            return tr(item.key, language, value)
        }
        return nil
    }

    /// 智谱窗口：`每 5 小时` / `每周` / `每天` / `限额`。
    private static func everyWindowLabel(_ fallback: String, _ language: AppLanguage) -> String? {
        if fallback == "每周" || fallback == "每天" || fallback == "限额" {
            return tr(fallback, language)
        }
        let prefix = "每 "
        guard fallback.hasPrefix(prefix) else { return nil }
        let units: [(suffix: String, key: String)] = [
            (" 小时", "每 %d 小时"),
            (" 分钟", "每 %d 分钟"),
            (" 天", "每 %d 天"),
            (" 周", "每 %d 周"),
        ]
        for item in units {
            guard fallback.hasSuffix(item.suffix) else { continue }
            let number = String(fallback.dropFirst(prefix.count).dropLast(item.suffix.count))
            guard let value = Int(number), String(value) == number else { return nil }
            return tr(item.key, language, value)
        }
        return nil
    }

    /// `附加 2` 是 ChatGPT additional_rate_limits 的兜底前缀。
    private static func localizeMetricPrefix(_ prefix: String, _ language: AppLanguage) -> String {
        if table[prefix] != nil { return tr(prefix, language) }
        if prefix.hasPrefix("附加 ") {
            let number = String(prefix.dropFirst("附加 ".count))
            if let value = Int(number), String(value) == number {
                return tr("附加 %d", language, value)
            }
        }
        return prefix
    }

    /// Grok 周额度未知产品：`分类 8`。
    private static func classifiedLabel(_ fallback: String, _ language: AppLanguage) -> String? {
        let prefix = "分类 "
        guard fallback.hasPrefix(prefix) else { return nil }
        let number = String(fallback.dropFirst(prefix.count))
        guard let value = Int(number), String(value) == number else { return nil }
        return tr("分类 %d", language, value)
    }

    private static func splitWindowLabel(
        _ fallback: String,
        suffix: String,
        window: String,
        language: AppLanguage
    ) -> String? {
        guard fallback.hasSuffix(suffix), fallback.count > suffix.count else { return nil }
        return joinWindowPrefix(String(fallback.dropLast(suffix.count)), window: window, language: language)
    }

    private static func joinWindowPrefix(_ prefix: String, window: String, language: AppLanguage) -> String {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return window }
        let localizedPrefix = localizeMetricPrefix(trimmed, language)
        return localizedPrefix + " " + window
    }

    private static func splitTrailingNumber(_ fallback: String, suffix: String) -> (prefix: String, number: String)? {
        guard fallback.hasSuffix(suffix), fallback.count > suffix.count else { return nil }
        let head = String(fallback.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }
        if let space = head.lastIndex(of: " ") {
            let token = String(head[head.index(after: space)...])
            guard isNumericToken(token) else { return nil }
            return (String(head[..<space]), token)
        }
        return isNumericToken(head) ? ("", head) : nil
    }

    private static func isNumericToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func metricKey(provider: ProviderID, id: String) -> String? {
        switch (provider, id) {
        case (.deepseek, "balance"): return "deepseek.balance"
        case (.deepseek, "total_spent"): return "deepseek.spent"
        case (.deepseek, "balance_paid"): return "deepseek.balancePaid"
        case (.deepseek, "balance_granted"): return "deepseek.balanceGranted"
        case (.jimeng, "subscription"): return "订阅积分"
        case (.jimeng, "recharge"): return "充值积分"
        case (.jimeng, "gift"): return "赠送积分"
        case (.t3chat, "four_hour"): return "Base（4 小时）"
        case (.t3chat, "overage"): return "Overage"
        case (.kimi, "seven_day"): return "本周用量"
        case (.kimi, "monthly"): return "总用量"
        case (.kimi, "code_7d"): return "Code 7 天"
        case (.kimi, "five_hour"): return "频限明细"
        case (.longcat, "fuel_packages"): return "加油包"
        case (.minimax, "credits"): return "积分余额"
        case (.minimax, "lifetime_tokens"): return "累计调用量"
        case (.minimax, "active_days"): return "活跃天数"
        case (.minimax, "last_7d_calls"): return "近 7 天调用量"
        case (.minimax, "last_30d_calls"): return "近 30 天调用量"
        case (.minimax, "video_gift"): return "视频赠送"
        case (.minimax, "today_tokens"): return "今日 tokens"
        case (.minimax, "last_30d_tokens"): return "近 30 天 tokens"
        case (.minimax, "last_30d_cash"): return "近 30 天消费"
        case (.zhipu, "mcp_monthly"): return "MCP 每月额度"
        case (.zhipu, "rate_period"): return "计费时段"
        case (.grok, "auto"): return "自动"
        case (.grok, "fast"): return "快速"
        case (.grok, "expert"): return "专家"
        case (.mimo, "balance"): return "余额"
        case (.mimo, "monthly"): return "月度额度"
        case (.perplexity, "monthly"): return "月度额度"
        case (.perplexity, "purchased"): return "购买额度"
        case (.perplexity, "promotional"): return "赠送额度"
        case (.perplexity, "balance"): return "余额"
        case (.claude, "extra_usage"): return "Extra usage"
        case (.claude, "prepaid_credits"): return "Usage credits"
        case (.openai, "credits"): return "Codex credits"
        case (.openai, "spend_limit"): return "Monthly spend limit"
        case (.ollama, "weekly"): return "Weekly usage"
        case (.abacus, "compute_points"): return "Compute Points"
        case (.cursor, "requests"): return "Requests"
        case (.cursor, "total"): return "Total"
        case (.cursor, "cursor_models"): return "Cursor Models"
        case (.cursor, "other_models"): return "Other Models"
        case (.cursor, "included"): return "Included"
        case (.cursor, "team_pooled"): return "Team pooled"
        case (.cursor, "team_on_demand"): return "Team on-demand"
        case (.cursor, "grok_bot"): return "Grok Bot"
        case (.notion, "billing_period"): return "Billing Period"
        default: return nil
        }
    }

    /// key → 语言 → 文案。新增字符串时五种语言都要补齐。
    private static let table: [String: [AppLanguage: String]] = [
        "dashboard.action.expand": [
            .zh: "展开当前账号", .en: "Expand account", .ja: "アカウントを展開",
            .fr: "Développer le compte", .ru: "Развернуть аккаунт",
        ],
        "dashboard.action.collapse": [
            .zh: "收起当前账号", .en: "Collapse account", .ja: "アカウントを閉じる",
            .fr: "Réduire le compte", .ru: "Свернуть аккаунт",
        ],
        "dashboard.action.moveEarlier": [
            .zh: "向前移动", .en: "Move earlier", .ja: "前へ移動",
            .fr: "Déplacer avant", .ru: "Переместить раньше",
        ],
        "dashboard.action.moveLater": [
            .zh: "向后移动", .en: "Move later", .ja: "後ろへ移動",
            .fr: "Déplacer après", .ru: "Переместить позже",
        ],
        "dashboard.action.refreshAll": [
            .zh: "刷新全部账号", .en: "Refresh all accounts", .ja: "すべて更新",
            .fr: "Tout actualiser", .ru: "Обновить все аккаунты",
        ],
        "dashboard.action.resetHelix": [
            .zh: "螺旋竖直", .en: "Straighten helix", .ja: "らせんを垂直に",
            .fr: "Redresser l’hélice", .ru: "Выпрямить спираль",
        ],
        "dashboard.position": [
            .zh: "%d / %d", .en: "%d of %d", .ja: "%d / %d",
            .fr: "%d sur %d", .ru: "%d из %d",
        ],
        "dashboard.status.available": [
            .zh: "可用", .en: "Available", .ja: "利用可能",
            .fr: "Disponible", .ru: "Доступно",
        ],
        "%@ 小时窗口": [
            .zh: "%@ 小时窗口", .en: "%@-hour window", .ja: "%@時間ウィンドウ",
            .fr: "Fenêtre %@ h", .ru: "Окно %@ ч",
        ],
        "%d 天窗口": [
            .zh: "%d 天窗口", .en: "%d-day window", .ja: "%d日ウィンドウ",
            .fr: "Fenêtre %d j", .ru: "Окно %d дн.",
        ],
        "5 小时窗口": [
            .zh: "5 小时窗口", .en: "5-hour window", .ja: "5時間ウィンドウ",
            .fr: "Fenêtre 5 h", .ru: "Окно 5 часов",
        ],
        "5h 限额": [
            .zh: "5h 限额", .en: "5h limit", .ja: "5時間上限",
            .fr: "Limite 5 h", .ru: "Лимит 5 ч",
        ],
        "Abacus 响应格式异常": [
            .zh: "Abacus 响应格式异常", .en: "Abacus response is malformed", .ja: "Abacus応答の形式が不正です",
            .fr: "Réponse Abacus mal formée", .ru: "Некорректный ответ Abacus",
        ],
        "Abacus 接口返回失败": [
            .zh: "Abacus 接口返回失败", .en: "Abacus request failed", .ja: "Abacusリクエスト失敗",
            .fr: "Échec de la requête Abacus", .ru: "Ошибка запроса Abacus",
        ],
        "Base - max": [
            .zh: "Base - max", .en: "Base - max", .ja: "Base - max",
            .fr: "Base - max", .ru: "Base - max",
        ],
        "Base（4 小时）": [
            .zh: "Base（4 小时）", .en: "Base (4 hours)", .ja: "Base（4時間）",
            .fr: "Base (4 h)", .ru: "Base (4 часа)",
        ],
        "Billing Period": [
            .zh: "账期", .en: "Billing Period", .ja: "請求期間",
            .fr: "Période de facturation", .ru: "Расчётный период",
        ],
        "Code 7 天": [
            .zh: "Code 7 天", .en: "Code 7-day", .ja: "Code 7日",
            .fr: "Code 7 j", .ru: "Code 7 дней",
        ],
        "Codex credits": [
            .zh: "Codex 积分", .en: "Codex credits", .ja: "Codexクレジット",
            .fr: "Crédits Codex", .ru: "Кредиты Codex",
        ],
        "Codex 代码审查": [
            .zh: "Codex 代码审查", .en: "Codex code review", .ja: "Codex コードレビュー",
            .fr: "Revue de code Codex", .ru: "Ревью кода Codex",
        ],
        "Compute Points": [
            .zh: "计算点数", .en: "Compute Points", .ja: "コンピュートポイント",
            .fr: "Points de calcul", .ru: "Баллы вычислений",
        ],
        "Credits": [
            .zh: "积分", .en: "Credits", .ja: "クレジット",
            .fr: "Crédits", .ru: "Кредиты",
        ],
        "Cursor Models": [
            .zh: "Cursor 模型", .en: "Cursor Models", .ja: "Cursorモデル",
            .fr: "Modèles Cursor", .ru: "Модели Cursor",
        ],
        "DeepSeek code": [
            .zh: "DeepSeek 错误码", .en: "DeepSeek code", .ja: "DeepSeek code",
            .fr: "DeepSeek code", .ru: "DeepSeek code",
        ],
        "Extra usage": [
            .zh: "额外用量", .en: "Extra usage", .ja: "追加使用量",
            .fr: "Usage supplémentaire", .ru: "Дополнительный расход",
        ],
        "Grok Bot": [
            .zh: "Grok 机器人", .en: "Grok Bot", .ja: "Grokボット",
            .fr: "Grok Bot", .ru: "Grok Bot",
        ],
        "HTTP \\(status)": [
            .zh: "HTTP \\(status)", .en: "HTTP \\(status)", .ja: "HTTP \\(status)",
            .fr: "HTTP \\(status)", .ru: "HTTP \\(status)",
        ],
        "Hourly usage": [
            .zh: "每小时用量", .en: "Hourly usage", .ja: "時間あたりの使用量",
            .fr: "Usage horaire", .ru: "Почасовой расход",
        ],
        "Included": [
            .zh: "包含额度", .en: "Included", .ja: "含まれる枠",
            .fr: "Inclus", .ru: "Включено",
        ],
        "LongCat code": [
            .zh: "LongCat 错误码", .en: "LongCat code", .ja: "LongCat code",
            .fr: "LongCat code", .ru: "LongCat code",
        ],
        "LongCat 响应数据异常": [
            .zh: "LongCat 响应数据异常", .en: "LongCat response is invalid", .ja: "LongCat応答が不正です",
            .fr: "Réponse LongCat invalide", .ru: "Некорректный ответ LongCat",
        ],
        "MCP 每月额度": [
            .zh: "MCP 每月额度", .en: "MCP monthly quota", .ja: "MCP 月間枠",
            .fr: "Quota MCP mensuel", .ru: "Месячная квота MCP",
        ],
        "Monthly spend limit": [
            .zh: "月度消费上限", .en: "Monthly spend limit", .ja: "月間支出上限",
            .fr: "Plafond de dépenses mensuel", .ru: "Месячный лимит трат",
        ],
        "Notion AI 额度数据异常": [
            .zh: "Notion AI 额度数据异常", .en: "Notion AI quota data is invalid", .ja: "Notion AI枠データが不正です",
            .fr: "Données de quota Notion AI invalides", .ru: "Некорректная квота Notion AI",
        ],
        "Notion workspace 摘要异常": [
            .zh: "Notion workspace 摘要异常", .en: "Notion workspace summary is invalid", .ja: "Notionワークスペース要約が不正です",
            .fr: "Résumé d'espace Notion invalide", .ru: "Некорректная сводка workspace Notion",
        ],
        "Ollama 用量数据异常": [
            .zh: "Ollama 用量数据异常", .en: "Ollama usage data is invalid", .ja: "Ollama使用量データが不正です",
            .fr: "Données d'usage Ollama invalides", .ru: "Некорректные данные Ollama",
        ],
        "On-demand": [
            .zh: "按需", .en: "On-demand", .ja: "オンデマンド",
            .fr: "À la demande", .ru: "По запросу",
        ],
        "Other Models": [
            .zh: "其他模型", .en: "Other Models", .ja: "その他のモデル",
            .fr: "Autres modèles", .ru: "Другие модели",
        ],
        "Overage": [
            .zh: "超额", .en: "Overage", .ja: "超過分",
            .fr: "Dépassement", .ru: "Сверх лимита",
        ],
        "Requests": [
            .zh: "请求", .en: "Requests", .ja: "リクエスト",
            .fr: "Requêtes", .ru: "Запросы",
        ],
        "Rolling": [
            .zh: "Rolling", .en: "Rolling", .ja: "ローリング",
            .fr: "Glissant", .ru: "Скользящий",
        ],
        "Rolling（%d 分钟）": [
            .zh: "Rolling（%d 分钟）", .en: "Rolling (%d minutes)", .ja: "ローリング（%d分）",
            .fr: "Glissant (%d min)", .ru: "Скользящее (%d мин)",
        ],
        "Rolling（%d 周）": [
            .zh: "Rolling（%d 周）", .en: "Rolling (%d weeks)", .ja: "ローリング（%d週）",
            .fr: "Glissant (%d sem.)", .ru: "Скользящее (%d нед.)",
        ],
        "Rolling（%d 天）": [
            .zh: "Rolling（%d 天）", .en: "Rolling (%d days)", .ja: "ローリング（%d日）",
            .fr: "Glissant (%d j)", .ru: "Скользящее (%d дн.)",
        ],
        "Rolling（%d 小时）": [
            .zh: "Rolling（%d 小时）", .en: "Rolling (%d hours)", .ja: "ローリング（%d時間）",
            .fr: "Glissant (%d h)", .ru: "Скользящее (%d ч)",
        ],
        "Session usage": [
            .zh: "会话用量", .en: "Session usage", .ja: "セッション使用量",
            .fr: "Usage de session", .ru: "Расход сессии",
        ],
        "StepFun API 返回失败": [
            .zh: "StepFun API 返回失败", .en: "StepFun API request failed", .ja: "StepFun APIリクエスト失敗",
            .fr: "Échec de l'API StepFun", .ru: "Ошибка API StepFun",
        ],
        "StepFun 用量数据异常": [
            .zh: "StepFun 用量数据异常", .en: "StepFun usage data is invalid", .ja: "StepFun使用量データが不正です",
            .fr: "Données d'usage StepFun invalides", .ru: "Некорректные данные StepFun",
        ],
        "T3 Chat 主窗口数据异常": [
            .zh: "T3 Chat 主窗口数据异常", .en: "T3 Chat primary window data is invalid", .ja: "T3 Chat主ウィンドウデータが不正です",
            .fr: "Données de fenêtre principale T3 Chat invalides", .ru: "Некорректные данные основного окна T3 Chat",
        ],
        "T3 Chat 遇到 Vercel 风控挑战": [
            .zh: "T3 Chat 遇到 Vercel 风控挑战", .en: "T3 Chat hit a Vercel challenge", .ja: "T3 ChatがVercelチャレンジに当たりました",
            .fr: "T3 Chat a rencontré un défi Vercel", .ru: "T3 Chat столкнулся с проверкой Vercel",
        ],
        "Team on-demand": [
            .zh: "团队按需", .en: "Team on-demand", .ja: "チームオンデマンド",
            .fr: "Équipe à la demande", .ru: "Команда по запросу",
        ],
        "Team pooled": [
            .zh: "团队共享", .en: "Team pooled", .ja: "チーム共有",
            .fr: "Mutualisé équipe", .ru: "Командный пул",
        ],
        "Token 包": [
            .zh: "Token 包", .en: "Token pack", .ja: "トークンパック",
            .fr: "Pack de tokens", .ru: "Пакет токенов",
        ],
        "Token 额度": [
            .zh: "Token 额度", .en: "Token quota", .ja: "トークン枠",
            .fr: "Quota de tokens", .ru: "Квота токенов",
        ],
        "Total": [
            .zh: "总计", .en: "Total", .ja: "合計",
            .fr: "Total", .ru: "Итого",
        ],
        "Usage credits": [
            .zh: "用量积分", .en: "Usage credits", .ja: "使用クレジット",
            .fr: "Crédits d'usage", .ru: "Кредиты использования",
        ],
        "Weekly usage": [
            .zh: "每周用量", .en: "Weekly usage", .ja: "週間使用量",
            .fr: "Usage hebdomadaire", .ru: "Недельный расход",
        ],
        "Zen 余额": [
            .zh: "Zen 余额", .en: "Zen balance", .ja: "Zen 残高",
            .fr: "Solde Zen", .ru: "Баланс Zen",
        ],
        "Zen 月上限": [
            .zh: "Zen 月上限", .en: "Zen monthly cap", .ja: "Zen 月上限",
            .fr: "Plafond mensuel Zen", .ru: "Месячный лимит Zen",
        ],
        "account.delete": [
            .zh: "删除", .en: "Delete", .ja: "削除",
            .fr: "Supprimer", .ru: "Удалить",
        ],
        "account.disable": [
            .zh: "停用", .en: "Disable", .ja: "停止",
            .fr: "Désactiver", .ru: "Отключить",
        ],
        "account.disabled": [
            .zh: "已停用", .en: "Disabled", .ja: "停止中",
            .fr: "Désactivé", .ru: "Отключено",
        ],
        "account.enable": [
            .zh: "启用", .en: "Enable", .ja: "有効化",
            .fr: "Activer", .ru: "Включить",
        ],
        "account.loggedIn": [
            .zh: "已登录", .en: "Signed in", .ja: "ログイン済み",
            .fr: "Connecté", .ru: "Выполнен вход",
        ],
        "account.login": [
            .zh: "登录", .en: "Log in", .ja: "ログイン",
            .fr: "Connexion", .ru: "Войти",
        ],
        "account.rename": [
            .zh: "重命名", .en: "Rename", .ja: "名前を変更",
            .fr: "Renommer", .ru: "Переименовать",
        ],
        "app.title": [
            .zh: "Usage Limits", .en: "Usage Limits", .ja: "Usage Limits",
            .fr: "Usage Limits", .ru: "Usage Limits",
        ],
        "card.allUnused": [
            .zh: "本套餐额度均未使用", .en: "No plan usage yet", .ja: "このプランの使用量はまだありません",
            .fr: "Aucune utilisation pour l'instant", .ru: "Лимиты тарифа ещё не использованы",
        ],
        "card.expandMore": [
            .zh: "展开查看其余 %d 项用量", .en: "Expand to see %d more metrics", .ja: "展開して残り %d 件を表示",
            .fr: "Développer pour voir %d autres mesures", .ru: "Развернуть ещё %d показателей",
        ],
        "card.hideUnused": [
            .zh: "隐藏未使用的指标", .en: "Hide unused metrics", .ja: "未使用の項目を隠す",
            .fr: "Masquer les mesures inutilisées", .ru: "Скрыть неиспользуемые показатели",
        ],
        "card.login": [
            .zh: "登录 %@", .en: "Sign in to %@", .ja: "%@ にログイン",
            .fr: "Se connecter à %@", .ru: "Войти в %@",
        ],
        "card.loginToSee": [
            .zh: "登录 %@ 查看订阅额度", .en: "Sign in to %@ for plan limits", .ja: "%@ にログインしてプラン上限を表示",
            .fr: "Connectez-vous à %@ pour les limites", .ru: "Войдите в %@ для лимитов тарифа",
        ],
        "card.logout": [
            .zh: "退出登录（清除本机 Cookie）", .en: "Sign out (clear local cookies)", .ja: "ログアウト（ローカル Cookie を削除）",
            .fr: "Se déconnecter (effacer les cookies locaux)", .ru: "Выйти (удалить локальные cookie)",
        ],
        "card.noNumeric": [
            .zh: "已登录，但官方未提供数值额度", .en: "Signed in, but no numeric limits provided", .ja: "ログイン済みですが、数値の上限は提供されていません",
            .fr: "Connecté, mais aucune limite chiffrée fournie", .ru: "Вход выполнен, но числовые лимиты не предоставлены",
        ],
        "card.notLoggedIn": [
            .zh: "未登录", .en: "Not signed in", .ja: "未ログイン",
            .fr: "Non connecté", .ru: "Вход не выполнен",
        ],
        "card.refresh": [
            .zh: "刷新用量", .en: "Refresh usage", .ja: "使用状況を更新",
            .fr: "Actualiser", .ru: "Обновить",
        ],
        "card.relogin": [
            .zh: "重新登录", .en: "Sign in again", .ja: "再ログイン",
            .fr: "Se reconnecter", .ru: "Войти заново",
        ],
        "card.reorderMetrics": [
            .zh: "调整额度顺序", .en: "Reorder quotas", .ja: "利用枠の並び替え",
            .fr: "Réorganiser les quotas", .ru: "Порядок квот",
        ],
        "card.retry": [
            .zh: "重试", .en: "Retry", .ja: "再試行",
            .fr: "Réessayer", .ru: "Повторить",
        ],
        "card.share": [
            .zh: "分享用量", .en: "Share usage", .ja: "使用状況を共有",
            .fr: "Partager l'usage", .ru: "Поделиться",
        ],
        "card.showUnused": [
            .zh: "显示 %d 项未使用的指标", .en: "Show %d unused metrics", .ja: "未使用の %d 件を表示",
            .fr: "Afficher %d mesures inutilisées", .ru: "Показать неиспользуемые (%d)",
        ],
        "card.updateToken": [
            .zh: "更新令牌", .en: "Update token", .ja: "トークンを更新",
            .fr: "Mettre à jour le jeton", .ru: "Обновить токен",
        ],
        "card.updatedAt": [
            .zh: "更新于 %@", .en: "Updated at %@", .ja: "%@ 更新",
            .fr: "Mis à jour à %@", .ru: "Обновлено в %@",
        ],
        "common.ok": [
            .zh: "确定", .en: "OK", .ja: "OK",
            .fr: "OK", .ru: "OK",
        ],
        "custom.card.expiresIn": [
            .zh: "%@", .en: "%@", .ja: "%@",
            .fr: "%@", .ru: "%@",
        ],
        "custom.card.moreFields": [
            .zh: "还有 %d 项，展开查看", .en: "%d more, expand to view", .ja: "他 %d 件、展開して表示",
            .fr: "%d de plus, développer", .ru: "Ещё %d, развернуть",
        ],
        "custom.card.usedShare": [
            .zh: "已用占比 %d%%", .en: "Used share %d%%", .ja: "使用割合 %d%%",
            .fr: "Part utilisée %d%%", .ru: "Доля использованного %d%%",
        ],
        "custom.error.notJSON": [
            .zh: "不是 JSON", .en: "Not JSON", .ja: "JSON ではありません",
            .fr: "Pas du JSON", .ru: "Не JSON",
        ],
        "custom.error.requestFailed": [
            .zh: "请求失败", .en: "Request failed", .ja: "リクエスト失敗",
            .fr: "Échec de la requête", .ru: "Ошибка запроса",
        ],
        "custom.error.tooLarge": [
            .zh: "响应过大", .en: "Response too large", .ja: "応答が大きすぎます",
            .fr: "Réponse trop grande", .ru: "Слишком большой ответ",
        ],
        "custom.error.unreadable": [
            .zh: "字段无法读取", .en: "Couldn't read fields", .ja: "フィールドを読めません",
            .fr: "Champs illisibles", .ru: "Не удалось прочитать поля",
        ],
        "custom.logout": [
            .zh: "清除令牌", .en: "Clear token", .ja: "トークンを削除",
            .fr: "Effacer le jeton", .ru: "Удалить токен",
        ],
        "custom.noNumeric": [
            .zh: "已登录，但没有可显示的数字", .en: "Signed in, but no numbers to show", .ja: "ログイン済みですが数字がありません",
            .fr: "Connecté, mais aucun chiffre", .ru: "Вход выполнен, но чисел нет",
        ],
        "custom.preset.crof.field.credits": [
            .zh: "积分", .en: "Credits", .ja: "クレジット",
            .fr: "Crédits", .ru: "Кредиты",
        ],
        "custom.preset.crof.field.requests_plan": [
            .zh: "请求上限", .en: "Request limit", .ja: "リクエスト上限",
            .fr: "Plafond de requêtes", .ru: "Лимит запросов",
        ],
        "custom.preset.crof.field.usable_requests": [
            .zh: "剩余请求", .en: "Requests left", .ja: "残リクエスト",
            .fr: "Requêtes restantes", .ru: "Оставшиеся запросы",
        ],
        "custom.preset.kimi-api-cn.field.data_available_balance": [
            .zh: "可用余额", .en: "Available balance", .ja: "利用可能残高",
            .fr: "Solde disponible", .ru: "Доступный баланс",
        ],
        "custom.preset.kimi-api-cn.field.data_cash_balance": [
            .zh: "现金余额", .en: "Cash balance", .ja: "現金残高",
            .fr: "Solde cash", .ru: "Наличный остаток",
        ],
        "custom.preset.kimi-api-cn.field.data_voucher_balance": [
            .zh: "代金券", .en: "Voucher", .ja: "クーポン",
            .fr: "Bon", .ru: "Ваучер",
        ],
        "custom.preset.kimi-api-cn.name": [
            .zh: "Kimi API 国内", .en: "Kimi API China", .ja: "Kimi API 中国",
            .fr: "Kimi API Chine", .ru: "Kimi API Китай",
        ],
        "custom.preset.kimi-api-intl.field.data_available_balance": [
            .zh: "可用余额", .en: "Available balance", .ja: "利用可能残高",
            .fr: "Solde disponible", .ru: "Доступный остаток",
        ],
        "custom.preset.kimi-api-intl.field.data_cash_balance": [
            .zh: "现金余额", .en: "Cash balance", .ja: "現金残高",
            .fr: "Solde cash", .ru: "Наличный остаток",
        ],
        "custom.preset.kimi-api-intl.field.data_voucher_balance": [
            .zh: "代金券", .en: "Voucher", .ja: "クーポン",
            .fr: "Bon", .ru: "Ваучер",
        ],
        "custom.preset.kimi-api-intl.name": [
            .zh: "Kimi API", .en: "Kimi API", .ja: "Kimi API",
            .fr: "Kimi API", .ru: "Kimi API",
        ],
        "custom.preset.openrouter-key.field.data_limit": [
            .zh: "额度上限", .en: "Limit", .ja: "上限",
            .fr: "Plafond", .ru: "Лимит",
        ],
        "custom.preset.openrouter-key.field.data_limit_remaining": [
            .zh: "剩余额度", .en: "Remaining", .ja: "Restant",
            .fr: "Remaining", .ru: "Remaining",
        ],
        "custom.preset.openrouter-key.field.data_usage": [
            .zh: "已用额度", .en: "Usage", .ja: "使用量",
            .fr: "Usage", .ru: "Расход",
        ],
        "custom.preset.poe.field.current_point_balance": [
            .zh: "积分余额", .en: "Point balance", .ja: "ポイント残高",
            .fr: "Solde de points", .ru: "Баланс баллов",
        ],
        "custom.role.count": [
            .zh: "计数", .en: "Count", .ja: "回数",
            .fr: "Compteur", .ru: "Счётчик",
        ],
        "custom.role.count.default": [
            .zh: "次数", .en: "Count", .ja: "回数",
            .fr: "Nombre", .ru: "Число",
        ],
        "custom.role.limit": [
            .zh: "总额", .en: "Limit", .ja: "上限",
            .fr: "Plafond", .ru: "Лимит",
        ],
        "custom.role.other": [
            .zh: "数值", .en: "Value", .ja: "数値",
            .fr: "Valeur", .ru: "Значение",
        ],
        "custom.role.percent": [
            .zh: "百分比", .en: "Percent", .ja: "割合",
            .fr: "Pourcentage", .ru: "Процент",
        ],
        "custom.role.percent.default": [
            .zh: "百分比", .en: "Percent", .ja: "パーセント",
            .fr: "Pourcentage", .ru: "Процент",
        ],
        "custom.role.remaining": [
            .zh: "余额", .en: "Balance", .ja: "残高",
            .fr: "Solde", .ru: "Остаток",
        ],
        "custom.role.timestamp": [
            .zh: "时间", .en: "Time", .ja: "時刻",
            .fr: "Date", .ru: "Время",
        ],
        "custom.role.timestamp.default": [
            .zh: "到期时间", .en: "Expires", .ja: "期限",
            .fr: "Expiration", .ru: "Срок",
        ],
        "custom.role.used": [
            .zh: "已用", .en: "Used", .ja: "使用済み",
            .fr: "Utilisé", .ru: "Использовано",
        ],
        "custom.template.addAccount": [
            .zh: "从模板添加账号", .en: "Add account from template", .ja: "テンプレートから追加",
            .fr: "Ajouter depuis le modèle", .ru: "Добавить из шаблона",
        ],
        "custom.template.delete": [
            .zh: "删除模板", .en: "Delete template", .ja: "テンプレートを削除",
            .fr: "Supprimer le modèle", .ru: "Удалить шаблон",
        ],
        "custom.template.inUse": [
            .zh: "仍有账号使用此模板，无法删除。", .en: "Accounts still use this template, so it can't be deleted.", .ja: "このテンプレートを使うアカウントがあるため削除できません。",
            .fr: "Des comptes utilisent encore ce modèle ; suppression impossible.", .ru: "Шаблон ещё используется аккаунтами, удалить нельзя.",
        ],
        "custom.template.section": [
            .zh: "自定义模板", .en: "Custom templates", .ja: "カスタム テンプレート",
            .fr: "Modèles perso", .ru: "Свои шаблоны",
        ],
        "custom.token.footer": [
            .zh: "令牌只存在本机独立键，不进快照、不上传。", .en: "The token stays in a separate on-device key. It is not stored in snapshots and is never uploaded.", .ja: "トークンは端末内の別キーにのみ保存され、スナップショットにもアップロードされません。",
            .fr: "Le jeton reste dans une clé locale distincte ; pas dans les instantanés, jamais envoyé.", .ru: "Токен хранится в отдельном локальном ключе, не попадает в снимки и не загружается.",
        ],
        "custom.token.placeholder": [
            .zh: "Bearer 令牌", .en: "Bearer token", .ja: "Bearer トークン",
            .fr: "Jeton Bearer", .ru: "Bearer-токен",
        ],
        "custom.token.save": [
            .zh: "保存令牌", .en: "Save token", .ja: "トークンを保存",
            .fr: "Enregistrer le jeton", .ru: "Сохранить токен",
        ],
        "custom.token.title": [
            .zh: "更新令牌", .en: "Update token", .ja: "トークンを更新",
            .fr: "Mettre à jour le jeton", .ru: "Обновить токен",
        ],
        "custom.wizard.addAccount": [
            .zh: "添加账号", .en: "Add account", .ja: "アカウントを追加",
            .fr: "Ajouter un compte", .ru: "Добавить аккаунт",
        ],
        "custom.wizard.autoPicked": [
            .zh: "已按字段名自动勾选 %d 项，可自行增减", .en: "%d fields auto-selected by name; adjust as needed", .ja: "フィールド名から %d 件を自動選択しました",
            .fr: "%d champs présélectionnés par nom ; ajustez si besoin", .ru: "Автоматически выбрано %d полей по имени",
        ],
        "custom.wizard.balance": [
            .zh: "余额", .en: "Balance", .ja: "残高",
            .fr: "Solde", .ru: "Остаток",
        ],
        "custom.wizard.chooseIcon": [
            .zh: "选择图标", .en: "Choose icon", .ja: "アイコンを選択",
            .fr: "Choisir une icône", .ru: "Выбрать значок",
        ],
        "custom.wizard.clearIcon": [
            .zh: "清除图标", .en: "Clear icon", .ja: "アイコンを消去",
            .fr: "Effacer l'icône", .ru: "Убрать значок",
        ],
        "custom.wizard.displayName": [
            .zh: "展示名", .en: "Label", .ja: "表示名",
            .fr: "Libellé", .ru: "Подпись",
        ],
        "custom.wizard.editTemplate": [
            .zh: "编辑模板", .en: "Edit template", .ja: "テンプレートを編集",
            .fr: "Modifier le modèle", .ru: "Изменить шаблон",
        ],
        "custom.wizard.httpsOnly": [
            .zh: "只接受 https 地址。", .en: "HTTPS URLs only.", .ja: "https のみ。",
            .fr: "URL HTTPS uniquement.", .ru: "Только HTTPS.",
        ],
        "custom.wizard.name": [
            .zh: "显示名称", .en: "Display name", .ja: "表示名",
            .fr: "Nom affiché", .ru: "Отображаемое имя",
        ],
        "custom.wizard.needField": [
            .zh: "请至少勾选一项要展示的字段。", .en: "Select at least one field to display.", .ja: "表示するフィールドを 1 つ以上選んでください。",
            .fr: "Sélectionnez au moins un champ à afficher.", .ru: "Выберите хотя бы одно поле для отображения.",
        ],
        "custom.wizard.pickHint": [
            .zh: "勾选要展示的数字字段，至少一项。", .en: "Pick at least one numeric field to show.", .ja: "表示する数値フィールドを 1 つ以上選んでください。",
            .fr: "Cochez au moins un champ numérique à afficher.", .ru: "Выберите хотя бы одно числовое поле.",
        ],
        "custom.wizard.presetHint": [
            .zh: "网址和字段已按此预设填好。保存前仍须通过一次实时测试。", .en: "URL and fields are prefilled from this preset. You still must pass a live test before saving.", .ja: "URL とフィールドはこのプリセットで入力済み。保存前に実地テストが必要です。",
            .fr: "L'URL et les champs sont préremplis. Un test en direct est encore requis avant d'enregistrer.", .ru: "URL и поля уже из пресета. Перед сохранением нужен живой тест.",
        ],
        "custom.wizard.recommended": [
            .zh: "推荐", .en: "Suggested", .ja: "おすすめ",
            .fr: "Suggéré", .ru: "Рекомендовано",
        ],
        "custom.wizard.replaceIcon": [
            .zh: "替换图标", .en: "Replace icon", .ja: "アイコンを差し替え",
            .fr: "Remplacer l'icône", .ru: "Заменить значок",
        ],
        "custom.wizard.retestRequired": [
            .zh: "改模板须重新测试成功后才能保存。", .en: "Re-test successfully before saving template changes.", .ja: "テンプレート変更は再テスト成功後に保存できます。",
            .fr: "Retestez avec succès avant d'enregistrer le modèle.", .ru: "Перед сохранением шаблона нужна успешная повторная проверка.",
        ],
        "custom.wizard.role": [
            .zh: "字段类型", .en: "Field type", .ja: "フィールド種別",
            .fr: "Type de champ", .ru: "Тип поля",
        ],
        "custom.wizard.rootGroup": [
            .zh: "顶层", .en: "Top level", .ja: "トップレベル",
            .fr: "Racine", .ru: "Корень",
        ],
        "custom.wizard.save": [
            .zh: "保存并添加账号", .en: "Save and add account", .ja: "保存してアカウントを追加",
            .fr: "Enregistrer et ajouter", .ru: "Сохранить и добавить",
        ],
        "custom.wizard.saveHint": [
            .zh: "先勾选至少一项要展示的字段。", .en: "Check at least one field to display.", .ja: "表示するフィールドを 1 つ以上選んでください。",
            .fr: "Cochez au moins un champ à afficher.", .ru: "Отметьте хотя бы одно поле для отображения.",
        ],
        "custom.wizard.saveTemplate": [
            .zh: "保存模板", .en: "Save template", .ja: "テンプレートを保存",
            .fr: "Enregistrer le modèle", .ru: "Сохранить шаблон",
        ],
        "custom.wizard.status": [
            .zh: "HTTP %d · %d 字节", .en: "HTTP %d · %d bytes", .ja: "HTTP %d · %d バイト",
            .fr: "HTTP %d · %d octets", .ru: "HTTP %d · %d байт",
        ],
        "custom.wizard.test": [
            .zh: "测试连接", .en: "Test connection", .ja: "接続をテスト",
            .fr: "Tester la connexion", .ru: "Проверить соединение",
        ],
        "custom.wizard.testing": [
            .zh: "正在请求…", .en: "Requesting…", .ja: "リクエスト中…",
            .fr: "Requête en cours…", .ru: "Запрос…",
        ],
        "custom.wizard.title": [
            .zh: "配置自定义用量", .en: "Set up custom usage", .ja: "カスタム使用量を設定",
            .fr: "Configurer l'usage perso", .ru: "Настройка своего usage",
        ],
        "custom.wizard.token": [
            .zh: "访问令牌", .en: "Access token", .ja: "アクセス トークン",
            .fr: "Jeton d'accès", .ru: "Токен доступа",
        ],
        "custom.wizard.truncated": [
            .zh: "字段过多，已截断显示。", .en: "Too many fields; list truncated.", .ja: "フィールドが多すぎるため一部のみ表示。",
            .fr: "Trop de champs ; liste tronquée.", .ru: "Слишком много полей; список обрезан.",
        ],
        "custom.wizard.url": [
            .zh: "用量接口 URL", .en: "Usage API URL", .ja: "使用量 API の URL",
            .fr: "URL de l'API d'usage", .ru: "URL API usage",
        ],
        "custom.wizard.used": [
            .zh: "已用", .en: "Used", .ja: "使用済み",
            .fr: "Utilisé", .ru: "Использовано",
        ],
        "deepseek.balance": [
            .zh: "重置余额", .en: "Prepaid balance", .ja: "チャージ残高",
            .fr: "Solde prépayé", .ru: "Предоплата",
        ],
        "deepseek.balanceGranted": [
            .zh: "赠送余额", .en: "Granted balance", .ja: "付与残高",
            .fr: "Solde offert", .ru: "Подаренный баланс",
        ],
        "deepseek.balancePaid": [
            .zh: "充值余额", .en: "Paid balance", .ja: "チャージ残高",
            .fr: "Solde payant", .ru: "Оплаченный баланс",
        ],
        "deepseek.byKey": [
            .zh: "按 API Key", .en: "By API Key", .ja: "API キー別",
            .fr: "Par clé API", .ru: "По API-ключу",
        ],
        "deepseek.cost": [
            .zh: "消费金额", .en: "Cost", .ja: "金額",
            .fr: "Coût", .ru: "Расход",
        ],
        "deepseek.expandHint": [
            .zh: "展开查看时间维度与 API Key", .en: "Expand for time range and API keys", .ja: "展開して期間と API キーを表示",
            .fr: "Développer pour périodes et clés API", .ru: "Развернуть период и API-ключи",
        ],
        "deepseek.reqCount": [
            .zh: "%d 次", .en: "%d req", .ja: "%d 回",
            .fr: "%d req", .ru: "%d запр.",
        ],
        "deepseek.requests": [
            .zh: "API 请求次数", .en: "API requests", .ja: "API リクエスト",
            .fr: "Requêtes API", .ru: "Запросы API",
        ],
        "deepseek.spent": [
            .zh: "累计消费金额", .en: "Total spent", .ja: "累計消費",
            .fr: "Dépensé au total", .ru: "Всего потрачено",
        ],
        "deepseek.tokens": [
            .zh: "Tokens", .en: "Tokens", .ja: "トークン",
            .fr: "Jetons", .ru: "Токены",
        ],
        "demo.banner": [
            .zh: "演示模式已开启，以下为示例数据", .en: "Demo mode is on — sample data below", .ja: "デモモード有効。以下はサンプルデータです",
            .fr: "Mode démo activé — données d'exemple ci-dessous", .ru: "Демо-режим включён — ниже примерные данные",
        ],
        "diagnostics.clear": [
            .zh: "清空", .en: "Clear", .ja: "消去",
            .fr: "Effacer", .ru: "Очистить",
        ],
        "diagnostics.copied": [
            .zh: "已复制", .en: "Copied", .ja: "コピーしました",
            .fr: "Copié", .ru: "Скопировано",
        ],
        "diagnostics.copy": [
            .zh: "复制", .en: "Copy", .ja: "コピー",
            .fr: "Copier", .ru: "Копировать",
        ],
        "diagnostics.empty": [
            .zh: "暂无诊断记录", .en: "No diagnostic records", .ja: "診断記録はありません",
            .fr: "Aucun journal de diagnostic", .ru: "Нет записей диагностики",
        ],
        "diagnostics.emptyHint": [
            .zh: "刷新后，每个探针的状态、脱敏预览和解析摘要会出现在这里。", .en: "After a refresh, each probe's status, redacted preview, and parse summary show up here.", .ja: "更新後、各プローブの状態・伏せ字プレビュー・解析要約がここに出ます。",
            .fr: "Après un rafraîchissement, le statut, l'aperçu masqué et l'analyse de chaque sonde apparaissent ici.", .ru: "После обновления здесь появятся статус, редактированный просмотр и сводка разбора.",
        ],
        "diagnostics.shareSubject": [
            .zh: "Usage Limits 诊断", .en: "Usage Limits diagnostics", .ja: "Usage Limits 診断",
            .fr: "Diagnostics Usage Limits", .ru: "Диагностика Usage Limits",
        ],
        "disabled.all.hint": [
            .zh: "到右上角设置 → 服务商 → 新增供应商，添加需要关注的账号。", .en: "Go to Settings → Providers → Add provider (top right) to add accounts.", .ja: "右上の設定 → プロバイダ → プロバイダを追加からアカウントを追加してください。",
            .fr: "Réglages → Fournisseurs → Ajouter un fournisseur (en haut à droite).", .ru: "Настройки → Провайдеры → Добавить провайдера (вверху справа).",
        ],
        "disabled.all.title": [
            .zh: "还没有添加供应商", .en: "No providers added yet", .ja: "プロバイダが未追加です",
            .fr: "Aucun fournisseur ajouté", .ru: "Провайдеры ещё не добавлены",
        ],
        "feedback.cancel": [
            .zh: "取消", .en: "Cancel", .ja: "キャンセル",
            .fr: "Annuler", .ru: "Отмена",
        ],
        "feedback.logs.disclosure": [
            .zh: "日志会脱敏，但可能包含账号或模板名称及用量信息。", .en: "Logs are redacted, but may include account or template names and usage details.", .ja: "ログは伏せ字処理されますが、アカウント名・テンプレート名・使用量情報が含まれる場合があります。",
            .fr: "Les journaux sont expurgés, mais peuvent contenir des noms de comptes ou de modèles et des données d’utilisation.", .ru: "Журнал маскируется, но может содержать названия аккаунтов или шаблонов и сведения об использовании.",
        ],
        "feedback.logs.exclude": [
            .zh: "不携带日志", .en: "Without logs", .ja: "ログなし",
            .fr: "Sans journaux", .ru: "Без журнала",
        ],
        "feedback.logs.include": [
            .zh: "携带日志", .en: "Include logs", .ja: "ログを添付",
            .fr: "Joindre les journaux", .ru: "Прикрепить журнал",
        ],
        "feedback.logs.prompt": [
            .zh: "是否携带诊断日志？", .en: "Include diagnostic logs?", .ja: "診断ログを添付しますか？",
            .fr: "Joindre les journaux de diagnostic ?", .ru: "Прикрепить журнал диагностики?",
        ],
        "feedback.mail.failed.message": [
            .zh: "邮件编辑器发生错误，请稍后重试。", .en: "The mail composer encountered an error. Try again later.", .ja: "メール作成中にエラーが発生しました。後でもう一度お試しください。",
            .fr: "L’éditeur de courrier a rencontré une erreur. Réessayez plus tard.", .ru: "В редакторе письма произошла ошибка. Повторите попытку позже.",
        ],
        "feedback.mail.failed.title": [
            .zh: "邮件编辑失败", .en: "Couldn't prepare email", .ja: "メールを準備できませんでした",
            .fr: "Impossible de préparer l’e-mail", .ru: "Не удалось подготовить письмо",
        ],
        "feedback.mail.unavailable.message": [
            .zh: "请先在系统“邮件”App 中配置邮箱账号，然后再试。", .en: "Set up an email account in Apple Mail, then try again.", .ja: "Appleの「メール」でアカウントを設定してから、もう一度お試しください。",
            .fr: "Configurez un compte dans Mail d’Apple, puis réessayez.", .ru: "Настройте учётную запись в Apple Mail и повторите попытку.",
        ],
        "feedback.mail.unavailable.title": [
            .zh: "无法发送邮件", .en: "Mail unavailable", .ja: "メールを送信できません",
            .fr: "E-mail indisponible", .ru: "Почта недоступна",
        ],
        "feedback.mail.subject": [
            .zh: "Usage Limits 反馈：[请填一句概述]",
            .en: "Usage Limits feedback: [Add a short summary]",
            .ja: "Usage Limits フィードバック：[概要を一言]",
            .fr: "Commentaires Usage Limits : [Ajoutez un bref résumé]",
            .ru: "Отзыв об Usage Limits: [Добавьте краткое описание]",
        ],
        "feedback.mail.body": [
            .zh: "来源：Usage Limits\n\n请在下方描述你的反馈：\n\n",
            .en: "Source: Usage Limits\n\nPlease describe your feedback below:\n\n",
            .ja: "送信元：Usage Limits\n\n以下にフィードバックをご記入ください：\n\n",
            .fr: "Source : Usage Limits\n\nDécrivez vos commentaires ci-dessous :\n\n",
            .ru: "Источник: Usage Limits\n\nОпишите ваш отзыв ниже:\n\n",
        ],
        "jimeng.creditsUnavailable": [
            .zh: "积分暂未获取到", .en: "Credits not available yet", .ja: "ポイントを取得できませんでした",
            .fr: "Crédits pas encore disponibles", .ru: "Баллы пока не получены",
        ],
        "jimeng.creditsUnavailableHint": [
            .zh: "系统繁忙，下拉重试", .en: "System busy. Pull to retry.", .ja: "混み合っています。引き下げて再試行",
            .fr: "Système occupé. Tirez pour réessayer.", .ru: "Система занята. Потяните, чтобы повторить.",
        ],
        "jimeng.expandHint": [
            .zh: "展开查看近1个月明细", .en: "Expand for last-month ledger", .ja: "展開して1か月明細を表示",
            .fr: "Développer pour le détail du mois", .ru: "Развернуть журнал за месяц",
        ],
        "jimeng.historyCaption": [
            .zh: "仅展示近1个月，更新可能有延迟", .en: "Last 30 days only; updates may lag", .ja: "直近1か月のみ。反映に遅れが出ることがあります",
            .fr: "30 derniers jours seulement ; mise à jour éventuellement différée", .ru: "Только последние 30 дней; обновление может запаздывать",
        ],
        "jimeng.historyTitle": [
            .zh: "近1个月明细", .en: "Last 30 days", .ja: "直近1か月の明細",
            .fr: "30 derniers jours", .ru: "За последние 30 дней",
        ],
        "login.alreadySignedIn": [
            .zh: "已经登录", .en: "Already signed in", .ja: "すでにログイン済み",
            .fr: "Déjà connecté", .ru: "Уже выполнен вход",
        ],
        "login.banner": [
            .zh: "在官方页面登录，完成后自动返回；凭据仅存本机。通行密钥在此不可用，请用密码、邮箱验证码或 Google / Apple 登录。", .en: "Sign in on the official page — you'll return automatically. Credentials stay on this device. Passkeys don't work here; use a password, email code, or Google / Apple.", .ja: "公式ページでログインすると自動的に戻ります。資格情報は本体のみに保存。パスキーは使えないため、パスワード、メールコード、または Google / Apple をご利用ください。",
            .fr: "Connectez-vous sur la page officielle — retour automatique. Les identifiants restent sur l'appareil. Les passkeys ne fonctionnent pas ici ; utilisez un mot de passe, un code e-mail, ou Google / Apple.", .ru: "Войдите на официальной странице — возврат произойдёт автоматически. Данные остаются на устройстве. Passkey здесь не работают — используйте пароль, код из письма или Google / Apple.",
        ],
        "login.check": [
            .zh: "检测登录", .en: "Check login", .ja: "ログイン確認",
            .fr: "Vérifier", .ru: "Проверить",
        ],
        "login.checking": [
            .zh: "正在检测登录状态…", .en: "Checking login status…", .ja: "ログイン状態を確認中…",
            .fr: "Vérification de la connexion…", .ru: "Проверяем состояние входа…",
        ],
        "login.close": [
            .zh: "关闭", .en: "Close", .ja: "閉じる",
            .fr: "Fermer", .ru: "Закрыть",
        ],
        "login.confirm.no": [
            .zh: "否", .en: "No", .ja: "いいえ",
            .fr: "Non", .ru: "Нет",
        ],
        "login.confirm.yes": [
            .zh: "是", .en: "Yes", .ja: "はい",
            .fr: "Oui", .ru: "Да",
        ],
        "login.confirmUse": [
            .zh: "是否登录", .en: "Use this session?", .ja: "このログインを使いますか",
            .fr: "Utiliser cette session ?", .ru: "Войти с этим аккаунтом?",
        ],
        "login.detected": [
            .zh: "已检测到登录，正在获取用量…", .en: "Signed in — fetching usage…", .ja: "ログインを検出、使用状況を取得中…",
            .fr: "Connecté — récupération en cours…", .ru: "Вход обнаружен — получаем данные…",
        ],
        "login.signedInAccount": [
            .zh: "登录账号：%@", .en: "Signed-in account: %@", .ja: "ログインアカウント：%@",
            .fr: "Compte connecté : %@", .ru: "Аккаунт входа: %@",
        ],
        "metric.expirePrefix": [
            .zh: "到期：", .en: "Expires: ", .ja: "期限：",
            .fr: "Expire : ", .ru: "Истекает: ",
        ],
        "metric.remaining": [
            .zh: "剩 %d/%d", .en: "%d/%d left", .ja: "残り %d/%d",
            .fr: "%d/%d restants", .ru: "Осталось %d/%d",
        ],
        "metric.resetPrefix": [
            .zh: "重置：", .en: "Resets: ", .ja: "リセット：",
            .fr: "Réinit. : ", .ru: "Сброс: ",
        ],
        "metric.valid": [
            .zh: "有效", .en: "Active", .ja: "有効",
            .fr: "Actif", .ru: "Активна",
        ],
        "metric.weeklyService": [
            .zh: "%@（周）", .en: "%@ (week)", .ja: "%@（週）",
            .fr: "%@ (sem.)", .ru: "%@ (нед.)",
        ],
        "metricOrder.footer": [
            .zh: "长按拖动调整顺序。折叠卡片与 2×2 显示第 1 条，桌面 2×4/4×4 显示前 2 条；首页长按额度也可打开此编辑。接口新增的计量排在最后。", .en: "Press and drag to reorder. Collapsed cards and the 2×2 widget show the first quota; 2×4/4×4 show the first two. Long-press a quota on the home screen to open this editor. Newly added quotas go last.", .ja: "長押ししてドラッグで並び替え。折りたたみカードと 2×2 は1番目、2×4/4×4 は先頭2件。ホーム画面で利用枠を長押ししても開けます。新しい利用枠は末尾に追加されます。",
            .fr: "Appuyez longuement et faites glisser. Les cartes repliées et le widget 2×2 montrent le 1er quota ; 2×4/4×4 les deux premiers. Un appui long sur un quota ouvre cet éditeur. Les nouveaux quotas vont à la fin.", .ru: "Удерживайте и перетаскивайте. Свёрнутые карточки и виджет 2×2 показывают 1-ю квоту; 2×4/4×4 — первые две. Долгое нажатие на квоту на главном экране открывает этот редактор. Новые квоты добавляются в конец.",
        ],
        "metricOrder.reset": [
            .zh: "恢复默认顺序", .en: "Reset to default", .ja: "デフォルトに戻す",
            .fr: "Rétablir l'ordre par défaut", .ru: "Сбросить порядок",
        ],
        "metricOrder.title": [
            .zh: "额度顺序", .en: "Quota order", .ja: "利用枠の順序",
            .fr: "Ordre des quotas", .ru: "Порядок квот",
        ],
        "notify.expiry.body": [
            .zh: "%@ 将于 %d 天后到期/续费", .en: "%@ expires/renews in %d days", .ja: "%@ は %d 日後に期限/更新となります",
            .fr: "%@ expire/se renouvelle dans %d jours", .ru: "%@ истекает/продлевается через %d дн",
        ],
        "notify.expiry.days": [
            .zh: "提前 %d 天", .en: "%d days before", .ja: "%d 日前",
            .fr: "%d jours avant", .ru: "за %d дн",
        ],
        "notify.expiry.footer": [
            .zh: "仅对能获取到期/续费时间的服务商生效。", .en: "Only applies to providers that expose an expiry/renewal date.", .ja: "期限/更新日を取得できるプロバイダのみ対象です。",
            .fr: "S'applique uniquement aux fournisseurs exposant une date d'expiration.", .ru: "Работает только для провайдеров с датой окончания/продления.",
        ],
        "notify.expiry.header": [
            .zh: "套餐到期", .en: "Plan expiry", .ja: "プラン期限",
            .fr: "Expiration du forfait", .ru: "Окончание тарифа",
        ],
        "notify.expiry.title": [
            .zh: "%@ 套餐即将到期", .en: "%@ plan expiring soon", .ja: "%@ プランがまもなく期限",
            .fr: "Forfait %@ bientôt expiré", .ru: "%@: тариф скоро закончится",
        ],
        "notify.expiry.toggle": [
            .zh: "套餐到期提醒", .en: "Plan expiry reminder", .ja: "プラン期限リマインダー",
            .fr: "Rappel d'expiration du forfait", .ru: "Напоминание об окончании тарифа",
        ],
        "notify.general.footer": [
            .zh: "提醒为本机通知，需允许通知权限；iPhone 锁屏时会自动转发到已配对的 Apple Watch。阈值与回满检测依赖 App 刷新拿到新数据（前台自动刷新或系统安排的后台刷新）。", .en: "Alerts are local notifications and need permission; when iPhone is locked they forward to a paired Apple Watch automatically. Threshold and reset detection rely on refreshes (foreground auto-refresh or system-scheduled background refresh).", .ja: "通知はローカル通知で、許可が必要です。iPhone ロック中はペアリング済み Apple Watch に自動転送されます。しきい値と回復検出は更新（フォアグラウンド自動更新またはシステムのバックグラウンド更新）に依存します。",
            .fr: "Les alertes sont des notifications locales (autorisation requise) ; iPhone verrouillé, elles sont transférées vers l'Apple Watch jumelée. La détection dépend des actualisations.", .ru: "Оповещения — локальные уведомления, нужно разрешение; при заблокированном iPhone они пересылаются на Apple Watch. Обнаружение зависит от обновлений данных.",
        ],
        "notify.prepaid.amount": [
            .zh: "告警金额", .en: "Alert amount", .ja: "アラート金額",
            .fr: "Montant d'alerte", .ru: "Сумма оповещения",
        ],
        "notify.prepaid.body": [
            .zh: "%@ 剩余 %@（告警线 %@）", .en: "%@ is %@ (alert at %@)", .ja: "%@ は %@（しきい値 %@）",
            .fr: "%@ est %@ (seuil %@)", .ru: "%@ — %@ (порог %@)",
        ],
        "notify.prepaid.footer": [
            .zh: "DeepSeek 与自定义账号：重置/预充值余额降到该金额及以下时提醒；充值回到阈值之上后再跌破才会再次提醒。自定义只走统一档，无百分比、到期或重置提醒；按供应商配置时自定义不发。", .en: "DeepSeek and custom accounts: alerts when prepaid balance falls to or through this amount; rearms after you top up above it. Custom accounts use the unified prepaid tier only — no percent, expiry, or reset alerts — and stay silent when scope is per-provider.", .ja: "DeepSeek とカスタムアカウント：チャージ残高がこの金額以下になったら通知。再チャージ後に再び下回ると再通知。カスタムは統一設定のみ（パーセント/期限/リセットなし）。プロバイダ別のときは送りません。",
            .fr: "DeepSeek et comptes perso : alerte quand le solde passe à ce montant ou en dessous ; se réarme après une recharge. Les comptes perso n'utilisent que le palier unifié (pas de % / échéance / reset) et restent muets en mode par fournisseur.", .ru: "DeepSeek и свои аккаунты: оповещает, когда баланс падает до этой суммы или ниже; снова после пополнения. Свои аккаунты только на общем пороге, без процентов/срока/сброса; в режиме по провайдеру не срабатывают.",
        ],
        "notify.prepaid.header": [
            .zh: "预充值金额", .en: "Prepaid balance", .ja: "チャージ残高",
            .fr: "Solde prépayé", .ru: "Предоплата",
        ],
        "notify.prepaid.title": [
            .zh: "%@ 余额告警", .en: "%@ balance alert", .ja: "%@ 残高アラート",
            .fr: "Alerte de solde %@", .ru: "%@: баланс",
        ],
        "notify.prepaid.toggle": [
            .zh: "预充值金额告警", .en: "Prepaid balance alert", .ja: "チャージ残高アラート",
            .fr: "Alerte de solde prépayé", .ru: "Оповещение о предоплате",
        ],
        "notify.provider": [
            .zh: "服务商", .en: "Provider", .ja: "プロバイダ",
            .fr: "Fournisseur", .ru: "Провайдер",
        ],
        "notify.reset.body.detected": [
            .zh: "%@ 可用额度已回满 100%%", .en: "%@ is back to 100%% available", .ja: "%@ の残量が 100%% に回復しました",
            .fr: "%@ est revenu à 100 %% disponible", .ru: "%@ снова доступно на 100%%",
        ],
        "notify.reset.body.scheduled": [
            .zh: "%@ 已到重置时间，可用额度应已回满", .en: "%@ reached its reset time — quota should be full again", .ja: "%@ はリセット時刻になりました。残量は回復しているはずです",
            .fr: "%@ a atteint son heure de réinitialisation — quota rechargé", .ru: "%@ достигло времени сброса — квота должна восстановиться",
        ],
        "notify.reset.footer": [
            .zh: "已知重置时间到点提醒；刷新时发现额度提前回满（供应商主动重置）也会提醒。", .en: "Fires at the known reset time; also when a refresh finds the quota back to full early (provider-initiated reset).", .ja: "既知のリセット時刻に通知。更新時に早期回復（プロバイダ側リセット）を検出した場合も通知します。",
            .fr: "Se déclenche à l'heure de réinitialisation connue, ou si le quota revient à 100 % plus tôt.", .ru: "Срабатывает в известное время сброса, а также при досрочном восстановлении квоты.",
        ],
        "notify.reset.header": [
            .zh: "额度重置", .en: "Quota reset", .ja: "上限リセット",
            .fr: "Réinitialisation du quota", .ru: "Сброс квоты",
        ],
        "notify.reset.title": [
            .zh: "%@ 额度已重置", .en: "%@ quota reset", .ja: "%@ 上限リセット",
            .fr: "Quota %@ réinitialisé", .ru: "%@: квота сброшена",
        ],
        "notify.reset.toggle": [
            .zh: "额度重置提醒", .en: "Quota reset alert", .ja: "上限リセット通知",
            .fr: "Alerte de réinitialisation du quota", .ru: "Оповещение о сбросе квоты",
        ],
        "notify.scope.perProvider": [
            .zh: "按供应商", .en: "Per provider", .ja: "プロバイダ別",
            .fr: "Par fournisseur", .ru: "По провайдеру",
        ],
        "notify.scope.unified": [
            .zh: "统一配置", .en: "Same for all", .ja: "一括設定",
            .fr: "Commun", .ru: "Общие",
        ],
        "notify.threshold.body": [
            .zh: "%@ 已用 %d%%（阈值 %d%%）", .en: "%@ is at %d%% (threshold %d%%)", .ja: "%@ は %d%% 使用（しきい値 %d%%）",
            .fr: "%@ est à %d %% (seuil %d %%)", .ru: "%@ — %d%% (порог %d%%)",
        ],
        "notify.threshold.footer": [
            .zh: "任一限额窗口的已用百分比达到阈值时提醒；每个窗口周期只提醒一次。", .en: "Alerts when any limit window reaches the threshold; once per window cycle.", .ja: "いずれかの上限ウィンドウがしきい値に達したら通知します（各サイクル 1 回）。",
            .fr: "Alerte quand une fenêtre de limite atteint le seuil ; une fois par cycle.", .ru: "Оповещает, когда любое окно лимита достигает порога; один раз за цикл.",
        ],
        "notify.threshold.header": [
            .zh: "额度阈值", .en: "Usage threshold", .ja: "使用量しきい値",
            .fr: "Seuil d'usage", .ru: "Порог расхода",
        ],
        "notify.threshold.percent": [
            .zh: "触发阈值", .en: "Threshold", .ja: "しきい値",
            .fr: "Seuil", .ru: "Порог",
        ],
        "notify.threshold.title": [
            .zh: "%@ 额度提醒", .en: "%@ usage alert", .ja: "%@ 使用量通知",
            .fr: "Alerte d'usage %@", .ru: "%@: расход лимита",
        ],
        "notify.threshold.toggle": [
            .zh: "额度阈值提醒", .en: "Usage threshold alert", .ja: "使用量しきい値通知",
            .fr: "Alerte de seuil d'usage", .ru: "Оповещение о пороге",
        ],
        "prepaid_credits": [
            .zh: "prepaid_credits", .en: "prepaid_credits", .ja: "prepaid_credits",
            .fr: "prepaid_credits", .ru: "prepaid_credits",
        ],
        "preview.large44": [
            .zh: "4×4 总览（systemLarge）", .en: "4×4 overview (systemLarge)", .ja: "4×4 概要（systemLarge）",
            .fr: "4×4 vue d'ensemble (systemLarge)", .ru: "4×4 обзор (systemLarge)",
        ],
        "preview.simulated": [
            .zh: "尚未添加供应商，以下为 Claude / ChatGPT / Grok 的模拟预览；添加供应商后将显示真实数据。", .en: "No providers added yet — this is a simulated preview of Claude / ChatGPT / Grok. Real data appears once you add a provider.", .ja: "プロバイダ未追加のため Claude / ChatGPT / Grok のシミュレーション表示です。追加すると実データになります。",
            .fr: "Aucun fournisseur ajouté — aperçu simulé de Claude / ChatGPT / Grok. Les vraies données apparaîtront après ajout.", .ru: "Провайдеры не добавлены — это имитация для Claude / ChatGPT / Grok. Реальные данные появятся после добавления.",
        ],
        "preview.noData": [
            .zh: "尚无数据：先登录任一服务商，或在设置中开启演示模式。", .en: "No data yet — sign in to a provider or turn on demo mode in Settings.", .ja: "データがありません。いずれかにログインするか、設定でデモモードをオンにしてください。",
            .fr: "Pas encore de données — connectez-vous ou activez le mode démo.", .ru: "Пока нет данных — войдите или включите демо-режим.",
        ],
        "preview.pickProviders": [
            .zh: "显示的账号", .en: "Accounts to show", .ja: "表示するアカウント",
            .fr: "Comptes affichés", .ru: "Аккаунты",
        ],
        "preview.single24": [
            .zh: "2×4", .en: "2×4", .ja: "2×4",
            .fr: "2×4", .ru: "2×4",
        ],
        "preview.small22": [
            .zh: "2×2（系统小）", .en: "2×2 (systemSmall)", .ja: "2×2（systemSmall）",
            .fr: "2×2 (systemSmall)", .ru: "2×2 (systemSmall)",
        ],
        "privacy.footer": [
            .zh: "登录凭据仅保存在本机系统 WebKit 存储中，App 只向各官方站点发起请求，不上传任何数据。自定义 token 本机另键、不上传。", .en: "Credentials stay in this device's WebKit storage. The app only talks to official sites and uploads nothing. Custom tokens stay in a separate on-device key and are never uploaded.", .ja: "ログイン資格情報は本体の WebKit ストレージにのみ保存されます。アプリは公式サイトにのみアクセスし、データを一切アップロードしません。カスタム token は端末内の別キーにのみ保存し、アップロードしません。",
            .fr: "Les identifiants restent dans le stockage WebKit de l'appareil. L'app ne contacte que les sites officiels et n'envoie rien. Les jetons personnalisés restent dans une clé locale distincte et ne sont jamais envoyés.", .ru: "Учётные данные хранятся только в WebKit-хранилище устройства. Приложение обращается только к официальным сайтам и ничего не передаёт. Свои токены лежат в отдельном локальном ключе и не загружаются.",
        ],
        "provider.name.jimeng": [
            .zh: "即梦", .en: "Jimeng", .ja: "即夢",
            .fr: "Jimeng", .ru: "Jimeng",
        ],
        "provider.name.minimax_global": [
            .zh: "MiniMax 国际", .en: "MiniMax International", .ja: "MiniMax International",
            .fr: "MiniMax International", .ru: "MiniMax International",
        ],
        "provider.name.zhipu": [
            .zh: "智谱", .en: "Zhipu", .ja: "智譜",
            .fr: "Zhipu", .ru: "Zhipu",
        ],
        "provider.vendor.jimeng": [
            .zh: "剪映 / 字节", .en: "CapCut / ByteDance", .ja: "CapCut / ByteDance",
            .fr: "CapCut / ByteDance", .ru: "CapCut / ByteDance",
        ],
        "provider.vendor.longcat": [
            .zh: "美团", .en: "Meituan", .ja: "美団",
            .fr: "Meituan", .ru: "Meituan",
        ],
        "provider.vendor.mimo": [
            .zh: "小米", .en: "Xiaomi", .ja: "Xiaomi",
            .fr: "Xiaomi", .ru: "Xiaomi",
        ],
        "provider.vendor.opencode": [
            .zh: "OpenCode", .en: "OpenCode", .ja: "OpenCode",
            .fr: "OpenCode", .ru: "OpenCode",
        ],
        "provider.vendor.qoder": [
            .zh: "阿里 Qoder", .en: "Alibaba Qoder", .ja: "アリババ Qoder",
            .fr: "Alibaba Qoder", .ru: "Alibaba Qoder",
        ],
        "provider.vendor.stepfun": [
            .zh: "阶跃星辰", .en: "StepFun", .ja: "StepFun",
            .fr: "StepFun", .ru: "StepFun",
        ],
        "provider.vendor.zhipu": [
            .zh: "智谱", .en: "Zhipu", .ja: "智譜",
            .fr: "Zhipu", .ru: "Zhipu",
        ],
        "providers.accounts": [
            .zh: "已添加账号", .en: "Added accounts", .ja: "追加済みアカウント",
            .fr: "Comptes ajoutés", .ru: "Добавленные аккаунты",
        ],
        "providers.add": [
            .zh: "新增供应商", .en: "Add provider", .ja: "プロバイダを追加",
            .fr: "Ajouter un fournisseur", .ru: "Добавить провайдера",
        ],
        "providers.addAndLogin": [
            .zh: "添加并登录", .en: "Add & log in", .ja: "追加してログイン",
            .fr: "Ajouter et se connecter", .ru: "Добавить и войти",
        ],
        "providers.choose": [
            .zh: "选择供应商", .en: "Choose a provider", .ja: "プロバイダを選択",
            .fr: "Choisir un fournisseur", .ru: "Выберите провайдера",
        ],
        "providers.choose.tintHint": [
            .zh: "点右侧色环，可改该供应商的默认颜色。", .en: "Tap the color ring to change that provider's default color.", .ja: "右のカラーリングをタップすると、そのプロバイダの既定カラーを変更できます。",
            .fr: "Touchez l'anneau de couleur pour changer la couleur par défaut.", .ru: "Нажмите цветовое кольцо справа, чтобы сменить цвет провайдера.",
        ],
        "providers.custom": [
            .zh: "自定义", .en: "Custom", .ja: "カスタム",
            .fr: "Personnalisé", .ru: "Свой",
        ],
        "providers.custom.footer": [
            .zh: "用 HTTPS GET + Bearer 对接自己的用量接口。", .en: "Connect your own usage API with HTTPS GET + Bearer.", .ja: "HTTPS GET + Bearer で独自の使用量 API に接続します。",
            .fr: "Branchez votre API d'usage en HTTPS GET + Bearer.", .ru: "Подключите свой usage API через HTTPS GET + Bearer.",
        ],
        "providers.clearName": [
            .zh: "清除名称", .en: "Clear name", .ja: "名前を消去",
            .fr: "Effacer le nom", .ru: "Очистить имя",
        ],
        "providers.customName": [
            .zh: "自定义名称", .en: "Custom name", .ja: "カスタム名",
            .fr: "Nom personnalisé", .ru: "Своё название",
        ],
        "providers.empty": [
            .zh: "还没有添加账号，点击下方「新增供应商」开始。", .en: "No accounts yet. Tap \"Add provider\" below to start.", .ja: "アカウントがまだありません。下の「プロバイダを追加」から始めてください。",
            .fr: "Aucun compte. Touchez « Ajouter un fournisseur » ci-dessous.", .ru: "Аккаунтов пока нет. Нажмите «Добавить провайдера» ниже.",
        ],
        "providers.preset.experimental": [
            .zh: "实验性", .en: "Experimental", .ja: "実験的",
            .fr: "Expérimental", .ru: "Экспериментально",
        ],
        "providers.reorder": [
            .zh: "排序", .en: "Reorder", .ja: "並び替え",
            .fr: "Réorganiser", .ru: "Сортировка",
        ],
        "providers.reorderDone": [
            .zh: "完成", .en: "Done", .ja: "完了",
            .fr: "OK", .ru: "Готово",
        ],
        "providers.resetTints": [
            .zh: "重置所有自定义颜色", .en: "Reset all custom colors", .ja: "カスタムカラーを全てリセット",
            .fr: "Réinitialiser toutes les couleurs", .ru: "Сбросить все свои цвета",
        ],
        "providers.resetTints.confirm": [
            .zh: "将清除所有账号与供应商的自定义颜色，恢复内置品牌色。", .en: "Removes all custom colors for accounts and providers, restoring built-in brand colors.", .ja: "全アカウントとプロバイダのカスタムカラーを消去し、内蔵ブランドカラーに戻します。",
            .fr: "Supprime toutes les couleurs personnalisées et rétablit les couleurs intégrées.", .ru: "Удаляет все свои цвета аккаунтов и провайдеров, возвращая встроенные.",
        ],
        "providers.startSetup": [
            .zh: "开始配置", .en: "Start setup", .ja: "設定を開始",
            .fr: "Commencer", .ru: "Настроить",
        ],
        "settings.addWidget.footer": [
            .zh: "在桌面长按空白处 → 左上角「+」→ 搜索「Usage Limits」即可添加小组件。", .en: "To add a widget: long-press the Home Screen → “+” → search “Usage Limits”.", .ja: "ホーム画面を長押し → 左上の「+」→「Usage Limits」を検索してウィジェットを追加。",
            .fr: "Pour ajouter un widget : appui long sur l'écran d'accueil → « + » → cherchez « Usage Limits ».", .ru: "Чтобы добавить виджет: долгое нажатие на главном экране → «+» → найдите «Usage Limits».",
        ],
        "settings.autoRefresh": [
            .zh: "自动刷新", .en: "Auto refresh", .ja: "自動更新",
            .fr: "Actualisation auto", .ru: "Автообновление",
        ],
        "settings.autoRefresh.footer": [
            .zh: "仅在 App 打开期间刷新，最长 60 分钟。", .en: "Refreshes only while the app is open, up to 60 minutes.", .ja: "アプリ起動中のみ更新。最長 60 分。",
            .fr: "Uniquement lorsque l'app est ouverte, 60 minutes max.", .ru: "Только при открытом приложении, не дольше 60 минут.",
        ],
        "settings.autoRefresh.off": [
            .zh: "不自动刷新", .en: "Off", .ja: "オフ",
            .fr: "Désactivée", .ru: "Выключено",
        ],
        "settings.autoRefresh.unit": [
            .zh: "分钟", .en: "min", .ja: "分",
            .fr: "min", .ru: "мин",
        ],
        "settings.autoRefresh.unitSeconds": [
            .zh: "秒", .en: "sec", .ja: "秒",
            .fr: "s", .ru: "с",
        ],
        "settings.demo": [
            .zh: "演示模式", .en: "Demo mode", .ja: "デモモード",
            .fr: "Mode démo", .ru: "Демо-режим",
        ],
        "settings.demo.footer": [
            .zh: "用示例数据预览，不影响真实数据。", .en: "Preview with sample data. Real data is untouched.", .ja: "サンプルデータでプレビュー。実データは変わりません。",
            .fr: "Aperçu avec des données d'exemple. Les vraies données restent intactes.", .ru: "Предпросмотр на примерных данных. Реальные данные не меняются.",
        ],
        "settings.diagLog": [
            .zh: "探针诊断日志", .en: "Probe diagnostic log", .ja: "プローブ診断ログ",
            .fr: "Journal de diagnostic", .ru: "Журнал диагностики",
        ],
        "settings.done": [
            .zh: "完成", .en: "Done", .ja: "完了",
            .fr: "OK", .ru: "Готово",
        ],
        "settings.feedback": [
            .zh: "反馈", .en: "Feedback", .ja: "フィードバック",
            .fr: "Commentaires", .ru: "Обратная связь",
        ],
        "settings.language": [
            .zh: "语言", .en: "Language", .ja: "言語",
            .fr: "Langue", .ru: "Язык",
        ],
        "settings.language.system": [
            .zh: "跟随系统", .en: "Match system", .ja: "システムに合わせる",
            .fr: "Suivre le système", .ru: "Как в системе",
        ],
        "settings.notifications": [
            .zh: "提醒", .en: "Alerts", .ja: "通知",
            .fr: "Alertes", .ru: "Уведомления",
        ],
        "settings.privacy": [
            .zh: "隐私", .en: "Privacy", .ja: "プライバシー",
            .fr: "Confidentialité", .ru: "Конфиденциальность",
        ],
        "settings.privacy.body": [
            .zh: "登录 Cookie 仅保存在本机系统 WebKit 存储与 App Group 沙盒中；App 只向各官方域名发起请求；无任何统计上报，用量快照中不含任何凭据。退出登录即彻底清除对应站点数据。自定义 token 本机另键、不上传。", .en: "Sign-in cookies live only in this device's WebKit storage and the App Group sandbox. The app calls official domains only; nothing is reported anywhere, and usage snapshots contain no credentials. Signing out wipes that site's local data. Custom tokens stay in a separate on-device key and are never uploaded.", .ja: "ログイン Cookie は本体の WebKit ストレージと App Group サンドボックスにのみ保存されます。アプリは公式ドメインにのみアクセスし、統計送信は一切ありません。ログアウトすると該当サイトのデータは完全に削除されます。カスタム token は端末内の別キーにのみ保存し、アップロードしません。",
            .fr: "Les cookies de connexion restent dans le stockage WebKit et le bac à sable App Group de l'appareil. L'app n'appelle que les domaines officiels ; aucune télémétrie, et les instantanés ne contiennent aucun identifiant. La déconnexion efface les données du site. Les jetons personnalisés restent dans une clé locale distincte et ne sont jamais envoyés.", .ru: "Cookie входа хранятся только в WebKit-хранилище устройства и песочнице App Group. Приложение обращается только к официальным доменам; телеметрии нет, в снимках нет учётных данных. Выход полностью удаляет данные сайта. Свои токены лежат в отдельном локальном ключе и не загружаются.",
        ],
        "settings.privacy.title": [
            .zh: "凭据全部本地化", .en: "All credentials stay local", .ja: "資格情報はすべてローカル保存",
            .fr: "Identifiants 100 % locaux", .ru: "Все данные хранятся локально",
        ],
        "settings.providers": [
            .zh: "服务商", .en: "Providers", .ja: "プロバイダ",
            .fr: "Fournisseurs", .ru: "Провайдеры",
        ],
        "settings.resetTime": [
            .zh: "重置时间", .en: "Reset time", .ja: "リセット時刻",
            .fr: "Heure de réinitialisation", .ru: "Время сброса",
        ],
        "settings.resetTime.absolute": [
            .zh: "时刻", .en: "Clock time", .ja: "時刻",
            .fr: "Heure exacte", .ru: "Точное время",
        ],
        "settings.resetTime.countdown": [
            .zh: "倒计时", .en: "Countdown", .ja: "カウントダウン",
            .fr: "Compte à rebours", .ru: "Обратный отсчёт",
        ],
        "settings.resetTime.footer": [
            .zh: "倒计时显示还剩多久；时刻显示具体钟点。", .en: "Countdown shows time left; clock time shows the exact hour.", .ja: "カウントダウンは残り時間、時刻は具体的な時間です。",
            .fr: "Le compte à rebours montre le reste ; l'heure exacte affiche l'horaire.", .ru: "Обратный отсчёт — сколько осталось; точное время — час сброса.",
        ],
        "settings.share.hideBrand": [
            .zh: "隐藏分享二维码", .en: "Hide share QR code", .ja: "共有 QR を隠す",
            .fr: "Masquer le QR de partage", .ru: "Скрыть QR для шаринга",
        ],
        "settings.theme": [
            .zh: "主题", .en: "Theme", .ja: "テーマ",
            .fr: "Thème", .ru: "Тема",
        ],
        "settings.dashboardTheme": [
            .zh: "首页主题", .en: "Dashboard theme", .ja: "ホームのテーマ",
            .fr: "Thème de l'accueil", .ru: "Тема главного экрана",
        ],
        "settings.dashboardTheme.flat": [
            .zh: "平铺", .en: "Flat", .ja: "フラット",
            .fr: "Plat", .ru: "Плоская",
        ],
        "settings.dashboardTheme.roulette": [
            .zh: "轮盘", .en: "Roulette", .ja: "ルーレット",
            .fr: "Roulette", .ru: "Рулетка",
        ],
        "settings.dashboardTheme.helix": [
            .zh: "螺旋", .en: "Helix", .ja: "らせん",
            .fr: "Hélice", .ru: "Спираль",
        ],
        "sideKey.label": [
            .zh: "侧边键", .en: "Side key", .ja: "サイドキー",
            .fr: "Touche latérale", .ru: "Боковая кнопка",
        ],
        "settings.sideKey.guideTitle": [
            .zh: "设置操作按钮", .en: "Set up the Action Button", .ja: "アクションボタンを設定",
            .fr: "Configurer le bouton Action", .ru: "Настроить кнопку «Действие»",
        ],
        // 快捷指令在系统里显示的名字就是「侧边菜单」（未本地化），各语言步骤里原样写
        "settings.sideKey.guideSteps": [
            .zh: "1. 点下方「前往设置」打开 iPhone 设置，在首页点「操作按钮」\n\n2. 左右滑动，选到「快捷指令」\n\n3. 点「选择快捷指令」，在 Usage Limits 下选「侧边菜单」\n\n4. 回到本 App 首页按一下操作按钮：弹出 设置 / 分享 / 主题；再按轮换选中，点菜单项确认",
            .en: "1. Tap “Open Settings” below, then tap “Action Button” on the Settings home screen\n\n2. Swipe to “Shortcut”\n\n3. Tap “Choose a Shortcut” and pick “侧边菜单” under Usage Limits\n\n4. Back on the app’s home screen, press the Action Button: Settings / Share / Theme pop up; press again to cycle, tap an item to confirm",
            .ja: "1. 下の「設定を開く」をタップし、設定のトップ画面で「アクションボタン」を開く\n\n2. 左右にスワイプして「ショートカット」を選ぶ\n\n3. 「ショートカットを選択」から Usage Limits の「侧边菜单」を選ぶ\n\n4. このアプリのホームでアクションボタンを押す：設定 / 共有 / テーマが表示され、もう一度押すと切り替え、項目をタップで決定",
            .fr: "1. Touchez « Ouvrir Réglages » ci-dessous, puis « Bouton Action » sur l’écran d’accueil des Réglages\n\n2. Balayez jusqu’à « Raccourci »\n\n3. Touchez « Choisir un raccourci » et prenez « 侧边菜单 » sous Usage Limits\n\n4. De retour sur l’accueil de l’app, appuyez sur le bouton Action : Réglages / Partager / Thème apparaissent ; appuyez encore pour passer au suivant, touchez un élément pour confirmer",
            .ru: "1. Нажмите «Открыть Настройки» ниже, затем на главном экране Настроек откройте «Кнопка „Действие“»\n\n2. Пролистайте до «Быстрая команда»\n\n3. Нажмите «Выбрать быструю команду» и выберите «侧边菜单» в разделе Usage Limits\n\n4. Вернитесь на главный экран приложения и нажмите кнопку «Действие»: появятся Настройки / Поделиться / Тема; нажмите ещё раз для перебора, коснитесь пункта для подтверждения",
        ],
        "settings.sideKey.open": [
            .zh: "前往设置", .en: "Open Settings", .ja: "設定を開く",
            .fr: "Ouvrir Réglages", .ru: "Открыть Настройки",
        ],
        "sideKey.hint": [
            .zh: "按操作按钮打开菜单，再按轮换选中，点菜单项确认",
            .en: "Press the Action Button to open the menu, press again to cycle, tap an item to confirm",
            .ja: "アクションボタンでメニューを開き、もう一度押して切り替え、項目をタップして決定",
            .fr: "Appuyez sur le bouton Action pour ouvrir le menu, appuyez encore pour passer au suivant, touchez un élément pour confirmer",
            .ru: "Нажмите кнопку «Действие», чтобы открыть меню; нажмите ещё раз для перебора, коснитесь пункта для подтверждения",
        ],
        "sideKey.menu.share": [
            .zh: "分享", .en: "Share", .ja: "共有",
            .fr: "Partager", .ru: "Поделиться",
        ],
        "sideKey.menu.theme": [
            .zh: "主题", .en: "Theme", .ja: "テーマ",
            .fr: "Thème", .ru: "Тема",
        ],
        "sideKey.menu.rootHint": [
            .zh: "再按操作按钮轮换选中，点菜单项确认",
            .en: "Press the Action Button again to cycle, tap an item to confirm",
            .ja: "アクションボタンをもう一度押して切り替え、項目をタップして決定",
            .fr: "Appuyez encore sur le bouton Action pour passer au suivant, touchez un élément pour confirmer",
            .ru: "Нажмите кнопку «Действие» ещё раз для перебора, коснитесь пункта для подтверждения",
        ],
        "sideKey.menu.themeHint": [
            .zh: "再按操作按钮轮换主题，点主题切换",
            .en: "Press the Action Button again to cycle themes, tap one to switch",
            .ja: "アクションボタンをもう一度押してテーマを切り替え、タップで適用",
            .fr: "Appuyez encore sur le bouton Action pour changer de thème, touchez-en un pour l'appliquer",
            .ru: "Нажмите кнопку «Действие» ещё раз для перебора тем, коснитесь темы для переключения",
        ],
        "settings.dashboardTheme.footer": [
            .zh: "轮盘、螺旋是 3D 卡片场景，折叠态露出两条计量条；深浅色都跟随上面的主题设置。",
            .en: "Roulette and Helix are 3D card scenes that show two meters while collapsed. All three follow the theme above.",
            .ja: "ルーレットとらせんは 3D カードシーンで、折りたたみ時に 2 本のメーターを表示します。3 つとも上のテーマに従います。",
            .fr: "Roulette et Hélice sont des scènes 3D qui affichent deux jauges repliées. Les trois suivent le thème ci-dessus.",
            .ru: "Рулетка и Спираль — 3D-сцены карточек, в свёрнутом виде показывают две шкалы. Все три следуют теме выше.",
        ],
        "settings.theme.dark": [
            .zh: "深色", .en: "Dark", .ja: "ダーク",
            .fr: "Sombre", .ru: "Тёмная",
        ],
        "settings.theme.light": [
            .zh: "浅色", .en: "Light", .ja: "ライト",
            .fr: "Clair", .ru: "Светлая",
        ],
        "settings.theme.system": [
            .zh: "跟随系统", .en: "Match system", .ja: "システムに合わせる",
            .fr: "Suivre le système", .ru: "Как в системе",
        ],
        "settings.title": [
            .zh: "设置", .en: "Settings", .ja: "設定",
            .fr: "Réglages", .ru: "Настройки",
        ],
        "settings.usageDisplay": [
            .zh: "用量展示", .en: "Usage display", .ja: "使用量の表示",
            .fr: "Affichage de l'usage", .ru: "Отображение расхода",
        ],
        "settings.usageDisplay.footer": [
            .zh: "提醒阈值始终按已用计算。", .en: "Alerts always use usage.", .ja: "通知しきい値は常に使用量です。",
            .fr: "Les seuils restent basés sur l'usage.", .ru: "Пороги всегда по использованию.",
        ],
        "settings.usageDisplay.remaining": [
            .zh: "剩余", .en: "Remaining", .ja: "残り",
            .fr: "Restant", .ru: "Осталось",
        ],
        "settings.usageDisplay.used": [
            .zh: "已用", .en: "Used", .ja: "使用済み",
            .fr: "Utilisé", .ru: "Использовано",
        ],
        "settings.version": [
            .zh: "版本", .en: "Version", .ja: "バージョン",
            .fr: "Version", .ru: "Версия",
        ],
        "settings.widgetPreview": [
            .zh: "小组件", .en: "Widgets", .ja: "ウィジェット",
            .fr: "Widgets", .ru: "Виджеты",
        ],
        "widgets.preview": [
            .zh: "预览", .en: "Preview", .ja: "プレビュー",
            .fr: "Aperçu", .ru: "Предпросмотр",
        ],
        "settings.appearance": [
            .zh: "外观", .en: "Appearance", .ja: "外観",
            .fr: "Apparence", .ru: "Внешний вид",
        ],
        "settings.refreshGroup": [
            .zh: "刷新与提醒", .en: "Refresh & alerts", .ja: "更新と通知",
            .fr: "Actualisation et alertes", .ru: "Обновление и уведомления",
        ],
        "settings.advanced": [
            .zh: "高级", .en: "Advanced", .ja: "詳細",
            .fr: "Avancé", .ru: "Дополнительно",
        ],
        "settings.appIcon": [
            .zh: "图标", .en: "App icon", .ja: "アイコン",
            .fr: "Icône", .ru: "Значок",
        ],
        "appIcon.original": [
            .zh: "原始", .en: "Original", .ja: "オリジナル",
            .fr: "Originale", .ru: "Оригинал",
        ],
        "appIcon.footer": [
            .zh: "更换后桌面图标随之变化；更多图标后续添加。", .en: "The home-screen icon changes right away; more icons are coming.", .ja: "ホーム画面のアイコンがすぐに切り替わります。今後さらに追加予定。",
            .fr: "L'icône de l'écran d'accueil change aussitôt ; d'autres icônes arrivent.", .ru: "Значок на экране меняется сразу; новые значки появятся позже.",
        ],
        "share.edit.done": [
            .zh: "完成", .en: "Done", .ja: "完了",
            .fr: "OK", .ru: "Готово",
        ],
        "share.edit.selectAll": [
            .zh: "全选", .en: "Select All", .ja: "すべて選択",
            .fr: "Tout", .ru: "Все",
        ],
        "share.edit.title": [
            .zh: "选择要分享的实例", .en: "Choose accounts to share", .ja: "共有するアカウント",
            .fr: "Comptes à partager", .ru: "Выберите аккаунты",
        ],
        "share.failed": [
            .zh: "保存失败", .en: "Couldn't save", .ja: "保存に失敗",
            .fr: "Échec de l'enregistrement", .ru: "Не удалось сохранить",
        ],
        "share.global": [
            .zh: "分享全部用量", .en: "Share all usage", .ja: "すべての使用状況を共有",
            .fr: "Partager tout", .ru: "Поделиться всем",
        ],
        "share.manage.collapse": [
            .zh: "分享折叠", .en: "Hide options", .ja: "オプションを隠す",
            .fr: "Masquer options", .ru: "Скрыть опции",
        ],
        "share.manage.expand": [
            .zh: "分享展开", .en: "Show options", .ja: "オプションを表示",
            .fr: "Afficher options", .ru: "Показать опции",
        ],
        "share.moments.guide": [
            .zh: "图片已保存到相册（并已复制）。微信不允许第三方 App 直达朋友圈发布页：打开微信 → 朋友圈 → 右上角相机 → 从相册选择这张图即可发布。", .en: "The image is saved to Photos (and copied). WeChat doesn't let apps open the Moments composer directly: open WeChat → Moments → camera icon → pick this image from your album.", .ja: "画像は写真に保存（コピー済み）。WeChat の仕様によりモーメンツ投稿画面へ直接移動できません：WeChat → モーメンツ → カメラ → アルバムからこの画像を選択してください。",
            .fr: "Image enregistrée dans Photos (et copiée). WeChat n'autorise pas l'ouverture directe du composeur Moments : WeChat → Moments → appareil photo → choisissez cette image.", .ru: "Изображение сохранено в Фото (и скопировано). WeChat не позволяет открыть «Моменты» напрямую: WeChat → Моменты → камера → выберите это изображение из альбома.",
        ],
        "share.moments.title": [
            .zh: "分享到朋友圈", .en: "Share to Moments", .ja: "モーメンツに共有",
            .fr: "Partager sur Moments", .ru: "Поделиться в «Моментах»",
        ],
        "share.openWeChat": [
            .zh: "打开微信", .en: "Open WeChat", .ja: "WeChat を開く",
            .fr: "Ouvrir WeChat", .ru: "Открыть WeChat",
        ],
        "share.opt.glow": [
            .zh: "光晕", .en: "Glow", .ja: "グロー",
            .fr: "Halo", .ru: "Сияние",
        ],
        "share.opt.details": [
            .zh: "明细", .en: "Details", .ja: "詳細",
            .fr: "Détails", .ru: "Детали",
        ],
        "share.opt.hideTime": [
            .zh: "隐藏时间", .en: "No time", .ja: "時刻を隠す",
            .fr: "Sans heure", .ru: "Без времени",
        ],
        "share.opt.hideUnused": [
            .zh: "隐藏未用", .en: "Hide unused", .ja: "未使用を隠す",
            .fr: "Sans inutilisé", .ru: "Скрыть пустые",
        ],
        "share.opt.sameColor": [
            .zh: "同色条", .en: "Same color", .ja: "同色バー",
            .fr: "Même couleur", .ru: "Один цвет",
        ],
        "share.preview.title": [
            .zh: "分享预览", .en: "Share preview", .ja: "共有プレビュー",
            .fr: "Aperçu du partage", .ru: "Предпросмотр",
        ],
        "share.saved": [
            .zh: "已保存到相册", .en: "Saved to Photos", .ja: "写真に保存しました",
            .fr: "Enregistré dans Photos", .ru: "Сохранено в Фото",
        ],
        "share.scanAppStore": [
            .zh: "扫码下载 Usage Limits", .en: "Scan to get Usage Limits", .ja: "スキャンして Usage Limits",
            .fr: "Scanner Usage Limits", .ru: "Сканируйте Usage Limits",
        ],
        "share.target.edit": [
            .zh: "编辑", .en: "Edit", .ja: "編集",
            .fr: "Modifier", .ru: "Изменить",
        ],
        "share.target.moments": [
            .zh: "朋友圈", .en: "Moments", .ja: "モーメント",
            .fr: "Moments", .ru: "Моменты",
        ],
        "share.target.other": [
            .zh: "分享", .en: "Share", .ja: "共有",
            .fr: "Partager", .ru: "Поделиться",
        ],
        "share.target.save": [
            .zh: "保存到相册", .en: "Save to Photos", .ja: "写真に保存",
            .fr: "Enregistrer", .ru: "В Фото",
        ],
        "share.target.wechat": [
            .zh: "微信", .en: "WeChat", .ja: "WeChat",
            .fr: "WeChat", .ru: "WeChat",
        ],
        "share.wechat.missing": [
            .zh: "未安装微信", .en: "WeChat is not installed", .ja: "WeChat がありません",
            .fr: "WeChat n'est pas installé", .ru: "WeChat не установлен",
        ],
        "time.compactMin": [
            .zh: "%d 分后", .en: "in %dm", .ja: "%d 分後",
            .fr: "dans %d min", .ru: "через %d мин",
        ],
        "time.day": [
            .zh: "%d 天后", .en: "in %dd", .ja: "%d 日後",
            .fr: "dans %d j", .ru: "через %d дн",
        ],
        "time.dayHour": [
            .zh: "%d 天 %d 小时后", .en: "in %dd %dh", .ja: "%d 日 %d 時間後",
            .fr: "dans %d j %d h", .ru: "через %d дн %d ч",
        ],
        "time.hour": [
            .zh: "%d 小时后", .en: "in %dh", .ja: "%d 時間後",
            .fr: "dans %d h", .ru: "через %d ч",
        ],
        "time.hourMin": [
            .zh: "%d 小时 %d 分后", .en: "in %dh %dm", .ja: "%d 時間 %d 分後",
            .fr: "dans %d h %d min", .ru: "через %d ч %d мин",
        ],
        "time.min": [
            .zh: "%d 分钟后", .en: "in %dm", .ja: "%d 分後",
            .fr: "dans %d min", .ru: "через %d мин",
        ],
        "time.reset": [
            .zh: "已重置", .en: "Reset", .ja: "リセット済み",
            .fr: "Réinitialisé", .ru: "Сброшено",
        ],
        "time.tomorrowAt": [
            .zh: "明天 %@", .en: "tomorrow %@", .ja: "明日 %@",
            .fr: "demain %@", .ru: "завтра %@",
        ],
        "tint.color": [
            .zh: "颜色", .en: "Color", .ja: "カラー",
            .fr: "Couleur", .ru: "Цвет",
        ],
        "tint.end": [
            .zh: "结束色", .en: "End color", .ja: "終了色",
            .fr: "Couleur de fin", .ru: "Конечный цвет",
        ],
        "tint.gradient": [
            .zh: "渐变", .en: "Gradient", .ja: "グラデーション",
            .fr: "Dégradé", .ru: "Градиент",
        ],
        "tint.hex": [
            .zh: "色号", .en: "Hex", .ja: "カラーコード",
            .fr: "Code hex", .ru: "Hex-код",
        ],
        "tint.menu": [
            .zh: "主题色…", .en: "Theme color…", .ja: "テーマカラー…",
            .fr: "Couleur du thème…", .ru: "Цвет темы…",
        ],
        "tint.mode": [
            .zh: "颜色模式", .en: "Color mode", .ja: "カラーモード",
            .fr: "Mode de couleur", .ru: "Режим цвета",
        ],
        "tint.picker": [
            .zh: "取色器", .en: "Color picker", .ja: "カラーピッカー",
            .fr: "Sélecteur", .ru: "Палитра",
        ],
        "tint.preview": [
            .zh: "预览", .en: "Preview", .ja: "プレビュー",
            .fr: "Aperçu", .ru: "Предпросмотр",
        ],
        "tint.providerDefault": [
            .zh: "默认颜色", .en: "Default color", .ja: "既定カラー",
            .fr: "Couleur par défaut", .ru: "Цвет по умолчанию",
        ],
        "tint.restoreDefault": [
            .zh: "恢复默认", .en: "Restore default", .ja: "デフォルトに戻す",
            .fr: "Rétablir par défaut", .ru: "Сбросить по умолчанию",
        ],
        "tint.restoreDefault.footer": [
            .zh: "清除本层自定义：账号回落供应商默认色，供应商回落内置品牌色。", .en: "Clears this override: accounts fall back to the provider default, providers fall back to the built-in brand color.", .ja: "この設定を消去：アカウントはプロバイダ既定色に、プロバイダは内蔵ブランドカラーに戻ります。",
            .fr: "Efface ce niveau : les comptes reviennent à la couleur du fournisseur, les fournisseurs à la couleur intégrée.", .ru: "Сбрасывает это переопределение: аккаунты вернутся к цвету провайдера, провайдеры — к встроенному цвету.",
        ],
        "tint.solid": [
            .zh: "纯色", .en: "Solid", .ja: "単色",
            .fr: "Uni", .ru: "Однотонный",
        ],
        "tint.start": [
            .zh: "起始色", .en: "Start color", .ja: "開始色",
            .fr: "Couleur de départ", .ru: "Начальный цвет",
        ],
        "watch.enableHint": [
            .zh: "向上滑动，在设置中开启", .en: "Swipe up to enable in Settings", .ja: "上にスワイプして設定でオン",
            .fr: "Balayez vers le haut pour activer dans Réglages", .ru: "Смахните вверх и включите в настройках",
        ],
        "watch.loginOnPhone": [
            .zh: "在 iPhone 上登录后自动同步", .en: "Sign in on iPhone to sync", .ja: "iPhone でログインすると同期されます",
            .fr: "Connectez-vous sur l'iPhone pour synchroniser", .ru: "Войдите на iPhone — данные синхронизируются",
        ],
        "watch.syncFooter": [
            .zh: "开关与 iPhone App 实时同步。", .en: "Toggles sync with the iPhone app.", .ja: "スイッチは iPhone アプリと同期します。",
            .fr: "Les réglages se synchronisent avec l'app iPhone.", .ru: "Переключатели синхронизируются с приложением на iPhone.",
        ],
        "widget.accountType": [
            .zh: "账号", .en: "Account", .ja: "アカウント",
            .fr: "Compte", .ru: "Аккаунт",
        ],
        "widget.metricType": [
            .zh: "额度", .en: "Quotas", .ja: "利用枠",
            .fr: "Quotas", .ru: "Квоты",
        ],
        "widget.quotaParam": [
            .zh: "额度（留空则跟随首页）", .en: "Quotas (empty = follow home)", .ja: "利用枠（空欄ならホームに従う）",
            .fr: "Quotas (vide = suivre l'accueil)", .ru: "Квоты (пусто = как на главном экране)",
        ],
        "widget.allDisabled": [
            .zh: "所有服务商都已停用", .en: "All providers disabled", .ja: "すべてのプロバイダが無効",
            .fr: "Tous les fournisseurs désactivés", .ru: "Все провайдеры отключены",
        ],
        "widget.chooseAccount": [
            .zh: "选择账号", .en: "Choose account", .ja: "アカウントを選択",
            .fr: "Choisir un compte", .ru: "Выбрать аккаунт",
        ],
        "widget.disabled": [
            .zh: "已停用", .en: "Disabled", .ja: "無効",
            .fr: "Désactivé", .ru: "Отключено",
        ],
        "widget.enableInApp": [
            .zh: "在 App 设置中重新开启", .en: "Re-enable in app Settings", .ja: "アプリの設定でオンにしてください",
            .fr: "Réactivez dans les réglages", .ru: "Включите в настройках приложения",
        ],
        "widget.gallery.medium": [
            .zh: "中等总览", .en: "Medium overview", .ja: "中サイズ概要",
            .fr: "Aperçu moyen", .ru: "Средний обзор",
        ],
        "widget.gallery.mediumDetail": [
            .zh: "几行进度条总览。", .en: "A few quota bars.", .ja: "数行の進捗バー。",
            .fr: "Quelques barres de quota.", .ru: "Несколько полос квот.",
        ],
        "widget.gallery.large": [
            .zh: "多账号总览", .en: "Multi-account overview", .ja: "複数アカウント概要",
            .fr: "Aperçu multi-comptes", .ru: "Обзор нескольких аккаунтов",
        ],
        "widget.gallery.largeDetail": [
            .zh: "按账号实例分组；额度取各实例首页排序的前几条。", .en: "Grouped by account; each shows its first homepage quotas.", .ja: "アカウントごとにまとめ、ホーム順の先頭クォータを表示。",
            .fr: "Groupé par compte ; premiers quotas de l'accueil.", .ru: "По аккаунтам: первые квоты с главного экрана.",
        ],
        "widget.gallery.single": [
            .zh: "单服务商", .en: "Single provider", .ja: "単一プロバイダ",
            .fr: "Un fournisseur", .ru: "Один провайдер",
        ],
        "widget.gallery.singleDetail": [
            .zh: "圆环显示该账号的当前用量。", .en: "A ring for this account's current usage.", .ja: "このアカウントの使用量をリング表示。",
            .fr: "Un anneau pour l'usage de ce compte.", .ru: "Кольцо текущего расхода аккаунта.",
        ],
        "widget.highestUsage": [
            .zh: "最高用量（自动）", .en: "Highest usage (auto)", .ja: "使用量がいちばん高い（自動）",
            .fr: "Plus forte utilisation (auto)", .ru: "Наибольший расход (авто)",
        ],
        "widget.homeSlot": [
            .zh: "首页额度 %d", .en: "Home quota %d", .ja: "ホーム利用枠 %d",
            .fr: "Quota d'accueil %d", .ru: "Квота %d с главного экрана",
        ],
        "widget.emptySlot": [
            .zh: "（空）", .en: "(empty)", .ja: "（空き）",
            .fr: "(vide)", .ru: "(пусто)",
        ],
        "widget.followHome": [
            .zh: "跟随首页额度", .en: "Follow home quotas", .ja: "ホームの利用枠に従う",
            .fr: "Suivre les quotas d'accueil", .ru: "Как на главном экране",
        ],
        "widget.more": [
            .zh: "还有 %d 项，打开 App 查看", .en: "%d more — open the app", .ja: "他 %d 件はアプリで表示",
            .fr: "%d de plus — ouvrez l'app", .ru: "Ещё %d — смотрите в приложении",
        ],
        "widget.noNumeric": [
            .zh: "已登录，官方未提供数值额度", .en: "Signed in — no numeric limits", .ja: "ログイン済み・数値上限なし",
            .fr: "Connecté — pas de limites chiffrées", .ru: "Вход выполнен — нет числовых лимитов",
        ],
        "widget.openToLogin": [
            .zh: "打开 App 登录", .en: "Open the app to sign in", .ja: "アプリでログイン",
            .fr: "Ouvrez l'app pour vous connecter", .ru: "Откройте приложение для входа",
        ],
        "widget.overviewDescription": [
            .zh: "勾选账号实例；额度自动取首页排序的前几条。", .en: "Pick accounts; quotas follow homepage order.", .ja: "アカウントを選び、クォータはホーム順。",
            .fr: "Choisissez les comptes ; les quotas suivent l'accueil.", .ru: "Выберите аккаунты; квоты по порядку главного экрана.",
        ],
        "widget.overviewTitle": [
            .zh: "用量总览", .en: "Usage overview", .ja: "使用量の概要",
            .fr: "Aperçu de l'usage", .ru: "Обзор расхода",
        ],
        "widget.providerType": [
            .zh: "服务商", .en: "Provider", .ja: "プロバイダ",
            .fr: "Fournisseur", .ru: "Провайдер",
        ],
        "widget.singleDescription": [
            .zh: "单个服务商的用量。", .en: "Usage for one provider.", .ja: "1つのプロバイダの使用量。",
            .fr: "Usage d'un fournisseur.", .ru: "Расход одного провайдера.",
        ],
        "上月": [
            .zh: "上月", .en: "Last month", .ja: "先月",
            .fr: "Le mois dernier", .ru: "Прошлый месяц",
        ],
        "上限": [
            .zh: "上限", .en: "Limit", .ja: "上限",
            .fr: "Plafond", .ru: "Лимит",
        ],
        "专家": [
            .zh: "专家", .en: "Expert", .ja: "エキスパート",
            .fr: "Expert", .ru: "Эксперт",
        ],
        "今天": [
            .zh: "今天", .en: "Today", .ja: "今日",
            .fr: "Aujourd'hui", .ru: "Сегодня",
        ],
        "今日": [
            .zh: "今日", .en: "Today", .ja: "今日",
            .fr: "Aujourd'hui", .ru: "Сегодня",
        ],
        "今日 tokens": [
            .zh: "今日 tokens", .en: "Tokens today", .ja: "本日のトークン",
            .fr: "Tokens du jour", .ru: "Токены сегодня",
        ],
        "今日限额": [
            .zh: "今日限额", .en: "Daily limit", .ja: "本日の上限",
            .fr: "Limite quotidienne", .ru: "Лимит за день",
        ],
        "付费": [
            .zh: "付费", .en: "Paid", .ja: "有料",
            .fr: "Payé", .ru: "Платно",
        ],
        "低谷 0.5x": [
            .zh: "低谷 0.5x", .en: "Off-peak 0.5x", .ja: "オフピーク 0.5x",
            .fr: "Heures creuses 0.5x", .ru: "Спад 0.5x",
        ],
        "可用余额": [
            .zh: "可用余额", .en: "Available balance", .ja: "利用可能残高",
            .fr: "Solde disponible", .ru: "Доступный баланс",
        ],
        "余额": [
            .zh: "余额", .en: "Balance", .ja: "残高",
            .fr: "Solde", .ru: "Остаток",
        ],
        "代金券": [
            .zh: "代金券", .en: "Voucher", .ja: "クーポン",
            .fr: "Bon", .ru: "Ваучер",
        ],
        "余额数据异常": [
            .zh: "余额数据异常", .en: "Balance data is invalid", .ja: "残高データが不正です",
            .fr: "Solde invalide", .ru: "Данные баланса неверны",
        ],
        "充值积分": [
            .zh: "充值积分", .en: "Purchased credits", .ja: "チャージクレジット",
            .fr: "Crédits achetés", .ru: "Купленные кредиты",
        ],
        "分类 %d": [
            .zh: "分类 %d", .en: "Category %d", .ja: "分類 %d",
            .fr: "Catégorie %d", .ru: "Категория %d",
        ],
        "分钟": [
            .zh: "分钟", .en: "minutes", .ja: "分",
            .fr: "minutes", .ru: "мин",
        ],
        "剩余": [
            .zh: "剩余", .en: "Left", .ja: "残り",
            .fr: "Restant", .ru: "Осталось",
        ],
        "剩余积分": [
            .zh: "剩余积分", .en: "Remaining credits", .ja: "残りクレジット",
            .fr: "Crédits restants", .ru: "Оставшиеся кредиты",
        ],
        "剩余额度": [
            .zh: "剩余额度", .en: "Remaining quota", .ja: "残り枠",
            .fr: "Quota restant", .ru: "Оставшаяся квота",
        ],
        "剩余请求": [
            .zh: "剩余请求", .en: "Requests left", .ja: "残リクエスト",
            .fr: "Requêtes restantes", .ru: "Оставшиеся запросы",
        ],
        "加油包": [
            .zh: "加油包", .en: "Fuel pack", .ja: "追加パック",
            .fr: "Pack bonus", .ru: "Пакет пополнения",
        ],
        "周窗口": [
            .zh: "周窗口", .en: "Weekly window", .ja: "週間ウィンドウ",
            .fr: "Fenêtre hebdo", .ru: "Недельное окно",
        ],
        "周限额": [
            .zh: "周限额", .en: "Weekly limit", .ja: "週間上限",
            .fr: "Limite hebdo", .ru: "Недельный лимит",
        ],
        "响应状态码异常": [
            .zh: "响应状态码异常", .en: "Unexpected response status", .ja: "予期しないステータス",
            .fr: "Statut de réponse inattendu", .ru: "Неожиданный статус ответа",
        ],
        "图像生成": [
            .zh: "图像生成", .en: "Image generation", .ja: "画像生成",
            .fr: "Génération d'images", .ru: "Генерация изображений",
        ],
        "图生视频": [
            .zh: "图生视频", .en: "Image to video", .ja: "画像から動画",
            .fr: "Image vers vidéo", .ru: "Изображение в видео",
        ],
        "天": [
            .zh: "天", .en: "days", .ja: "日",
            .fr: "j", .ru: "дн.",
        ],
        "季": [
            .zh: "季", .en: "qtr", .ja: "四半期",
            .fr: "trim.", .ru: "кв.",
        ],
        "小时": [
            .zh: "小时", .en: "hours", .ja: "時間",
            .fr: "heures", .ru: "ч",
        ],
        "现金余额": [
            .zh: "现金余额", .en: "Cash balance", .ja: "現金残高",
            .fr: "Solde cash", .ru: "Наличный остаток",
        ],
        "已使用": [
            .zh: "已使用", .en: "Used", .ja: "使用済み",
            .fr: "Utilisé", .ru: "Использовано",
        ],
        "已用": [
            .zh: "已用", .en: "Used", .ja: "使用済み",
            .fr: "Utilisé", .ru: "Использовано",
        ],
        "已用额度": [
            .zh: "已用额度", .en: "Used quota", .ja: "使用済み枠",
            .fr: "Quota utilisé", .ru: "Использованная квота",
        ],
        "年": [
            .zh: "年", .en: "yr", .ja: "年",
            .fr: "an", .ru: "год",
        ],
        "当前 workspace 不适用 Notion AI 额度": [
            .zh: "当前 workspace 不适用 Notion AI 额度", .en: "This workspace has no Notion AI quota", .ja: "このワークスペースにNotion AI枠はありません",
            .fr: "Cet espace n'a pas de quota Notion AI", .ru: "У этого workspace нет квоты Notion AI",
        ],
        "快速": [
            .zh: "快速", .en: "Fast", .ja: "高速",
            .fr: "Rapide", .ru: "Быстрый",
        ],
        "总用量": [
            .zh: "总用量", .en: "Total usage", .ja: "合計使用量",
            .fr: "Usage total", .ru: "Общий расход",
        ],
        "按月重置": [
            .zh: "按月重置", .en: "Resets monthly", .ja: "毎月リセット",
            .fr: "Réinitialisation mensuelle", .ru: "Сброс раз в месяц",
        ],
        "控制台接口无响应": [
            .zh: "控制台接口无响应", .en: "Console API did not respond", .ja: "コンソールAPIが応答しません",
            .fr: "L'API console n'a pas répondu", .ru: "API консоли не ответила",
        ],
        "推理": [
            .zh: "推理", .en: "Reasoning", .ja: "推論",
            .fr: "Raisonnement", .ru: "Рассуждение",
        ],
        "插件": [
            .zh: "插件", .en: "Plugins", .ja: "プラグイン",
            .fr: "Extensions", .ru: "Плагины",
        ],
        "文本生成": [
            .zh: "文本生成", .en: "Text generation", .ja: "テキスト生成",
            .fr: "Génération de texte", .ru: "Генерация текста",
        ],
        "文生视频": [
            .zh: "文生视频", .en: "Text to video", .ja: "テキストから動画",
            .fr: "Texte vers vidéo", .ru: "Текст в видео",
        ],
        "无上限": [
            .zh: "无上限", .en: "Unlimited", .ja: "無制限",
            .fr: "Illimité", .ru: "Без лимита",
        ],
        "无网络": [
            .zh: "无网络", .en: "No network", .ja: "ネットワークなし",
            .fr: "Pas de réseau", .ru: "Нет сети",
        ],
        "无限制": [
            .zh: "无限制", .en: "Unlimited", .ja: "無制限",
            .fr: "Illimité", .ru: "Без лимита",
        ],
        "明文被拦": [
            .zh: "明文被拦", .en: "Cleartext blocked", .ja: "平文が拒否されました",
            .fr: "Texte en clair bloqué", .ru: "Открытый текст заблокирован",
        ],
        "昨天": [
            .zh: "昨天", .en: "Yesterday", .ja: "昨日",
            .fr: "Hier", .ru: "Вчера",
        ],
        "智谱响应状态码异常": [
            .zh: "智谱响应状态码异常", .en: "Zhipu response status is invalid", .ja: "Zhipuのステータスが不正です",
            .fr: "Statut Zhipu invalide", .ru: "Некорректный статус Zhipu",
        ],
        "智谱接口失败": [
            .zh: "智谱接口失败", .en: "Zhipu request failed", .ja: "Zhipu リクエスト失敗",
            .fr: "Échec Zhipu", .ru: "Ошибка Zhipu",
        ],
        "最近到期": [
            .zh: "最近到期", .en: "Expires", .ja: "最近の期限",
            .fr: "Expire le", .ru: "Истекает",
        ],
        "月": [
            .zh: "月", .en: "mo", .ja: "月",
            .fr: "mois", .ru: "мес.",
        ],
        "月度额度": [
            .zh: "月度额度", .en: "Monthly quota", .ja: "月間枠",
            .fr: "Quota mensuel", .ru: "Месячная квота",
        ],
        "未找到 Notion workspace": [
            .zh: "未找到 Notion workspace", .en: "No Notion workspace found", .ja: "Notionワークスペースが見つかりません",
            .fr: "Aucun espace Notion trouvé", .ru: "Workspace Notion не найден",
        ],
        "未找到 T3 Chat 用量数据": [
            .zh: "未找到 T3 Chat 用量数据", .en: "T3 Chat usage data not found", .ja: "T3 Chat使用量データが見つかりません",
            .fr: "Données d'usage T3 Chat introuvables", .ru: "Данные использования T3 Chat не найдены",
        ],
        "未知时长": [
            .zh: "未知时长", .en: "Unknown duration", .ja: "不明な期間",
            .fr: "Durée inconnue", .ru: "Неизвестная длительность",
        ],
        "未获取到 Notion AI 额度响应": [
            .zh: "未获取到 Notion AI 额度响应", .en: "Did not receive Notion AI quota response", .ja: "Notion AI枠の応答がありません",
            .fr: "Pas de réponse de quota Notion AI", .ru: "Нет ответа квоты Notion AI",
        ],
        "未获取到 Notion workspace 响应": [
            .zh: "未获取到 Notion workspace 响应", .en: "Did not receive Notion workspace response", .ja: "Notionワークスペース応答がありません",
            .fr: "Pas de réponse d'espace Notion", .ru: "Нет ответа workspace Notion",
        ],
        "未获取到 Ollama settings 响应": [
            .zh: "未获取到 Ollama settings 响应", .en: "Did not receive Ollama settings response", .ja: "Ollama設定応答がありません",
            .fr: "Pas de réponse des réglages Ollama", .ru: "Нет ответа настроек Ollama",
        ],
        "未获取到 StepFun 用量响应": [
            .zh: "未获取到 StepFun 用量响应", .en: "Did not receive StepFun usage response", .ja: "StepFun使用量応答がありません",
            .fr: "Pas de réponse d'usage StepFun", .ru: "Нет ответа использования StepFun",
        ],
        "未获取到 T3 Chat 响应": [
            .zh: "未获取到 T3 Chat 响应", .en: "Did not receive T3 Chat response", .ja: "T3 Chat応答がありません",
            .fr: "Pas de réponse T3 Chat", .ru: "Нет ответа T3 Chat",
        ],
        "未获取到任何响应": [
            .zh: "未获取到任何响应", .en: "No response received", .ja: "応答がありません",
            .fr: "Aucune réponse", .ru: "Нет ответа",
        ],
        "未获取到余额响应": [
            .zh: "未获取到余额响应", .en: "Did not receive balance response", .ja: "残高応答がありません",
            .fr: "Pas de réponse de solde", .ru: "Нет ответа по балансу",
        ],
        "未获取到用量数据": [
            .zh: "未获取到用量数据", .en: "Did not receive usage data", .ja: "使用量データがありません",
            .fr: "Pas de données d'usage", .ru: "Нет данных об использовании",
        ],
        "未获取到算力点响应": [
            .zh: "未获取到算力点响应", .en: "Did not receive compute-points response", .ja: "コンピュートポイント応答がありません",
            .fr: "Pas de réponse des points de calcul", .ru: "Нет ответа по баллам вычислений",
        ],
        "未获取到额度响应": [
            .zh: "未获取到额度响应", .en: "Did not receive quota response", .ja: "枠の応答がありません",
            .fr: "Pas de réponse de quota", .ru: "Нет ответа квоты",
        ],
        "本周用量": [
            .zh: "本周用量", .en: "Weekly usage", .ja: "今週の使用量",
            .fr: "Usage hebdo", .ru: "Расход за неделю",
        ],
        "本周限额": [
            .zh: "本周限额", .en: "Weekly limit", .ja: "今週の上限",
            .fr: "Limite hebdomadaire", .ru: "Лимит за неделю",
        ],
        "本月": [
            .zh: "本月", .en: "This month", .ja: "今月",
            .fr: "Ce mois", .ru: "Этот месяц",
        ],
        "本月限额": [
            .zh: "本月限额", .en: "Monthly limit", .ja: "今月の上限",
            .fr: "Limite mensuelle", .ru: "Лимит за месяц",
        ],
        "标准": [
            .zh: "标准", .en: "Standard", .ja: "標準",
            .fr: "Standard", .ru: "Стандарт",
        ],
        "每周": [
            .zh: "每周", .en: "Weekly", .ja: "毎週",
            .fr: "Hebdomadaire", .ru: "Еженедельно",
        ],
        "每周窗口": [
            .zh: "每周窗口", .en: "Weekly window", .ja: "週間ウィンドウ",
            .fr: "Fenêtre hebdo", .ru: "Недельное окно",
        ],
        "每天": [
            .zh: "每天", .en: "Daily", .ja: "毎日",
            .fr: "Quotidien", .ru: "Ежедневно",
        ],
        "每 %d 小时": [
            .zh: "每 %d 小时", .en: "Every %d hours", .ja: "%d時間ごと",
            .fr: "Toutes les %d h", .ru: "Каждые %d ч",
        ],
        "每 %d 分钟": [
            .zh: "每 %d 分钟", .en: "Every %d minutes", .ja: "%d分ごと",
            .fr: "Toutes les %d min", .ru: "Каждые %d мин",
        ],
        "每 %d 天": [
            .zh: "每 %d 天", .en: "Every %d days", .ja: "%d日ごと",
            .fr: "Tous les %d j", .ru: "Каждые %d дн.",
        ],
        "每 %d 周": [
            .zh: "每 %d 周", .en: "Every %d weeks", .ja: "%d週ごと",
            .fr: "Toutes les %d sem.", .ru: "Каждые %d нед.",
        ],
        "每月窗口": [
            .zh: "每月窗口", .en: "Monthly window", .ja: "月間ウィンドウ",
            .fr: "Fenêtre mensuelle", .ru: "Месячное окно",
        ],
        "活跃天数": [
            .zh: "活跃天数", .en: "Active days", .ja: "利用日数",
            .fr: "Jours actifs", .ru: "Активные дни",
        ],
        "游客额度": [
            .zh: "游客额度", .en: "Guest quota", .ja: "ゲスト枠",
            .fr: "Quota invité", .ru: "Гостевая квота",
        ],
        "Grok 需要浏览器验证": [
            .zh: "Grok 要求浏览器验证，当前用量请求未通过。请先在官网完成验证后重试。",
            .en: "Grok requires browser verification; the usage request was rejected. Complete verification on the official page and retry.",
            .ja: "Grok のブラウザ認証が必要なため、使用量リクエストが拒否されました。公式ページで認証して再試行してください。",
            .fr: "Grok exige une vérification du navigateur. La requête d’usage a été refusée. Terminez la vérification sur le site officiel puis réessayez.",
            .ru: "Grok требует проверки браузера. Запрос расхода отклонён. Пройдите проверку на официальном сайте и повторите попытку.",
        ],
        "请先完成官网登录并进入用量页面": [
            .zh: "请先在官网完成登录，并返回账号或用量页面后再检测。",
            .en: "Finish signing in on the official site, then return to the account or usage page and check again.",
            .ja: "公式サイトでログインし、アカウントまたは使用状況ページに戻って再確認してください。",
            .fr: "Connectez-vous sur le site officiel, puis revenez à la page du compte ou de l’usage et vérifiez à nouveau.",
            .ru: "Войдите на официальном сайте, вернитесь на страницу аккаунта или расхода и повторите проверку.",
        ],
        "检测到游客额度，请先登录账号": [
            .zh: "当前获取到的是游客额度，尚未确认账号登录。",
            .en: "Only guest quota was returned. Account sign-in has not been confirmed.",
            .ja: "ゲスト枠のみ取得できました。アカウントへのログインは未確認です。",
            .fr: "Seul le quota invité a été reçu. La connexion au compte n’est pas confirmée.",
            .ru: "Получена только гостевая квота. Вход в аккаунт ещё не подтверждён.",
        ],
        "login.webOnlyBlocked": [
            .zh: "已阻止打开其他 App，请在网页中完成登录。",
            .en: "Opening another app was blocked. Complete sign-in on the website.",
            .ja: "別のアプリへの移動を停止しました。Web サイトでログインしてください。",
            .fr: "L’ouverture d’une autre app a été bloquée. Connectez-vous sur le site web.",
            .ru: "Переход в другое приложение заблокирован. Войдите на сайте.",
        ],
        "login.continueOnWeb": [
            .zh: "继续网页登录", .en: "Continue on web", .ja: "Web で続ける",
            .fr: "Continuer sur le web", .ru: "Продолжить на сайте",
        ],
        "尚未检测到登录会话": [
            .zh: "官网用量接口尚未识别到登录会话，请完成登录回跳后再试。",
            .en: "The official usage API has not recognized a session. Complete the sign-in redirect and retry.",
            .ja: "公式の使用量 API がログインを認識していません。ログイン後のリダイレクトを完了して再試行してください。",
            .fr: "L’API d’usage officielle ne reconnaît pas encore la session. Terminez la redirection de connexion puis réessayez.",
            .ru: "Официальный API расхода ещё не распознал сеанс. Дождитесь перенаправления после входа и повторите попытку.",
        ],
        "用量数据异常": [
            .zh: "用量数据异常", .en: "Usage data is invalid", .ja: "使用量データが不正です",
            .fr: "Données d'usage invalides", .ru: "Данные расхода неверны",
        ],
        "短期限流": [
            .zh: "短期限流", .en: " short rate limit", .ja: "短期レート制限",
            .fr: " limite courte", .ru: " краткий лимит",
        ],
        "积分": [
            .zh: "积分", .en: "credits", .ja: "クレジット",
            .fr: "crédits", .ru: "кредиты",
        ],
        "积分余额": [
            .zh: "积分余额", .en: "Credit balance", .ja: "クレジット残高",
            .fr: "Solde de crédits", .ru: "Баланс кредитов",
        ],
        "窗口": [
            .zh: "窗口", .en: "window", .ja: "ウィンドウ",
            .fr: "fenêtre", .ru: "окно",
        ],
        "窗口 %d 分钟": [
            .zh: "窗口 %d 分钟", .en: "%d-minute window", .ja: "%d分ウィンドウ",
            .fr: "Fenêtre %d min", .ru: "Окно %d мин",
        ],
        "窗口 %d 小时": [
            .zh: "窗口 %d 小时", .en: "%d-hour window", .ja: "%d時間ウィンドウ",
            .fr: "Fenêtre %d h", .ru: "Окно %d ч",
        ],
        "第三方": [
            .zh: "第三方", .en: "Third party", .ja: "サードパーティ",
            .fr: "Tiers", .ru: "Сторонние",
        ],
        "算力点数据异常": [
            .zh: "算力点数据异常", .en: "Compute-points data is invalid", .ja: "コンピュートポイントデータが不正です",
            .fr: "Données de points de calcul invalides", .ru: "Некорректные баллы вычислений",
        ],
        "系统繁忙": [
            .zh: "系统繁忙", .en: "System busy", .ja: "システム混雑中",
            .fr: "Système occupé", .ru: "Система занята",
        ],
        "累计调用量": [
            .zh: "累计调用量", .en: "Lifetime calls", .ja: "累計呼び出し",
            .fr: "Appels cumulés", .ru: "Всего вызовов",
        ],
        "网络错误": [
            .zh: "网络错误", .en: "Network error", .ja: "ネットワークエラー",
            .fr: "Erreur réseau", .ru: "Ошибка сети",
        ],
        "自动": [
            .zh: "自动", .en: "Auto", .ja: "自動",
            .fr: "Auto", .ru: "Авто",
        ],
        "视频赠送": [
            .zh: "视频赠送", .en: "Video bonus", .ja: "動画ボーナス",
            .fr: "Bonus vidéo", .ru: "Бонус видео",
        ],
        "计费时段": [
            .zh: "计费时段", .en: "Billing window", .ja: "課金時間帯",
            .fr: "Fenêtre tarifaire", .ru: "Тарифное окно",
        ],
        "订阅积分": [
            .zh: "订阅积分", .en: "Subscription credits", .ja: "サブスククレジット",
            .fr: "Crédits d'abonnement", .ru: "Кредиты подписки",
        ],
        "证书不受信任": [
            .zh: "证书不受信任", .en: "Untrusted certificate", .ja: "証明書が信頼できません",
            .fr: "Certificat non fiable", .ru: "Сертификат не доверен",
        ],
        "语音合成": [
            .zh: "语音合成", .en: "Speech synthesis", .ja: "音声合成",
            .fr: "Synthèse vocale", .ru: "Синтез речи",
        ],
        "请求上限": [
            .zh: "请求上限", .en: "Request limit", .ja: "リクエスト上限",
            .fr: "Plafond de requêtes", .ru: "Лимит запросов",
        ],
        "请求超时": [
            .zh: "请求超时", .en: "Request timed out", .ja: "タイムアウト",
            .fr: "Délai dépassé", .ru: "Тайм-аут",
        ],
        "购买额度": [
            .zh: "购买额度", .en: "Purchased quota", .ja: "購入枠",
            .fr: "Quota acheté", .ru: "Купленная квота",
        ],
        "赠送": [
            .zh: "赠送", .en: "Bonus", .ja: "ボーナス",
            .fr: "Bonus", .ru: "Бонус",
        ],
        "赠送积分": [
            .zh: "赠送积分", .en: "Bonus credits", .ja: "ボーナスクレジット",
            .fr: "Crédits bonus", .ru: "Бонусные кредиты",
        ],
        "赠送额度": [
            .zh: "赠送额度", .en: "Bonus quota", .ja: "ボーナス枠",
            .fr: "Quota bonus", .ru: "Бонусная квота",
        ],
        "超时": [
            .zh: "超时", .en: "Timed out", .ja: "タイムアウト",
            .fr: "Expiré", .ru: "Тайм-аут",
        ],
        "近 30 天": [
            .zh: "近 30 天", .en: "Last 30 days", .ja: "過去30日",
            .fr: "30 derniers jours", .ru: "За 30 дней",
        ],
        "近 30 天 tokens": [
            .zh: "近 30 天 tokens", .en: "Tokens (30 days)", .ja: "30日のトークン",
            .fr: "Tokens (30 j)", .ru: "Токены за 30 дней",
        ],
        "近 30 天消费": [
            .zh: "近 30 天消费", .en: "Spend (30 days)", .ja: "30日の消費",
            .fr: "Dépense (30 j)", .ru: "Траты за 30 дней",
        ],
        "近 30 天调用量": [
            .zh: "近 30 天调用量", .en: "Calls (30 days)", .ja: "30日の呼び出し",
            .fr: "Appels (30 j)", .ru: "Вызовы за 30 дней",
        ],
        "近 7 天": [
            .zh: "近 7 天", .en: "Last 7 days", .ja: "過去7日",
            .fr: "7 derniers jours", .ru: "За 7 дней",
        ],
        "近 7 天 Token": [
            .zh: "近 7 天 Token", .en: "Tokens (7 days)", .ja: "7日間のトークン",
            .fr: "Jetons (7 j)", .ru: "Токены за 7 дней",
        ],
        "近 7 天调用量": [
            .zh: "近 7 天调用量", .en: "Calls (7 days)", .ja: "7日の呼び出し",
            .fr: "Appels (7 j)", .ru: "Вызовы за 7 дней",
        ],
        "配额": [
            .zh: "配额", .en: "Quota", .ja: "クォータ",
            .fr: "Quota", .ru: "Квота",
        ],
        "配额数据异常": [
            .zh: "配额数据异常", .en: "Quota data is invalid", .ja: "クォータデータが不正です",
            .fr: "Données de quota invalides", .ru: "Некорректные данные квоты",
        ],
        "音乐生成": [
            .zh: "音乐生成", .en: "Music generation", .ja: "音楽生成",
            .fr: "Génération musicale", .ru: "Генерация музыки",
        ],
        "频限明细": [
            .zh: "频限明细", .en: "Rate-limit details", .ja: "レート制限",
            .fr: "Détail du quota", .ru: "Лимит частоты",
        ],
        "账期结束": [
            .zh: "账期结束", .en: "Period end", .ja: "期間終了",
            .fr: "Fin de période", .ru: "Конец периода",
        ],
        "额度上限": [
            .zh: "额度上限", .en: "Quota limit", .ja: "枠上限",
            .fr: "Plafond de quota", .ru: "Лимит квоты",
        ],
        "额度数据异常": [
            .zh: "额度数据异常", .en: "Quota data is invalid", .ja: "枠データが不正です",
            .fr: "Données de quota invalides", .ru: "Некорректные данные квоты",
        ],
        "限额": [
            .zh: "限额", .en: "Limit", .ja: "上限",
            .fr: "Limite", .ru: "Лимит",
        ],
        "附加 %d": [
            .zh: "附加 %d", .en: "Extra %d", .ja: "追加 %d",
            .fr: "Extra %d", .ru: "Доп. %d",
        ],
        "状态": [
            .zh: "状态", .en: "Status", .ja: "状態",
            .fr: "État", .ru: "Статус",
        ],
        "高峰 1x": [
            .zh: "高峰 1x", .en: "Peak 1x", .ja: "ピーク 1x",
            .fr: "Heure de pointe 1x", .ru: "Пик 1x",
        ],
        "（超额）": [
            .zh: "（超额）", .en: " (overage)", .ja: "（超過）",
            .fr: " (dépassement)", .ru: " (сверх лимита)",
        ],
        "（积分）": [
            .zh: "（积分）", .en: " (credits)", .ja: "（クレジット）",
            .fr: " (crédits)", .ru: " (кредиты)",
        ],
    ]
}

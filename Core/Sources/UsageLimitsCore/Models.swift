import Foundation

/// 支持的 AI 服务商。
public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case openai
    case grok
    case cursor
    case deepseek
    case zhipu
    case kimi
    case minimax
    case jimeng
    case opencode
    case longcat
    case mimo
    case qoder
    case perplexity
    case augment
    case abacus
    case t3chat
    case notion
    case ollama
    case stepfun
    case copilot
    case gemini
    case antigravity
    case kiro
    case minimaxGlobal = "minimax_global"

    public var id: String { rawValue }

    /// 产品 / 模型线名称，首页、小组件、分享图用。
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "ChatGPT"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .deepseek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .jimeng: return "即梦"
        case .opencode: return "OpenCode"
        case .longcat: return "LongCat"
        case .mimo: return "MiMo"
        case .qoder: return "Qoder"
        case .perplexity: return "Perplexity"
        case .augment: return "Augment"
        case .abacus: return "Abacus AI"
        case .t3chat: return "T3 Chat"
        case .notion: return "Notion AI"
        case .ollama: return "Ollama"
        case .stepfun: return "StepFun"
        case .copilot: return "Copilot"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .kiro: return "Kiro"
        case .minimaxGlobal: return "MiniMax 国际"
        }
    }

    /// 供应商（公司）名称，设置 / 提醒下拉用。与产品名区分：Claude→Anthropic，ChatGPT→OpenAI。
    public var vendorName: String {
        switch self {
        case .claude: return "Anthropic"
        case .openai: return "OpenAI"
        case .grok: return "xAI"
        case .cursor: return "Cursor"
        case .deepseek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .jimeng: return "剪映 / 字节"
        case .opencode: return "OpenCode"
        case .longcat: return "美团"
        case .mimo: return "小米"
        case .qoder: return "阿里 Qoder"
        case .perplexity: return "Perplexity"
        case .augment: return "Augment Code"
        case .abacus: return "Abacus.AI"
        case .t3chat: return "T3 Tools"
        case .notion: return "Notion"
        case .ollama: return "Ollama Cloud"
        case .stepfun: return "阶跃星辰"
        case .copilot: return "GitHub"
        case .gemini: return "Google"
        case .antigravity: return "Google"
        case .kiro: return "AWS"
        case .minimaxGlobal: return "MiniMax"
        }
    }

    /// 界面语言下的产品名。缺键时回落 `displayName`（中文品牌名保持不变）。
    public func localizedName(_ language: AppLanguage) -> String {
        let key = "provider.name.\(rawValue)"
        let value = L10n.tr(key, language)
        return value == key ? displayName : value
    }

    /// 界面语言下的供应商名。缺键时回落 `vendorName`。
    public func localizedVendor(_ language: AppLanguage) -> String {
        let key = "provider.vendor.\(rawValue)"
        let value = L10n.tr(key, language)
        return value == key ? vendorName : value
    }

    /// Asset catalog 里的纯图形商标名（无文字）。
    public var logoAssetName: String {
        switch self {
        case .claude: return "LogoClaude"
        case .openai: return "LogoOpenAI"
        case .grok: return "LogoGrok"
        case .cursor: return "LogoCursor"
        case .deepseek: return "LogoDeepSeek"
        case .zhipu: return "LogoZhipu"
        case .kimi: return "LogoKimi"
        case .minimax: return "LogoMiniMax"
        case .jimeng: return "LogoJimeng"
        case .opencode: return "LogoOpenCode"
        case .longcat: return "LogoLongCat"
        case .mimo: return "LogoMiMo"
        case .qoder: return "LogoQoder"
        case .perplexity: return "LogoPerplexity"
        case .augment: return "LogoAugment"
        case .abacus: return "LogoAbacus"
        case .t3chat: return "LogoT3Chat"
        case .notion: return "LogoNotion"
        case .ollama: return "LogoOllama"
        case .stepfun: return "LogoStepFun"
        case .copilot: return "LogoCopilot"
        case .gemini: return "LogoGemini"
        case .antigravity: return "LogoAntigravity"
        case .kiro: return "LogoKiro"
        case .minimaxGlobal: return "LogoMiniMaxGlobal"
        }
    }

    /// 站点源（探针 fetch 的执行上下文，也是 Cookie 的归属站点）。
    public var origin: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai")!
        case .openai: return URL(string: "https://chatgpt.com")!
        case .grok: return URL(string: "https://grok.com")!
        case .cursor: return URL(string: "https://cursor.com")!
        case .deepseek: return URL(string: "https://platform.deepseek.com")!
        case .zhipu: return URL(string: "https://open.bigmodel.cn")!
        case .kimi: return URL(string: "https://www.kimi.com")!
        case .minimax: return URL(string: "https://platform.minimaxi.com")!
        case .jimeng: return URL(string: "https://jimeng.jianying.com")!
        case .opencode: return URL(string: "https://opencode.ai")!
        case .longcat: return URL(string: "https://longcat.chat")!
        case .mimo: return URL(string: "https://platform.xiaomimimo.com")!
        case .qoder: return URL(string: "https://qoder.com")!
        case .perplexity: return URL(string: "https://www.perplexity.ai")!
        case .augment: return URL(string: "https://app.augmentcode.com")!
        case .abacus: return URL(string: "https://apps.abacus.ai")!
        case .t3chat: return URL(string: "https://t3.chat")!
        case .notion: return URL(string: "https://app.notion.com")!
        case .ollama: return URL(string: "https://ollama.com")!
        case .stepfun: return URL(string: "https://platform.stepfun.com")!
        case .copilot: return URL(string: "https://github.com")!
        case .gemini: return URL(string: "https://gemini.google.com")!
        case .antigravity: return URL(string: "https://antigravity.google")!
        case .kiro: return URL(string: "https://app.kiro.dev")!
        case .minimaxGlobal: return URL(string: "https://platform.minimax.io")!
        }
    }

    /// 登录入口页。
    public var loginURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/login")!
        case .openai: return URL(string: "https://chatgpt.com/auth/login")!
        case .grok: return URL(string: "https://grok.com/")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .zhipu: return URL(string: "https://open.bigmodel.cn/coding-plan/personal/usage")!
        case .kimi: return URL(string: "https://www.kimi.com/code")!
        case .minimax: return URL(string: "https://platform.minimaxi.com/console/usage")!
        case .jimeng: return URL(string: "https://jimeng.jianying.com/ai-tool/home")!
        case .opencode: return URL(string: "https://opencode.ai/auth")!
        case .longcat: return URL(string: "https://longcat.chat/platform/usage")!
        case .mimo: return URL(string: "https://platform.xiaomimimo.com/#/console/balance")!
        case .qoder: return URL(string: "https://qoder.com/account/usage")!
        case .perplexity: return URL(string: "https://www.perplexity.ai/account/usage")!
        case .augment: return URL(string: "https://app.augmentcode.com")!
        case .abacus: return URL(string: "https://apps.abacus.ai/")!
        case .t3chat: return URL(string: "https://t3.chat/settings/subscription")!
        case .notion: return URL(string: "https://app.notion.com/")!
        case .ollama: return URL(string: "https://ollama.com/signin")!
        case .stepfun: return URL(string: "https://platform.stepfun.com/plan-usage")!
        case .copilot: return URL(string: "https://github.com/login")!
        case .gemini: return URL(string: "https://gemini.google.com/app")!
        case .antigravity: return URL(string: "https://antigravity.google/")!
        case .kiro: return URL(string: "https://app.kiro.dev/")!
        case .minimaxGlobal: return URL(string: "https://platform.minimax.io/console/usage")!
        }
    }

    /// 探针执行前加载的页面。必须保证最终停留在 API 同源上。
    public var probeURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/login")!
        case .openai: return URL(string: "https://chatgpt.com/")!
        case .grok: return URL(string: "https://grok.com/")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .zhipu: return URL(string: "https://open.bigmodel.cn/coding-plan/personal/usage")!
        case .kimi: return URL(string: "https://www.kimi.com/code/console")!
        case .minimax: return URL(string: "https://platform.minimaxi.com/console/usage")!
        case .jimeng: return URL(string: "https://jimeng.jianying.com/ai-tool/home")!
        case .opencode: return URL(string: "https://opencode.ai/auth")!
        case .longcat: return URL(string: "https://longcat.chat/platform/usage")!
        case .mimo: return URL(string: "https://platform.xiaomimimo.com/#/console/balance")!
        case .qoder: return URL(string: "https://qoder.com/account/usage")!
        case .perplexity: return URL(string: "https://www.perplexity.ai/account/usage")!
        case .augment: return URL(string: "https://app.augmentcode.com/account/subscription")!
        case .abacus: return URL(string: "https://apps.abacus.ai/")!
        case .t3chat: return URL(string: "https://t3.chat/settings/subscription")!
        case .notion: return URL(string: "https://app.notion.com/")!
        case .ollama: return URL(string: "https://ollama.com/settings")!
        case .stepfun: return URL(string: "https://platform.stepfun.com/plan-usage")!
        case .copilot: return URL(string: "https://github.com/settings/copilot")!
        case .gemini: return URL(string: "https://gemini.google.com/app")!
        case .antigravity: return URL(string: "https://antigravity.google/")!
        case .kiro: return URL(string: "https://app.kiro.dev/")!
        case .minimaxGlobal: return URL(string: "https://platform.minimax.io/console/usage")!
        }
    }

    public var cookieDomains: [String] {
        switch self {
        case .claude: return ["claude.ai"]
        case .openai: return ["chatgpt.com", "openai.com"]
        case .grok: return ["grok.com", "x.ai"]
        case .cursor: return ["cursor.com", "cursor.sh"]
        case .deepseek: return ["deepseek.com"]
        case .zhipu: return ["bigmodel.cn"]
        case .kimi: return ["kimi.com", "moonshot.cn"]
        case .minimax: return ["minimaxi.com"]
        case .jimeng: return ["jimeng.jianying.com", "jianying.com"]
        case .opencode: return ["opencode.ai"]
        case .longcat: return ["longcat.chat"]
        case .mimo: return ["xiaomimimo.com"]
        case .qoder: return ["qoder.com", "qoder.com.cn"]
        case .perplexity: return ["perplexity.ai"]
        case .augment: return ["augmentcode.com"]
        case .abacus: return ["abacus.ai"]
        case .t3chat: return ["t3.chat"]
        case .notion: return ["notion.com", "notion.so"]
        case .ollama: return ["ollama.com"]
        case .stepfun: return ["stepfun.com"]
        case .copilot: return ["github.com"]
        case .gemini: return ["gemini.google.com", "google.com"]
        case .antigravity: return ["antigravity.google", "google.com"]
        case .kiro: return ["kiro.dev"]
        case .minimaxGlobal: return ["minimax.io"]
        }
    }
}

/// 时间序列上的一个点（DeepSeek 消耗图、智谱/MiniMax 调用趋势）。
public struct UsagePoint: Codable, Equatable, Sendable {
    public var at: Date
    public var value: Double

    public init(at: Date, value: Double) {
        self.at = at
        self.value = value
    }
}

/// 即梦等积分流水的一条（金额为绝对值，正负看 `historyType`）。
public struct CreditLedgerEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// 官网 `amount`：积分绝对值，恒为非负。
    public var amount: Double
    /// `1` 获得 / `2` 消耗。其它值解析时丢弃。
    public var historyType: Int
    public var createdAt: Date
    public var extraContent: String?

    public init(
        id: String,
        title: String,
        amount: Double,
        historyType: Int,
        createdAt: Date,
        extraContent: String? = nil
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.historyType = historyType
        self.createdAt = createdAt
        self.extraContent = extraContent
    }

    public var isGain: Bool { historyType == 1 }

    public var signedAmount: Double { isGain ? amount : -abs(amount) }
}

/// DeepSeek 时间维度 / API Key 维度的一组消耗数字。
public struct UsageBreakdown: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var cost: Double?
    public var requests: Double?
    public var tokens: Double?
    public var series: [UsagePoint]
    /// DeepSeek API Key 最后使用时间；用于倒序排列。
    public var lastUsed: Date?
    /// DeepSeek 缓存命中 / 未命中 / 输出 token（模型维度）。
    public var cacheHitTokens: Double?
    public var cacheMissTokens: Double?
    public var outputTokens: Double?

    public init(
        id: String,
        label: String,
        cost: Double? = nil,
        requests: Double? = nil,
        tokens: Double? = nil,
        series: [UsagePoint] = [],
        lastUsed: Date? = nil,
        cacheHitTokens: Double? = nil,
        cacheMissTokens: Double? = nil,
        outputTokens: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.cost = cost
        self.requests = requests
        self.tokens = tokens
        self.series = series
        self.lastUsed = lastUsed
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.outputTokens = outputTokens
    }

    var persistenceValidationIssue: String? {
        for (name, value) in [
            ("cost", cost), ("requests", requests), ("tokens", tokens),
            ("cacheHitTokens", cacheHitTokens), ("cacheMissTokens", cacheMissTokens),
            ("outputTokens", outputTokens),
        ] {
            if let value, !value.isFinite { return "breakdown.\(name)" }
        }
        if let lastUsed, !JSONHelp.isSafeDate(lastUsed) { return "breakdown.lastUsed" }
        for point in series {
            if !point.value.isFinite { return "breakdown.series" }
            if !JSONHelp.isSafeDate(point.at) { return "breakdown.series.at" }
        }
        return nil
    }
}

/// 单条用量指标（一个限额窗口或订阅状态）。
public struct UsageMetric: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// 已用百分比，0...100。
    public var usedPercent: Double?
    /// 剩余次数（Grok 这类按次计的额度）。
    public var remaining: Double?
    public var total: Double?
    /// 额度重置/订阅到期时间。
    public var resetsAt: Date?
    public var detail: String?
    /// 非百分比数值（金额、token、次数）。DeepSeek 折叠两金额走这里。
    public var amount: Double?
    /// 金额币种（如 CNY / USD）；非金额可空。
    public var currency: String?
    /// 官网主用量窗口：即使 0% 也要展示（如 MiniMax 5h / 周限额 / 视频赠送）。
    public var pinned: Bool?
    /// 官网原样数值（如 MiniMax 5h「0%/100%」），优先于剩次数 / 单百分比。
    public var displayValue: String?
    /// 自定义字段的语义角色（`CustomFieldRole.rawValue`），只供自定义卡展示层用；内置服务商为空。
    public var kind: String?

    public init(
        id: String,
        label: String,
        usedPercent: Double? = nil,
        remaining: Double? = nil,
        total: Double? = nil,
        resetsAt: Date? = nil,
        detail: String? = nil,
        amount: Double? = nil,
        currency: String? = nil,
        pinned: Bool? = nil,
        displayValue: String? = nil,
        kind: String? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.remaining = remaining
        self.total = total
        self.resetsAt = resetsAt
        self.detail = detail
        self.amount = amount
        self.currency = currency
        self.pinned = pinned
        self.displayValue = displayValue
        self.kind = kind
    }

    /// 是否有实际用量。0% / 剩余额度未动 / 无任何数值的指标视为「未使用」，
    /// 首页默认不展示（避免堆满 0% 进度条）。官网钉住的窗口除外。
    public var hasUsage: Bool {
        if pinned == true { return true }
        if let percent = usedPercent, percent > 0 { return true }
        if let remaining, let total, total > 0, remaining < total { return true }
        if let amount, amount > 0 { return true }
        return false
    }

    var persistenceValidationIssue: String? {
        if let usedPercent {
            if !usedPercent.isFinite { return "metric.usedPercent" }
            if usedPercent < 0 || usedPercent > 100 { return "metric.usedPercent.range" }
        }
        for (name, value) in [("remaining", remaining), ("total", total), ("amount", amount)] {
            if let value, !value.isFinite { return "metric.\(name)" }
        }
        if let resetsAt, !JSONHelp.isSafeDate(resetsAt) { return "metric.resetsAt" }
        return nil
    }
}

/// 订阅计费周期。展开卡片在金额前展示「月」或「年」。
public enum BillingCycle: String, Codable, Sendable {
    case monthly
    case quarterly
    case yearly

    /// 展开行金额前的短标签：月度→月，季度→季，年度→年。
    public var tag: String {
        switch self {
        case .monthly: return "月"
        case .quarterly: return "季"
        case .yearly: return "年"
        }
    }

    /// 从接口字段 / 套餐名解析周期（annually、TIME_UNIT_YEAR、年度会员、包年计划 等）。
    /// 先认年再认月，避免「年度」被漏掉。
    public static func parse(_ raw: String?) -> BillingCycle? {
        guard let raw, !raw.isEmpty else { return nil }
        let s = raw.lowercased()
        if s.contains("year") || s.contains("annual") || s.contains("年") { return .yearly }
        if s.contains("quarter") || s.contains("季") { return .quarterly }
        if s.contains("month") || s.contains("月") { return .monthly }
        return nil
    }

    /// 显式字段优先；否则用账期起止跨度（≥300 天为年，≥80 天为季）。
    public static func resolve(
        explicit: BillingCycle?,
        periodStart: Date? = nil,
        periodEnd: Date? = nil
    ) -> BillingCycle? {
        if let explicit { return explicit }
        if let start = periodStart, let end = periodEnd {
            let days = end.timeIntervalSince(start) / 86_400
            if days >= 300 { return .yearly }
            if days >= 80 { return .quarterly }
            if days > 0 { return .monthly }
        }
        return nil
    }
}

/// 快照状态。
public enum SnapshotStatus: Codable, Equatable, Sendable {
    case ok
    case needsLogin
    case error(String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var isNeedsLogin: Bool {
        if case .needsLogin = self { return true }
        return false
    }

    /// 界面展示：已知错误键走 L10n，未知原文（如 `HTTP 503`）原样返回。
    public func displayText(_ language: AppLanguage) -> String {
        switch self {
        case .ok:
            return ""
        case .needsLogin:
            return L10n.tr("card.notLoggedIn", language)
        case .error(let raw):
            return L10n.trError(raw, language)
        }
    }

    /// 已登录无额度 / 失败 / 未登录的空态文案。即梦会话在、积分未到时调用方把 okKey 换成 jimeng.creditsUnavailable。
    public func emptyUsageCaption(language: AppLanguage, okKey: String = "card.noNumeric") -> String {
        switch self {
        case .ok:
            return L10n.tr(okKey, language)
        case .needsLogin:
            return L10n.tr("card.notLoggedIn", language)
        case .error:
            let text = displayText(language)
            return text.isEmpty ? L10n.tr("card.notLoggedIn", language) : text
        }
    }
}

/// 某个服务商在某一时刻的用量快照。只含用量数字，不含任何凭据。
public struct ProviderSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var planName: String?
    public var metrics: [UsageMetric]
    public var fetchedAt: Date
    public var status: SnapshotStatus
    /// 站点在未登录时也返回了游客额度（如 grok.com），数据有效但非订阅套餐。
    public var isAnonymous: Bool?
    /// 订阅计费来源："app_store" 表示 iOS 内购（标价高于官网，如 Max 20x $249.99 vs $200）。
    /// nil 表示未知/官网价。
    public var billingSource: String?
    /// 月付 / 年付。有标价的付费套餐应填；预充值、免费、游客为 nil。
    public var billingCycle: BillingCycle?
    /// 智谱等官网商品 ID（如 product-733034），用于按 SKU 取周期和标价。
    public var planProductID: String?
    /// 套餐到期/下次续费时间（到期提醒用）。仅部分服务商的接口可证实，拿不到为 nil。
    public var planExpiresAt: Date?
    /// 预充值类服务商的币种（DeepSeek 为 CNY/USD）。
    public var currency: String?
    /// DeepSeek 官网时间维度（今天 / 昨天 / 近 7 天 / 近 30 天 / 本月 / 上月）。
    public var timeBreakdowns: [UsageBreakdown]?
    /// DeepSeek 按 API Key 的请求次数 / 消耗金额 / tokens。
    public var keyBreakdowns: [UsageBreakdown]?
    /// 即梦近 1 个月积分流水（首页展开列表；折叠不展示）。
    public var creditHistory: [CreditLedgerEntry]?
    /// DeepSeek 按模型的消耗（缓存命中 / 输出 token）。
    public var modelBreakdowns: [UsageBreakdown]?
    /// 自定义用量快照。`provider` 编码占位固定为 `.claude`，不得用于品牌 / 预充值卡 / 提醒档。
    public var isCustom: Bool

    public var id: String { provider.rawValue }

    public init(
        provider: ProviderID,
        planName: String? = nil,
        metrics: [UsageMetric] = [],
        fetchedAt: Date,
        status: SnapshotStatus,
        isAnonymous: Bool? = nil,
        billingSource: String? = nil,
        billingCycle: BillingCycle? = nil,
        planProductID: String? = nil,
        planExpiresAt: Date? = nil,
        currency: String? = nil,
        timeBreakdowns: [UsageBreakdown]? = nil,
        keyBreakdowns: [UsageBreakdown]? = nil,
        creditHistory: [CreditLedgerEntry]? = nil,
        modelBreakdowns: [UsageBreakdown]? = nil,
        isCustom: Bool = false
    ) {
        self.provider = provider
        self.planName = planName
        self.metrics = metrics
        self.fetchedAt = fetchedAt
        self.status = status
        self.isAnonymous = isAnonymous
        self.billingSource = billingSource
        self.billingCycle = billingCycle
        self.planProductID = planProductID
        self.planExpiresAt = planExpiresAt
        self.currency = currency
        self.timeBreakdowns = timeBreakdowns
        self.keyBreakdowns = keyBreakdowns
        self.creditHistory = creditHistory
        self.modelBreakdowns = modelBreakdowns
        self.isCustom = isCustom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        metrics = try container.decode([UsageMetric].self, forKey: .metrics)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        status = try container.decode(SnapshotStatus.self, forKey: .status)
        isAnonymous = try container.decodeIfPresent(Bool.self, forKey: .isAnonymous)
        billingSource = try container.decodeIfPresent(String.self, forKey: .billingSource)
        billingCycle = try container.decodeIfPresent(BillingCycle.self, forKey: .billingCycle)
        planProductID = try container.decodeIfPresent(String.self, forKey: .planProductID)
        planExpiresAt = try container.decodeIfPresent(Date.self, forKey: .planExpiresAt)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        timeBreakdowns = try container.decodeIfPresent([UsageBreakdown].self, forKey: .timeBreakdowns)
        keyBreakdowns = try container.decodeIfPresent([UsageBreakdown].self, forKey: .keyBreakdowns)
        creditHistory = try container.decodeIfPresent([CreditLedgerEntry].self, forKey: .creditHistory)
        modelBreakdowns = try container.decodeIfPresent([UsageBreakdown].self, forKey: .modelBreakdowns)
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(planName, forKey: .planName)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(isAnonymous, forKey: .isAnonymous)
        try container.encodeIfPresent(billingSource, forKey: .billingSource)
        try container.encodeIfPresent(billingCycle, forKey: .billingCycle)
        try container.encodeIfPresent(planProductID, forKey: .planProductID)
        try container.encodeIfPresent(planExpiresAt, forKey: .planExpiresAt)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encodeIfPresent(timeBreakdowns, forKey: .timeBreakdowns)
        try container.encodeIfPresent(keyBreakdowns, forKey: .keyBreakdowns)
        try container.encodeIfPresent(creditHistory, forKey: .creditHistory)
        try container.encodeIfPresent(modelBreakdowns, forKey: .modelBreakdowns)
        try container.encode(isCustom, forKey: .isCustom)
    }

    private enum CodingKeys: String, CodingKey {
        case provider, planName, metrics, fetchedAt, status
        case isAnonymous, billingSource, billingCycle, planProductID, planExpiresAt
        case currency, timeBreakdowns, keyBreakdowns, creditHistory, modelBreakdowns, isCustom
    }

    /// 落盘前的数字 / 日期闸门。越界百分比、非有限金额、不安全日期一律拒绝。
    public var persistenceValidationIssue: String? {
        if !JSONHelp.isSafeDate(fetchedAt) { return "fetchedAt" }
        if let planExpiresAt, !JSONHelp.isSafeDate(planExpiresAt) { return "planExpiresAt" }
        for metric in metrics {
            if let issue = metric.persistenceValidationIssue { return issue }
        }
        for list in [timeBreakdowns, keyBreakdowns, modelBreakdowns] {
            if let list {
                for item in list {
                    if let issue = item.persistenceValidationIssue { return issue }
                }
            }
        }
        if let creditHistory {
            for entry in creditHistory {
                if !entry.amount.isFinite { return "creditHistory.amount" }
                if !JSONHelp.isSafeDate(entry.createdAt) { return "creditHistory.createdAt" }
            }
        }
        return nil
    }

    /// DeepSeek 预充值卡：折叠只画两个金额，展开画时间维度 + API Key 图表。
    /// 自定义快照即使占位 `.deepseek` 也不得走这条。
    public var isPrepaidCard: Bool { provider == .deepseek && !isCustom }

    /// 展示优先级最高的指标（折叠卡片摘要与小组件 2x2 用）：
    /// 优先取有实际用量的百分比指标，其次任何百分比指标，最后兜底第一条。
    public var primaryMetric: UsageMetric? {
        metrics.first { $0.hasUsage && $0.usedPercent != nil }
            ?? metrics.first { $0.usedPercent != nil }
            ?? metrics.first
    }

    /// 有实际用量的指标（首页展开态默认只画这些）。
    public var activeMetrics: [UsageMetric] {
        metrics.filter(\.hasUsage)
    }

    /// 折叠卡片摘要与 2×2：展开态同一份可见列表的第一位（已套用用户计量顺序）。
    public var collapsedMetric: UsageMetric? {
        activeMetrics.first ?? metrics.first
    }

    /// 折叠卡片按布局露出前 `limit` 条有用量的指标（平铺 1 条、轮盘 / 螺旋 2 条）；
    /// 没有任何有用量的指标时仍兜底第一条，与 `collapsedMetric` 口径一致。
    public func collapsedMetrics(limit: Int) -> [UsageMetric] {
        let active = activeMetrics
        guard !active.isEmpty else { return metrics.first.map { [$0] } ?? [] }
        return Array(active.prefix(max(1, limit)))
    }

    /// 折叠卡片摘要用：重置时间最远（窗口时长最大）的指标，一般即周额度。
    /// 并列时取列表中靠前的一条（各解析器都把总量级指标排在细分之前）；
    /// 没有任何带重置时间的百分比指标时，回退周总量 / 主指标。
    public var longestWindowMetric: UsageMetric? {
        let candidates = metrics.filter { $0.usedPercent != nil && $0.resetsAt != nil }
        guard let farthest = candidates.compactMap(\.resetsAt).max() else {
            return weeklySummaryMetric ?? primaryMetric
        }
        return candidates.first { $0.resetsAt == farthest }
    }

    /// 总览小组件（2×4）用：每家只画一条「周 / 计费周期」级别的总量。
    /// 按各家周口径的 id 优先取，缺失时回退主指标。
    public var weeklySummaryMetric: UsageMetric? {
        for id in ["seven_day", "weekly", "secondary", "cursor_models", "included", "five_hour", "tokens_limit", "remaining"] {
            if let m = metrics.first(where: { $0.id == id && $0.usedPercent != nil }) { return m }
        }
        return primaryMetric
    }
}

/// 一次探针请求的原始结果。status <= 0 表示网络层失败（body 为错误描述）。
public struct ProbeResult: Codable, Equatable, Sendable {
    public var status: Int
    public var body: String
    /// 响应头（小写或原样皆可）。只用于 grpc-status / Vercel 风控等判定，不落盘凭据。
    public var headers: [String: String]?

    public init(status: Int, body: String, headers: [String: String]? = nil) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public var isOK: Bool { (200..<300).contains(status) }

    /// 401 / 403：会话失效，应提示重新登录。
    public var isUnauthorized: Bool { status == 401 || status == 403 }

    /// 探针失败如何进快照：凭据失效 → `needsLogin`；有 HTTP 码 → `HTTP N`；
    /// `-3` 超时；其余网络 / 脚本失败不当成退出登录。
    public var failureStatus: SnapshotStatus {
        if isUnauthorized { return .needsLogin }
        if status > 0 { return .error("HTTP \(status)") }
        if status == -3 { return .error("请求超时") }
        return .error("网络错误")
    }
}

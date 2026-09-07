import Foundation

/// 自定义用量的 Bearer 预设：只预填 URL 与字段，不新增 `ProviderID`。
/// 向导仍必须现场测通后才能保存。
public struct CustomUsagePreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var requestURL: String
    public var fields: [CustomUsageField]
    public var experimental: Bool

    public init(
        id: String,
        name: String,
        requestURL: String,
        fields: [CustomUsageField],
        experimental: Bool = false
    ) {
        self.id = id
        self.name = name
        self.requestURL = requestURL
        self.fields = fields
        self.experimental = experimental
    }

    /// 加号页商标。Kimi 两站复用官方 Kimi 标；其余各有独立 imageset。
    public var logoAssetName: String {
        switch id {
        case "kimi-api-intl", "kimi-api-cn": return "LogoKimi"
        case "crof": return "LogoCrof"
        case "poe": return "LogoPoe"
        case "openrouter-key": return "LogoOpenRouter"
        default: return "LogoKimi"
        }
    }

    public func localizedName(_ language: AppLanguage) -> String {
        let key = "custom.preset.\(id).name"
        let value = L10n.tr(key, language)
        return value == key ? name : value
    }

    public func localizedFieldName(path: String, language: AppLanguage) -> String {
        let slug = path.replacingOccurrences(of: ".", with: "_")
        let key = "custom.preset.\(id).field.\(slug)"
        let value = L10n.tr(key, language)
        if value != key { return value }
        if let displayName = fields.first(where: { $0.path == path })?.displayName {
            let translated = L10n.tr(displayName, language)
            return translated == displayName ? displayName : translated
        }
        return CustomUsageTemplate.defaultDisplayName(for: path)
    }

    public static let all: [CustomUsagePreset] = [
        CustomUsagePreset(
            id: "kimi-api-intl",
            name: "Kimi API",
            requestURL: "https://api.moonshot.ai/v1/users/me/balance",
            fields: [
                CustomUsageField(path: "data.available_balance", displayName: "可用余额", role: .remaining, currency: "USD"),
                CustomUsageField(path: "data.cash_balance", displayName: "现金余额", role: .remaining, currency: "USD"),
                CustomUsageField(path: "data.voucher_balance", displayName: "代金券", role: .remaining, currency: "USD"),
            ]
        ),
        CustomUsagePreset(
            id: "kimi-api-cn",
            name: "Kimi API 中国站",
            requestURL: "https://api.moonshot.cn/v1/users/me/balance",
            fields: [
                CustomUsageField(path: "data.available_balance", displayName: "可用余额", role: .remaining, currency: "CNY"),
                CustomUsageField(path: "data.cash_balance", displayName: "现金余额", role: .remaining, currency: "CNY"),
                CustomUsageField(path: "data.voucher_balance", displayName: "代金券", role: .remaining, currency: "CNY"),
            ]
        ),
        CustomUsagePreset(
            id: "crof",
            name: "Crof",
            requestURL: "https://crof.ai/usage_api/",
            fields: [
                CustomUsageField(path: "credits", displayName: "积分", role: .remaining, currency: "USD"),
                CustomUsageField(path: "requests_plan", displayName: "请求上限", role: .limit),
                CustomUsageField(path: "usable_requests", displayName: "剩余请求", role: .remaining),
            ],
            experimental: true
        ),
        CustomUsagePreset(
            id: "poe",
            name: "Poe",
            requestURL: "https://api.poe.com/usage/current_balance",
            fields: [
                CustomUsageField(path: "current_point_balance", displayName: "积分余额", role: .remaining),
            ]
        ),
        CustomUsagePreset(
            id: "openrouter-key",
            name: "OpenRouter Key",
            requestURL: "https://openrouter.ai/api/v1/key",
            fields: [
                CustomUsageField(path: "data.usage", displayName: "已用额度", role: .used, currency: "USD"),
                CustomUsageField(path: "data.limit", displayName: "额度上限", role: .limit, currency: "USD"),
                CustomUsageField(path: "data.limit_remaining", displayName: "剩余额度", role: .remaining, currency: "USD"),
            ]
        ),
    ]
}

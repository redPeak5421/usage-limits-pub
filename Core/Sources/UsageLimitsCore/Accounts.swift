import Foundation

/// 账号身份：内置供应商走 `ProviderID`，自定义走模板 UUID。禁止把自定义做成 `ProviderID` case。
public enum AccountSource: Equatable, Sendable {
    case builtin(ProviderID)
    case custom(templateID: UUID)
}

extension AccountSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case provider
        case templateID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "builtin":
            self = .builtin(try container.decode(ProviderID.self, forKey: .provider))
        case "custom":
            self = .custom(templateID: try container.decode(UUID.self, forKey: .templateID))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown AccountSource.kind \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let provider):
            try container.encode("builtin", forKey: .kind)
            try container.encode(provider, forKey: .provider)
        case .custom(let templateID):
            try container.encode("custom", forKey: .kind)
            try container.encode(templateID, forKey: .templateID)
        }
    }
}

/// 手动添加的账号。服务商全部走「手动新增」，没有固定内置列表。
///
/// 每个服务商的**第一个**账号是主账号（`isPrimary == true`）：沿用 `ProviderID`
/// 直连的老链路——default WKWebsiteDataStore、`snapshot.<provider>` 快照键、
/// Widget / Watch / 提醒全部兼容不动；同服务商后续账号是附加账号：
/// 独立 UUID dataStore，快照按 `snapshot.account.<uuid>` 单独存取。
/// 自定义账号 `isPrimary` 恒为 false，只走账号级快照键。
public struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: AccountSource
    /// 用户自定义显示名（首页卡片标题）。
    public var name: String
    public var createdAt: Date
    /// 主账号：走服务商级老链路（default dataStore + provider 快照键 + Widget/Watch）。
    /// 自定义账号恒为 false。
    public var isPrimary: Bool
    /// 停用后配置仍保留，但不进首页/小组件，也不再向官网拉用量。缺省视为启用。
    public var isEnabled: Bool
    /// 账号自定义主题色；nil 回落供应商默认覆盖 → 内置品牌色（TintResolver）。
    public var tint: BrandTint?
    /// 稳定身份指纹（SHA-256 hex）。首次成功解析写入；冲突时不覆盖快照。
    public var identityFingerprint: String?

    /// 内置服务商；自定义账号为 nil。禁止用占位 provider 做品牌判断。
    public var provider: ProviderID? {
        if case .builtin(let providerID) = source { return providerID }
        return nil
    }

    public var isCustom: Bool {
        if case .custom = source { return true }
        return false
    }

    public var templateID: UUID? {
        if case .custom(let templateID) = source { return templateID }
        return nil
    }

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        name: String,
        createdAt: Date = Date(),
        isPrimary: Bool = false,
        isEnabled: Bool = true,
        tint: BrandTint? = nil,
        identityFingerprint: String? = nil
    ) {
        self.init(
            id: id,
            source: .builtin(provider),
            name: name,
            createdAt: createdAt,
            isPrimary: isPrimary,
            isEnabled: isEnabled,
            tint: tint,
            identityFingerprint: identityFingerprint
        )
    }

    public init(
        id: UUID = UUID(),
        source: AccountSource,
        name: String,
        createdAt: Date = Date(),
        isPrimary: Bool = false,
        isEnabled: Bool = true,
        tint: BrandTint? = nil,
        identityFingerprint: String? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.createdAt = createdAt
        if case .custom = source {
            self.isPrimary = false
        } else {
            self.isPrimary = isPrimary
        }
        self.isEnabled = isEnabled
        self.tint = tint
        self.identityFingerprint = identityFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        tint = try container.decodeIfPresent(BrandTint.self, forKey: .tint)
        if let decodedSource = try container.decodeIfPresent(AccountSource.self, forKey: .source) {
            source = decodedSource
        } else {
            let providerID = try container.decode(ProviderID.self, forKey: .provider)
            source = .builtin(providerID)
        }
        if case .custom = source {
            isPrimary = false
        } else {
            isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        }
        identityFingerprint = try container.decodeIfPresent(String.self, forKey: .identityFingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(tint, forKey: .tint)
        try container.encodeIfPresent(identityFingerprint, forKey: .identityFingerprint)
        if case .builtin(let providerID) = source {
            try container.encode(providerID, forKey: .provider)
        }
    }

    /// 名称留空时：内置回退服务商名；自定义回退模板名，禁止回落 Claude/ChatGPT。
    public var displayName: String {
        displayName(templates: [])
    }

    public func displayName(templates: [CustomUsageTemplate] = [], language: AppLanguage = .system) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch source {
        case .builtin(let providerID):
            return providerID.localizedName(language)
        case .custom(let templateID):
            let templateName = templates.first { $0.id == templateID }?.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let templateName, !templateName.isEmpty { return templateName }
            return ""
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case provider
        case name
        case createdAt
        case isPrimary
        case isEnabled
        case tint
        case identityFingerprint
    }
}

/// 账号展示顺序：存储数组即展示顺序，不按服务商重新聚组。
public enum AccountOrder {
    public static func moving(
        _ accounts: [ProviderAccount],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> [ProviderAccount] {
        var next = accounts
        let moving = fromOffsets.sorted().map { next[$0] }
        for index in fromOffsets.sorted().reversed() {
            next.remove(at: index)
        }
        var dest = toOffset
        for index in fromOffsets.sorted() where index < toOffset {
            dest -= 1
        }
        dest = max(0, min(dest, next.count))
        next.insert(contentsOf: moving, at: dest)
        return next
    }

}


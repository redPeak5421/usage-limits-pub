import Foundation

/// 手表自定义账号摘要。不含 token / URL / Authorization。
public struct WatchCustomMetric: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var amount: Double?
    public var currency: String?
    public var displayValue: String?
    public var kind: String?
    public var resetsAt: Date?

    public init(
        id: String,
        label: String,
        amount: Double? = nil,
        currency: String? = nil,
        displayValue: String? = nil,
        kind: String? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.amount = amount
        self.currency = currency
        self.displayValue = displayValue
        self.kind = kind
        self.resetsAt = resetsAt
    }

    /// 重建无提醒语义的展示指标，供手表复用 Core 自定义字段 presenter。
    public var usageMetric: UsageMetric {
        UsageMetric(
            id: id,
            label: label,
            resetsAt: resetsAt,
            amount: amount,
            currency: currency,
            pinned: true,
            displayValue: displayValue,
            kind: kind
        )
    }
}

public struct WatchCustomItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var tint: BrandTint?
    public var metrics: [WatchCustomMetric]
    /// 旧包没有此字段。nil 按已登录无数字处理。
    public var status: SnapshotStatus?

    public init(
        id: UUID,
        title: String,
        tint: BrandTint? = nil,
        metrics: [WatchCustomMetric],
        status: SnapshotStatus? = nil
    ) {
        self.id = id
        self.title = title
        self.tint = tint
        self.metrics = Array(metrics.prefix(WatchCustomPayload.maxMetricsPerItem))
        self.status = status
    }

    /// 失败 / 未登录忽略 leftover 数字；旧包没有 status 时仍展示 metrics。
    public var visibleMetrics: [WatchCustomMetric] {
        if let status, !status.isOK { return [] }
        return metrics
    }
}

/// 手表 applicationContext 的自定义段：超体积时丢最旧项。
public enum WatchCustomPayload {
    /// 给内置主快照留余量；超限丢最旧自定义。
    public static let maxEncodedBytes = 12_000
    public static let maxMetricsPerItem = 8

    public static func items(
        accounts: [ProviderAccount],
        templates: [CustomUsageTemplate],
        snapshot: (UUID) -> ProviderSnapshot?,
        demoMode: Bool
    ) -> [WatchCustomItem] {
        if demoMode { return [] }
        return accounts.compactMap { account in
            guard account.isCustom, account.isEnabled else { return nil }
            let snap = snapshot(account.id)
            let status = snap?.status ?? .needsLogin
            let source = status.isOK ? (snap?.metrics ?? []) : []
            let metrics = source.prefix(maxMetricsPerItem).map {
                WatchCustomMetric(
                    id: $0.id,
                    label: $0.label,
                    amount: $0.amount,
                    currency: $0.currency ?? snap?.currency,
                    displayValue: $0.displayValue,
                    kind: $0.kind,
                    resetsAt: $0.resetsAt
                )
            }
            return WatchCustomItem(
                id: account.id,
                title: account.displayName(templates: templates),
                tint: TintResolver.resolve(
                    accountTint: account.tint,
                    templateTint: account.templateID.flatMap { id in
                        templates.first { $0.id == id }?.tint
                    }
                ),
                metrics: Array(metrics),
                status: status
            )
        }
    }

    public static func encode(
        _ items: [WatchCustomItem],
        encoder: JSONEncoder
    ) -> (data: Data, droppedOldest: Int) {
        var kept = items
        var dropped = 0
        while true {
            guard let data = try? encoder.encode(kept) else {
                return (Data(), items.count)
            }
            if data.count <= maxEncodedBytes || kept.isEmpty {
                return (data, dropped)
            }
            kept.removeFirst()
            dropped += 1
        }
    }

    public static func decode(_ data: Data, decoder: JSONDecoder) -> [WatchCustomItem] {
        (try? decoder.decode([WatchCustomItem].self, from: data)) ?? []
    }
}

/// 手表附加内置账号：独立 WebKit / 快照，不能和主号共用 ProviderID 页。
public struct WatchExtraItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var providerRaw: String
    public var title: String
    public var snapshot: ProviderSnapshot
    public var tint: BrandTint?

    public init(
        id: UUID,
        providerRaw: String,
        title: String,
        snapshot: ProviderSnapshot,
        tint: BrandTint? = nil
    ) {
        self.id = id
        self.providerRaw = providerRaw
        self.title = title
        self.snapshot = snapshot
        self.tint = tint
    }

    public var provider: ProviderID {
        ProviderID(rawValue: providerRaw) ?? .claude
    }
}

/// 手表 applicationContext 的附加内置账号段。不含 token；超体积丢最旧项。
public enum WatchExtraPayload {
    public static let maxEncodedBytes = 16_000
    public static let maxMetricsPerItem = 8

    public static func items(
        accounts: [ProviderAccount],
        snapshot: (UUID) -> ProviderSnapshot?,
        demoMode: Bool,
        tintOverrides: [String: BrandTint] = [:],
        language: AppLanguage = .system
    ) -> [WatchExtraItem] {
        if demoMode { return [] }
        return accounts.compactMap { account in
            guard !account.isCustom, !account.isPrimary else { return nil }
            guard let provider = account.provider else { return nil }
            // 附加账号只看自己的开关（服务商级开关是主账号的），这里不需要再传开关
            guard AccountVisibility.shouldShowOnHome(account, providerEnabled: true) else { return nil }
            let snap = snapshot(account.id) ?? ProviderSnapshot(
                provider: provider, fetchedAt: Date(), status: .needsLogin
            )
            return WatchExtraItem(
                id: account.id,
                providerRaw: provider.rawValue,
                title: account.displayName(language: language),
                snapshot: compact(snap, provider: provider),
                tint: TintResolver.resolve(
                    accountTint: account.tint,
                    provider: provider,
                    overrides: tintOverrides
                )
            )
        }
    }

    public static func encode(
        _ items: [WatchExtraItem],
        encoder: JSONEncoder
    ) -> (data: Data, droppedOldest: Int) {
        var kept = items
        var dropped = 0
        while true {
            guard let data = try? encoder.encode(kept) else {
                return (Data(), items.count)
            }
            if data.count <= maxEncodedBytes || kept.isEmpty {
                return (data, dropped)
            }
            kept.removeFirst()
            dropped += 1
        }
    }

    public static func decode(_ data: Data, decoder: JSONDecoder) -> [WatchExtraItem] {
        (try? decoder.decode([WatchExtraItem].self, from: data)) ?? []
    }

    private static func compact(_ snap: ProviderSnapshot, provider: ProviderID) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: snap.planName,
            metrics: Array(snap.metrics.prefix(maxMetricsPerItem)),
            fetchedAt: snap.fetchedAt,
            status: snap.status,
            isAnonymous: snap.isAnonymous,
            billingSource: snap.billingSource,
            billingCycle: snap.billingCycle,
            planProductID: snap.planProductID,
            planExpiresAt: snap.planExpiresAt,
            currency: snap.currency
        )
    }
}

/// 表端设置页的账号开关行：同一服务商的多个账号是平级的独立账号，各自一行、各自一个开关。
/// 停用的也要列出来，否则表上没法再打开。不含任何凭据。
public struct WatchAccountToggle: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var providerRaw: String
    public var title: String
    public var enabled: Bool
    /// 首个账号的快照按服务商键存，表端圆环页按它取；只用于表端本地即时更新，不表示从属关系。
    public var isPrimary: Bool

    public init(id: UUID, providerRaw: String, title: String, enabled: Bool, isPrimary: Bool) {
        self.id = id
        self.providerRaw = providerRaw
        self.title = title
        self.enabled = enabled
        self.isPrimary = isPrimary
    }

    public var provider: ProviderID {
        ProviderID(rawValue: providerRaw) ?? .claude
    }
}

public enum WatchAccountToggles {
    /// 只列内置且目录可见的账号，顺序跟手机端账号列表；演示模式不推。
    public static func items(
        accounts: [ProviderAccount],
        demoMode: Bool,
        displayName: (ProviderAccount) -> String
    ) -> [WatchAccountToggle] {
        if demoMode { return [] }
        return accounts.compactMap { account in
            guard !account.isCustom, let provider = account.provider,
                  ProviderAvailability.isAvailable(account) else { return nil }
            return WatchAccountToggle(
                id: account.id,
                providerRaw: provider.rawValue,
                title: displayName(account),
                enabled: account.isEnabled,
                isPrimary: account.isPrimary
            )
        }
    }

    /// 编码失败返回 nil：调用方记诊断，不要推空数据（表端会把空列表当成旧版手机、退回按服务商列）。
    public static func encode(_ items: [WatchAccountToggle], encoder: JSONEncoder) -> Data? {
        try? encoder.encode(items)
    }

    public static func decode(_ data: Data, decoder: JSONDecoder) -> [WatchAccountToggle] {
        (try? decoder.decode([WatchAccountToggle].self, from: data)) ?? []
    }
}

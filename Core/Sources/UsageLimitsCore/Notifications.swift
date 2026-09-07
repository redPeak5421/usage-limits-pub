import Foundation

/// 某一类提醒的作用范围：全服务商同一套，或每家单独配。
public enum AlertScope: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case unified
    case perProvider
    public var id: String { rawValue }
}

/// 单个服务商的四类提醒参数（按供应商配置时用；缺省与统一档相同）。
public struct ProviderAlertConfig: Codable, Equatable, Sendable {
    public var thresholdEnabled: Bool
    public var thresholdPercent: Double
    public var expiryEnabled: Bool
    public var expiryDaysBefore: Int
    public var resetEnabled: Bool
    public var prepaidAmountEnabled: Bool
    public var prepaidAmount: Double

    public init(
        thresholdEnabled: Bool = false,
        thresholdPercent: Double = 80,
        expiryEnabled: Bool = false,
        expiryDaysBefore: Int = 3,
        resetEnabled: Bool = false,
        prepaidAmountEnabled: Bool = false,
        prepaidAmount: Double = 10
    ) {
        self.thresholdEnabled = thresholdEnabled
        self.thresholdPercent = thresholdPercent
        self.expiryEnabled = expiryEnabled
        self.expiryDaysBefore = expiryDaysBefore
        self.resetEnabled = resetEnabled
        self.prepaidAmountEnabled = prepaidAmountEnabled
        self.prepaidAmount = prepaidAmount
    }

    public static func seeded(from unified: NotificationSettings) -> ProviderAlertConfig {
        ProviderAlertConfig(
            thresholdEnabled: unified.thresholdEnabled,
            thresholdPercent: unified.thresholdPercent,
            expiryEnabled: unified.expiryEnabled,
            expiryDaysBefore: unified.expiryDaysBefore,
            resetEnabled: unified.resetEnabled,
            prepaidAmountEnabled: unified.prepaidAmountEnabled,
            prepaidAmount: unified.prepaidAmount
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thresholdEnabled = try c.decodeIfPresent(Bool.self, forKey: .thresholdEnabled) ?? false
        thresholdPercent = try c.decodeIfPresent(Double.self, forKey: .thresholdPercent) ?? 80
        expiryEnabled = try c.decodeIfPresent(Bool.self, forKey: .expiryEnabled) ?? false
        expiryDaysBefore = try c.decodeIfPresent(Int.self, forKey: .expiryDaysBefore) ?? 3
        resetEnabled = try c.decodeIfPresent(Bool.self, forKey: .resetEnabled) ?? false
        prepaidAmountEnabled = try c.decodeIfPresent(Bool.self, forKey: .prepaidAmountEnabled) ?? false
        prepaidAmount = try c.decodeIfPresent(Double.self, forKey: .prepaidAmount) ?? 10
    }
}

/// 提醒设置：四类提醒各自独立开关；每类可选统一或按供应商。
/// 默认全关（开启时 App 层才申请系统通知权限）。
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// 额度已用百分比达到阈值时提醒。
    public var thresholdEnabled: Bool
    public var thresholdPercent: Double
    public var thresholdScope: AlertScope
    /// 套餐到期前 N 天提醒（仅对能拿到到期时间的服务商生效）。
    public var expiryEnabled: Bool
    public var expiryDaysBefore: Int
    public var expiryScope: AlertScope
    /// 额度重置提醒：按已知重置时间到点提醒 + 刷新时检测到额度突然回满提醒。
    public var resetEnabled: Bool
    public var resetScope: AlertScope
    /// 预充值余额降到该金额及以下时提醒。
    public var prepaidAmountEnabled: Bool
    public var prepaidAmount: Double
    public var prepaidScope: AlertScope
    /// 按供应商覆盖；key 为 `ProviderID.rawValue`。
    public var providerConfigs: [String: ProviderAlertConfig]

    public init(
        thresholdEnabled: Bool = false,
        thresholdPercent: Double = 80,
        thresholdScope: AlertScope = .unified,
        expiryEnabled: Bool = false,
        expiryDaysBefore: Int = 3,
        expiryScope: AlertScope = .unified,
        resetEnabled: Bool = false,
        resetScope: AlertScope = .unified,
        prepaidAmountEnabled: Bool = false,
        prepaidAmount: Double = 10,
        prepaidScope: AlertScope = .unified,
        providerConfigs: [String: ProviderAlertConfig] = [:]
    ) {
        self.thresholdEnabled = thresholdEnabled
        self.thresholdPercent = thresholdPercent
        self.thresholdScope = thresholdScope
        self.expiryEnabled = expiryEnabled
        self.expiryDaysBefore = expiryDaysBefore
        self.expiryScope = expiryScope
        self.resetEnabled = resetEnabled
        self.resetScope = resetScope
        self.prepaidAmountEnabled = prepaidAmountEnabled
        self.prepaidAmount = prepaidAmount
        self.prepaidScope = prepaidScope
        self.providerConfigs = providerConfigs
    }

    /// 某服务商实际生效的一套参数（统一档或该家覆盖）。
    public func resolved(for provider: ProviderID) -> ProviderAlertConfig {
        let over = providerConfigs[provider.rawValue]
        return ProviderAlertConfig(
            thresholdEnabled: thresholdScope == .perProvider
                ? (over?.thresholdEnabled ?? false) : thresholdEnabled,
            thresholdPercent: thresholdScope == .perProvider
                ? (over?.thresholdPercent ?? 80) : thresholdPercent,
            expiryEnabled: expiryScope == .perProvider
                ? (over?.expiryEnabled ?? false) : expiryEnabled,
            expiryDaysBefore: expiryScope == .perProvider
                ? (over?.expiryDaysBefore ?? 3) : expiryDaysBefore,
            resetEnabled: resetScope == .perProvider
                ? (over?.resetEnabled ?? false) : resetEnabled,
            prepaidAmountEnabled: prepaidScope == .perProvider
                ? (over?.prepaidAmountEnabled ?? false) : prepaidAmountEnabled,
            prepaidAmount: prepaidScope == .perProvider
                ? (over?.prepaidAmount ?? 10) : prepaidAmount
        )
    }

    public mutating func upsert(_ provider: ProviderID, _ config: ProviderAlertConfig) {
        providerConfigs[provider.rawValue] = config
    }

    public mutating func seedProviderIfNeeded(_ provider: ProviderID) {
        guard providerConfigs[provider.rawValue] == nil else { return }
        providerConfigs[provider.rawValue] = .seeded(from: self)
    }

    public var anyEnabled: Bool {
        if thresholdScope == .unified && thresholdEnabled { return true }
        if expiryScope == .unified && expiryEnabled { return true }
        if resetScope == .unified && resetEnabled { return true }
        if prepaidScope == .unified && prepaidAmountEnabled { return true }
        if thresholdScope == .perProvider && providerConfigs.values.contains(where: \.thresholdEnabled) { return true }
        if expiryScope == .perProvider && providerConfigs.values.contains(where: \.expiryEnabled) { return true }
        if resetScope == .perProvider && providerConfigs.values.contains(where: \.resetEnabled) { return true }
        if prepaidScope == .perProvider && providerConfigs.values.contains(where: \.prepaidAmountEnabled) { return true }
        return false
    }

    /// 后台探针要服务的提醒。到期提醒走日历预排，不需要后台刷快照。
    public var needsBackgroundProbe: Bool {
        if thresholdScope == .unified && thresholdEnabled { return true }
        if resetScope == .unified && resetEnabled { return true }
        if prepaidScope == .unified && prepaidAmountEnabled { return true }
        if thresholdScope == .perProvider && providerConfigs.values.contains(where: \.thresholdEnabled) { return true }
        if resetScope == .perProvider && providerConfigs.values.contains(where: \.resetEnabled) { return true }
        if prepaidScope == .perProvider && providerConfigs.values.contains(where: \.prepaidAmountEnabled) { return true }
        return false
    }

    public var needsCalendarReminders: Bool {
        if expiryScope == .unified && expiryEnabled { return true }
        if resetScope == .unified && resetEnabled { return true }
        if expiryScope == .perProvider && providerConfigs.values.contains(where: \.expiryEnabled) { return true }
        if resetScope == .perProvider && providerConfigs.values.contains(where: \.resetEnabled) { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thresholdEnabled = try c.decodeIfPresent(Bool.self, forKey: .thresholdEnabled) ?? false
        thresholdPercent = try c.decodeIfPresent(Double.self, forKey: .thresholdPercent) ?? 80
        thresholdScope = try c.decodeIfPresent(AlertScope.self, forKey: .thresholdScope) ?? .unified
        expiryEnabled = try c.decodeIfPresent(Bool.self, forKey: .expiryEnabled) ?? false
        expiryDaysBefore = try c.decodeIfPresent(Int.self, forKey: .expiryDaysBefore) ?? 3
        expiryScope = try c.decodeIfPresent(AlertScope.self, forKey: .expiryScope) ?? .unified
        resetEnabled = try c.decodeIfPresent(Bool.self, forKey: .resetEnabled) ?? false
        resetScope = try c.decodeIfPresent(AlertScope.self, forKey: .resetScope) ?? .unified
        prepaidAmountEnabled = try c.decodeIfPresent(Bool.self, forKey: .prepaidAmountEnabled) ?? false
        prepaidAmount = try c.decodeIfPresent(Double.self, forKey: .prepaidAmount) ?? 10
        prepaidScope = try c.decodeIfPresent(AlertScope.self, forKey: .prepaidScope) ?? .unified
        providerConfigs = try c.decodeIfPresent([String: ProviderAlertConfig].self, forKey: .providerConfigs) ?? [:]
    }
}

/// 预充值金额的币种：只有快照里已经拿到额度接口才显示符号，否则不显示。
public enum PrepaidCurrency {
    public static func code(from snapshot: ProviderSnapshot?) -> String? {
        guard let snapshot, snapshot.status.isOK else { return nil }
        if let c = snapshot.currency, !c.isEmpty { return c }
        if let c = snapshot.metrics.first(where: { $0.id == "balance" })?.currency, !c.isEmpty {
            return c
        }
        return nil
    }
}

/// 一次应当发出的提醒事件（决策器输出；App 层负责转成系统通知）。
public struct NotificationEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case threshold
        case reset
        case prepaidAmount
    }

    public var kind: Kind
    public var provider: ProviderID
    public var metricID: String
    public var metricLabel: String
    public var usedPercent: Double?
    /// 预充值告警的当前余额（金额，非百分比）。
    public var amount: Double?
    /// 去重键：同一窗口周期内同一事件只提醒一次（含 resetsAt，窗口重置后自动重新武装）。
    public var dedupeKey: String
    /// 自定义账号：标题用显示名，货币读账号快照。
    public var accountID: UUID?
    public var accountTitle: String?

    public init(
        kind: Kind,
        provider: ProviderID,
        metricID: String,
        metricLabel: String,
        usedPercent: Double?,
        amount: Double?,
        dedupeKey: String,
        accountID: UUID? = nil,
        accountTitle: String? = nil
    ) {
        self.kind = kind
        self.provider = provider
        self.metricID = metricID
        self.metricLabel = metricLabel
        self.usedPercent = usedPercent
        self.amount = amount
        self.dedupeKey = dedupeKey
        self.accountID = accountID
        self.accountTitle = accountTitle
    }

    /// 自定义账号字段名不走官方 `metricKey`（`prepaid_credits` 否则会变成 Claude「Usage credits」）。
    public func localizedMetricLabel(language: AppLanguage, isCustomAccount: Bool) -> String {
        if isCustomAccount {
            return L10n.tr(metricLabel, language)
        }
        return L10n.metricLabel(provider: provider, id: metricID, fallback: metricLabel, language: language)
    }
}

/// 纯决策逻辑：对比新旧快照 + 设置，得出应发的提醒。不做任何 I/O，可单测。
public enum NotificationDecider {
    public static func events(
        old: ProviderSnapshot?,
        new: ProviderSnapshot,
        settings: NotificationSettings,
        alreadyNotified: Set<String>,
        accountID: UUID? = nil,
        accountTitle: String? = nil
    ) -> [NotificationEvent] {
        if new.isCustom { return [] }
        var out: [NotificationEvent] = []
        let cfg = settings.resolved(for: new.provider)

        // 旧快照存在但非 ok（如 needsLogin，metrics 为空）时不判阈值穿越：
        // 重新登录成功的那一轮会把所有高用量指标都当成「新穿越」，全量误报
        if cfg.thresholdEnabled, new.status.isOK, old == nil || old!.status.isOK {
            for m in new.metrics {
                guard let pct = UsagePresentation.validUsedPercent(m.usedPercent),
                      pct >= cfg.thresholdPercent else { continue }
                if let old {
                    // 只在「穿越」阈值时提醒：必须拿到同一指标的旧值且在阈值之下。
                    // 指标瞬时缺失（接口漂移、解析防御式容错）视为未知，不算穿越
                    guard let oldPct = UsagePresentation.validUsedPercent(
                              old.metrics.first(where: { $0.id == m.id })?.usedPercent
                          ),
                          oldPct < cfg.thresholdPercent else { continue }
                }
                let key = scopedKey(
                    "threshold.\(new.provider.rawValue).\(m.id).\(Self.stamp(m.resetsAt))",
                    accountID: accountID
                )
                guard !alreadyNotified.contains(key) else { continue }
                out.append(NotificationEvent(
                    kind: .threshold, provider: new.provider,
                    metricID: m.id, metricLabel: m.label,
                    usedPercent: pct, amount: nil, dedupeKey: key,
                    accountID: accountID, accountTitle: accountTitle
                ))
            }
        }

        // 重置检测只看最长窗口（longestWindowMetric 按 resetsAt 最远取，天然排除 5h session）：
        // 前一次已用 > 0，本次同一指标回到 0（即可用额度回满 100%）。
        if cfg.resetEnabled,
           new.status.isOK,
           let old, old.status.isOK,
           let oldMetric = old.longestWindowMetric,
           let oldPct = UsagePresentation.validUsedPercent(oldMetric.usedPercent), oldPct > 0,
           let newMetric = new.metrics.first(where: { $0.id == oldMetric.id }),
           let newPct = UsagePresentation.validUsedPercent(newMetric.usedPercent), newPct <= 0 {
            let key = resetDedupeKey(
                provider: new.provider, metricID: oldMetric.id,
                resetsAt: oldMetric.resetsAt, accountID: accountID
            )
            if !alreadyNotified.contains(key) {
                out.append(NotificationEvent(
                    kind: .reset, provider: new.provider,
                    metricID: oldMetric.id, metricLabel: oldMetric.label,
                    usedPercent: oldPct, amount: nil, dedupeKey: key,
                    accountID: accountID, accountTitle: accountTitle
                ))
            }
        }

        // 预充值金额告警：有 balance 指标才判（DeepSeek 已有，其余家接口未到则不会触发）。
        // 只认「之上 → 阈值及以下」穿越。
        if cfg.prepaidAmountEnabled,
           new.status.isOK,
           let old, old.status.isOK,
           let oldAmt = prepaidBalance(old),
           let newAmt = prepaidBalance(new),
           oldAmt > cfg.prepaidAmount,
           newAmt <= cfg.prepaidAmount {
            let key = prepaidDedupeKey(
                provider: new.provider,
                threshold: cfg.prepaidAmount,
                fetchedAt: new.fetchedAt,
                accountID: accountID
            )
            out.append(NotificationEvent(
                kind: .prepaidAmount, provider: new.provider,
                metricID: prepaidMetric(new)?.id ?? "balance",
                metricLabel: prepaidMetric(new)?.label ?? "balance",
                usedPercent: nil, amount: newAmt, dedupeKey: key,
                accountID: accountID, accountTitle: accountTitle
            ))
        }

        return out
    }

    /// 预充值事件标识：阈值 + 本次快照时刻（作通知 request id，不参与「是否再发」判定）。
    public static func prepaidDedupeKey(
        provider: ProviderID,
        threshold: Double,
        fetchedAt: Date,
        accountID: UUID? = nil
    ) -> String {
        scopedKey(
            "prepaid.\(provider.rawValue).balance.\(roundedStamp(threshold)).at.\(dateStamp(fetchedAt))",
            accountID: accountID
        )
    }

    /// 预充值余额行：优先带币种的 remaining，再认 balance / prepaid_credits / 「余额」。
    public static func prepaidMetric(_ snap: ProviderSnapshot) -> UsageMetric? {
        let metrics = snap.metrics.filter { $0.amount != nil }
        if let m = metrics.first(where: {
            CustomUsageDisplay.effectiveRole($0) == .remaining && $0.currency != nil
        }) {
            return m
        }
        if let m = metrics.first(where: { $0.id == "balance" || $0.id == "prepaid_credits" }) {
            return m
        }
        return metrics.first(where: { $0.label == "余额" })
    }

    public static func prepaidBalance(_ snap: ProviderSnapshot) -> Double? {
        prepaidMetric(snap)?.amount
    }

    /// 自定义只接统一档预充值；perProvider 时不发。不要对自定义快照调用 `events(old:new:)`。
    public static func customPrepaidEvents(
        old: ProviderSnapshot?,
        new: ProviderSnapshot,
        accountID: UUID,
        accountTitle: String,
        settings: NotificationSettings
    ) -> [NotificationEvent] {
        guard new.isCustom else { return [] }
        guard settings.prepaidScope == .unified, settings.prepaidAmountEnabled else { return [] }
        guard new.status.isOK, let old, old.status.isOK,
              let oldAmount = prepaidBalance(old),
              let newAmount = prepaidBalance(new),
              oldAmount > settings.prepaidAmount,
              newAmount <= settings.prepaidAmount
        else { return [] }
        let key = customPrepaidDedupeKey(
            accountID: accountID,
            threshold: settings.prepaidAmount,
            fetchedAt: new.fetchedAt
        )
        return [NotificationEvent(
            kind: .prepaidAmount,
            provider: .claude,
            metricID: prepaidMetric(new)?.id ?? "balance",
            metricLabel: prepaidMetric(new)?.label ?? "balance",
            usedPercent: nil,
            amount: newAmount,
            dedupeKey: key,
            accountID: accountID,
            accountTitle: accountTitle
        )]
    }

    public static func customPrepaidDedupeKey(
        accountID: UUID,
        threshold: Double,
        fetchedAt: Date
    ) -> String {
        "prepaid.custom.\(accountID.uuidString).balance.\(roundedStamp(threshold)).at.\(dateStamp(fetchedAt))"
    }

    /// 重置事件的去重键（App 层预排「到点重置」通知时预先登记同一个键，
    /// 避免到点通知 + 刷新检测对同一次重置各发一条）。
    public static func resetDedupeKey(
        provider: ProviderID,
        metricID: String,
        resetsAt: Date?,
        accountID: UUID? = nil
    ) -> String {
        scopedKey(
            "reset.\(provider.rawValue).\(metricID).\(stamp(resetsAt))",
            accountID: accountID
        )
    }

    static func scopedKey(_ key: String, accountID: UUID?) -> String {
        guard let accountID else { return key }
        return "\(key).account.\(accountID.uuidString)"
    }

    public static func extraCalendarIDs(accountID: UUID) -> [String] {
        [
            "expiry.account.\(accountID.uuidString)",
            "resetAt.account.\(accountID.uuidString)",
        ]
    }

    /// resetsAt 按小时分桶：部分解析器的 resetsAt 是「now + 剩余秒数」推算的相对值，
    /// 每次刷新都会漂移几秒到几分钟；精确到秒会导致去重键永不匹配。
    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "-" }
        return String(Int(date.timeIntervalSince1970 / 3600))
    }

    private static func roundedStamp(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private static func dateStamp(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}

import Foundation

/// 自定义卡 / 小组件的展示推导。按快照 metrics 列表渲染（标签用展示名），
/// **不**写入 `UsageMetric.usedPercent`（避免触发百分比阈值提醒）。
/// 语义角色（`UsageMetric.kind`）只在这里用来挑主指标、推进度条、定格式。
public enum CustomUsageDisplay {
    public struct Tile: Equatable, Sendable {
        public var id: String
        public var label: String
        public var valueText: String
        public var amount: Double?
        public var role: CustomFieldRole
        /// 时间戳角色：绝对时间（展示层再转相对文案）。
        public var date: Date?
        /// 与 `UsageMetric.currency` 对齐，进度条只配对同单位字段。
        public var currency: String?

        public init(
            id: String,
            label: String,
            valueText: String,
            amount: Double? = nil,
            role: CustomFieldRole = .other,
            date: Date? = nil,
            currency: String? = nil
        ) {
            self.id = id
            self.label = label
            self.valueText = valueText
            self.amount = amount
            self.role = role
            self.date = date
            self.currency = currency
        }
    }

    /// 进度条：0…100 与说明（如「已用 20 / 总额 100」）。
    public struct Gauge: Equatable, Sendable {
        /// 当前展示口径下画到条上的百分比。
        public var displayedPercent: Double
        /// 永远是已用百分比，供风险颜色使用，不随展示口径反转。
        public var riskPercent: Double
        public var caption: String?
        public var source: Source

        public enum Source: String, Sendable {
            /// 用户勾的百分比字段
            case percentField
            /// 已用 / 总额
            case usedOverLimit
            /// 已用 / (已用 + 余额)
            case usedShare
            /// (总额 − 余额) / 总额
            case remainingOverLimit
        }

        public init(displayedPercent: Double, caption: String?, source: Source, riskPercent: Double? = nil) {
            self.displayedPercent = displayedPercent
            self.riskPercent = riskPercent ?? displayedPercent
            self.caption = caption
            self.source = source
        }
    }

    public struct Presentation: Equatable, Sendable {
        public var tiles: [Tile]
        /// `used / (used + balance)`，0...100。缺一项、有负数、或和为 0 时为 nil。
        public var usedSharePercent: Double?
        public var collapsedSummary: String
        /// 语义主指标（进度条配对 / 角色优先级）。折叠大号改走 `collapsedTile`。
        public var hero: Tile?
        /// 主指标之外的数字（不含时间戳）。
        public var secondary: [Tile]
        /// 时间戳字段单独一组（到期 / 重置）。
        public var timestamps: [Tile]
        public var gauge: Gauge?
    }

    public static func tiles(
        from snap: ProviderSnapshot,
        mode: UsageDisplayMode = .used,
        language: AppLanguage = .zh,
        resetStyle: ResetTimeStyle = .countdown,
        now: Date = Date()
    ) -> [Tile] {
        snap.metrics.compactMap { metric in
            guard metric.amount != nil || metric.pinned == true else { return nil }
            // 角色按源文案回退，展示名再本地化，避免英文界面把「剩余」匹配拆掉。
            let role = effectiveRole(metric)
            return Tile(
                id: metric.id,
                label: L10n.tr(metric.label, language),
                valueText: valueText(
                    for: metric, mode: mode, language: language, resetStyle: resetStyle, now: now
                ),
                amount: metric.amount,
                role: role,
                date: role == .timestamp ? metric.resetsAt : nil,
                currency: metric.currency
            )
        }
    }

    public static func presentation(
        from snap: ProviderSnapshot,
        mode: UsageDisplayMode = .used,
        language: AppLanguage = .zh,
        resetStyle: ResetTimeStyle = .countdown,
        now: Date = Date()
    ) -> Presentation {
        let tiles = tiles(
            from: snap, mode: mode, language: language, resetStyle: resetStyle, now: now
        )
        let numeric = tiles.filter { $0.role != .timestamp }
        let timestamps = tiles.filter { $0.role == .timestamp }
        let share = sharePercent(from: snap.metrics)
        let gauge = gauge(tiles: numeric, share: share, mode: mode)
        let hero = heroTile(numeric, gauge: gauge)
        let secondary = numeric.filter { $0.id != hero?.id }
        return Presentation(
            tiles: tiles,
            usedSharePercent: share,
            collapsedSummary: tiles.map { "\($0.label) \($0.valueText)" }.joined(separator: " · "),
            hero: hero,
            secondary: secondary,
            timestamps: timestamps,
            gauge: gauge
        )
    }

    static let heroPriority: [CustomFieldRole] = [.remaining, .used, .percent, .limit, .count, .other]

    /// 折叠卡片 / 2×2：展开顺序第一位（已套用用户计量顺序），不是语义 hero。
    public static func collapsedTile(from snap: ProviderSnapshot, shown: Presentation) -> Tile? {
        let byID = Dictionary(uniqueKeysWithValues: shown.tiles.map { ($0.id, $0) })
        if let first = snap.activeMetrics.first, let tile = byID[first.id], tile.role != .timestamp {
            return tile
        }
        return shown.tiles.first { $0.role != .timestamp } ?? shown.hero
    }

    public static func heroTile(_ tiles: [Tile], gauge: Gauge? = nil) -> Tile? {
        if let aligned = gaugeAlignedHero(tiles, gauge: gauge) {
            return aligned
        }
        return firstByPriority(tiles)
    }

    /// 进度条已经配对的字段优先当主指标，避免 Crof 大号画美元积分、条却是请求消耗。
    static func gaugeAlignedHero(_ tiles: [Tile], gauge: Gauge?) -> Tile? {
        guard let gauge else { return nil }
        let remaining = tiles.filter { effectiveRole($0) == .remaining }
        let used = tiles.filter { effectiveRole($0) == .used }
        let limit = tiles.filter { effectiveRole($0) == .limit }
        switch gauge.source {
        case .remainingOverLimit:
            return firstCompatiblePair(remaining, limit, where: {
                guard let remainingAmount = validGaugeOperand($0.amount),
                      let limitAmount = validGaugeOperand($1.amount) else { return false }
                return limitAmount > 0 && remainingAmount <= limitAmount
            })?.0
        case .usedOverLimit:
            guard let pair = firstCompatiblePair(used, limit, where: {
                guard validGaugeOperand($0.amount) != nil,
                      let limitAmount = validGaugeOperand($1.amount) else { return false }
                return limitAmount > 0
            }) else { return nil }
            if let rem = remaining.first(where: {
                tilesShareUnit($0, pair.0)
                    && tilesShareUnit($0, pair.1)
            }) {
                return rem
            }
            return pair.0
        case .usedShare:
            return firstCompatiblePair(used, remaining, where: {
                usedSharePercent(used: $0.amount, balance: $1.amount) != nil
            })?.1
        case .percentField:
            return nil
        }
    }

    static func firstByPriority(_ tiles: [Tile]) -> Tile? {
        for role in heroPriority {
            if let tile = tiles.first(where: { effectiveRole($0) == role }) { return tile }
        }
        return tiles.first
    }

    /// 无角色时用展示名回退，让「余额 / 剩余」仍能当主指标。
    static func effectiveRole(_ tile: Tile) -> CustomFieldRole {
        if tile.role != .other { return tile.role }
        if matchesFallbackLabel(tile.label, role: .remaining) { return .remaining }
        if matchesFallbackLabel(tile.label, role: .used) { return .used }
        if matchesFallbackLabel(tile.label, role: .limit) { return .limit }
        if matchesFallbackLabel(tile.label, role: .percent) { return .percent }
        return .other
    }

    /// 进度条来源优先级：百分比字段 → 已用/总额 → 已用占比 → 余额/总额。
    public static func gauge(
        tiles: [Tile],
        share: Double?,
        mode: UsageDisplayMode = .used
    ) -> Gauge? {
        if let tile = tiles.first(where: { $0.role == .percent }),
           let percent = UsagePresentation.validUsedPercent(tile.amount) {
            return gauge(usedPercent: percent, caption: nil, source: .percentField, mode: mode)
        }
        let usedTiles = tiles.filter { effectiveRole($0) == .used }
        let limitTiles = tiles.filter { effectiveRole($0) == .limit }
        let remainingTiles = tiles.filter { effectiveRole($0) == .remaining && !isRemainingPercent($0) }
        let remainingPercentTiles = tiles.filter { isRemainingPercent($0) }
        if let (used, limit) = firstCompatiblePair(usedTiles, limitTiles, where: {
            guard validGaugeOperand($0.amount) != nil,
                  let limitAmount = validGaugeOperand($1.amount) else { return false }
            return limitAmount > 0
        }), let usedAmount = validGaugeOperand(used.amount),
           let limitAmount = validGaugeOperand(limit.amount) {
            let percent = usedAmount >= limitAmount ? 100 : usedAmount / limitAmount * 100
            return gauge(
                usedPercent: percent,
                caption: "\(used.label) \(used.valueText) / \(limit.label) \(limit.valueText)",
                source: .usedOverLimit,
                mode: mode
            )
        }
        if let share = UsagePresentation.validUsedPercent(share),
           let (used, remaining) = firstCompatiblePair(usedTiles, remainingTiles, where: {
               validGaugeOperand($0.amount) != nil && validGaugeOperand($1.amount) != nil
           }) {
            return gauge(
                usedPercent: share,
                caption: "\(used.label) \(used.valueText) / \(remaining.label) \(remaining.valueText)",
                source: .usedShare,
                mode: mode
            )
        }
        if let (used, remaining) = firstCompatiblePair(usedTiles, remainingTiles, where: {
            usedSharePercent(used: $0.amount, balance: $1.amount) != nil
        }), let computed = usedSharePercent(used: used.amount, balance: remaining.amount) {
            return gauge(
                usedPercent: computed,
                caption: "\(used.label) \(used.valueText) / \(remaining.label) \(remaining.valueText)",
                source: .usedShare,
                mode: mode
            )
        }
        if let (remaining, limit) = firstCompatiblePair(remainingTiles, limitTiles, where: {
            guard let remainingAmount = validGaugeOperand($0.amount),
                  let limitAmount = validGaugeOperand($1.amount) else { return false }
            return limitAmount > 0 && remainingAmount <= limitAmount
        }), let remainingAmount = validGaugeOperand(remaining.amount),
           let limitAmount = validGaugeOperand(limit.amount) {
            let percent = (limitAmount - remainingAmount) / limitAmount * 100
            return gauge(
                usedPercent: percent,
                caption: "\(remaining.label) \(remaining.valueText) / \(limit.label) \(limit.valueText)",
                source: .remainingOverLimit,
                mode: mode
            )
        }
        if let tile = remainingPercentTiles.first,
           let remaining = UsagePresentation.validUsedPercent(tile.amount) {
            return gauge(
                usedPercent: 100 - remaining,
                caption: "\(tile.label) \(tile.valueText)",
                source: .remainingOverLimit,
                mode: mode
            )
        }
        return nil
    }

    /// 币种相同（忽略大小写与空白），或两边都没有币种。美元积分不得和请求上限配对。
    public static func compatibleUnits(_ a: String?, _ b: String?) -> Bool {
        normalizedUnit(a) == normalizedUnit(b)
    }

    /// 两边都没币种时，积分/余额不得和请求或 Token 上限配对。
    public static func compatibleMeasures(
        currencyA: String?, idA: String, labelA: String,
        currencyB: String?, idB: String, labelB: String
    ) -> Bool {
        guard compatibleUnits(currencyA, currencyB) else { return false }
        if normalizedUnit(currencyA).isEmpty && normalizedUnit(currencyB).isEmpty {
            if let familyA = implicitUnitFamily(id: idA, label: labelA),
               let familyB = implicitUnitFamily(id: idB, label: labelB) {
                return familyA == familyB
            }
        }
        return true
    }

    static func tilesShareUnit(_ a: Tile, _ b: Tile) -> Bool {
        compatibleMeasures(
            currencyA: a.currency, idA: a.id, labelA: a.label,
            currencyB: b.currency, idB: b.id, labelB: b.label
        )
    }

    static func implicitUnitFamily(id: String, label: String) -> String? {
        let blob = "\(id) \(label)".lowercased()
        let words = Set(CustomFieldSemantics.tokens(of: id) + CustomFieldSemantics.tokens(of: label))
        if words.contains(where: { ["request", "requests", "call", "calls"].contains($0) })
            || blob.contains("请求") || blob.contains("次数") {
            return "requests"
        }
        if words.contains(where: { ["token", "tokens"].contains($0) }) || blob.contains("token") {
            return "tokens"
        }
        if words.contains(where: { ["credit", "credits", "balance"].contains($0) })
            || blob.contains("积分") || blob.contains("余额") || blob.contains("额度") {
            return "credits"
        }
        return nil
    }

    private static func normalizedUnit(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func firstCompatiblePair(
        _ left: [Tile],
        _ right: [Tile],
        where predicate: (Tile, Tile) -> Bool
    ) -> (Tile, Tile)? {
        for a in left {
            for b in right where a.id != b.id {
                guard tilesShareUnit(a, b), predicate(a, b) else { continue }
                return (a, b)
            }
        }
        return nil
    }

    static func gauge(
        usedPercent: Double,
        caption: String?,
        source: Gauge.Source,
        mode: UsageDisplayMode
    ) -> Gauge {
        Gauge(
            displayedPercent: UsagePresentation.barPercent(used: usedPercent, mode: mode),
            caption: caption,
            source: source,
            riskPercent: usedPercent
        )
    }

    /// 展示名一对「已用」+「余额」才推占比。两条都是余额、或只有 id 叫 used/balance，都不画条。
    public static func sharePercent(from metrics: [UsageMetric]) -> Double? {
        let used = metrics.filter { effectiveRole($0) == .used }
        let remain = metrics.filter { effectiveRole($0) == .remaining && !isRemainingPercent($0) }
        for used in used {
            for remain in remain {
                guard used.id != remain.id else { continue }
                guard compatibleMeasures(
                    currencyA: used.currency, idA: used.id, labelA: used.label,
                    currencyB: remain.currency, idB: remain.id, labelB: remain.label
                ) else { continue }
                if let share = usedSharePercent(used: used.amount, balance: remain.amount) {
                    return share
                }
            }
        }
        return nil
    }

    public static func fieldRole(_ metric: UsageMetric) -> CustomFieldRole? {
        metric.kind.flatMap(CustomFieldRole.init(rawValue:))
    }

    /// 剩余占比：amount 是 0…100 的剩余%，不得当剩余次数去和上限配对。
    static func isRemainingPercent(_ metric: UsageMetric) -> Bool {
        guard effectiveRole(metric) == .remaining else { return false }
        if let display = metric.displayValue, display.contains("%") { return true }
        let hint = CustomFieldSemantics.infer(
            path: metric.id, value: metric.amount ?? 0, rawText: metric.displayValue
        )
        return hint.role == .remaining && hint.isPercentString
    }

    static func isRemainingPercent(_ tile: Tile) -> Bool {
        guard effectiveRole(tile) == .remaining else { return false }
        if tile.valueText.contains("%") { return true }
        let hint = CustomFieldSemantics.infer(
            path: tile.id, value: tile.amount ?? 0, rawText: tile.valueText
        )
        return hint.role == .remaining && hint.isPercentString
    }

    /// 有角色只认角色；无 kind 时才回退展示名。避免「已用上限」这种 limit 被拉进 used。
    public static func effectiveRole(_ metric: UsageMetric) -> CustomFieldRole {
        if let role = fieldRole(metric) { return role }
        if matchesFallbackLabel(metric.label, role: .remaining) { return .remaining }
        if matchesFallbackLabel(metric.label, role: .used) { return .used }
        if matchesFallbackLabel(metric.label, role: .limit) { return .limit }
        if matchesFallbackLabel(metric.label, role: .percent) { return .percent }
        return .other
    }

    /// 预充值只认钱：带币种的 remaining、id=balance、或「余额」类展示名。不认「剩余请求」。
    public static func matchesPrepaidLabel(_ label: String) -> Bool {
        if label.contains("余额") { return true }
        let lower = label.lowercased()
        if lower.contains("prepaid") { return true }
        if lower == "credits" || lower == "credit" { return true }
        if lower.hasSuffix("_credits") || lower.hasSuffix("_balance") {
            let spentLike = (lower.contains("used") || lower.contains("spent") || lower.contains("consum"))
                && !(lower.contains("unused") || lower.contains("unspent") || lower.contains("unconsum"))
            if !spentLike { return true }
        }
        for language in AppLanguage.allCases where language != .system {
            let def = CustomFieldRole.remaining.defaultLabel(language)
            guard !def.isEmpty else { continue }
            if label.compare(def, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return true
            }
        }
        return false
    }

    public static func matchesFallbackLabel(_ label: String, role: CustomFieldRole) -> Bool {
        switch role {
        case .used:
            if label.contains("已用") { return true }
        case .remaining:
            if label.contains("余额") || label.contains("剩余") || label.contains("可用") { return true }
            if label.compare("Remaining", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return true
            }
            if label.compare("Available", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return true
            }
        default:
            break
        }
        for language in AppLanguage.allCases where language != .system {
            let def = role.defaultLabel(language)
            guard !def.isEmpty else { continue }
            if label.compare(def, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return true
            }
        }
        return false
    }

    public static func usedSharePercent(used: Double?, balance: Double?) -> Double? {
        guard let used = validGaugeOperand(used),
              let balance = validGaugeOperand(balance) else { return nil }
        let total = used + balance
        guard total > 0, total.isFinite else { return nil }
        return (used / total) * 100
    }

    /// Gauge 运算的原始数量域。上界避免加法或后续比率运算在有限输入下溢出；
    /// 实际额度远低于该界限，超大有限哨兵按坏数据处理。
    private static func validGaugeOperand(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0,
              value <= Double.greatestFiniteMagnitude.squareRoot() else { return nil }
        return value
    }

    /// 自定义字段唯一的跨端值展示入口。百分比与时间戳不信任原始展示字符串，
    /// 且始终保持 `UsageMetric.usedPercent == nil`，只在展示阶段套用用户设置。
    public static func valueText(
        for metric: UsageMetric,
        mode: UsageDisplayMode = .used,
        language: AppLanguage = .zh,
        resetStyle: ResetTimeStyle = .countdown,
        now: Date = Date()
    ) -> String {
        let role = metric.kind.flatMap(CustomFieldRole.init(rawValue:)) ?? .other
        switch role {
        case .percent:
            guard let percent = UsagePresentation.validUsedPercent(metric.amount) else { return "—" }
            return percentText(UsagePresentation.barPercent(used: percent, mode: mode))
        case .remaining where isRemainingPercent(metric):
            guard let remaining = UsagePresentation.validUsedPercent(metric.amount) else { return "—" }
            return percentText(UsagePresentation.barPercent(used: 100 - remaining, mode: mode))
        case .timestamp:
            if let reset = metric.resetsAt {
                return TimeFormat.reset(
                    reset, now: now, language: language, style: resetStyle
                )
            }
            return format(metric)
        default:
            return format(metric)
        }
    }

    public static func format(_ metric: UsageMetric) -> String {
        if let display = metric.displayValue, !display.isEmpty { return display }
        guard let amount = metric.amount else { return "—" }
        return formatAmount(amount, currency: metric.currency)
    }

    /// 整数保持整数（≥ 10000 加千分位）；否则最多 2 位小数。无币种时不用 `MoneyFormat` 的 K/M/B。
    public static func formatAmount(_ amount: Double, currency: String? = nil) -> String {
        guard amount.isFinite else { return "—" }
        if let currency, !currency.isEmpty {
            return MoneyFormat.string(amount, currency: currency)
        }
        if amount == amount.rounded() {
            if abs(amount) >= 10_000 { return grouped(amount, fractionDigits: 0) }
            return String(format: "%.0f", amount)
        }
        if abs(amount) >= 10_000 { return grouped(amount, fractionDigits: 2) }
        return String(format: "%.2f", amount)
    }

    public static func percentText(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.0f%%", value) }
        return String(format: "%.1f%%", value)
    }

    static func grouped(_ amount: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.\(fractionDigits)f", amount)
    }

    /// 抬头下元信息：账号名已是模板名时改显示 host，避免重复。
    public static func metaLine(templateName: String?, host: String?, cardTitle: String) -> String? {
        let name = templateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = cardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != title { return name }
        if !host.isEmpty { return host }
        return nil
    }
}

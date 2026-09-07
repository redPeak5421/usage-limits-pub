import Foundation

/// 桌面小组件（2×2 / 2×4）的尺寸与着色约定。
/// SharedUI 的视图必须读这些常量，避免预览和 WidgetKit 各写一套。
public enum WidgetChrome {
    /// 2×2 底部用量标题。原先 `.caption2`（约 11pt）/ 9pt。
    public static let usageTitlePointSize: Double = 13
    /// 2×4 额度条高度。原先 `ProgressView` + `scaleEffect(y: 0.8)` ≈ 3.2pt。
    public static let quotaBarHeight: Double = 6
    /// 2×4 / 4×4 左侧商标边长。原先 11。
    public static let providerLogoSize: Double = 15
    /// 2×4 / 4×4 产品名（Claude / ChatGPT）字号。原先 caption ≈ 12。
    public static let providerNamePointSize: Double = 13
    /// 过长别名在 logo 旁换行，最多两行；字号字重与短名相同，不缩字。
    public static let providerNameLineLimit = 2
    /// 4×4 总览的名称字号整体缩小，8 字以内单行显示、不够宽时等比缩字。
    public static let largeOverviewNamePointSize: Double = 11
    public static let largeOverviewSingleLineNameLength = 8
    /// 左侧名称列宽。原先 72。加宽靠压缩间距和百分比列，额度条高度不变。
    public static let nameColumnWidth: Double = 88
    public static let percentColumnWidth: Double = 50
    /// 4×4 满 4 家时每家默认条数。
    public static let maxMetersPerAccount = 2
    /// 单账号 2×4：一张卡只有一个实例，最多 4 条。
    public static let maxMetersPerSingleAccount = 4
    /// 2×2 同心环最多两条。
    public static let maxMetersPerSmall = 2

    /// 2×4（单账号）只显示 1 个实例；4×4 总览最多 4 个。2×4 总览已下线（DEVLOG #99）。
    public static func overviewAccountLimit(isLarge: Bool) -> Int {
        isLarge ? 4 : 1
    }

    /// 总览每家额度：首页 `activeMetrics`（含改序）的前 N 条，不从别家补。
    /// 4×4：1→8、2→4、3→3、4+→2。2×4 单账号固定 1 家、前 4 条。
    public static func overviewMetersPerAccount(accountCount: Int, isLarge: Bool) -> Int {
        if !isLarge { return maxMetersPerSingleAccount }
        switch max(accountCount, 0) {
        case 0, 1: return 8
        case 2: return 4
        case 3: return 3
        default: return maxMetersPerAccount
        }
    }
    /// 2×2 名称 / 计量标签。比原先 caption / 13pt 更小，好往边缘靠。
    public static let smallNamePointSize: Double = 11
    public static let smallTitlePointSize: Double = 10
    public static let smallRingLineWidth: Double = 6
    public static let rainbowBloomLineWidth: Double = 2
    /// 三层描边 / 模糊相对线宽的倍数，由外到内。
    public static let rainbowRimLayers: [(stroke: Double, blur: Double)] = [(4.5, 3.2), (2.4, 1.8), (1, 0.9)]
    /// 向内到达（最外层描边 + 模糊）= 15.4pt，略过预览 padding 14 / 系统 content margin ~16，
    /// 但最外层透明度只有 0.28、末端是模糊尾巴，压不到贴边标题。
    public static var rainbowBloomReach: Double {
        rainbowBloomLineWidth * (rainbowRimLayers[0].stroke + rainbowRimLayers[0].blur)
    }
    public static let rainbowEdgeInsetPixels: Double = 1
    /// 按屏幕倍率换算成 pt：3x 机型 ⅓ pt，2x 机型 ½ pt。
    public static func rainbowEdgeInset(displayScale: Double) -> Double {
        rainbowEdgeInsetPixels / max(displayScale, 1)
    }
}

/// 小组件一行：一个已添加账号实例（不是「每个服务商只能一行」）。
public struct WidgetAccountItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: ProviderID
    public var title: String
    /// 附加账号走独立快照键；主账号 / 服务商级走 `snapshot.<provider>`。
    public var extraAccountID: UUID?
    /// 自定义账号：`extraAccountID` 必填，快照只读账号键。
    public var isCustom: Bool

    public init(
        id: String,
        provider: ProviderID,
        title: String,
        extraAccountID: UUID? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.extraAccountID = extraAccountID
        self.isCustom = isCustom
    }
}

/// 总览按账号实例勾选。空 `pickedIDs` = 全部可见实例（新装默认）；
/// 非空则只保留这些 id，顺序跟勾选顺序（编辑页实例顺序）。
public enum WidgetAccountItems {
    public static func overview(
        pickedIDs: [String],
        accounts: [ProviderAccount],
        providerOrder: [ProviderID],
        preview: Bool,
        isProviderEnabled: (ProviderID) -> Bool,
        language: AppLanguage = .system
    ) -> [WidgetAccountItem] {
        let fromAccounts: [WidgetAccountItem] = accounts.compactMap { account in
            switch account.source {
            case .builtin(let provider):
                if !preview {
                    guard AccountVisibility.shouldShowOnHome(
                        account, providerEnabled: isProviderEnabled(provider)
                    ) else { return nil }
                }
                return WidgetAccountItem(
                    id: account.id.uuidString,
                    provider: provider,
                    title: account.displayName(language: language),
                    extraAccountID: account.isPrimary ? nil : account.id,
                    isCustom: false
                )
            case .custom:
                if !preview {
                    guard AccountVisibility.shouldShowOnHome(account, providerEnabled: true) else {
                        return nil
                    }
                }
                return WidgetAccountItem(
                    id: account.id.uuidString,
                    provider: .claude,
                    title: account.displayName(language: language),
                    extraAccountID: account.id,
                    isCustom: true
                )
            }
        }
        if !fromAccounts.isEmpty {
            if pickedIDs.isEmpty { return fromAccounts }
            let byID = Dictionary(uniqueKeysWithValues: fromAccounts.map { ($0.id, $0) })
            return pickedIDs.compactMap { byID[$0] }
        }

        let order = providerOrder.isEmpty ? ProviderID.allCases : providerOrder
        let fallback: [WidgetAccountItem] = order.compactMap { provider in
            if !preview && !isProviderEnabled(provider) { return nil }
            return WidgetAccountItem(
                id: "provider.\(provider.rawValue)",
                provider: provider,
                title: provider.localizedName(language)
            )
        }
        if pickedIDs.isEmpty { return fallback }
        let byID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        return pickedIDs.compactMap { byID[$0] }
    }

    public static func snapshot(
        for item: WidgetAccountItem,
        now: Date,
        store: SharedStore
    ) -> ProviderSnapshot? {
        if item.isCustom {
            guard let extraID = item.extraAccountID else { return nil }
            if store.demoMode { return nil }
            return store.accountSnapshot(for: extraID)
        }
        if store.demoMode {
            return store.displaySnapshot(for: item.provider, now: now)
        }
        if let extraID = item.extraAccountID {
            return store.accountSnapshot(for: extraID)
        }
        return store.displaySnapshot(for: item.provider, now: now)
            ?? store.snapshot(for: item.provider)
    }

    /// 2×4 / 4×4 一行：官方用 `usedPercent`；自定义折叠行带首页 gauge 的展示百分比。
    public struct OverviewMeter: Equatable, Sendable {
        public var metric: UsageMetric
        public var displayedPercent: Double?
        public var riskPercent: Double?

        public init(metric: UsageMetric, displayedPercent: Double? = nil, riskPercent: Double? = nil) {
            self.metric = metric
            self.displayedPercent = displayedPercent
            self.riskPercent = riskPercent
        }
    }

    /// 按勾选顺序取计量；空勾选跟展开顺序。`cap` 默认总览上限。
    public static func selectedMeters(
        from snap: ProviderSnapshot,
        pickedIDs: [String] = [],
        cap: Int,
        mode: UsageDisplayMode = .used,
        language: AppLanguage = .zh
    ) -> [OverviewMeter] {
        let shown = snap.isCustom
            ? CustomUsageDisplay.presentation(from: snap, mode: mode, language: language)
            : nil
        var source = snap.activeMetrics.filter { $0.usedPercent != nil || $0.amount != nil }
        if source.isEmpty {
            source = snap.metrics.filter { $0.usedPercent != nil || $0.amount != nil }
        }
        if !pickedIDs.isEmpty {
            // 编辑页「+」能挑到未上屏的额度（用量为 0 或首页隐藏），用户点名要就得显示，不能只在首页可见项里找（DEVLOG #102）。
            let pool = snap.metrics.filter { $0.usedPercent != nil || $0.amount != nil }
            let ordered = pickedIDs.compactMap { id in pool.first { $0.id == id } }
            if !ordered.isEmpty { source = ordered }
        }
        return Array(source.prefix(max(cap, 0))).map { metric in
            if metric.id == shown?.hero?.id, let gauge = shown?.gauge {
                return OverviewMeter(
                    metric: metric,
                    displayedPercent: gauge.displayedPercent,
                    riskPercent: gauge.riskPercent
                )
            }
            return OverviewMeter(metric: metric)
        }
    }

    /// 2×4 / 4×4 行数据：默认每家 `maxMetersPerAccount` 条，跟展开态同一份可见顺序。总览按实例数改 cap。
    public static func overviewRows(
        from snap: ProviderSnapshot,
        mode: UsageDisplayMode = .used,
        language: AppLanguage = .zh,
        pickedIDs: [String] = [],
        cap: Int? = nil
    ) -> [OverviewMeter] {
        selectedMeters(
            from: snap,
            pickedIDs: pickedIDs,
            cap: cap ?? WidgetChrome.maxMetersPerAccount,
            mode: mode,
            language: language
        )
    }
}

/// 小组件行数超上限时的取舍。
public enum WidgetRowSelection {
    /// 超出上限时留最后一行给「还有 N 项」：`visible == cap - 1`。
    public static func overflow(rowCount: Int, cap: Int) -> (visible: Int, hidden: Int) {
        guard cap > 0 else { return (0, max(rowCount, 0)) }
        if rowCount <= cap { return (rowCount, 0) }
        let visible = cap - 1
        return (visible, rowCount - visible)
    }
}


/// 系统编辑页数组预填：`@Parameter(default:)` 在抽 metadata 时读不到 App Group、换账号时又会被系统重置回默认值，
/// 所以默认是 4 个与账号无关的 `home.slot.N` 占位槽；显示名由扩展按刚换到的账号现算（DEVLOG #104），
/// 时间线按 `prefillIDs` 把槽位映射成该账号的额度（含用户改序）；旧配置的 `home.follow` 行继续展开成首页额度（#102）。
public enum WidgetEditorPrefill {
    public static let slotPrefix = "home.slot."

    /// 槽位 id：`home.slot.N`；编辑页按账号预填时带上账号 `home.slot.N@<账号 id>`（DEVLOG #104），
    /// 时间线发现槽位属于别的账号（扩展进程里缓存的账号被别的小组件抢先改掉）就当作未配置、展开成本账号全部预填额度。
    public static let slotOwnerSeparator: Character = "@"

    public static func slotID(_ index: Int, owner: String? = nil) -> String {
        guard let owner, !owner.isEmpty else { return "\(slotPrefix)\(index)" }
        return "\(slotPrefix)\(index)\(slotOwnerSeparator)\(owner)"
    }

    public static func slotIndex(_ id: String) -> Int? {
        guard id.hasPrefix(slotPrefix) else { return nil }
        let rest = id.dropFirst(slotPrefix.count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).first.map({ $0 == slotOwnerSeparator }) ?? true else { return nil }
        return Int(String(digits))
    }

    public static func slotOwner(_ id: String) -> String? {
        guard slotIndex(id) != nil, let sep = id.firstIndex(of: slotOwnerSeparator) else { return nil }
        let owner = String(id[id.index(after: sep)...])
        return owner.isEmpty ? nil : owner
    }

    /// 全是槽位、且有槽位标着别的账号 = 默认值被别的账号污染，按本账号全部预填额度重来。
    static func isForeignDefault(_ identifiers: [String], account: String?) -> Bool {
        guard !identifiers.isEmpty, identifiers.allSatisfy({ slotIndex($0) != nil }) else { return false }
        return identifiers.contains { id in
            guard let owner = slotOwner(id) else { return false }
            return owner != account
        }
    }

    public static func resolveIDs(_ identifiers: [String], catalogIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in identifiers {
            if isHeaderID(id) { continue }
            let mapped: String?
            if let idx = slotIndex(id) {
                mapped = catalogIDs.indices.contains(idx) ? catalogIDs[idx] : nil
            } else {
                mapped = id
            }
            guard let mapped, seen.insert(mapped).inserted else { continue }
            result.append(mapped)
        }
        return result
    }

    /// 编辑页 `entities(for:)`：一对一解析系统传入的 identifier，空列表不回填首页。
    /// 「跟随首页额度」行与占位槽都保留自身 id 当实体 id，系统按 id 删除才能拿掉已选项。
    public static func editorItems(
        identifiers: [String],
        homeIDs: [String],
        catalogIDs: [String],
        account: String? = nil
    ) -> [(id: String, catalogID: String)] {
        let slots = prefillIDs(homeIDs: homeIDs, catalogIDs: catalogIDs)
        let identifiers = isForeignDefault(identifiers, account: account)
            ? slots.indices.map { slotID($0, owner: account) }
            : identifiers
        var seen = Set<String>()
        var result: [(id: String, catalogID: String)] = []
        for id in identifiers {
            let catalogID: String?
            if isFollowHomeID(id) {
                catalogID = id
            } else if let idx = slotIndex(id) {
                catalogID = slots.indices.contains(idx) ? slots[idx] : nil
            } else if catalogIDs.contains(id) {
                catalogID = id
            } else {
                catalogID = nil
            }
            guard let catalogID, seen.insert(catalogID).inserted else { continue }
            result.append((id: id, catalogID: catalogID))
        }
        return result
    }

    /// 占位槽对应的额度：首页可见额度在前，不够 `limit` 条再拿目录里其余有数值的补齐（DEVLOG #104：编辑页最多预填 4 条）。
    public static func prefillIDs(
        homeIDs: [String],
        catalogIDs: [String],
        limit: Int = WidgetChrome.maxMetersPerSingleAccount
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in homeIDs + catalogIDs where seen.insert(id).inserted {
            result.append(id)
            if result.count >= limit { break }
        }
        return result
    }

    /// 时间线读配置：空配置 → 首页可见额度；「跟随首页额度」行展开成首页可见额度；占位槽按序号映射到
    /// `prefillIDs`（首页在前、目录补齐到 4 条，与编辑页显示的名字同一份）；用户勾选过的保留（含新增的未上屏项），
    /// 按出现顺序去重，全都对不上才回落首页。
    public static func entitiesToShow(
        identifiers: [String],
        homeIDs: [String],
        catalogIDs: [String],
        account: String? = nil
    ) -> [String] {
        let identifiers = identifiers.filter { !isHeaderID($0) }
        if identifiers.isEmpty { return homeIDs }
        let slots = prefillIDs(homeIDs: homeIDs, catalogIDs: catalogIDs)
        if isForeignDefault(identifiers, account: account) { return slots }
        var seen = Set<String>()
        var result: [String] = []
        func add(_ id: String) {
            guard homeIDs.contains(id) || catalogIDs.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }
        var followed = false
        for id in identifiers {
            if isFollowHomeID(id) {
                followed = true
                homeIDs.forEach(add)
            } else if let idx = slotIndex(id) {
                if slots.indices.contains(idx) { add(slots[idx]) }
            } else {
                add(id)
            }
        }
        if result.isEmpty, !followed, !identifiers.allSatisfy({ slotIndex($0) != nil }) {
            return homeIDs
        }
        return result
    }

    /// 「跟随首页额度」行：与账号无关的一行说明，时间线把它展开成所选账号的首页可见额度（DEVLOG #102）。
    public static let followHomeID = "home.follow"

    public static func isFollowHomeID(_ id: String) -> Bool {
        id == followHomeID
    }

    public static func followHomeTitle(language: AppLanguage) -> String {
        L10n.tr("widget.followHome", language)
    }

    /// 占位槽拿不到账号时的显示名「首页额度 N」（DEVLOG #100 / #104：只在「最高用量（自动）」或该账号额度不够 N 条时出现）。
    public static func slotTitle(index: Int, language: AppLanguage) -> String {
        L10n.tr("widget.homeSlot", language, index + 1)
    }

    /// 账号额度不够 N 条时多余槽位的显示名「（空）」：系统不会按 `entities(for:)` 的条数裁掉默认槽位（DEVLOG #104），
    /// 只能如实标成空槽，时间线不显示它，用户可删。
    public static func emptySlotTitle(language: AppLanguage) -> String {
        L10n.tr("widget.emptySlot", language)
    }

    public static let headerPrefix = "home.header."

    public static func isHeaderID(_ id: String) -> Bool {
        id.hasPrefix(headerPrefix)
    }
}


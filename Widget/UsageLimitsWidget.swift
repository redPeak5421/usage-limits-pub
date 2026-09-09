import WidgetKit
import SwiftUI
import AppIntents
import os.log
import UsageLimitsCore

// MARK: - 2×2 单服务商小组件（可配置选择服务商）

enum ProviderChoice: String, AppEnum, CaseIterable {
    case claude, openai, grok, cursor, deepseek, zhipu, kimi, minimax, jimeng, opencode
    case longcat, mimo, qoder, perplexity, augment, abacus, t3chat, notion, ollama, stepfun
    case minimaxGlobal = "minimax_global"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.providerType")
    static var caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .claude: "Claude",
        .openai: "ChatGPT",
        .grok: "Grok",
        .cursor: "Cursor",
        .deepseek: "DeepSeek",
        .zhipu: DisplayRepresentation(title: LocalizedStringResource("provider.name.zhipu")),
        .kimi: "Kimi",
        .minimax: "MiniMax",
        .jimeng: DisplayRepresentation(title: LocalizedStringResource("provider.name.jimeng")),
        .opencode: "OpenCode",
        .longcat: "LongCat",
        .mimo: "MiMo",
        .qoder: "Qoder",
        .perplexity: "Perplexity",
        .augment: "Augment",
        .abacus: "Abacus AI",
        .t3chat: "T3 Chat",
        .notion: "Notion AI",
        .ollama: "Ollama",
        .stepfun: "StepFun",
        .minimaxGlobal: DisplayRepresentation(title: LocalizedStringResource("provider.name.minimax_global")),
    ]

    var providerID: ProviderID { ProviderID(rawValue: rawValue) ?? .claude }
}

/// 小组件配置里的账号实例（同一服务商多个账号各一条）。
struct AccountChoiceEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.accountType")
    static var defaultQuery = AccountChoiceQuery()

    var id: String
    var title: String
    var providerRaw: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// 「最高用量（自动）」虚拟账号：每次刷新时挑已用百分比最高的可见账号，参考 CodexBar 的最高用量自动选择。
enum HighestUsageChoice {
    static let id = "auto.highest"
    static var title: String { L10n.tr("widget.highestUsage", SharedStore.shared.appLanguage) }
    static var entity: AccountChoiceEntity { AccountChoiceEntity(id: id, title: title, providerRaw: "auto") }
}

struct AccountChoiceQuery: EntityQuery, EntityStringQuery {
    /// 按 id 回查必须覆盖全部账号（含已停用 / 服务商已关闭的），否则用户选中的账号
    /// 一旦不在「首页可见」列表里就解析失败，小组件会退回到第一个账号，显示成别人的用量。
    func entities(for identifiers: [AccountChoiceEntity.ID]) async throws -> [AccountChoiceEntity] {
        let store = SharedStore.shared
        let known = [HighestUsageChoice.entity] + store.accounts.map {
            AccountChoiceEntity(
                id: $0.id.uuidString,
                title: store.displayName(for: $0),
                providerRaw: $0.isCustom ? "custom" : ($0.provider?.rawValue ?? "custom")
            )
        } + ProviderID.allCases.map {
            AccountChoiceEntity(id: "provider.\($0.rawValue)", title: $0.localizedName(store.appLanguage), providerRaw: $0.rawValue)
        }
        let found = identifiers.compactMap { id in known.first { $0.id == id } }
        // 编辑页选中账号时系统会按 id 回查一次，紧接着调额度查询和默认实体的显示名；先记下它（DEVLOG #104）
        if found.count == 1, identifiers.count == 1 { EditorDependencyCache.note(found[0]) }
        return found
    }

    /// 选择器列表。`EntityQuery` 默认实现返回空数组，少了这行编辑页就是「无可用选项」（DEVLOG #101）。
    func suggestedEntities() async throws -> [AccountChoiceEntity] { Self.displayed() }

    func entities(matching string: String) async throws -> [AccountChoiceEntity] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = Self.all()
        guard !q.isEmpty else { return Self.displayed() }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    func defaultResult() async -> AccountChoiceEntity? { Self.all().first }

    /// 主屏已显示的实例，不含「用量最高（自动）」。总览编辑页预填必须跟这份名单。
    static func displayed() -> [AccountChoiceEntity] {
        all().filter { $0.id != HighestUsageChoice.id }
    }

    static func all() -> [AccountChoiceEntity] {
        let store = SharedStore.shared
        let visible = store.accounts.filter {
            AccountVisibility.shouldShowOnHome($0, providerEnabled: store.isProviderEnabled(for: $0))
        }
        if !visible.isEmpty {
            return [HighestUsageChoice.entity] + visible.map {
                AccountChoiceEntity(
                    id: $0.id.uuidString,
                    title: store.displayName(for: $0),
                    providerRaw: $0.isCustom ? "custom" : ($0.provider?.rawValue ?? "custom")
                )
            }
        }
        return [HighestUsageChoice.entity] + ProviderAvailability.providers.map {
            AccountChoiceEntity(
                id: "provider.\($0.rawValue)",
                title: $0.localizedName(store.appLanguage),
                providerRaw: $0.rawValue
            )
        }
    }
}

/// 编辑页勾选的计量条；id 跟 UsageMetric.id。
/// `title` 为空 = 与账号无关的行：占位槽 `home.slot.N`（默认值）或旧配置的「跟随首页额度」`home.follow`。
/// 换账号时系统的顺序是：算静态默认值 → 用新账号调 `entities(for:)` → 调默认实体的 `displayRepresentation`，
/// 所以占位槽的显示名在这里按 `EditorDependencyCache` 刚记下的账号现算；拿不到账号才退回「首页额度 N」。
/// 不得再按 nil 账号查目录猜实例——那会把首页第一个账号的额度名挂到别的账号下（DEVLOG #100 / #104）。
struct MetricChoiceEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.metricType")
    static var defaultQuery = MetricChoiceQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        if title.isEmpty {
            let language = SharedStore.shared.appLanguage
            if WidgetEditorPrefill.isFollowHomeID(id) {
                return DisplayRepresentation(title: "\(WidgetEditorPrefill.followHomeTitle(language: language))")
            }
            if let index = WidgetEditorPrefill.slotIndex(id) {
                // 换账号时系统刚用新账号调过 entities(for:)，这里按那个账号把第 N 槽显示成它的第 N 条额度名（DEVLOG #104）；
                // 该账号额度不够 N 条就标「（空）」；拿不到账号或「最高用量（自动）」才叫「首页额度 N」。
                if let account = EditorDependencyCache.recent(), account.id != HighestUsageChoice.id {
                    let names = MetricChoiceDefaults.prefillTitles(for: account)
                    if names.indices.contains(index) {
                        return DisplayRepresentation(title: "\(names[index])")
                    }
                    // 账号一条额度都没有（未登录 / 未抓到）时仍叫「首页额度 N」，登录后小组件照常跟随首页
                    if !names.isEmpty {
                        return DisplayRepresentation(title: "\(WidgetEditorPrefill.emptySlotTitle(language: language))")
                    }
                }
                return DisplayRepresentation(title: "\(WidgetEditorPrefill.slotTitle(index: index, language: language))")
            }
        }
        return DisplayRepresentation(title: "\(title.isEmpty ? id : title)")
    }
}

enum WidgetMetricCatalog {
    static func entities(for account: AccountChoiceEntity?, displayedOnly: Bool = false) -> [MetricChoiceEntity] {
        let store = SharedStore.shared
        guard let snap = snapshot(for: account, store: store) else { return [] }
        return metricPairs(from: snap, language: store.appLanguage, displayedOnly: displayedOnly).map {
            MetricChoiceEntity(id: $0.id, title: $0.title)
        }
    }

    static func resolvedIDs(for account: AccountChoiceEntity?, identifiers: [String]) -> [String] {
        WidgetEditorPrefill.entitiesToShow(
            identifiers: identifiers,
            homeIDs: entities(for: account, displayedOnly: true).map(\.id),
            catalogIDs: entities(for: account, displayedOnly: false).map(\.id),
            account: account?.id
        )
    }

    static func snapshot(for account: AccountChoiceEntity?, store: SharedStore) -> ProviderSnapshot? {
        let now = Date()
        if let account, account.id == HighestUsageChoice.id {
            // 编辑页目录必须和时间线挑同一个实例，否则槽位映射出的是别家的额度 id。
            return SingleEntryFactory.highestUsageEntry(date: now, preview: false, store: store).snapshot
        }
        if let account,
           let uuid = UUID(uuidString: account.id),
           let acc = store.accounts.first(where: { $0.id == uuid }) {
            return WidgetAccountItems.snapshot(
                for: WidgetAccountItem(
                    id: acc.id.uuidString,
                    provider: acc.provider ?? .claude,
                    title: store.displayName(for: acc),
                    extraAccountID: acc.isCustom || !acc.isPrimary ? acc.id : nil,
                    isCustom: acc.isCustom
                ),
                now: now,
                store: store
            )
        }
        if let account, account.id.hasPrefix("provider."),
           let provider = ProviderID(rawValue: String(account.id.dropFirst("provider.".count))) {
            return store.displaySnapshot(for: provider, now: now)
        }
        if let acc = store.accounts.first(where: {
            AccountVisibility.shouldShowOnHome($0, providerEnabled: store.isProviderEnabled(for: $0))
        }) {
            return WidgetAccountItems.snapshot(
                for: WidgetAccountItem(
                    id: acc.id.uuidString,
                    provider: acc.provider ?? .claude,
                    title: store.displayName(for: acc),
                    extraAccountID: acc.isCustom || !acc.isPrimary ? acc.id : nil,
                    isCustom: acc.isCustom
                ),
                now: now,
                store: store
            )
        }
        return store.displaySnapshot(for: .claude, now: now)
    }

    static func metricPairs(
        from snap: ProviderSnapshot,
        language: AppLanguage,
        displayedOnly: Bool = false
    ) -> [(id: String, title: String)] {
        let source: [UsageMetric]
        if displayedOnly {
            source = snap.activeMetrics
        } else {
            let homeIDs = Set(snap.activeMetrics.map(\.id))
            let extras = snap.metrics.filter { metric in
                homeIDs.contains(metric.id) == false
                    && (metric.usedPercent != nil || metric.amount != nil || metric.pinned == true)
            }
            source = snap.activeMetrics + extras
        }
        return source.map { metric in
            let title = snap.isCustom
                ? L10n.tr(metric.label, language)
                : L10n.metricLabel(provider: snap.provider, id: metric.id, fallback: metric.label, language: language)
            return (metric.id, title)
        }
    }
}

private let widgetDefaultsLog = OSLog(subsystem: "widget", category: "defaults")

private func logWidgetDefault(_ name: String, count: Int) {
    os_log("defaultResult %{public}@ count=%{public}d", log: widgetDefaultsLog, type: .info, name, count)
}

/// 编辑页换账号时系统的调用顺序（DEVLOG #104 日志实测）：先重建 intent 取 `@Parameter(default:)`（此时拿不到账号），
/// 再用新账号依赖调 `MetricChoiceQuery.entities(for:)`（返回值不上屏），最后调默认实体的 `displayRepresentation` 渲染并
/// 随配置持久化。带依赖的调用把账号记在扩展进程内，`displayRepresentation` 几毫秒后据此现算显示名。
/// 只认 2 秒内的记录：时间线解码也会走这些调用，别的小组件留下的账号不能被拿来命名。
enum EditorDependencyCache {
    private static let lock = NSLock()
    private static var account: AccountChoiceEntity?
    private static var stamp = Date.distantPast

    static func note(_ account: AccountChoiceEntity?) {
        lock.lock()
        self.account = account
        stamp = Date()
        lock.unlock()
    }

    static func recent(within seconds: TimeInterval = 2) -> AccountChoiceEntity? {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(stamp) < seconds else { return nil }
        return account
    }
}

enum MetricChoiceDefaults {
    /// `@Parameter(default:)`：4 个与账号无关的占位槽（2×4 最多 4 条，2×2 由 size 截到 2）。系统重建 intent 取默认值
    /// 发生在回查账号之前（DEVLOG #104 日志），这里拿不到账号、也定不了条数；显示名见
    /// `MetricChoiceEntity.displayRepresentation`，时间线按 `WidgetEditorPrefill.prefillIDs` 映射，多余槽位标「（空）」。
    /// 绝不能在这里按「首页第一个实例」预填额度名（DEVLOG #100）。
    static var slots: [MetricChoiceEntity] {
        (0..<WidgetChrome.maxMetersPerSingleAccount).map { MetricChoiceEntity(id: WidgetEditorPrefill.slotID($0), title: "") }
    }

    /// 某账号占位槽对应的额度名：首页可见额度在前，目录补齐到 4 条，与时间线的 `prefillIDs` 同一份顺序。
    /// 「最高用量（自动）」会换账号，不给具体名字（显示「首页额度 N」）。
    static func prefillTitles(for account: AccountChoiceEntity) -> [String] {
        guard account.id != HighestUsageChoice.id else { return [] }
        let home = WidgetMetricCatalog.entities(for: account, displayedOnly: true)
        let catalog = WidgetMetricCatalog.entities(for: account, displayedOnly: false)
        let ids = WidgetEditorPrefill.prefillIDs(homeIDs: home.map(\.id), catalogIDs: catalog.map(\.id))
        return ids.compactMap { id in (home + catalog).first { $0.id == id }?.title }
    }
}

enum OverviewDefaults {
    static func accounts(limit: Int) -> [AccountChoiceEntity] {
        Array(AccountChoiceQuery.displayed().prefix(limit))
    }
}

struct MetricChoiceQuery: EntityQuery, EntityStringQuery {
    @IntentParameterDependency<SingleProviderConfigIntent>(\.$account)
    var config

    func entities(for identifiers: [MetricChoiceEntity.ID]) async throws -> [MetricChoiceEntity] {
        EditorDependencyCache.note(config?.account)
        let catalog = WidgetMetricCatalog.entities(for: config?.account, displayedOnly: false)
        let home = WidgetMetricCatalog.entities(for: config?.account, displayedOnly: true)
        let items = WidgetEditorPrefill.editorItems(
            identifiers: identifiers,
            homeIDs: home.map(\.id),
            catalogIDs: catalog.map(\.id),
            account: config?.account.id
        )
        return items.map { item in
            if WidgetEditorPrefill.isFollowHomeID(item.id) {
                return MetricChoiceEntity(id: item.id, title: "")
            }
            let title = catalog.first { $0.id == item.catalogID }?.title ?? item.catalogID
            return MetricChoiceEntity(id: item.id, title: title)
        }
    }

    func suggestedEntities() async throws -> [MetricChoiceEntity] {
        EditorDependencyCache.note(config?.account)
        return WidgetMetricCatalog.entities(for: config?.account, displayedOnly: false)
    }

    func entities(matching string: String) async throws -> [MetricChoiceEntity] {
        EditorDependencyCache.note(config?.account)
        let all = WidgetMetricCatalog.entities(for: config?.account, displayedOnly: false)
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    /// 数组参数的默认值：`DynamicOptionsProvider.DefaultValue` 声明成 `[Entity]`，系统换账号时按依赖账号现算默认列表。
    /// 系统换账号时会带新账号依赖调这里（返回值本身不上屏，见 `EditorDependencyCache`）。
    /// 不得改成数组 `DefaultValue`：真机上会让所有编辑页「无法载入」（DEVLOG #56）。
    func defaultResult() async -> MetricChoiceEntity? {
        EditorDependencyCache.note(config?.account)
        return WidgetMetricCatalog.entities(for: config?.account, displayedOnly: true).first
    }
}

/// 总览账号：主页已显示实例，丢掉「最高用量（自动）」。
struct OverviewAccountChoiceQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [AccountChoiceEntity.ID]) async throws -> [AccountChoiceEntity] {
        let known = try await AccountChoiceQuery().entities(for: identifiers)
        return known.filter { $0.id != HighestUsageChoice.id }
    }

    func suggestedEntities() async throws -> [AccountChoiceEntity] { AccountChoiceQuery.displayed() }

    func entities(matching string: String) async throws -> [AccountChoiceEntity] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = AccountChoiceQuery.displayed()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    func defaultResult() async -> AccountChoiceEntity? {
        let first = OverviewDefaults.accounts(limit: 1).first
        logWidgetDefault("overviewAccounts", count: first == nil ? 0 : 1)
        return first
    }
}

struct SingleProviderConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "widget.chooseAccount"
    static var description = IntentDescription("widget.singleDescription")

    @Parameter(title: "widget.accountType")
    var account: AccountChoiceEntity?

    /// 参数名从 `metrics` 改成 `quotas`（DEVLOG #103）：系统只会原样显示存在配置里的额度文案、从不为它重新调查询，
    /// 老版本写死的「额度」占位行扩展没法刷新；换参数名后旧值随旧键一起被丢弃，空值 = 跟随首页。账号参数不改名，
    /// 系统会用 `entities(for:)` 重新解析它。改名后旧小组件的额度列表是空的（不是默认行），所以参数标题写明「留空则跟随首页」。
    @Parameter(
        title: "widget.quotaParam",
        default: MetricChoiceDefaults.slots,
        size: [
            .systemSmall: IntentCollectionSize(min: 0, max: 2),
            .systemMedium: IntentCollectionSize(min: 0, max: 4)
        ],
        query: MetricChoiceQuery()
    )
    var quotas: [MetricChoiceEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$account)") {
            \.$quotas
        }
    }
}

struct OverviewConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "widget.overviewTitle"
    static var description = IntentDescription("widget.overviewDescription")

    @Parameter(
        title: "widget.overviewTitle",
        default: OverviewDefaults.accounts(limit: 4),
        size: [
            .systemLarge: IntentCollectionSize(min: 1, max: 4)
        ],
        query: OverviewAccountChoiceQuery()
    )
    var accounts: [AccountChoiceEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$accounts)")
    }
}

struct SingleEntry: TimelineEntry {
    let date: Date
    let provider: ProviderID
    let title: String
    let snapshot: ProviderSnapshot?
    var disabled: Bool = false
    var extraAccountID: UUID?
    var isCustom: Bool = false
    var tint: BrandTint?
    var customLogoData: Data?
    var selectedMetricIDs: [String] = []
}

enum SingleEntryFactory {
    static func placeholder() -> SingleEntry {
        SingleEntry(
            date: Date(), provider: .claude, title: ProviderID.claude.localizedName(SharedStore.shared.appLanguage),
            snapshot: SharedStore.demoSnapshots(now: Date()).first
        )
    }

    static func entry(account: AccountChoiceEntity?, metricIDs: [String], date: Date, preview: Bool) -> SingleEntry {
        var resolved = resolve(account: account, date: date, preview: preview)
        resolved.selectedMetricIDs = metricIDs
        return resolved
    }

    static func timeline(account: AccountChoiceEntity?, metricIDs: [String], date: Date) -> Timeline<SingleEntry> {
        let entries = (0..<4).map { i in
            entry(account: account, metricIDs: metricIDs, date: date.addingTimeInterval(Double(i) * 15 * 60), preview: false)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private static func resolve(account: AccountChoiceEntity?, date: Date, preview: Bool) -> SingleEntry {
        let store = SharedStore.shared
        if let entity = account, entity.id == HighestUsageChoice.id {
            return highestUsageEntry(date: date, preview: preview, store: store)
        }
        if let entity = account,
           let uuid = UUID(uuidString: entity.id),
           let acc = store.accounts.first(where: { $0.id == uuid }) {
            return entry(for: acc, date: date, preview: preview, store: store)
        }
        if let entity = account, entity.id.hasPrefix("provider."),
           let provider = ProviderID(rawValue: String(entity.id.dropFirst("provider.".count))) {
            return fallbackEntry(provider: provider, date: date, preview: preview, store: store)
        }
        if let entity = account {
            let provider = ProviderID(rawValue: entity.providerRaw) ?? .claude
            return SingleEntry(
                date: date, provider: provider, title: entity.title, snapshot: nil,
                disabled: true, isCustom: entity.providerRaw == "custom"
            )
        }
        if let acc = store.accounts.first(where: {
            ProviderAvailability.isAvailable($0) && (preview || AccountVisibility.shouldShowOnHome($0, providerEnabled: store.isProviderEnabled(for: $0)))
        }) {
            return entry(for: acc, date: date, preview: preview, store: store)
        }
        return fallbackEntry(provider: .claude, date: date, preview: preview, store: store)
    }

    static func highestUsageEntry(date: Date, preview: Bool, store: SharedStore) -> SingleEntry {
        let visible = store.accounts.filter {
            preview || AccountVisibility.shouldShowOnHome($0, providerEnabled: store.isProviderEnabled(for: $0))
        }
        if !visible.isEmpty {
            let picked = HighestUsagePicker.pick(visible) { account -> ProviderSnapshot? in
                entry(for: account, date: date, preview: preview, store: store).snapshot
            } ?? visible[0]
            return entry(for: picked, date: date, preview: preview, store: store)
        }
        let providers = store.providerOrder.filter { ProviderAvailability.isAvailable($0) && (preview || store.isEnabled($0)) }
        let picked = HighestUsagePicker.pick(providers) { provider -> ProviderSnapshot? in
            fallbackEntry(provider: provider, date: date, preview: preview, store: store).snapshot
        } ?? providers.first ?? .claude
        return fallbackEntry(provider: picked, date: date, preview: preview, store: store)
    }

    private static func entry(
        for account: ProviderAccount, date: Date, preview: Bool, store: SharedStore
    ) -> SingleEntry {
        let disabled = !preview && !AccountVisibility.shouldShowOnHome(
            account, providerEnabled: store.isProviderEnabled(for: account)
        )
        let provider = account.provider ?? .claude
        var snap = WidgetAccountItems.snapshot(
            for: WidgetAccountItem(
                id: account.id.uuidString,
                provider: provider,
                title: store.displayName(for: account),
                extraAccountID: account.isCustom || !account.isPrimary ? account.id : nil,
                isCustom: account.isCustom
            ),
            now: date,
            store: store
        )
        if snap == nil, preview, let builtin = account.provider {
            snap = SharedStore.demoSnapshots(now: date).first { $0.provider == builtin }
        }
        return SingleEntry(
            date: date, provider: provider, title: store.displayName(for: account),
            snapshot: snap, disabled: disabled,
            extraAccountID: account.isCustom || !account.isPrimary ? account.id : nil,
            isCustom: account.isCustom,
            tint: account.isCustom
                ? TintResolver.resolve(
                    accountTint: account.tint,
                    templateTint: account.templateID.flatMap { store.customTemplate(id: $0)?.tint }
                )
                : store.resolvedTint(provider: provider, accountID: account.id),
            customLogoData: account.isCustom ? store.customLogoData(for: account) : nil
        )
    }

    private static func fallbackEntry(
        provider: ProviderID, date: Date, preview: Bool, store: SharedStore
    ) -> SingleEntry {
        let disabled = !ProviderAvailability.isAvailable(provider) || (!preview && !store.isEnabled(provider))
        var snap = store.displaySnapshot(for: provider, now: date)
        if snap == nil, preview {
            snap = SharedStore.demoSnapshots(now: date).first { $0.provider == provider }
        }
        let title = store.primaryAccount(of: provider).map { store.displayName(for: $0) }
            ?? provider.localizedName(store.appLanguage)
        return SingleEntry(date: date, provider: provider, title: title, snapshot: snap, disabled: disabled)
    }
}

struct SingleProviderSmallTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SingleEntry { SingleEntryFactory.placeholder() }

    func snapshot(for configuration: SingleProviderConfigIntent, in context: Context) async -> SingleEntry {
        SingleEntryFactory.entry(
            account: configuration.account,
            metricIDs: WidgetMetricCatalog.resolvedIDs(for: configuration.account, identifiers: configuration.quotas?.map(\.id) ?? []),
            date: Date(),
            preview: context.isPreview
        )
    }

    func timeline(for configuration: SingleProviderConfigIntent, in context: Context) async -> Timeline<SingleEntry> {
        return SingleEntryFactory.timeline(
            account: configuration.account,
            metricIDs: WidgetMetricCatalog.resolvedIDs(for: configuration.account, identifiers: configuration.quotas?.map(\.id) ?? []),
            date: Date()
        )
    }
}

struct SingleProviderMediumTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SingleEntry { SingleEntryFactory.placeholder() }

    func snapshot(for configuration: SingleProviderConfigIntent, in context: Context) async -> SingleEntry {
        SingleEntryFactory.entry(
            account: configuration.account,
            metricIDs: WidgetMetricCatalog.resolvedIDs(for: configuration.account, identifiers: configuration.quotas?.map(\.id) ?? []),
            date: Date(),
            preview: context.isPreview
        )
    }

    func timeline(for configuration: SingleProviderConfigIntent, in context: Context) async -> Timeline<SingleEntry> {
        return SingleEntryFactory.timeline(
            account: configuration.account,
            metricIDs: WidgetMetricCatalog.resolvedIDs(for: configuration.account, identifiers: configuration.quotas?.map(\.id) ?? []),
            date: Date()
        )
    }
}

struct SingleProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "SingleProviderWidget",
            intent: SingleProviderConfigIntent.self,
            provider: SingleProviderSmallTimeline()
        ) { entry in
            SmallUsageView(
                provider: entry.provider, snapshot: entry.snapshot, now: entry.date,
                disabled: entry.disabled, title: entry.title,
                isCustom: entry.isCustom, tint: entry.tint, customLogoData: entry.customLogoData,
                selectedMetricIDs: entry.selectedMetricIDs
            )
                .environment(\.appLanguage, SharedStore.shared.appLanguage)
                .environment(\.usageDisplayMode, SharedStore.shared.usageDisplayMode)
                .environment(\.resetTimeStyle, SharedStore.shared.resetTimeStyle)
                .widgetContentChrome()
                .containerBackground(for: .widget) { WidgetAppearance.background }
                .widgetAppearance()
                .widgetURL(singleWidgetURL(entry))
        }
        .configurationDisplayName("widget.gallery.single")
        .description("widget.gallery.singleDetail")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct SingleProviderMediumWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "SingleProviderMediumWidget",
            intent: SingleProviderConfigIntent.self,
            provider: SingleProviderMediumTimeline()
        ) { entry in
            MediumUsageView(
                items: entry.disabled ? [] : [
                    WidgetAccountDisplay(
                        id: entry.title, provider: entry.provider,
                        title: entry.title, snapshot: entry.snapshot,
                        isCustom: entry.isCustom, tint: entry.tint,
                        customLogoData: entry.customLogoData,
                        selectedMetricIDs: entry.selectedMetricIDs
                    )
                ],
                now: entry.date,
                maxMeters: WidgetChrome.maxMetersPerSingleAccount
            )
            .environment(\.appLanguage, SharedStore.shared.appLanguage)
                .environment(\.usageDisplayMode, SharedStore.shared.usageDisplayMode)
                .environment(\.resetTimeStyle, SharedStore.shared.resetTimeStyle)

                .widgetContentChrome()
                .containerBackground(for: .widget) { WidgetAppearance.background }
                .widgetAppearance()
                .widgetURL(singleWidgetURL(entry))
        }
        .configurationDisplayName("widget.gallery.medium")
        .description("widget.gallery.mediumDetail")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct OverviewEntry: TimelineEntry {
    let date: Date
    let items: [WidgetAccountDisplay]
}

enum OverviewEntryFactory {
    static func makeEntry(accountIDs: [String], date: Date, preview: Bool, accountLimit: Int) -> OverviewEntry {
        let store = SharedStore.shared
        let items = Array(WidgetAccountItems.overview(
            pickedIDs: accountIDs,
            accounts: store.accounts,
            providerOrder: store.providerOrder,
            preview: preview,
            isProviderEnabled: { store.isEnabled($0) },
            language: store.appLanguage
        ).prefix(max(accountLimit, 0)))
        let displays = items.map { item -> WidgetAccountDisplay in
            var snap = WidgetAccountItems.snapshot(for: item, now: date, store: store)
            if snap == nil, preview, !item.isCustom {
                snap = SharedStore.demoSnapshots(now: date).first { $0.provider == item.provider }
            }
            let account = item.extraAccountID.flatMap { extra in
                store.accounts.first { $0.id == extra }
            } ?? store.accounts.first(where: { $0.id.uuidString == item.id })
            let templateTint = account?.templateID.flatMap { store.customTemplate(id: $0)?.tint }
            let title = account.map { store.displayName(for: $0) }
                ?? (item.isCustom ? item.title : item.provider.localizedName(store.appLanguage))
            return WidgetAccountDisplay(
                id: item.id, provider: item.provider, title: title, snapshot: snap,
                isCustom: item.isCustom,
                tint: item.isCustom
                    ? TintResolver.resolve(accountTint: account?.tint, templateTint: templateTint)
                    : store.resolvedTint(provider: item.provider, accountID: account?.id),
                customLogoData: account.flatMap { store.customLogoData(for: $0) }
            )
        }
        return OverviewEntry(date: date, items: displays)
    }
}

struct OverviewLargeTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        snapshot(for: OverviewConfigIntent(), in: context)
    }

    func snapshot(for configuration: OverviewConfigIntent, in context: Context) -> OverviewEntry {
        OverviewEntryFactory.makeEntry(
            accountIDs: configuration.accounts?.map(\.id) ?? [],
            date: Date(),
            preview: context.isPreview,
            accountLimit: WidgetChrome.overviewAccountLimit(isLarge: true)
        )
    }

    func timeline(for configuration: OverviewConfigIntent, in context: Context) -> Timeline<OverviewEntry> {
        let now = Date()
        return Timeline(
            entries: [snapshot(for: configuration, in: context)],
            policy: .after(now.addingTimeInterval(15 * 60))
        )
    }
}

struct OverviewLargeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "OverviewLargeWidget",
            intent: OverviewConfigIntent.self,
            provider: OverviewLargeTimeline()
        ) { entry in
            MediumUsageView(items: entry.items, now: entry.date)
            .environment(\.appLanguage, SharedStore.shared.appLanguage)
            .environment(\.usageDisplayMode, SharedStore.shared.usageDisplayMode)
            .environment(\.resetTimeStyle, SharedStore.shared.resetTimeStyle)
            .widgetContentChrome()
            .containerBackground(for: .widget) { WidgetAppearance.background }
            .widgetAppearance()
            .widgetURL(URL(string: "usagelimits://open"))
        }
        .configurationDisplayName("widget.gallery.large")
        .description("widget.gallery.largeDetail")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

private struct WidgetContentChrome: ViewModifier {
    @Environment(\.widgetContentMargins) private var margins

    func body(content: Content) -> some View {
        content
            .padding(margins)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
            }
    }
}

/// 小组件深浅色跟随 App 设置 → 外观 → 主题（`SharedStore.appTheme`）：选了浅色 / 深色就固定 colorScheme，
/// 跟随系统则不动。`.primary` 等动态色按这个环境解析；底色不靠动态色，直接给定（DEVLOG #111）。App 改主题时会 reload 时间线。
private struct WidgetAppearance: ViewModifier {
    /// 底色：固定模式给纯白 / 纯黑（与 systemBackground 同值），跟随系统仍用系统动态色。
    static var background: Color {
        switch SharedStore.shared.appTheme {
        case .light: .white
        case .dark: .black
        case .system: Color(.systemBackground)
        }
    }

    func body(content: Content) -> some View {
        switch SharedStore.shared.appTheme {
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        case .system: content
        }
    }
}

private extension View {
    func widgetContentChrome() -> some View {
        modifier(WidgetContentChrome())
    }

    func widgetAppearance() -> some View {
        modifier(WidgetAppearance())
    }
}

private func singleWidgetURL(_ entry: SingleEntry) -> URL? {
    if let id = entry.extraAccountID {
        return AppDeepLink.accountURL(id)
    }
    return URL(string: "usagelimits://open/\(entry.provider.rawValue)")
}

@main
struct UsageLimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        SingleProviderWidget()
        SingleProviderMediumWidget()
        OverviewLargeWidget()
    }
}

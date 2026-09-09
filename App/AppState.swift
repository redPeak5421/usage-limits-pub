import SwiftUI
import WebKit
import WidgetKit
import UsageLimitsCore

/// 全局状态：快照缓存、刷新编排、演示模式。
@MainActor
final class AppState: ObservableObject {
    @Published var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published var refreshing: Set<ProviderID> = []
    @Published private(set) var isRefreshingAll = false
    /// 手动添加的账号（主账号 + 附加账号）：服务商没有固定内置列表。
    /// 主账号走服务商级老链路；附加账号独立登录态与快照，首页紧跟同服务商主卡显示。
    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var customTemplates: [CustomUsageTemplate] = []
    @Published var accountSnapshots: [UUID: ProviderSnapshot] = [:]
    @Published var refreshingAccounts: Set<UUID> = []
    /// 附加 / 自定义账号的在飞刷新世代。logout / remove / 停用时 +1，探针返回后对不上就丢弃。
    private var accountRefreshGeneration: [UUID: UInt64] = [:]
    /// 主号（含登录探测）的在飞刷新世代。
    private var primaryRefreshGeneration: [ProviderID: UInt64] = [:]
    /// 已启用的服务商（设置页开关；关闭的不进首页、不刷新、不进小组件）。
    @Published private(set) var enabledProviders: Set<ProviderID> = []
    /// 全局服务商顺序（含关闭项；主页与设置页拖动共用、联动）。
    @Published private(set) var providerOrder: [ProviderID] = ProviderID.allCases
    @Published var demoMode: Bool {
        didSet {
            store.demoMode = demoMode
            reloadFromStore()
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.pushState()
        }
    }
    /// 显示语言（设置页选择；system 表示跟随系统，匹配不上用英语）。
    @Published var language: AppLanguage {
        didSet {
            store.appLanguage = language
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.pushState()
            scheduleReminderReload()
        }
    }
    /// 外观主题（黑 / 白 / 跟随系统）。小组件也按它定深浅色，改完要重载时间线。
    @Published var theme: AppTheme {
        didSet {
            store.appTheme = theme
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    /// 首页主题布局（平铺 / 轮盘 / 螺旋）。深浅色都跟随 `theme`；只作用于首页。
    @Published var dashboardTheme: DashboardTheme {
        didSet { store.dashboardTheme = dashboardTheme }
    }
    /// 百分比展示口径（按已用 / 按剩余）。只影响展示层，提醒阈值仍按已用。
    @Published var usageDisplayMode: UsageDisplayMode {
        didSet {
            store.usageDisplayMode = usageDisplayMode
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.pushState()
        }
    }
    /// 重置时间展示口径（倒计时 / 具体时刻）。
    @Published var resetTimeStyle: ResetTimeStyle {
        didSet {
            store.resetTimeStyle = resetTimeStyle
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.pushState()
        }
    }
    /// 自动刷新间隔（秒）。0 = 不自动刷新。
    @Published var autoRefreshInterval: Double {
        didSet {
            store.autoRefreshInterval = autoRefreshInterval
            restartAutoRefreshLoop()
        }
    }
    /// 组合键解锁后才显示隐藏分享品牌行的开关（进程内有效，不落盘）。
    @Published private(set) var shareBrandUnlocked = false
    private var shareBrandUnlockedAt: Date?
    private var shareBrandUnlockExpiryTask: Task<Void, Never>?
    /// 提醒设置（阈值 / 套餐到期 / 额度重置，均可单独开关）。
    @Published var notificationSettings: NotificationSettings {
        didSet {
            store.notificationSettings = notificationSettings
            // 只在「从全关到开启第一项」时申请权限（避免每次调参数都刷诊断日志）
            if notificationSettings.anyEnabled && !oldValue.anyEnabled {
                NotificationManager.shared.requestAuthorizationIfNeeded()
            }
            NotificationManager.shared.rescheduleCalendarReminders(language: language)
        }
    }
    private var autoRefreshTask: Task<Void, Never>?
    private var widgetReloadTask: Task<Void, Never>?
    private var reminderReloadTask: Task<Void, Never>?
    private var watchPushTask: Task<Void, Never>?

    let store = SharedStore.shared
    private let fetcher = WebViewFetcher.shared
    private let customUsageClient = CustomUsageClient(session: CustomUsageClient.makeSession())

    func setWidgetRainbowGlow(_ on: Bool) {
        store.widgetRainbowGlow = on
        WidgetCenter.shared.reloadAllTimelines()
    }

    @Published var cardRefreshGlow: Bool {
        didSet { store.cardRefreshRainbowGlow = cardRefreshGlow }
    }

    @Published var cardTintedBars: Bool {
        didSet { store.cardTintedBars = cardTintedBars }
    }

    @Published var cardBarShimmer: Bool {
        didSet { store.cardBarShimmer = cardBarShimmer }
    }


    enum AutoRoute: Equatable {
        case none
        case widgetPreview
        case settings
        case notificationSettings
        case sharePreview
        case login(ProviderID)
        /// 服务商二级菜单；addSheet = true 时直接弹出「新增供应商」选择器。
        case providersSettings(addSheet: Bool)
        /// 打开新增供应商并直接进入自定义向导（`--open-custom-wizard`）。
        case customWizard
        /// 直接打开某服务商主卡的「编辑计量顺序」面板（`--open-metric-order <id>`）。
        case metricOrder(ProviderID)
        /// 直接打开设置 → 外观页（`--open-appearance`）。
        case appearance
        /// 直接打开设置并弹出「侧边键」分步说明（`--open-side-key-guide`）。
        case sideKeyGuide
    }

    let autoRoute: AutoRoute
    /// --auto-refresh：启动即刷新全部服务商（端到端管线自动化验证用）。
    let autoRefreshOnLaunch: Bool
    /// --expand-cards：首页卡片以展开态启动（模拟器截图验证展开布局用）。
    let expandCardsOnLaunch: Bool
    /// --open-side-key：首页出现即弹出侧边键一级菜单（模拟器截图验证侧边键用）。
    let openSideKeyMenuOnLaunch: Bool
    /// --helix-coil-gain <值>：螺旋主题以指定拧度（线圈半径增益，负值反向拧）启动，模拟器截图验证用；越界值由模型夹住。
    let helixCoilGainOnLaunch: Double?
    /// 小组件深链：`usagelimits://open/<provider>` 定位主账号卡，`usagelimits://open/account/<uuid>` 定位账号卡；旧 aiusage scheme 仍兼容。
    /// 首页拿到后滚过去 / 展开（`pendingRevealTarget`）。
    @Published var pendingDeepLink: AppDeepLink?

    init() {
        let args = LaunchArguments()
        autoRefreshOnLaunch = args.contains("--auto-refresh")
        expandCardsOnLaunch = args.contains("--expand-cards")
        openSideKeyMenuOnLaunch = args.contains("--open-side-key")
        helixCoilGainOnLaunch = args.value(after: "--helix-coil-gain").flatMap(Double.init)
        if args.contains("--demo") {
            SharedStore.shared.demoMode = true
        } else if args.contains("--no-demo") {
            SharedStore.shared.demoMode = false
        }
        // --dashboard-theme <flat|roulette|helix>：模拟器截图验证三种首页主题用。
        if let theme = args.value(after: "--dashboard-theme").flatMap(DashboardTheme.init(rawValue:)) {
            SharedStore.shared.dashboardTheme = theme
        }
        if args.contains("--open-widget-preview") {
            autoRoute = .widgetPreview
        } else if args.contains("--open-add-provider") {
            autoRoute = .providersSettings(addSheet: true)
        } else if args.contains("--open-providers") {
            autoRoute = .providersSettings(addSheet: false)
        } else if args.contains("--open-notification-settings") {
            autoRoute = .notificationSettings
        } else if args.contains("--open-share") {
            autoRoute = .sharePreview
        } else if args.contains("--open-settings") {
            autoRoute = .settings
        } else if args.contains("--open-appearance") {
            autoRoute = .appearance
        } else if args.contains("--open-side-key-guide") {
            autoRoute = .sideKeyGuide
        } else if args.contains("--open-custom-wizard") {
            autoRoute = .customWizard
        } else if let provider = args.value(after: "--open-login").flatMap(ProviderID.init(rawValue:)) {
            autoRoute = .login(provider)
        } else if let provider = args.value(after: "--open-metric-order").flatMap(ProviderID.init(rawValue:)) {
            autoRoute = .metricOrder(provider)
        } else {
            autoRoute = .none
        }
        // --seed-demo-snapshots：模拟器自动化用，把演示数据当真实快照落盘并补主账号
        //（非演示模式下才能验证依赖真实快照的功能，如计量顺序、提醒）。
        if args.contains("--seed-demo-snapshots") {
            let store = SharedStore.shared
            store.demoMode = false
            var accounts = store.accounts
            for snap in SharedStore.demoSnapshots(now: Date()) {
                store.save(snap)
                if !accounts.contains(where: { $0.provider == snap.provider && $0.isPrimary }) {
                    accounts.append(ProviderAccount(provider: snap.provider, name: "", isPrimary: true))
                }
                store.setEnabled(true, for: snap.provider)
            }
            store.accounts = accounts
        }
        demoMode = SharedStore.shared.demoMode
        language = SharedStore.shared.appLanguage
        cardRefreshGlow = SharedStore.shared.cardRefreshRainbowGlow
        cardTintedBars = SharedStore.shared.cardTintedBars
        cardBarShimmer = SharedStore.shared.cardBarShimmer
        theme = SharedStore.shared.appTheme
        dashboardTheme = SharedStore.shared.dashboardTheme
        usageDisplayMode = SharedStore.shared.usageDisplayMode
        resetTimeStyle = SharedStore.shared.resetTimeStyle
        autoRefreshInterval = SharedStore.shared.autoRefreshInterval
        notificationSettings = SharedStore.shared.notificationSettings
        if args.contains("--notify-per-provider") {
            notificationSettings.thresholdScope = .perProvider
            notificationSettings.expiryScope = .perProvider
            notificationSettings.resetScope = .perProvider
            notificationSettings.prepaidScope = .perProvider
            notificationSettings.seedProviderIfNeeded(.claude)
        }
        // 固定开关模式 → 手动新增模式的一次性迁移（有历史快照的服务商保留为主账号）
        SharedStore.shared.migrateToManualAccountsIfNeeded()
        enabledProviders = Set(SharedStore.shared.enabledProviders)
        providerOrder = SharedStore.shared.providerOrder
        accounts = SharedStore.shared.accounts
        customTemplates = SharedStore.shared.customTemplates
        providerTintOverrides = SharedStore.shared.providerTintOverrides
        reloadFromStore()
        restartAutoRefreshLoop()
        // 手表：接收表端开关/排序操作，激活后即推送一次完整状态
        WatchSync.shared.onSetEnabled = { [weak self] provider, enabled in
            Task { @MainActor in self?.setEnabled(enabled, for: provider) }
        }
        WatchSync.shared.onSetOrder = { [weak self] order in
            Task { @MainActor in self?.setOrder(order) }
        }
        WatchSync.shared.activate()
        // 上次进程里打开过隐藏二维码：开关已随重启消失，分享状态必须一并恢复。
        restoreShareBrandVisibility()
        // 冷启动 didSet 不会跑：按当前语言重排日历提醒
        scheduleReminderReload()
    }

    /// 组合键完成：显示开关（默认关闭），并开始 30 分钟可见窗口。
    func unlockShareBrand(now: Date = Date()) {
        restoreShareBrandVisibility()
        shareBrandUnlockedAt = now
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            shareBrandUnlocked = true
        }
        scheduleShareBrandUnlockExpiry(now: now)
    }

    /// 进程被杀再开时 `shareBrandUnlocked` 本就是 false；常驻超时或回到前台时收回开关。
    func expireShareBrandUnlockIfNeeded(now: Date = Date()) {
        guard shareBrandUnlocked else { return }
        guard !BrandUnlockSession.isVisible(unlockedAt: shareBrandUnlockedAt, now: now) else { return }
        hideShareBrandUnlock()
    }

    private func hideShareBrandUnlock() {
        shareBrandUnlockExpiryTask?.cancel()
        shareBrandUnlockExpiryTask = nil
        shareBrandUnlockedAt = nil
        restoreShareBrandVisibility()
        guard shareBrandUnlocked else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            shareBrandUnlocked = false
        }
    }

    /// 开关不在时分享图必须带二维码；再次解锁后开关也从关闭态开始。
    private func restoreShareBrandVisibility() {
        let next = BrandUnlockSession.shareOptionsAfterHidingToggle(store.shareComposeOptions)
        if next != store.shareComposeOptions {
            store.shareComposeOptions = next
        }
    }

    private func scheduleShareBrandUnlockExpiry(now: Date) {
        shareBrandUnlockExpiryTask?.cancel()
        guard shareBrandUnlocked, let unlockedAt = shareBrandUnlockedAt else { return }
        let remaining = BrandUnlockSession.remainingVisible(unlockedAt: unlockedAt, now: now)
        if remaining <= 0 {
            hideShareBrandUnlock()
            return
        }
        guard let delay = SafeDuration.nanoseconds(seconds: remaining) else {
            hideShareBrandUnlock()
            return
        }
        shareBrandUnlockExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.expireShareBrandUnlockIfNeeded()
        }
    }

    /// 按设置的间隔在前台周期性刷新全部已启用服务商；0 关闭。
    private func restartAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        let interval = autoRefreshInterval
        guard interval > 0, let delay = SafeDuration.nanoseconds(seconds: interval), delay > 0 else {
            autoRefreshTask = nil
            return
        }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { break }
                guard let self else { break }
                if !self.demoMode {
                    await self.refreshAll()
                }
            }
        }
    }

    /// 首页与刷新循环实际参与的服务商（按全局自定义顺序）。
    var activeProviders: [ProviderID] {
        providerOrder.filter { ProviderAvailability.isAvailable($0) && enabledProviders.contains($0) }
    }

    var visibleAccounts: [ProviderAccount] { accounts.filter(ProviderAvailability.isAvailable) }
    var availableProviders: [ProviderID] { providerOrder.filter(ProviderAvailability.isAvailable) }


    /// 手表端拖动排序回传：缺失的服务商补到末尾后走同一条应用路径。
    func setOrder(_ order: [ProviderID]) {
        var next = order
        for p in ProviderID.allCases where !next.contains(p) { next.append(p) }
        applyOrder(next)
    }

    private func applyOrder(_ order: [ProviderID]) {
        store.providerOrder = order
        providerOrder = order
        scheduleWidgetReload()
        scheduleWatchPush()
    }

    /// 合并 0.6 秒内的多次预排提醒重排请求（refreshAll 排队刷多家，逐家全量重排是浪费）。
    private func scheduleReminderReload() {
        reminderReloadTask?.cancel()
        reminderReloadTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            NotificationManager.shared.rescheduleCalendarReminders(language: language)
        }
    }

    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// 合并 0.6 秒内的多次手表全量推送（拖动换位时逐帧 JSON 会掉帧）。
    private func scheduleWatchPush() {
        watchPushTask?.cancel()
        watchPushTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            WatchSync.shared.pushState()
        }
    }

    func isEnabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    /// 设置页开关：持久化到 App Group，并同步首页与小组件。
    func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        store.setEnabled(enabled, for: provider)
        if enabled {
            enabledProviders.insert(provider)
        } else {
            bumpPrimaryRefreshGeneration(provider)
            for account in accounts where account.provider == provider && !account.isPrimary {
                bumpAccountRefreshGeneration(account.id)
            }
            enabledProviders.remove(provider)
        }
        reloadFromStore()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
        // 关掉的服务商不再保留已预排的到期/重置提醒
        scheduleReminderReload()
    }

    func reloadFromStore() {
        accounts = store.accounts
        customTemplates = store.customTemplates
        var dict: [ProviderID: ProviderSnapshot] = [:]
        if demoMode {
            // 演示模式是橱窗：全部服务商都展示演示数据，不受「已添加」限制。
            for snap in SharedStore.demoSnapshots(now: Date()) {
                dict[snap.provider] = snap
            }
        } else {
            for snap in store.displaySnapshots() {
                dict[snap.provider] = snap
            }
        }
        snapshots = dict
        var accountDict: [UUID: ProviderSnapshot] = [:]
        for account in accounts where !account.isPrimary {
            if account.isCustom {
                // D9：演示橱窗只留内置供应商，隐藏真实自定义卡。
                if demoMode { continue }
                accountDict[account.id] = store.accountSnapshot(for: account.id)
            } else if demoMode, let provider = account.provider {
                accountDict[account.id] = dict[provider]
            } else {
                accountDict[account.id] = store.accountSnapshot(for: account.id)
            }
        }
        accountSnapshots = accountDict
    }

    func snapshot(_ provider: ProviderID) -> ProviderSnapshot? {
        snapshots[provider]
    }

    // MARK: - 手动添加的账号（主账号 + 附加账号）

    /// 该服务商的主账号（走服务商级老链路的那一个）。
    func primaryAccount(_ provider: ProviderID) -> ProviderAccount? {
        accounts.first { $0.provider == provider && $0.isPrimary }
    }

    /// 该服务商的附加账号（不含主账号）。
    func extraAccounts(of provider: ProviderID) -> [ProviderAccount] {
        accounts.filter { $0.provider == provider && !$0.isPrimary }
    }

    /// 设置页/首页拖动后的新顺序：账号数组照单全收（允许不同服务商穿插）；
    /// 服务商全局顺序按账号首次出现的服务商重排（小组件/手表仍按服务商），
    /// 没有账号的服务商保持原有相对顺序垫底。
    func applyAccountOrder(_ ordered: [ProviderAccount]) {
        accounts = ordered
        persistAccounts()
        var next: [ProviderID] = []
        for account in ordered {
            if let provider = account.provider, !next.contains(provider) {
                next.append(provider)
            }
        }
        for provider in providerOrder where !next.contains(provider) {
            next.append(provider)
        }
        applyOrder(next)
    }


    /// 首页是否显示该服务商的主卡：演示模式未添加的仍橱窗展示；已添加则尊重停用。
    func showsPrimaryCard(_ provider: ProviderID?) -> Bool {
        guard let provider, ProviderAvailability.isAvailable(provider) else { return false }
        if let primary = primaryAccount(provider) {
            return AccountVisibility.shouldShowOnHome(
                primary, providerEnabled: enabledProviders.contains(provider)
            )
        }
        return demoMode
    }

    /// 首页是否显示该附加账号：停用账号或所属服务商停用时隐藏。
    func showsAccount(_ account: ProviderAccount) -> Bool {
        if account.isCustom && demoMode { return false }
        return AccountVisibility.shouldShowOnHome(
            account, providerEnabled: store.isProviderEnabled(for: account)
        )
    }

    func isProviderEnabled(for account: ProviderAccount) -> Bool {
        store.isProviderEnabled(for: account)
    }

    /// 停用/启用已添加账号：不删配置；主账号同步服务商级开关（首页/小组件/手表）。
    func setAccountEnabled(_ account: ProviderAccount, enabled: Bool) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if !enabled {
            bumpAccountRefreshGeneration(account.id)
        }
        accounts[idx].isEnabled = enabled
        persistAccounts()
        if accounts[idx].isPrimary, let provider = account.provider {
            setEnabled(enabled, for: provider)
        } else {
            reloadFromStore()
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.pushState()
            scheduleReminderReload()
        }
        store.appendDiagnostic("\(diagnosticPrefix(for: account)): \(enabled ? "启用" : "停用")账号「\(account.displayName)」")
    }

    /// 新增账号：该服务商还没有主账号时先建主账号（沿用服务商级登录与快照，
    /// Widget / Watch / 提醒即刻生效）；已有主账号则追加独立 dataStore 的附加账号。
    @discardableResult
    func addAccount(provider: ProviderID, name: String) -> ProviderAccount {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account: ProviderAccount
        if primaryAccount(provider) == nil {
            // 名称留空 → 回退服务商产品名（displayName 计算属性处理）
            account = ProviderAccount(provider: provider, name: trimmed, isPrimary: true)
            accounts.append(account)
            persistAccounts()
            setEnabled(true, for: provider)
        } else {
            // 名称留空 → displayName 按界面语言回落服务商名，不把 vendorName 写进账号名
            account = ProviderAccount(provider: provider, name: trimmed)
            accounts.append(account)
            persistAccounts()
            reloadFromStore()
        }
        store.appendDiagnostic("\(provider.rawValue): 新增账号「\(account.displayName)」")
        return account
    }

    func renameAccount(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].name = trimmed
        persistAccounts()
        scheduleWidgetReload()
        WatchSync.shared.pushState()
    }

    // MARK: 自定义主题色（账号级 + 供应商默认；三层回落见 TintResolver）

    /// 供应商默认色覆盖（内存镜像；持久化在 SharedStore）。
    @Published private(set) var providerTintOverrides: [String: BrandTint] = [:]

    func resolvedTint(for account: ProviderAccount) -> BrandTint {
        switch account.source {
        case .builtin(let provider):
            return TintResolver.resolve(
                accountTint: account.tint, provider: provider, overrides: providerTintOverrides
            )
        case .custom(let templateID):
            let templateTint = customTemplates.first { $0.id == templateID }?.tint
            return TintResolver.resolve(accountTint: account.tint, templateTint: templateTint)
        }
    }

    func diagnosticPrefix(for account: ProviderAccount) -> String {
        account.provider?.rawValue ?? "custom"
    }

    /// 服务商级取色：主账号的自定义色优先（演示橱窗卡与未添加主账号时走供应商覆盖）。
    func resolvedTint(provider: ProviderID) -> BrandTint {
        TintResolver.resolve(
            accountTint: primaryAccount(provider)?.tint, provider: provider,
            overrides: providerTintOverrides
        )
    }

    /// 设置/清除账号自定义色（nil = 恢复默认，回落供应商覆盖 → 内置）。
    func setAccountTint(_ account: ProviderAccount, tint: BrandTint?) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].tint = tint
        persistAccounts()
        store.appendDiagnostic(
            "\(diagnosticPrefix(for: account)): 账号「\(account.displayName)」主题色 \(tint.map { $0.isGradient ? "\($0.startHex)→\($0.endHex ?? "")" : $0.startHex } ?? "恢复默认")"
        )
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
    }

    func setTemplateTint(_ template: CustomUsageTemplate, tint: BrandTint?) {
        var list = store.customTemplates
        guard let index = list.firstIndex(where: { $0.id == template.id }) else { return }
        list[index].tint = tint
        store.customTemplates = list
        customTemplates = list
        objectWillChange.send()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
    }

    func customLogoData(for template: CustomUsageTemplate) -> Data? {
        store.customLogoData(for: template)
    }

    func customLogoData(for account: ProviderAccount) -> Data? {
        store.customLogoData(for: account)
    }

    func setCustomLogo(templateID: UUID, data: Data?, isManual: Bool) {
        var list = store.customTemplates
        guard let index = list.firstIndex(where: { $0.id == templateID }) else { return }
        if let old = list[index].logoRelativePath {
            store.removeCustomLogo(relativePath: old)
        }
        if let data, !data.isEmpty {
            let ext = CustomFaviconParser.suggestedExtension(for: data)
            list[index].logoRelativePath = store.writeCustomLogo(
                data: data, for: templateID, fileExtension: ext
            )
        } else {
            list[index].logoRelativePath = nil
        }
        list[index].logoIsManual = isManual
        store.customTemplates = list
        customTemplates = list
        objectWillChange.send()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
    }

    /// 设置/清除供应商默认色（nil = 恢复内置品牌色）。同供应商新增账号自动继承。
    func setProviderTint(_ provider: ProviderID, tint: BrandTint?) {
        var map = store.providerTintOverrides
        if let tint {
            map[provider.rawValue] = tint
        } else {
            map.removeValue(forKey: provider.rawValue)
        }
        store.providerTintOverrides = map
        providerTintOverrides = map
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
    }

    /// 一键重置：清空所有账号色 + 所有供应商默认覆盖。
    func resetAllCustomTints() {
        store.resetAllCustomTints()
        accounts = store.accounts
        customTemplates = store.customTemplates
        providerTintOverrides = [:]
        store.appendDiagnostic("已重置所有自定义主题色")
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
    }

    /// 删除账号。主账号：退出登录（清站点数据与快照）并关闭该服务商；
    /// 附加账号：清空其独立站点数据（含磁盘容器）与快照。
    func removeAccount(_ account: ProviderAccount) async {
        bumpAccountRefreshGeneration(account.id)
        if let provider = account.provider, account.isPrimary {
            bumpPrimaryRefreshGeneration(provider)
        }
        if account.isCustom {
            store.removeCustomAccountData(accountID: account.id)
            accountSnapshots[account.id] = nil
        } else if account.isPrimary, let provider = account.provider {
            await logout(provider)
            setEnabled(false, for: provider)
        } else if let provider = account.provider {
            bumpAccountRefreshGeneration(account.id)
            store.removeAccountSnapshot(for: account.id)
            accountSnapshots[account.id] = nil
            accounts.removeAll { $0.id == account.id }
            persistAccounts()
            await fetcher.clearAccountData(provider: provider, accountID: account.id, removeStore: true)
        }
        accounts.removeAll { $0.id == account.id }
        persistAccounts()
        customTemplates = store.customTemplates
        store.appendDiagnostic("\(diagnosticPrefix(for: account)): 已删除账号「\(account.displayName)」")
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
        scheduleReminderReload()
    }

    /// 附加账号退出登录：内置清 WebKit；自定义只清 token。
    func logoutAccount(_ account: ProviderAccount) async {
        bumpAccountRefreshGeneration(account.id)
        store.removeAccountSnapshot(for: account.id)
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            AccountIdentity.clearFingerprint(&accounts[idx])
            persistAccounts(clearingFingerprintFor: [account.id])
        }
        if !demoMode {
            accountSnapshots[account.id] = nil
        }
        if account.isCustom {
            store.removeAccountToken(for: account.id)
        } else if let provider = account.provider {
            await fetcher.clearAccountData(provider: provider, accountID: account.id)
        }
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
        scheduleReminderReload()
    }

    /// 刷新附加账号。自定义走 URLSession；内置仍走 WebView 探针。
    /// 自定义提交后接提醒 / 小组件 / Watch。
    @discardableResult
    func refreshAccount(
        _ account: ProviderAccount,
        allowWhenDisabled: Bool = false,
        using existingWebView: WKWebView? = nil
    ) async -> ProviderSnapshot? {
        if account.isCustom {
            return await refreshCustomAccount(account, allowWhenDisabled: allowWhenDisabled)
        }
        guard let provider = account.provider else { return accountSnapshots[account.id] }
        if !allowWhenDisabled {
            guard AccountVisibility.shouldProbe(account, providerEnabled: isEnabled(provider)) else {
                return accountSnapshots[account.id]
            }
        }
        guard !refreshingAccounts.contains(account.id) else { return accountSnapshots[account.id] }
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }

        let startFingerprint = account.identityFingerprint
        let startGeneration = accountRefreshGeneration[account.id] ?? 0
        let startFetchedAt = store.accountSnapshot(for: account.id)?.fetchedAt
        let live = existingWebView
            ?? (provider == .jimeng ? fetcher.retainedLiveJimengWebView(accountID: account.id) : nil)
        let results = await fetcher.runProbes(for: provider, accountID: account.id, using: live)
        if Task.isCancelled { return accountSnapshots[account.id] }
        if shouldAbortInFlightRefresh(
            accountID: account.id, startFingerprint: startFingerprint, startGeneration: startGeneration
        ) {
            store.appendDiagnostic("\(provider.rawValue)(\(account.name)): 刷新期间账号已退出或删除，丢弃本轮结果")
            return accountSnapshots[account.id]
        }
        if store.accountSnapshot(for: account.id)?.fetchedAt != startFetchedAt {
            store.appendDiagnostic("\(provider.rawValue)(\(account.name)): 刷新期间快照已被更新，丢弃本轮结果")
            return adoptAccountSnapshotFromStore(accountID: account.id)
        }
        appendProbeDiagnostics(prefix: "\(provider.rawValue)(\(account.name))", results: results)
        if provider == .jimeng {
            let reused = live != nil || fetcher.retainedLiveJimengWebView(accountID: account.id) != nil
            store.appendDiagnostic("jimeng.probe= \(reused ? "live" : "offscreen")")
            await appendJimengDiagnostics(results: results, accountID: account.id)
        }
        if shouldAbortInFlightRefresh(
            accountID: account.id, startFingerprint: startFingerprint, startGeneration: startGeneration
        ) {
            store.appendDiagnostic("\(provider.rawValue)(\(account.name)): 刷新期间账号已退出或删除，丢弃本轮结果")
            return accountSnapshots[account.id]
        }
        if store.accountSnapshot(for: account.id)?.fetchedAt != startFetchedAt {
            store.appendDiagnostic("\(provider.rawValue)(\(account.name)): 刷新期间快照已被更新，丢弃本轮结果")
            return adoptAccountSnapshotFromStore(accountID: account.id)
        }
        if Task.isCancelled { return accountSnapshots[account.id] }
        let old = store.accountSnapshot(for: account.id)
        var snap = Self.parse(provider: provider, results: results, now: Date())
        snap = RefreshPolicy.preservingBreakdowns(old: old, new: snap)
        let identityOK = applyIdentity(provider: provider, accountID: account.id, results: results, snap: &snap)
        store.appendDiagnostic("\(provider.rawValue)(\(account.name)).parsed= " + DiagnosticRedactor.summary(of: snap))
        if !identityOK {
            // 身份冲突：rejected 快照不得写进内存覆盖 last-good
            scheduleWidgetReload()
            scheduleWatchPush()
            scheduleReminderReload()
            return accountSnapshots[account.id]
        }
        let shouldCommit = RefreshPolicy.shouldCommit(old: old, new: snap, results: results)
        let didPersist = shouldCommit && store.saveAccountSnapshot(snap, accountID: account.id)
        if !shouldCommit {
            store.appendDiagnostic("\(provider.rawValue)(\(account.name)): 探针不可靠，保留上次有效快照")
        } else if !didPersist {
            store.appendDiagnostic("\(provider.rawValue)(\(account.name)): 快照持久化失败，保留安全可见值")
        }
        // 回读：套用用户自定义的计量顺序（MetricOrdering）；失败时只能回退旧值/安全错误。
        let persisted = didPersist ? store.accountSnapshot(for: account.id) : nil
        let committed = RefreshPolicy.visibleSnapshot(old: old, parsed: snap, persisted: persisted)
        if !demoMode {
            accountSnapshots[account.id] = committed
            if didPersist, !account.isCustom {
                let events = NotificationDecider.events(
                    old: old, new: committed, settings: notificationSettings,
                    alreadyNotified: store.notifiedKeys(),
                    accountID: account.id,
                    accountTitle: store.displayName(for: account)
                )
                await NotificationManager.shared.deliver(events, language: language)
                scheduleReminderReload()
            }
        }
        scheduleWidgetReload()
        scheduleWatchPush()
        return committed
    }

    @discardableResult
    func refreshCustomAccount(
        _ account: ProviderAccount,
        allowWhenDisabled: Bool = false
    ) async -> ProviderSnapshot? {
        if !allowWhenDisabled {
            guard AccountVisibility.shouldProbe(account, providerEnabled: true) else {
                return accountSnapshots[account.id]
            }
        }
        guard !refreshingAccounts.contains(account.id) else { return accountSnapshots[account.id] }
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }

        let startFingerprint = account.identityFingerprint
        let startGeneration = accountRefreshGeneration[account.id] ?? 0
        let old = store.accountSnapshot(for: account.id)
        guard let templateID = account.templateID,
              let template = store.customTemplate(id: templateID) else {
            if shouldAbortInFlightRefresh(
                accountID: account.id, startFingerprint: startFingerprint, startGeneration: startGeneration
            ) {
                return accountSnapshots[account.id]
            }
            guard store.accounts.contains(where: { $0.id == account.id }) else {
                return accountSnapshots[account.id]
            }
            let snap = ProviderSnapshot(
                provider: .claude, fetchedAt: Date(), status: .error("custom.error.unreadable"), isCustom: true
            )
            let didPersist = store.saveAccountSnapshot(snap, accountID: account.id)
            let persisted = didPersist ? store.accountSnapshot(for: account.id) : nil
            let committed = RefreshPolicy.visibleSnapshot(old: old, parsed: snap, persisted: persisted)
            if !demoMode { accountSnapshots[account.id] = committed }
            return committed
        }
        let startFetchedAt = old?.fetchedAt
        let outcome = await CustomUsageRefresh.perform(
            template: template,
            token: store.accountToken(for: account.id),
            old: old,
            client: customUsageClient
        )
        if Task.isCancelled { return accountSnapshots[account.id] }
        if shouldAbortInFlightRefresh(
            accountID: account.id, startFingerprint: startFingerprint, startGeneration: startGeneration
        ) {
            store.appendDiagnostic("custom.\(template.name): 刷新期间账号已退出或删除，丢弃本轮结果")
            return accountSnapshots[account.id]
        }
        if store.accountSnapshot(for: account.id)?.fetchedAt != startFetchedAt {
            store.appendDiagnostic("custom.\(template.name): 刷新期间快照已被更新，丢弃本轮结果")
            return adoptAccountSnapshotFromStore(accountID: account.id)
        }
        store.appendDiagnostic(outcome.diagnostic)
        store.appendDiagnostic("custom.\(template.name).parsed= " + DiagnosticRedactor.summary(of: outcome.snapshot))
        let didPersist = outcome.didCommit
            && store.saveAccountSnapshot(outcome.snapshot, accountID: account.id)
        let persisted = didPersist ? store.accountSnapshot(for: account.id) : nil
        let committed = RefreshPolicy.visibleSnapshot(
            old: old, parsed: outcome.snapshot, persisted: persisted
        )
        // 先回写内存再 await 投递：删除/换绑发生在 deliver 期间时，不得把已清快照写回。
        if !demoMode {
            accountSnapshots[account.id] = committed
        }
        if didPersist {
            if !demoMode {
                let title = store.displayName(for: account)
                let events = NotificationDecider.customPrepaidEvents(
                    old: old,
                    new: committed,
                    accountID: account.id,
                    accountTitle: title,
                    settings: notificationSettings
                )
                await NotificationManager.shared.deliver(events, language: language)
            }
            scheduleWidgetReload()
            scheduleWatchPush()
        } else if !outcome.didCommit {
            store.appendDiagnostic("custom.\(template.name): 探针不可靠，保留上次有效快照")
        } else {
            store.appendDiagnostic("custom.\(template.name): 快照持久化失败，保留安全可见值")
        }
        return committed
    }

    @discardableResult
    func addCustomAccount(template: CustomUsageTemplate, name: String, token: String) -> ProviderAccount {
        if store.customTemplate(id: template.id) == nil {
            store.customTemplates = store.customTemplates + [template]
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = ProviderAccount(
            source: .custom(templateID: template.id),
            name: trimmed
        )
        accounts.append(account)
        persistAccounts()
        store.setAccountToken(token, for: account.id)
        customTemplates = store.customTemplates
        store.appendDiagnostic("custom: 新增账号「\(store.displayName(for: account))」")
        objectWillChange.send()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
        return account
    }

    func updateCustomToken(_ account: ProviderAccount, token: String) {
        store.setAccountToken(token, for: account.id)
        store.appendDiagnostic("custom: 已更新账号「\(account.displayName)」令牌")
        bumpAccountRefreshGeneration(account.id)
        refreshAccountAfterInFlight(account.id)
    }

    @discardableResult
    func replaceCustomTemplate(_ template: CustomUsageTemplate) -> Bool {
        var list = store.customTemplates
        guard let index = list.firstIndex(where: { $0.id == template.id }) else { return false }
        list[index] = template
        store.customTemplates = list
        customTemplates = list
        for account in accounts where account.templateID == template.id {
            bumpAccountRefreshGeneration(account.id)
            refreshAccountAfterInFlight(account.id)
        }
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func removeCustomTemplate(id: UUID) -> Bool {
        let ok = store.removeCustomTemplate(id: id)
        customTemplates = store.customTemplates
        return ok
    }

    func handleOpenURL(_ url: URL) {
        guard let link = AppDeepLink.parse(url) else { return }
        pendingDeepLink = link == .home ? nil : link
    }

    /// 退到后台：落盘诊断；作废未消费的深链（目标卡不在首页时会一直挂着，下次该卡出现会莫名跳过去）。
    func sceneDidEnterBackground() {
        store.flushDiagnostics()
        pendingDeepLink = nil
    }

    /// 待定位的首页卡片：按当前账号表把深链换算成场景项（主账号 → `.account`，演示态没账号 → `.demo`）。
    var pendingRevealTarget: DashboardSceneItemID? {
        pendingDeepLink?.revealTarget(accounts: accounts, demoMode: demoMode)
    }

    /// 正在飞的全量刷新；重入时等它结束而不是立刻返回（平铺下拉刷新的转圈要撑到真正刷完）。
    private var refreshAllTask: Task<Void, Never>?

    func refreshAll() async {
        if let inFlight = refreshAllTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshAll()
        }
        refreshAllTask = task
        await task.value
        refreshAllTask = nil
    }

    private func performRefreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        // 并发刷新：每个目标一张独立 WebView（独立 WebContent 进程），探针是
        // IO 等待，主线程只做调度；WebViewFetcher 内部有并发上限兜底，
        // 不会重演「无限并发挤死主线程」的老问题。所有卡片同时转圈，
        // 整体耗时 ≈ 最慢一家，而不是所有家之和。
        let startedAt = Date()
        var targets = 0
        await withTaskGroup(of: Void.self) { group in
            for provider in activeProviders {
                targets += 1
                group.addTask { @MainActor [weak self] in
                    await self?.refresh(provider)
                }
            }
            for account in accounts where !account.isPrimary
                && AccountVisibility.shouldProbe(
                    account, providerEnabled: store.isProviderEnabled(for: account)
                ) {
                targets += 1
                group.addTask { @MainActor [weak self] in
                    await self?.refreshAccount(account)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        store.appendDiagnostic("refreshAll: 完成 \(targets) 个目标，耗时 \(String(format: "%.1f", elapsed))s")
    }

    /// 抓取某服务商用量：探针 → 解析 → 落盘 → 通知小组件。
    /// 返回本轮快照（登录检测复用此路径）。
    @discardableResult
    func refresh(_ provider: ProviderID, using existingWebView: WKWebView? = nil) async -> ProviderSnapshot? {
        // 登录探测也走这条路径，因此不在这里按停用短路；自动刷新循环已只遍历未停用配置。
        guard !refreshing.contains(provider) else { return snapshots[provider] }
        refreshing.insert(provider)
        defer { refreshing.remove(provider) }

        let startPrimary = accounts.first(where: { $0.provider == provider && $0.isPrimary })
        let startFingerprint = startPrimary?.identityFingerprint
        let startGeneration = primaryRefreshGeneration[provider] ?? 0
        let startFetchedAt = store.snapshot(for: provider)?.fetchedAt
        let live = existingWebView
            ?? (provider == .jimeng ? fetcher.retainedLiveJimengWebView(accountID: nil) : nil)
        let results = await fetcher.runProbes(for: provider, using: live)
        if Task.isCancelled { return snapshots[provider] }
        if shouldAbortInFlightPrimaryRefresh(
            provider: provider,
            startAccountID: startPrimary?.id,
            startFingerprint: startFingerprint,
            startGeneration: startGeneration
        ) {
            store.appendDiagnostic("\(provider.rawValue): 刷新期间账号已退出或删除，丢弃本轮结果")
            return snapshots[provider]
        }
        if store.snapshot(for: provider)?.fetchedAt != startFetchedAt {
            store.appendDiagnostic("\(provider.rawValue): 刷新期间快照已被更新，丢弃本轮结果")
            return adoptPrimarySnapshotFromStore(provider)
        }
        appendProbeDiagnostics(prefix: provider.rawValue, results: results)
        if provider == .jimeng {
            let reused = live != nil || fetcher.retainedLiveJimengWebView(accountID: nil) != nil
            store.appendDiagnostic("jimeng.probe= \(reused ? "live" : "offscreen")")
            await appendJimengDiagnostics(results: results, accountID: nil)
        }
        if shouldAbortInFlightPrimaryRefresh(
            provider: provider,
            startAccountID: startPrimary?.id,
            startFingerprint: startFingerprint,
            startGeneration: startGeneration
        ) {
            store.appendDiagnostic("\(provider.rawValue): 刷新期间账号已退出或删除，丢弃本轮结果")
            return snapshots[provider]
        }
        if store.snapshot(for: provider)?.fetchedAt != startFetchedAt {
            store.appendDiagnostic("\(provider.rawValue): 刷新期间快照已被更新，丢弃本轮结果")
            return adoptPrimarySnapshotFromStore(provider)
        }
        if Task.isCancelled { return snapshots[provider] }
        let old = store.snapshot(for: provider)
        var snap = Self.parse(provider: provider, results: results, now: Date())
        snap = RefreshPolicy.preservingBreakdowns(old: old, new: snap)
        let identityOK = applyIdentity(provider: provider, accountID: nil, results: results, snap: &snap)
        store.appendDiagnostic("\(provider.rawValue).parsed= " + DiagnosticRedactor.summary(of: snap))
        if !identityOK {
            // 身份冲突：rejected 快照不得写进内存覆盖 last-good
            scheduleWidgetReload()
            scheduleWatchPush()
            scheduleReminderReload()
            return snapshots[provider]
        }
        let shouldCommit = RefreshPolicy.shouldCommit(old: old, new: snap, results: results)
        let didPersist = shouldCommit && store.save(snap)
        if !shouldCommit {
            store.appendDiagnostic("\(provider.rawValue): 探针不可靠，保留上次有效快照")
        } else if !didPersist {
            store.appendDiagnostic("\(provider.rawValue): 快照持久化失败，保留安全可见值")
        }
        // 回读：套用用户自定义的计量顺序；失败时绝不把被拒绝的解析值送进运行态。
        let persisted = didPersist ? store.snapshot(for: provider) : nil
        let committed = RefreshPolicy.visibleSnapshot(old: old, parsed: snap, persisted: persisted)
        if !demoMode {
            snapshots[provider] = committed
            if didPersist {
                // 提醒：对比新旧快照检测阈值穿越/额度回满，并重排日历型提醒
                let events = NotificationDecider.events(
                    old: old, new: committed, settings: notificationSettings,
                    alreadyNotified: store.notifiedKeys()
                )
                await NotificationManager.shared.deliver(events, language: language)
                scheduleReminderReload()
            }
        }
        scheduleWidgetReload()
        scheduleWatchPush()
        return committed
    }

    /// 登录检查返回新网页请求的解析值，不落盘、不回退 last-good；确认后才走正常刷新。
    /// 无可见用量页时，在同账号 dataStore 的离屏官网页验证（Grok 认证中转页兜底）。
    func checkLogin(_ provider: ProviderID, accountID: UUID?, using webView: WKWebView?) async -> ProviderSnapshot {
        let host = webView?.url?.host ?? provider.probeURL.host ?? "none"
        let source = webView == nil ? "offscreen" : "live"
        var context = "\(provider.rawValue).loginCheck= \(source) host=\(host) loading=\(webView?.isLoading ?? false)"
        if provider == .cursor {
            let dataStore = webView?.configuration.websiteDataStore ?? WebViewFetcher.dataStore(accountID: accountID)
            let cookies = await dataStore.httpCookieStore.allCookies()
            let hasSession = cookies.contains {
                $0.name == "WorkosCursorSessionToken"
                    && LoginWebViewScripts.host($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                                               matches: ["cursor.com", "cursor.sh"])
            }
            context += " sessionCookie=\(hasSession)"
        }
        store.appendDiagnostic(context)
        let results = await fetcher.runProbes(for: provider, accountID: accountID, using: webView)
        appendProbeDiagnostics(prefix: provider.rawValue + ".login", results: results)
        let snapshot = Self.parse(provider: provider, results: results, now: Date())
        store.appendDiagnostic("\(provider.rawValue).login.parsed= " + DiagnosticRedactor.summary(of: snapshot))
        return snapshot
    }

    /// 每个探针一行：HTTP 状态、字节数、脱敏后的响应预览（Release 也记，用户交日志即可定位漂移）。
    private func appendProbeDiagnostics(prefix: String, results: [String: ProbeResult]) {
        for (name, r) in results.sorted(by: { $0.key < $1.key }) {
            store.appendDiagnostic(
                DiagnosticRedactor.probeLine(prefix: prefix, name: name, status: r.status, body: r.body)
            )
        }
    }

    /// 即梦诊断只写布尔和 Cookie **名**，禁止写 value / token / sec_uid。
    private func appendJimengDiagnostics(results: [String: ProbeResult], accountID: UUID?) async {
        if let page = results["page"] {
            store.appendDiagnostic("jimeng.page= \(page.body)")
        }
        let names = await fetcher.jimengObservedCookieNames(accountID: accountID)
        store.appendDiagnostic("jimeng.cookieNames= \(names.joined(separator: ","))")
        store.appendDiagnostic(
            "jimeng.sessionCookie= \(JimengSession.indicatesLogin(cookieNames: names))"
        )
    }

    /// 写回账号表：按 id 合并 store 里已有指纹，避免后台 bind 被陈旧内存表冲掉。
    /// logout / 清指纹只允许目标账号写回 nil。
    private func persistAccounts(clearingFingerprintFor clearedIDs: Set<UUID> = []) {
        let merged = AccountIdentity.preservingStoredFingerprints(
            writing: accounts,
            stored: store.accounts,
            allowingCleared: clearedIDs
        )
        accounts = merged
        store.accounts = merged
    }

    /// 后台已 bind 或本轮 matched 时，把 store 指纹灌回内存，避免下一次整表写回再冲掉。
    private func copyIdentityFingerprint(from latest: [ProviderAccount], provider: ProviderID, accountID: UUID?) {
        if let accountID, let src = latest.first(where: { $0.id == accountID }),
           let idx = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[idx].identityFingerprint = src.identityFingerprint
        } else if accountID == nil,
                  let src = latest.first(where: { $0.provider == provider && $0.isPrimary }),
                  let idx = accounts.firstIndex(where: { $0.provider == provider && $0.isPrimary }) {
            accounts[idx].identityFingerprint = src.identityFingerprint
        }
    }

    /// 首次成功解析绑定指纹；冲突时标 needsLogin 且不覆盖已存快照。
    @discardableResult
    private func applyIdentity(
        provider: ProviderID,
        accountID: UUID?,
        results: [String: ProbeResult],
        snap: inout ProviderSnapshot
    ) -> Bool {
        var latest = store.accounts
        switch AccountIdentity.apply(
            accounts: &latest,
            provider: provider,
            accountID: accountID,
            results: results,
            snap: &snap
        ) {
        case .mismatch:
            store.appendDiagnostic("\(provider.rawValue): 账号身份与已绑定指纹不一致，未覆盖快照")
            return false
        case .bound:
            store.accounts = latest
            copyIdentityFingerprint(from: latest, provider: provider, accountID: accountID)
            return true
        case .matched:
            copyIdentityFingerprint(from: latest, provider: provider, accountID: accountID)
            return true
        case .skipped:
            return true
        }
    }

    private func bumpAccountRefreshGeneration(_ id: UUID) {
        accountRefreshGeneration[id, default: 0] += 1
    }

    /// 等当前在飞刷新因世代 bump 自己 abort 后，再用最新模板/令牌重刷。
    private func refreshAccountAfterInFlight(_ id: UUID) {
        Task {
            while refreshingAccounts.contains(id) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let live = accounts.first(where: { $0.id == id }) else { return }
            await refreshAccount(live, allowWhenDisabled: true)
        }
    }

    private func bumpPrimaryRefreshGeneration(_ provider: ProviderID) {
        primaryRefreshGeneration[provider, default: 0] += 1
    }

    /// fetchedAt CAS 丢弃本轮时，灌回 store 赢家，避免 UI 停在内存 last-good。
    private func adoptAccountSnapshotFromStore(accountID: UUID) -> ProviderSnapshot? {
        let winner = store.accountSnapshot(for: accountID)
        if !demoMode, let winner {
            accountSnapshots[accountID] = winner
        }
        return winner ?? accountSnapshots[accountID]
    }

    private func adoptPrimarySnapshotFromStore(_ provider: ProviderID) -> ProviderSnapshot? {
        let winner = store.snapshot(for: provider)
        if !demoMode, let winner {
            snapshots[provider] = winner
        }
        return winner ?? snapshots[provider]
    }

    /// 在飞刷新对抗 logout/remove：账号已删，指纹被清，或世代被 logout/停用推进。
    private func shouldAbortInFlightRefresh(
        accountID: UUID,
        startFingerprint: String?,
        startGeneration: UInt64
    ) -> Bool {
        let current = accounts.first(where: { $0.id == accountID })
        return InFlightRefresh.shouldAbort(
            startAccountPresent: true,
            currentAccountPresent: current != nil,
            startFingerprint: startFingerprint,
            currentFingerprint: current?.identityFingerprint,
            startGeneration: startGeneration,
            currentGeneration: accountRefreshGeneration[accountID] ?? 0
        )
    }

    private func shouldAbortInFlightPrimaryRefresh(
        provider: ProviderID,
        startAccountID: UUID?,
        startFingerprint: String?,
        startGeneration: UInt64
    ) -> Bool {
        let current = accounts.first(where: { $0.provider == provider && $0.isPrimary })
        return InFlightRefresh.shouldAbort(
            startAccountPresent: startAccountID != nil,
            currentAccountPresent: current != nil && current?.id == startAccountID,
            startFingerprint: startFingerprint,
            currentFingerprint: current?.identityFingerprint,
            startGeneration: startGeneration,
            currentGeneration: primaryRefreshGeneration[provider] ?? 0
        )
    }

    static func parse(provider: ProviderID, results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        switch provider {
        case .claude: return ClaudeParser.parse(results: results, now: now)
        case .openai: return OpenAIParser.parse(results: results, now: now)
        case .grok: return GrokParser.parse(results: results, now: now)
        case .cursor: return CursorParser.parse(results: results, now: now)
        case .deepseek: return DeepSeekParser.parse(results: results, now: now)
        case .zhipu: return ZhipuParser.parse(results: results, now: now)
        case .kimi: return KimiParser.parse(results: results, now: now)
        case .minimax: return MiniMaxParser.parse(results: results, now: now, provider: .minimax)
        case .jimeng: return JimengParser.parse(results: results, now: now)
        case .opencode: return OpenCodeParser.parse(results: results, now: now)
        case .longcat: return LongCatParser.parse(results: results, now: now)
        case .mimo: return MiMoParser.parse(results: results, now: now)
        case .qoder: return QoderParser.parse(results: results, now: now)
        case .perplexity: return PerplexityParser.parse(results: results, now: now)
        case .augment: return AugmentParser.parse(results: results, now: now)
        case .abacus: return AbacusParser.parse(results: results, now: now)
        case .t3chat: return T3ChatParser.parse(results: results, now: now)
        case .notion: return NotionParser.parse(results: results, now: now)
        case .ollama: return OllamaParser.parse(results: results, now: now)
        case .stepfun: return StepFunParser.parse(results: results, now: now)
        case .copilot: return CopilotParser.parse(results: results, now: now)
        case .gemini: return GeminiParser.parse(results: results, now: now)
        case .antigravity: return AntigravityParser.parse(results: results, now: now)
        case .kiro: return KiroParser.parse(results: results, now: now)
        case .minimaxGlobal: return MiniMaxParser.parse(results: results, now: now, provider: .minimaxGlobal)
        }
    }

    /// 前台激活时，只对「曾经成功登录」的服务商做静默刷新，避免打扰未登录站点。
    func autoRefreshIfStale() async {
        // 先把后台刷新（BGAppRefreshTask 只写 store 不碰内存态）的结果灌回 UI，
        // 否则刚被后台刷新过的服务商恰好过不了下面的 10 分钟陈旧线，界面一直是旧数据
        reloadFromStore()
        WatchSync.shared.pushState()
        guard !demoMode else { return }
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let stale = activeProviders.filter { provider in
            guard let snap = store.snapshot(for: provider) else { return false }
            return snap.status.isOK && snap.fetchedAt < cutoff
        }
        let staleAccounts = accounts.filter { account in
            if account.isCustom {
                guard AccountVisibility.shouldProbe(account, providerEnabled: true) else { return false }
            } else if account.isPrimary {
                return false
            } else {
                guard let provider = account.provider else { return false }
                guard AccountVisibility.shouldProbe(account, providerEnabled: isEnabled(provider)) else { return false }
            }
            guard let snap = store.accountSnapshot(for: account.id), snap.status.isOK else { return false }
            return snap.fetchedAt < cutoff
        }
        await withTaskGroup(of: Void.self) { group in
            for provider in stale {
                group.addTask { @MainActor [weak self] in
                    await self?.refresh(provider)
                }
            }
            for account in staleAccounts {
                group.addTask { @MainActor [weak self] in
                    await self?.refreshAccount(account)
                }
            }
        }
    }

    /// 退出登录：清除该站点全部本机数据与快照。
    func logout(_ provider: ProviderID) async {
        bumpPrimaryRefreshGeneration(provider)
        store.removeSnapshot(for: provider)
        if let idx = accounts.firstIndex(where: { $0.provider == provider && $0.isPrimary }) {
            AccountIdentity.clearFingerprint(&accounts[idx])
            persistAccounts(clearingFingerprintFor: [accounts[idx].id])
        }
        if !demoMode {
            snapshots[provider] = nil
        }
        await fetcher.clearWebsiteData(for: provider)
        store.appendDiagnostic("\(provider.rawValue): 已退出登录并清除本机站点数据")
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
        // 已退出的服务商不再保留已预排的到期/重置提醒
        scheduleReminderReload()
    }
}

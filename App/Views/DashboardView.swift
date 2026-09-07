import SwiftUI
import UIKit
import UsageLimitsCore

/// 主界面：用量卡片。按设置 → 外观 → 首页主题在平铺列表与轮盘 / 螺旋场景之间切换。
struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var carousel = DashboardCarouselModel()
    /// 侧边键 = 操作按钮（快捷指令）：命令桥接与菜单状态机；首页只执行它发出的效果。
    @StateObject private var sideKey = DashboardSideKeyController()
    @EnvironmentObject private var edition: Edition
    @State private var loginRequest: LoginRequest?
    @State private var tokenAccount: ProviderAccount?
    @State private var showWidgetPreview = false
    @State private var showSettings = false
    @State private var showNotificationSettings = false
    @State private var showEditionRoute = false
    @State private var showAppearance = false
    @State private var showProvidersSettings = false
    @State private var showAddProvider = false
    @State private var didAutoRefresh = false
    @State private var didHandleAutoRoute = false
    @State private var autoRoutePending = false
    @State private var didConsumeLaunchExpansion = false
    @State private var pendingShare: ShareRequest?
    @State private var editTemplate: CustomUsageTemplate?
    @State private var metricOrderTarget: MetricOrderTarget?
    /// 平铺主题：展开的卡片集合与深链要滚到的卡（场景主题由 carousel 持有对应状态）。
    @State private var flatExpandedIDs: Set<DashboardSceneItemID> = []
    @State private var flatRevealTarget: DashboardSceneItemID?

    var body: some View {
        let items = sceneItems
        let sceneIDs = items.map(\.id)
        let shareItems = displayedShareItems(from: items)
        let selectedID = carousel.selectedID
        let selectedItem = items.first { $0.id == selectedID }
        // 布局来自首页主题偏好（平铺 → nil），场景配色跟随外观设置的深浅色。
        let layout = DashboardSceneLayout(preference: state.dashboardTheme)
        let theme = layout == nil ? nil : DashboardSceneTheme(colorScheme: colorScheme)
        NavigationStack {
            Group {
                if let layout, let theme {
                    DashboardCarouselView(
                        items: items,
                        theme: theme,
                        layout: layout,
                        model: carousel,
                        showsDemoBanner: state.demoMode,
                        onRefreshAll: { Task { await state.refreshAll() } },
                        onAddProvider: { showAddProvider = true },
                        onCommitAccountOrder: commitAccountOrder,
                        onCommitDemoOrder: commitDemoOrder
                    )
                } else {
                    DashboardFlatView(
                        items: items,
                        showsDemoBanner: state.demoMode,
                        showsEmptyHint: state.accounts.isEmpty && !state.demoMode,
                        expandedIDs: $flatExpandedIDs,
                        revealTarget: $flatRevealTarget,
                        onRefreshAll: { await state.refreshAll() },
                        onAddProvider: { showAddProvider = true },
                        onMoveAccount: moveFlatAccount,
                        onMoveDemoProvider: moveFlatDemoProvider
                    )
                }
            }
            // 侧边键（操作按钮）的镜像菜单，三种主题共用：按下弹出设置 / 分享 / 主题，再按轮换选中，点菜单项确认
            .overlay {
                DashboardSideKeyView(
                    controller: sideKey,
                    theme: theme,
                    currentTheme: state.dashboardTheme,
                    opensMenuOnAppear: state.openSideKeyMenuOnLaunch
                )
            }
            // 顶栏不用系统底色：顶边不透明、往下渐进磨砂到透明，三种主题一致
            .dashboardTopFade(solid: theme?.pageBackground ?? Color(.systemGroupedBackground))
            .navigationTitle(L10n.tr("app.title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(theme.map { $0.isDark ? .dark : .light }, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await state.refreshAll() }
                    } label: {
                        if state.isRefreshingAll {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .tint(theme?.primaryForeground)
                    .accessibilityLabel(L10n.tr("card.refresh", lang))
                    .disabled(state.isRefreshingAll)
                }
                ToolbarItem(placement: .principal) {
                    Group {
                        if theme == nil {
                            // 平铺：点标题一键折叠 / 展开全部卡片。
                            Button(action: toggleAllFlatCards) {
                                dashboardTitleLabel
                            }
                            .buttonStyle(.plain)
                        } else if selectedItem?.canExpand == true {
                            Button(action: toggleSelectedCard) {
                                dashboardTitleLabel
                            }
                            .buttonStyle(.plain)
                        } else {
                            dashboardTitleLabel
                        }
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            beginShare(selected: shareItems, isGlobal: true)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(L10n.tr("share.global", lang))
                        .disabled(shareItems.isEmpty)
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(L10n.tr("settings.title", lang))
                    }
                    .tint(theme?.primaryForeground)
                    // 液态玻璃胶囊右侧留白多于左侧：补左侧内边距，和右边对称。
                    .padding(.leading, 10)
                }
            }
            .sheet(item: $loginRequest) { request in
                LoginSheetView(request: request)
                    .onDisappear {
                        if let account = request.account {
                            Task { await state.refreshAccount(account) }
                        } else {
                            Task { await state.refresh(request.provider) }
                        }
                    }
            }
            .sheet(item: $tokenAccount) { account in
                CustomTokenSheet(account: account)
            }
            .navigationDestination(isPresented: $showWidgetPreview) {
                WidgetPreviewView()
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showNotificationSettings) {
                NotificationSettingsView()
            }
            .navigationDestination(isPresented: $showEditionRoute) {
                Group {
                    if let id = edition.pendingRoute, let view = edition.route(id) {
                        view
                    }
                }
            }
            .navigationDestination(isPresented: $showAppearance) {
                AppearanceSettingsView()
            }
            .navigationDestination(isPresented: $showProvidersSettings) {
                ProvidersSettingsView()
            }
            .sheet(isPresented: $showAddProvider) {
                AddProviderSheet { provider, name in
                    let account = state.addAccount(provider: provider, name: name)
                    loginRequest = loginRequestFor(account)
                }
            }
            .sheet(item: $pendingShare) { request in
                SharePreviewSheet(request: request)
            }
            .sheet(item: $editTemplate) { template in
                CustomUsageWizardView(mode: .editTemplate(template))
            }
            .sheet(item: $metricOrderTarget) { target in
                MetricOrderSheet(target: target)
                    .environmentObject(state)
            }
            .onAppear {
                edition.handleLaunch(ProcessInfo.processInfo.arguments)
                if edition.pendingRoute != nil { showEditionRoute = true }
                handleAutoRoute()
                applyFlatLaunchExpansion()
                scheduleLaunchExpansion()
                revealPendingDeepLink()
                configureSideKey()
                carousel.applyLaunchCoilGainIfNeeded(state.helixCoilGainOnLaunch)
            }
            .onChange(of: edition.pendingRoute) { _, route in
                if route != nil { showEditionRoute = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: SideKeyCommandBus.notification)) { _ in
                consumeSideKeyCommand()
            }
            .onChange(of: state.pendingDeepLink) { _, _ in
                revealPendingDeepLink()
            }
            .onChange(of: sceneIDs) { _, _ in
                revealPendingDeepLink()
            }
            .onChange(of: blocksAccountDeepLink) { _, blocked in
                if !blocked {
                    revealPendingDeepLink()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    revealPendingDeepLink()
                } else {
                    carousel.cancelInteraction()
                }
            }
            .onChange(of: state.dashboardTheme) { _, theme in
                sideKey.currentTheme = theme
            }
        }
    }

    private var dashboardTitleLabel: some View {
        Text(L10n.tr("app.title", lang))
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .foregroundStyle(
                isFlatDashboard ? Color.primary : DashboardSceneTheme(colorScheme: colorScheme).primaryForeground
            )
    }

    private var isFlatDashboard: Bool {
        state.dashboardTheme == .flat
    }


    /// 首页渲染、排序和分享共用这一份按存储顺序生成的目录。
    private var sceneItems: [DashboardSceneItem] {
        var items: [DashboardSceneItem] = []
        items.reserveCapacity(state.accounts.count + state.providerOrder.count)
        var seenPrimaryProviders = Set<ProviderID>()

        for account in state.accounts {
            switch account.source {
            case .builtin(let provider):
                if account.isPrimary {
                    seenPrimaryProviders.insert(provider)
                    guard state.showsPrimaryCard(account.provider) else { continue }
                    let snapshot = state.snapshot(provider)
                    let title = state.store.displayName(for: account)
                    items.append(DashboardSceneItem(
                        id: DashboardSceneItemID.account(account.id),
                        source: .builtin(provider: provider, account: account),
                        snapshot: snapshot,
                        title: title,
                        tint: state.resolvedTint(provider: provider),
                        isRefreshing: state.refreshing.contains(provider),
                        canExpand: ProviderCardView.canExpand(snapshot: snapshot),
                        refreshGlow: refreshGlowEnabled,
                        tintedBars: tintedBarsEnabled,
                        barShimmer: barShimmerEnabled,
                        customLogoData: nil,
                        customSubtitle: nil,
                        onLogin: { loginRequest = LoginRequest(provider: provider) },
                        onRefresh: { Task { await state.refresh(provider) } },
                        onLogout: { Task { await state.logout(provider) } },
                        onShare: {
                            if let item = shareCard(account: account, provider: provider) {
                                beginShare(selected: [item], isGlobal: false)
                            }
                        },
                        onEdit: nil,
                        onReorderMetrics: reorderAction(
                            snapshot: snapshot,
                            key: SharedStore.metricOrderKey(provider: provider),
                            title: title,
                            provider: provider,
                            reload: { state.store.snapshot(for: provider)?.metrics ?? [] }
                        )
                    ))
                } else {
                    guard state.showsAccount(account) else { continue }
                    let snapshot = state.accountSnapshots[account.id]
                    let title = state.store.displayName(for: account)
                    items.append(DashboardSceneItem(
                        id: DashboardSceneItemID.account(account.id),
                        source: .builtin(provider: provider, account: account),
                        snapshot: snapshot,
                        title: title,
                        tint: state.resolvedTint(for: account),
                        isRefreshing: state.refreshingAccounts.contains(account.id),
                        canExpand: ProviderCardView.canExpand(snapshot: snapshot),
                        refreshGlow: refreshGlowEnabled,
                        tintedBars: tintedBarsEnabled,
                        barShimmer: barShimmerEnabled,
                        customLogoData: nil,
                        customSubtitle: nil,
                        onLogin: { loginRequest = LoginRequest(account: account) },
                        onRefresh: { Task { await state.refreshAccount(account) } },
                        onLogout: { Task { await state.logoutAccount(account) } },
                        onShare: {
                            if let item = shareCard(account: account, provider: provider) {
                                beginShare(selected: [item], isGlobal: false)
                            }
                        },
                        onEdit: nil,
                        onReorderMetrics: reorderAction(
                            snapshot: snapshot,
                            key: SharedStore.metricOrderKey(accountID: account.id),
                            title: title,
                            provider: provider,
                            reload: { state.store.accountSnapshot(for: account.id)?.metrics ?? [] }
                        )
                    ))
                }
            case .custom:
                guard state.showsAccount(account) else { continue }
                let snapshot = state.accountSnapshots[account.id]
                let title = state.store.displayName(for: account)
                let logoData = state.customLogoData(for: account)
                items.append(DashboardSceneItem(
                    id: DashboardSceneItemID.account(account.id),
                    source: .custom(account: account),
                    snapshot: snapshot,
                    title: title,
                    tint: state.resolvedTint(for: account),
                    isRefreshing: state.refreshingAccounts.contains(account.id),
                    canExpand: ProviderCardView.canExpand(snapshot: snapshot),
                    refreshGlow: refreshGlowEnabled,
                    tintedBars: tintedBarsEnabled,
                    barShimmer: barShimmerEnabled,
                    customLogoData: logoData,
                    customSubtitle: customMetaLine(for: account),
                    onLogin: { tokenAccount = account },
                    onRefresh: { Task { await state.refreshAccount(account) } },
                    onLogout: { Task { await state.logoutAccount(account) } },
                    onShare: {
                        if let item = shareCard(account: account, provider: nil) {
                            beginShare(selected: [item], isGlobal: false)
                        }
                    },
                    onEdit: { openEditTemplate(for: account) },
                    onReorderMetrics: reorderAction(
                        snapshot: snapshot,
                        key: SharedStore.metricOrderKey(accountID: account.id),
                        title: title,
                        reload: { state.store.accountSnapshot(for: account.id)?.metrics ?? [] }
                    )
                ))
            }
        }

        if state.demoMode {
            for provider in state.providerOrder where !seenPrimaryProviders.contains(provider) {
                let snapshot = state.snapshot(provider)
                let title = provider.localizedName(lang)
                items.append(DashboardSceneItem(
                    id: DashboardSceneItemID.demo(provider),
                    source: .demo(provider: provider),
                    snapshot: snapshot,
                    title: title,
                    tint: state.resolvedTint(provider: provider),
                    isRefreshing: state.refreshing.contains(provider),
                    canExpand: ProviderCardView.canExpand(snapshot: snapshot),
                    refreshGlow: refreshGlowEnabled,
                    tintedBars: tintedBarsEnabled,
                    barShimmer: barShimmerEnabled,
                    customLogoData: nil,
                    customSubtitle: nil,
                    onLogin: { loginRequest = LoginRequest(provider: provider) },
                    onRefresh: { Task { await state.refresh(provider) } },
                    onLogout: { Task { await state.logout(provider) } },
                    onShare: {
                        if let item = shareCard(account: nil, provider: provider) {
                            beginShare(selected: [item], isGlobal: false)
                        }
                    },
                    onEdit: nil,
                    onReorderMetrics: reorderAction(
                        snapshot: snapshot,
                        key: SharedStore.metricOrderKey(provider: provider),
                        title: title,
                        provider: provider,
                        reload: { state.store.snapshot(for: provider)?.metrics ?? [] }
                    )
                ))
            }
        }
        return items
    }

    private func displayedShareItems(from items: [DashboardSceneItem]) -> [ShareCardInput] {
        items.compactMap { item in
            guard let snapshot = item.snapshot else { return nil }
            let shareID: String
            switch item.id {
            case .account(let accountID):
                shareID = ShareCardInput.accountID(accountID)
            case .demo(let provider):
                shareID = ShareCardInput.demoID(provider)
            }
            return ShareCardInput(
                id: shareID,
                snapshot: snapshot,
                title: item.title,
                tint: item.tint,
                customLogoData: item.customLogoData
            )
        }
    }

    private var sceneAnimationsPaused: Bool {
        blocksAccountDeepLink
    }

    private var refreshGlowEnabled: Bool {
        state.cardRefreshGlow && edition.cardDecorations().refreshGlow && !sceneAnimationsPaused
    }

    private var tintedBarsEnabled: Bool {
        state.cardTintedBars && edition.cardDecorations().tintedBars
    }

    private var barShimmerEnabled: Bool {
        state.cardBarShimmer && edition.cardDecorations().barShimmer && !sceneAnimationsPaused
    }

    private func commitAccountOrder(_ orderedIDs: [UUID]) {
        var visibleAccountIDs: [UUID] = []
        for item in sceneItems {
            guard case .account(let accountID) = item.id else { continue }
            visibleAccountIDs.append(accountID)
        }
        guard orderedIDs.count == visibleAccountIDs.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(visibleAccountIDs)
        else {
            rollbackCarouselOrder()
            return
        }

        var accountsByID: [UUID: ProviderAccount] = [:]
        for account in state.accounts {
            guard accountsByID.updateValue(account, forKey: account.id) == nil else {
                rollbackCarouselOrder()
                return
            }
        }
        var replacements: [ProviderAccount] = []
        replacements.reserveCapacity(orderedIDs.count)
        for accountID in orderedIDs {
            guard let account = accountsByID[accountID] else {
                rollbackCarouselOrder()
                return
            }
            replacements.append(account)
        }

        let visibleSet = Set(visibleAccountIDs)
        var next = state.accounts
        var replacementIndex = 0
        for index in next.indices where visibleSet.contains(next[index].id) {
            guard replacements.indices.contains(replacementIndex) else {
                rollbackCarouselOrder()
                return
            }
            next[index] = replacements[replacementIndex]
            replacementIndex += 1
        }
        guard replacementIndex == replacements.count else {
            rollbackCarouselOrder()
            return
        }
        state.applyAccountOrder(next)
    }

    private func commitDemoOrder(_ orderedProviders: [ProviderID]) {
        var visibleDemoProviders: [ProviderID] = []
        for item in sceneItems {
            guard case .demo(let provider) = item.id else { continue }
            visibleDemoProviders.append(provider)
        }
        guard orderedProviders.count == visibleDemoProviders.count,
              Set(orderedProviders).count == orderedProviders.count,
              Set(orderedProviders) == Set(visibleDemoProviders)
        else {
            rollbackCarouselOrder()
            return
        }

        let visibleSet = Set(visibleDemoProviders)
        var next = state.providerOrder
        var replacementIndex = 0
        for index in next.indices where visibleSet.contains(next[index]) {
            guard orderedProviders.indices.contains(replacementIndex) else {
                rollbackCarouselOrder()
                return
            }
            next[index] = orderedProviders[replacementIndex]
            replacementIndex += 1
        }
        guard replacementIndex == orderedProviders.count else {
            rollbackCarouselOrder()
            return
        }
        state.setOrder(next)
    }

    /// 场景：把轮盘目录拉回存储顺序。平铺列表直接照 state 渲染，被拒的排序本来就没落盘，无需处理。
    private func rollbackCarouselOrder() {
        carousel.reconcile(ids: sceneItems.map(\.id))
    }

    /// 平铺拖动：把 `moving` 插到 `target` 之前（nil = 末尾）。用当下的目录重算可见账号顺序，再走同一套校验落盘。
    private func moveFlatAccount(_ moving: UUID, before target: UUID?) {
        var order: [UUID] = []
        for item in sceneItems {
            if case .account(let id) = item.id { order.append(id) }
        }
        guard let from = order.firstIndex(of: moving), moving != target else { return }
        order.remove(at: from)
        if let target, let to = order.firstIndex(of: target) {
            order.insert(moving, at: to)
        } else {
            order.append(moving)
        }
        commitAccountOrder(order)
    }

    /// 平铺拖动：演示橱窗卡拖到 `target` 上就换到它的位置。
    private func moveFlatDemoProvider(_ moving: ProviderID, over target: ProviderID) {
        var order: [ProviderID] = []
        for item in sceneItems {
            if case .demo(let provider) = item.id { order.append(provider) }
        }
        guard moving != target,
              let from = order.firstIndex(of: moving),
              let to = order.firstIndex(of: target)
        else { return }
        order.remove(at: from)
        order.insert(moving, at: to)
        commitDemoOrder(order)
    }

    /// 只有已登录且 ≥2 条计量的卡片才给「编辑计量顺序」入口；演示模式不落盘。
    private func reorderAction(
        snapshot: ProviderSnapshot?,
        key: String,
        title: String,
        provider: ProviderID? = nil,
        reload: @escaping () -> [UsageMetric]
    ) -> (() -> Void)? {
        guard !state.demoMode, let snap = snapshot, snap.status.isOK, snap.metrics.count >= 2 else { return nil }
        return {
            metricOrderTarget = MetricOrderTarget(
                key: key, title: title, metrics: snap.metrics, provider: provider, reload: reload
            )
        }
    }

    private func openEditTemplate(for account: ProviderAccount) {
        guard let templateID = account.templateID,
              let template = state.customTemplates.first(where: { $0.id == templateID }) else { return }
        editTemplate = template
    }

    private func customMetaLine(for account: ProviderAccount) -> String? {
        guard case .custom(let templateID) = account.source else { return nil }
        let template = state.customTemplates.first { $0.id == templateID }
        return CustomUsageDisplay.metaLine(
            templateName: template?.name,
            host: template?.requestHost,
            cardTitle: state.store.displayName(for: account)
        )
    }

    /// 单卡分享只预勾这一张；「编辑」仍能从首页目录里加选其他实例。
    private func shareCard(account: ProviderAccount?, provider: ProviderID?) -> ShareCardInput? {
        let catalog = displayedShareItems(from: sceneItems)
        if let account {
            return catalog.first { $0.id == ShareCardInput.accountID(account.id) }
        }
        if let provider {
            return catalog.first { $0.id == ShareCardInput.demoID(provider) }
        }
        return nil
    }

    private func beginShare(selected: [ShareCardInput], isGlobal: Bool) {
        guard !selected.isEmpty else { return }
        let catalog = displayedShareItems(from: sceneItems)
        let composed = ShareFlow.compose(
            snapshots: selected.map(\.snapshot),
            titles: selected.map(\.title),
            tints: selected.map { Optional($0.tint) },
            expanded: true,
            language: lang,
            customLogos: selected.map { Self.cgImage(from: $0.customLogoData) }
        )
        pendingShare = ShareRequest(
            catalog: catalog,
            selectedIDs: Set(selected.map(\.id)),
            expanded: true,
            isGlobal: isGlobal,
            result: composed
        )
    }

    private static func cgImage(from data: Data?) -> CGImage? {
        guard let data, let image = UIImage(data: data) else { return nil }
        return image.cgImage
    }

    private var blocksAccountDeepLink: Bool {
        scenePhase != .active || autoRoutePending
            || showSettings || showNotificationSettings || showProvidersSettings || showWidgetPreview
            || showEditionRoute || showAppearance || showAddProvider
            || loginRequest != nil || tokenAccount != nil || pendingShare != nil
            || editTemplate != nil || metricOrderTarget != nil
    }

    /// 主账号走 default dataStore；附加账号走独立 store。与服务商页同一套。
    private func loginRequestFor(_ account: ProviderAccount) -> LoginRequest? {
        guard let provider = account.provider else { return nil }
        return account.isPrimary ? LoginRequest(provider: provider) : LoginRequest(account: account)
    }

    /// 小组件深链：定位到它展示的那张卡（内置主账号 / 附加账号 / 自定义账号 / 演示卡都走这里）。
    private func revealPendingDeepLink() {
        guard let target = state.pendingRevealTarget, !blocksAccountDeepLink else { return }
        let ids = sceneItems.map(\.id)
        guard ids.contains(target) else { return }
        if isFlatDashboard {
            flatRevealTarget = target
        } else {
            // 场景主题：转到前排，能展开就直接展开
            carousel.reconcile(ids: ids, preferredID: target)
            carousel.collapseAndFocus(target, reduceMotion: reduceMotion)
            if sceneItems.first(where: { $0.id == target })?.canExpand == true {
                carousel.toggleExpansion(for: target, canExpand: true, reduceMotion: reduceMotion)
            }
        }
        state.pendingDeepLink = nil
    }

    /// 平铺主题下的 `--expand-cards`：可展开的卡片全部以展开态启动（场景主题走 `scheduleLaunchExpansion`）。
    /// 还没有任何可展开的卡（首装无快照）时不记「已消费」，等下次出现首页再试。
    private func applyFlatLaunchExpansion() {
        guard isFlatDashboard, state.expandCardsOnLaunch, !didConsumeLaunchExpansion else { return }
        let expandable = Set(sceneItems.filter(\.canExpand).map(\.id))
        guard !expandable.isEmpty else { return }
        flatExpandedIDs = expandable
        didConsumeLaunchExpansion = true
    }

    private func toggleAllFlatCards() {
        let expandable = sceneItems.filter(\.canExpand).map(\.id)
        guard !expandable.isEmpty else { return }
        let allExpanded = expandable.allSatisfy { flatExpandedIDs.contains($0) }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            flatExpandedIDs = allExpanded ? [] : Set(expandable)
        }
    }

    private func scheduleLaunchExpansion() {
        guard state.expandCardsOnLaunch, !didConsumeLaunchExpansion, !isFlatDashboard else { return }
        let initialItems = sceneItems
        let preservedTarget: DashboardSceneItemID?
        if let pendingTarget = state.pendingRevealTarget, !blocksAccountDeepLink {
            preservedTarget = initialItems.contains { $0.id == pendingTarget } ? pendingTarget : nil
        } else {
            preservedTarget = nil
        }

        Task { @MainActor in
            await Task.yield()
            guard !didConsumeLaunchExpansion else { return }
            let items = sceneItems
            let ids = items.map(\.id)
            let target: DashboardSceneItemID?
            if let preservedTarget, ids.contains(preservedTarget) {
                target = preservedTarget
            } else {
                target = carousel.selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            }
            carousel.reconcile(ids: ids, preferredID: target)
            didConsumeLaunchExpansion = true
            guard let target,
                  let targetItem = items.first(where: { $0.id == target })
            else { return }
            if targetItem.canExpand {
                carousel.toggleExpansion(
                    for: target,
                    canExpand: true,
                    reduceMotion: reduceMotion
                )
            } else {
                carousel.collapseAndFocus(target, reduceMotion: reduceMotion)
            }
        }
    }

    private func toggleSelectedCard() {
        guard let selectedID = carousel.selectedID,
              let selected = sceneItems.first(where: { $0.id == selectedID }),
              selected.canExpand
        else { return }
        carousel.toggleExpansion(
            for: selectedID,
            canExpand: true,
            reduceMotion: reduceMotion
        )
    }

    /// 响应 --open-widget-preview / --open-login 启动参数（自动化验证用）。
    private func handleAutoRoute() {
        if state.autoRefreshOnLaunch, !didAutoRefresh {
            didAutoRefresh = true
            Task { await state.refreshAll() }
        }
        guard !didHandleAutoRoute else { return }
        didHandleAutoRoute = true
        switch state.autoRoute {
        case .none:
            break
        case .widgetPreview, .settings, .notificationSettings, .login, .sharePreview,
             .providersSettings, .customWizard, .metricOrder, .appearance, .sideKeyGuide:
            autoRoutePending = true
            Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    autoRoutePending = false
                    return
                }
                switch state.autoRoute {
                case .widgetPreview: showWidgetPreview = true
                case .settings, .sideKeyGuide: showSettings = true
                case .notificationSettings: showNotificationSettings = true
                case .appearance: showAppearance = true
                case .login(let provider): loginRequest = LoginRequest(provider: provider)
                case .providersSettings, .customWizard: showProvidersSettings = true
                case .sharePreview:
                    beginShare(selected: displayedShareItems(from: sceneItems), isGlobal: true)
                case .metricOrder(let provider):
                    reorderAction(
                        snapshot: state.snapshot(provider),
                        key: SharedStore.metricOrderKey(provider: provider),
                        title: state.primaryAccount(provider).map { state.store.displayName(for: $0) }
                            ?? provider.localizedName(lang),
                        provider: provider,
                        reload: { state.store.snapshot(for: provider)?.metrics ?? [] }
                    )?()
                case .none:
                    break
                }
                autoRoutePending = false
                revealPendingDeepLink()
            }
        }
    }

    // MARK: - 侧边键（操作按钮）

    private func configureSideKey() {
        sideKey.onEffect = { [self] effect in handleSideKey(effect) }
        sideKey.currentTheme = state.dashboardTheme
        consumeSideKeyCommand()
    }

    /// 操作按钮 / 快捷指令发来的命令：弹菜单前先收起盖在首页上的页面，命令才落得到首页。
    private func consumeSideKeyCommand() {
        guard let command = SideKeyCommandBus.shared.take() else { return }
        switch command {
        case .menu:
            dismissRoutesForSideKey()
            sideKey.pressSideKey()
        case .settings:
            dismissRoutesForSideKey()
            showSettings = true
        case .share:
            dismissRoutesForSideKey()
            beginShare(selected: displayedShareItems(from: sceneItems), isGlobal: true)
        case .theme(let theme):
            applyDashboardTheme(theme)
        }
        SharedStore.shared.appendDiagnostic("sideKey: handled \(command), menu=\(sideKey.menu == nil ? "closed" : "open")")
    }

    private func applyDashboardTheme(_ theme: DashboardTheme) {
        guard theme != state.dashboardTheme else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            state.dashboardTheme = theme
        }
    }

    private func dismissRoutesForSideKey() {
        showSettings = false
        showNotificationSettings = false
        showProvidersSettings = false
        showWidgetPreview = false
        showEditionRoute = false
        showAppearance = false
        showAddProvider = false
        pendingShare = nil
        editTemplate = nil
        metricOrderTarget = nil
    }

    /// 侧边键状态机发出的效果：跳转 / 切主题在这里执行，触感与诊断由控制器给。
    private func handleSideKey(_ effect: DashboardSideKeyEffect) {
        switch effect {
        case .openSettings:
            showSettings = true
        case .openShare:
            beginShare(selected: displayedShareItems(from: sceneItems), isGlobal: true)
        case .applyTheme(let theme):
            applyDashboardTheme(theme)
        case .menuOpened, .themeMenuOpened, .selectionChanged, .menuClosed:
            break
        }
    }
}

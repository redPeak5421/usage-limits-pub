import SwiftUI
import UIKit
import UsageLimitsCore

/// 首页「平铺」主题：原版竖向列表。卡片按存储顺序铺开、原位展开；整卡长按拖动排序；下拉刷新。
/// 卡面走系统白 / 黑（`sceneTheme: nil`），深浅色跟随外观设置。
/// regular 宽度（iPad 竖 / 横屏、Stage Manager 大窗）改铺自适应多列，单列的行为一条不改：
/// 卡片仍原位展开（顶边固定、只向下长），同一行的邻卡顶对齐、始终可见。
struct DashboardFlatView: View {
    let items: [DashboardSceneItem]
    let showsDemoBanner: Bool
    /// 没有任何账号且不在演示模式：显示「添加供应商」空态。
    let showsEmptyHint: Bool
    /// 展开的卡片集合由首页持有（标题一键折叠 / 展开、`--expand-cards` 都改它）。
    @Binding var expandedIDs: Set<DashboardSceneItemID>
    /// 深链 / 通知要滚到的卡；滚完由本视图清掉。
    @Binding var revealTarget: DashboardSceneItemID?
    let onRefreshAll: () async -> Void
    let onAddProvider: () -> Void
    /// 拖动排序只上报相对移动（谁插到谁前面 / 谁换到谁的位置），由首页按当下的目录重算顺序并校验落盘；
    /// 本视图不持有绝对顺序，动画进行中反复触发也不会用过期快照覆盖存储。
    let onMoveAccount: (UUID, UUID?) -> Void
    let onMoveDemoProvider: (ProviderID, ProviderID) -> Void

    @Environment(\.appLanguage) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// regular 宽度（iPad 竖 / 横屏、Stage Manager 大窗）铺多列；compact（iPhone、iPad 1/3 分屏）保持单列原版。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var collapsedCardHeight: CGFloat = 0
    /// 正在长按拖动的卡片。
    @State private var draggingAccountID: UUID?
    @State private var draggingProvider: ProviderID?
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var reorderTick = 0
    /// 当前压在视口顶边的那张卡。多列 / 单列容器互换时整段内容重建、滚动偏移归零，
    /// 靠它把阅读位置滚回来（`DashboardScrollAnchor`）。展开状态另有 `expandedIDs` 保管。
    @State private var topAnchor: DashboardSceneItemID?

    /// 多列时的列定义：列宽 360–460pt。iPad 竖屏 2 列、横屏 3 列、13 寸横屏也是 3 列（4 列要 4×360 + 3×14 + 32 = 1514pt，超过任何 iPad）。
    private static let wideColumns = [
        GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 14, alignment: .top),
    ]

    /// 多列只在 regular 宽度启用；compact 走下面的单列分支，布局与 iPhone 逐像素一致。
    private var usesMultiColumn: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                listContent
                    .environment(\.dashboardFlatCollapsedHeight, collapsedCardHeight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .coordinateSpace(name: "dashboardList")
                    .sensoryFeedback(.selection, trigger: reorderTick)
                    .onDrop(of: [.text], delegate: AccountListDropDelegate(
                        draggingID: $draggingAccountID,
                        frames: $cardFrames,
                        // 多列时按二维读序判定插入点；单列传 nil，仍走原来的中线滞回判定。
                        multiColumnOrder: usesMultiColumn ? accountOrder : nil,
                        onMove: { moving, target in
                            withAnimation(expansionAnimation) { onMoveAccount(moving, target) }
                            reorderTick += 1
                        }
                    ))
            }
            .background(Color(.systemGroupedBackground))
            .dashboardHidesSystemScrollEdgeEffect()
            .refreshable { await onRefreshAll() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { clearDragState() }
            }
            .onChange(of: revealTarget) { _, target in
                reveal(target, using: proxy)
            }
            .onChange(of: usesMultiColumn) { _, _ in
                collapsedCardHeight = 0
                restoreTopAnchor(using: proxy)
            }
            .onChange(of: dynamicTypeSize) { _, _ in
                collapsedCardHeight = 0
            }
            .onPreferenceChange(DashboardFlatCollapsedHeightKey.self) { height in
                // 懒列表保留见过的最大值，滚走较高的卡片时其余卡不跳动。
                if height > collapsedCardHeight { collapsedCardHeight = height }
            }
            .onAppear {
                reveal(revealTarget, using: proxy)
            }
        }
    }

    /// 单列（compact）与多列（regular）共用同一批卡片视图，只换容器：
    /// 卡片仍是原位展开（顶边固定、只向下长），多列里同一行的邻卡保持顶对齐、始终可见。
    @ViewBuilder
    private var listContent: some View {
        if usesMultiColumn {
            VStack(spacing: 14) {
                // 这三块是单列文本，铺满多列屏会横跨整块玻璃；收进可读栏宽居中。
                // 背景传 nil：外层 ScrollView 已有底色，再铺一层会盖住它。
                if showsDemoBanner {
                    demoBanner
                        .readableWidth(background: nil)
                }
                if showsEmptyHint {
                    allDisabledHint
                        .readableWidth(background: nil)
                }
                LazyVGrid(columns: Self.wideColumns, spacing: 14) {
                    cardList
                }
                privacyFooter
                    .readableWidth(background: nil)
            }
        } else {
            LazyVStack(spacing: 14) {
                if showsDemoBanner {
                    demoBanner
                }
                if showsEmptyHint {
                    allDisabledHint
                }
                cardList
                privacyFooter
            }
        }
    }

    /// 已添加账号按存储顺序展示，允许不同服务商穿插；演示橱窗卡排在后面。
    private var cardList: some View {
        ForEach(items) { item in
            card(item)
                .modifier(tracksTopAnchor(item))
                .id(item.id)
        }
    }

    /// 账号卡的当前显示顺序（多列拖动排序按它算读序插入点）。
    private var accountOrder: [UUID] {
        items.compactMap { item in
            if case .account(let id) = item.id { return id }
            return nil
        }
    }

    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    /// 每张卡只上报自己相对视口顶边的三段位置（`onGeometryChange` 仅在取值变化时回调），
    /// 滚动过程中不会逐像素写状态。
    private func tracksTopAnchor(_ item: DashboardSceneItem) -> some ViewModifier {
        TopAnchorReporter(
            item: item.id,
            isFirstItem: items.first?.id == item.id,
            anchor: $topAnchor
        )
    }

    private struct TopAnchorReporter: ViewModifier {
        let item: DashboardSceneItemID
        let isFirstItem: Bool
        @Binding var anchor: DashboardSceneItemID?

        func body(content: Content) -> some View {
            content.onGeometryChange(for: DashboardScrollAnchor.CardPosition.self) { proxy in
                let frame = proxy.frame(in: .scrollView(axis: .vertical))
                return DashboardScrollAnchor.position(minY: frame.minY, maxY: frame.maxY)
            } action: { position in
                anchor = DashboardScrollAnchor.updated(
                    anchor: anchor,
                    card: item,
                    position: position,
                    isFirstItem: isFirstItem
                )
            }
        }
    }

    @ViewBuilder
    private func card(_ item: DashboardSceneItem) -> some View {
        let isExpanded = item.canExpand && expandedIDs.contains(item.id)
        let card = ProviderCardView(
            provider: item.provider ?? .claude,
            snapshot: item.snapshot,
            isRefreshing: item.isRefreshing,
            isExpanded: isExpanded,
            sceneTheme: nil,
            expandedViewportHeight: nil,
            onToggleExpanded: { toggleExpansion(item) },
            onLogin: item.onLogin,
            onRefresh: item.onRefresh,
            onLogout: item.onLogout,
            onShare: item.onShare,
            titleOverride: item.title,
            tint: item.tint,
            isCustom: item.isCustom,
            customLogoData: item.customLogoData,
            customSubtitle: item.customSubtitle,
            onEdit: item.onEdit,
            onReorderMetrics: item.onReorderMetrics,
            refreshGlow: item.refreshGlow && !reduceMotion,
            tintedBars: item.tintedBars,
            barShimmer: item.barShimmer && !reduceMotion
        )
        // 点卡片本体原位展开 / 收起；子级按钮、菜单优先。
        .onTapGesture { toggleExpansion(item) }

        switch item.id {
        case .account(let accountID):
            // 整卡拖动排序：容器级按指针 Y 与各卡中线换位。
            card
                .opacity(draggingAccountID == accountID ? 0.6 : 1)
                .onDrag {
                    draggingAccountID = accountID
                    return DragSessionItemProvider.make(object: accountID.uuidString as NSString) {
                        if draggingAccountID == accountID { draggingAccountID = nil }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("dashboardList")) } action: {
                    cardFrames[accountID] = $0
                }
                .onDisappear { cardFrames.removeValue(forKey: accountID) }
        case .demo(let provider):
            // 演示橱窗卡（没有真实账号）：按服务商顺序拖动。
            card
                .opacity(draggingProvider == provider ? 0.6 : 1)
                .onDrag {
                    draggingProvider = provider
                    return DragSessionItemProvider.make(object: provider.rawValue as NSString) {
                        if draggingProvider == provider { draggingProvider = nil }
                    }
                }
                .onDrop(of: [.text], delegate: ProviderCardDropDelegate(
                    item: provider,
                    dragging: $draggingProvider,
                    onMove: { moving in
                        withAnimation(expansionAnimation) { onMoveDemoProvider(moving, provider) }
                        reorderTick += 1
                    }
                ))
        }
    }

    private func toggleExpansion(_ item: DashboardSceneItem) {
        guard item.canExpand else { return }
        withAnimation(expansionAnimation) {
            if expandedIDs.contains(item.id) {
                expandedIDs.remove(item.id)
            } else {
                expandedIDs.insert(item.id)
            }
        }
    }

    /// 多列 / 单列容器互换后把阅读位置滚回锚点。锚点为空代表原本就在最顶，什么都不做。
    /// 不带动画：这一步是在补容器重建丢掉的偏移量，不是用户发起的滚动。
    private func restoreTopAnchor(using proxy: ScrollViewProxy) {
        guard let topAnchor else { return }
        // 新容器这一帧刚建好，等布局落定再滚，否则 scrollTo 落在旧几何上。
        // 滚两次：懒容器只有滚过去之后才把沿途的卡真正建出来，展开的卡一变高，第一次的落点
        // 就会短一截（实测两列滚到 DeepSeek 那行、缩窄后停在上一行）。第二次按真实高度收尾。
        Task { @MainActor in
            proxy.scrollTo(topAnchor, anchor: .top)
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(topAnchor, anchor: .top)
        }
    }

    private func reveal(_ target: DashboardSceneItemID?, using proxy: ScrollViewProxy) {
        guard let target else { return }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(target, anchor: .center)
        }
        revealTarget = nil
    }

    // MARK: - 排序

    private func clearDragState() {
        draggingAccountID = nil
        draggingProvider = nil
    }

    /// 容器级判定：单列用指针 Y 与各卡中线换位，间隙也能落点；多列改按二维读序判定
    /// （`multiColumnOrder` 非空时生效），否则同一行并排的卡中线相同、纵向判定会失效。
    private struct AccountListDropDelegate: DropDelegate {
        @Binding var draggingID: UUID?
        @Binding var frames: [UUID: CGRect]
        let multiColumnOrder: [UUID]?
        let onMove: @MainActor (UUID, UUID?) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            draggingID != nil
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            MainActor.assumeIsolated {
                applyPointer(info.location)
            }
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            draggingID = nil
            return true
        }

        @MainActor
        private func applyPointer(_ pointer: CGPoint) {
            guard let dragging = draggingID else { return }
            let decision: DragReorder.Decision
            if let multiColumnOrder {
                // 按显示顺序取出已测量的卡（含被拖卡），交给 Core 的纯几何判定。
                let cards = multiColumnOrder.compactMap { id in
                    frames[id].map {
                        GridDragReorder.Card(
                            id: id,
                            x: Double($0.origin.x),
                            y: Double($0.origin.y),
                            width: Double($0.size.width),
                            height: Double($0.size.height)
                        )
                    }
                }
                decision = GridDragReorder.decision(
                    pointerX: Double(pointer.x),
                    pointerY: Double(pointer.y),
                    cards: cards,
                    dragging: dragging
                )
            } else {
                let cards = frames
                    .map { (id: $0.key, midY: Double($0.value.midY)) }
                    .sorted { $0.midY < $1.midY }
                decision = DragReorder.decision(
                    pointerY: Double(pointer.y),
                    cards: cards,
                    dragging: dragging
                )
            }
            switch decision {
            case .none:
                break
            case .before(let target):
                onMove(dragging, target)
            case .toEnd:
                onMove(dragging, nil)
            }
        }
    }

    /// 演示橱窗卡：按服务商顺序拖动（没有真实账号）。账号卡拖过演示卡时不接管，
    /// 让容器级判定继续工作（否则演示卡区域会变成账号排序的死区）。
    private struct ProviderCardDropDelegate: DropDelegate {
        let item: ProviderID
        @Binding var dragging: ProviderID?
        let onMove: @MainActor (ProviderID) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            dragging != nil
        }

        func dropEntered(info: DropInfo) {
            MainActor.assumeIsolated {
                guard let dragging, dragging != item else { return }
                onMove(dragging)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }
    }

    // MARK: - 附属视图

    private var allDisabledHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L10n.tr("disabled.all.title", lang))
                .font(.subheadline)
            Text(L10n.tr("disabled.all.hint", lang))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onAddProvider) {
                Text(L10n.tr("providers.add", lang))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .accessibilityLabel(L10n.tr("providers.add", lang))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(L10n.tr("demo.banner", lang))
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private var privacyFooter: some View {
        Text(L10n.tr("privacy.footer", lang))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
            .padding(.horizontal, 12)
    }
}

/// 拖动会话结束（放手、取消、系统中断）时系统会释放 NSItemProvider；借随它一起释放的
/// 关联 token 的 deinit 通知视图清空「正在拖动」状态。onDrag 没有结束回调，卡片
/// DropDelegate 只覆盖落在卡片上的情况，长按后原地松手 / 拖到空白处放手都不会走
/// performDrop（DEVLOG #42）。
/// 不能继承 NSItemProvider：`-initWithObject:` 内部会调 `[self init]`，
/// 子类没有 `init()` 就 fatal「Use of unimplemented initializer」（DEVLOG #52）。
private enum DragSessionItemProvider {
    nonisolated(unsafe) private static var tokenKey: UInt8 = 0

    static func make(object: NSItemProviderWriting, onEnd: @escaping @MainActor @Sendable () -> Void) -> NSItemProvider {
        let provider = NSItemProvider(object: object)
        objc_setAssociatedObject(provider, &tokenKey, DragSessionToken(onEnd: onEnd), .OBJC_ASSOCIATION_RETAIN)
        return provider
    }

    private final class DragSessionToken {
        private let onEnd: @MainActor @Sendable () -> Void
        init(onEnd: @escaping @MainActor @Sendable () -> Void) { self.onEnd = onEnd }
        deinit {
            let onEnd = onEnd
            Task { @MainActor in onEnd() }
        }
    }
}

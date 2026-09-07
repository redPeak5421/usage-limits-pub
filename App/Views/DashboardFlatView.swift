import SwiftUI
import UIKit
import UsageLimitsCore

/// 首页「平铺」主题：原版竖向列表。卡片按存储顺序铺开、原位展开；整卡长按拖动排序；下拉刷新。
/// 卡面走系统白 / 黑（`sceneTheme: nil`），深浅色跟随外观设置。
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
    /// 正在长按拖动的卡片。
    @State private var draggingAccountID: UUID?
    @State private var draggingProvider: ProviderID?
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var reorderTick = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if showsDemoBanner {
                        demoBanner
                    }
                    if showsEmptyHint {
                        allDisabledHint
                    }
                    // 已添加账号按存储顺序展示，允许不同服务商穿插；演示橱窗卡排在后面。
                    ForEach(items) { item in
                        card(item)
                            .id(item.id)
                    }
                    privacyFooter
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .coordinateSpace(name: "dashboardList")
                .sensoryFeedback(.selection, trigger: reorderTick)
                .onDrop(of: [.text], delegate: AccountListDropDelegate(
                    draggingID: $draggingAccountID,
                    frames: $cardFrames,
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
            .onAppear {
                reveal(revealTarget, using: proxy)
            }
        }
    }

    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
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

    /// 容器级判定：用指针 Y 与各卡中线换位，间隙也能落点。
    private struct AccountListDropDelegate: DropDelegate {
        @Binding var draggingID: UUID?
        @Binding var frames: [UUID: CGRect]
        let onMove: @MainActor (UUID, UUID?) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            draggingID != nil
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            MainActor.assumeIsolated {
                applyPointer(Double(info.location.y))
            }
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            draggingID = nil
            return true
        }

        @MainActor
        private func applyPointer(_ pointerY: Double) {
            guard let dragging = draggingID else { return }
            let cards = frames
                .map { (id: $0.key, midY: Double($0.value.midY)) }
                .sorted { $0.midY < $1.midY }
            switch DragReorder.decision(pointerY: pointerY, cards: cards, dragging: dragging) {
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

import UsageLimitsCore
import Foundation
import SwiftUI
import UIKit

struct DashboardRenderSlotID: Hashable {
    let logicalID: DashboardSceneItemID
    let cycle: Int
}

private struct DashboardRenderSlot: Identifiable {
    let id: DashboardRenderSlotID
    let item: DashboardSceneItem
    let virtualIndex: Int
    var isActionable: Bool
}

private struct DashboardMeasuredCardRegion: Equatable {
    let slotID: DashboardRenderSlotID
    let logicalID: DashboardSceneItemID
    let frame: CGRect
    let depth: Double
    let renderOrder: Int
    let isFront: Bool
    let isActionable: Bool
}

private struct DashboardBlankTapCandidate {
    let location: CGPoint
    let timestamp: TimeInterval
}

@MainActor
struct DashboardCarouselView: View {
    /// 两侧留白 20pt（参考的 320 宽在 402pt 屏上留白 41pt，用户要求减半、卡片等比放大）。
    private static let maximumCollapsedCardWidth: CGFloat = 362
    /// 宽屏（iPad 竖屏、Stage Manager 大窗）纵向盘面还有余量时按场景高度等比放大卡片的系数：
    /// = iPhone 竖屏基准（362pt 卡宽 / 874pt 场景高）。轮盘的纵向盘距、螺旋的螺距都随卡高走，
    /// 保持这个比例，放大后的盘面上下仍不会被裁掉。
    /// 这个系数只在 `horizontalSizeClass == .regular` 时参与计算，手机一律走 362 上限，见 `sceneCanvas`。
    private static let collapsedCardWidthPerSceneHeight: CGFloat = 362.0 / 874.0
    /// 放大的绝对上限：再大卡片内容（字号固定）会显得空。
    private static let widescreenCollapsedCardWidth: CGFloat = 520
    private static let visibleOpacityThreshold = 0.03
    private static let blankDoubleTapInterval: TimeInterval = 0.320
    private static let blankDoubleTapDistance: CGFloat = 24
    private static let physicalSlotDeltas = Array(stride(from: -4, through: 4, by: 1))

    let items: [DashboardSceneItem]
    let theme: DashboardSceneTheme
    let layout: DashboardSceneLayout
    @ObservedObject private var model: DashboardCarouselModel
    let showsDemoBanner: Bool
    let onRefreshAll: @MainActor () -> Void
    let onAddProvider: () -> Void
    let onCommitAccountOrder: ([UUID]) -> Void
    let onCommitDemoOrder: ([ProviderID]) -> Void
    private let stableIDs: [DashboardSceneItemID]
    private let expandableIDs: [DashboardSceneItemID]
    private let itemDictionary: [DashboardSceneItemID: DashboardSceneItem]

    @Environment(\.appLanguage) private var language
    @Environment(\.usageDisplayMode) private var displayMode
    @Environment(\.resetTimeStyle) private var resetStyle
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.scenePhase) private var scenePhase
    /// 卡片放大只认宽度 size class：regular = iPad 全屏 / 竖屏 / 大窗；compact = 所有 iPhone 与窄分屏。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var controlRegions: [UUID: CGRect] = [:]
    /// 计量条区域：触摸可从这里开始并滚动场景，只是不从这里起整卡排序（长按交给计量条的上下文菜单）
    @State private var deferredRegions: [UUID: CGRect] = [:]
    @State private var blankTapCandidate: DashboardBlankTapCandidate?
    /// 画布延伸到屏幕上下边后，顶 / 底安全区里较大的那个：展开卡居中，两侧各让出这么多才不会钻到顶栏或 Home 条下面。
    @State private var verticalSafeInset: CGFloat = 0
    /// 螺旋横向倾斜上一次咔哒时的角度：每转过 `DashboardSceneTick.tiltStepDegrees` 再响一声。
    @State private var lastTickTilt: Double = DashboardSceneMath.helixCoilTiltRange.upperBound

    init(
        items: [DashboardSceneItem],
        theme: DashboardSceneTheme,
        layout: DashboardSceneLayout,
        model: DashboardCarouselModel,
        showsDemoBanner: Bool,
        onRefreshAll: @escaping @MainActor () -> Void,
        onAddProvider: @escaping () -> Void,
        onCommitAccountOrder: @escaping ([UUID]) -> Void,
        onCommitDemoOrder: @escaping ([ProviderID]) -> Void
    ) {
        self.items = items
        self.theme = theme
        self.layout = layout
        _model = ObservedObject(wrappedValue: model)
        self.showsDemoBanner = showsDemoBanner
        self.onRefreshAll = onRefreshAll
        self.onAddProvider = onAddProvider
        self.onCommitAccountOrder = onCommitAccountOrder
        self.onCommitDemoOrder = onCommitDemoOrder
        stableIDs = items.map(\.id)
        expandableIDs = items.filter(\.canExpand).map(\.id)

        var dictionary: [DashboardSceneItemID: DashboardSceneItem] = [:]
        dictionary.reserveCapacity(items.count)
        for item in items where dictionary[item.id] == nil {
            dictionary[item.id] = item
        }
        itemDictionary = dictionary
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                sceneCanvas(proxy: proxy)
            }
            // 场景画布一直画到屏幕顶边和底边：远端卡片从渐进磨砂的顶栏下方穿过，
            // 渐变 / 导轨 / 裁切边也不会停在安全区边上留出横边。
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(proxy.safeAreaInsets.top, proxy.safeAreaInsets.bottom)
            } action: { inset in
                verticalSafeInset = inset
            }
        }
        // 演示横幅贴在安全区顶部（导航栏下方），盖在场景之上
        .overlay(alignment: .top) {
            if showsDemoBanner {
                demoBanner
            }
        }
        .background(theme.pageBackground.ignoresSafeArea())
        .onAppear {
            model.reconcile(ids: stableIDs)
            if scenePhase != .active || voiceOverEnabled || reduceMotion {
                cancelSceneInteraction()
            }
        }
        .onChange(of: stableIDs) { _, ids in
            model.reconcile(ids: ids)
        }
        .onChange(of: expandableIDs) { _, ids in
            guard let expandedID = model.expandedID, !ids.contains(expandedID) else { return }
            model.toggleExpansion(for: expandedID, canExpand: false, reduceMotion: reduceMotion)
        }
        .onChange(of: theme) { _, _ in
            cancelSceneInteraction()
        }
        .onChange(of: layout) { _, _ in
            cancelSceneInteraction()
        }
        .onChange(of: scenePhase) { _, _ in
            cancelSceneInteraction()
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled {
                cancelSceneInteraction()
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled {
                cancelSceneInteraction()
            }
        }
        .onChange(of: model.selectedID) { oldID, newID in
            guard oldID != nil, newID != nil, oldID != newID else { return }
            DashboardSceneHaptic.selectionChanged()
            DashboardSceneTick.play()
        }
        .onChange(of: model.tiltDegrees) { _, tilt in
            guard layout == .helix, tilt.isFinite else { return }
            if abs(tilt - lastTickTilt) >= DashboardSceneTick.tiltStepDegrees {
                lastTickTilt = tilt
                DashboardSceneHaptic.selectionChanged()
                DashboardSceneTick.play()
            }
        }
        .onChange(of: model.reorderPreview) { oldPreview, newPreview in
            guard oldPreview != nil, newPreview != nil, oldPreview != newPreview else { return }
            DashboardSceneHaptic.selectionChanged()
        }
    }

    private static func safeRoundedVirtualIndex(_ position: Double) -> Int {
        guard position.isFinite else { return 0 }
        let roundedPosition = position.rounded()
        return Int(exactly: roundedPosition)
            ?? (roundedPosition.sign == .minus ? Int.min : Int.max)
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(L10n.tr("demo.banner", language))
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(theme.primaryForeground)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(theme.pageDepth.opacity(theme.isDark ? 0.92 : 0.78))
    }

    private func sceneCanvas(proxy: GeometryProxy) -> some View {
        let activeIDs = model.reorderPreview ?? model.orderedIDs
        let frontVirtualIndex = Self.safeRoundedVirtualIndex(model.position)
        let renderSlots = makeRenderSlots(
            activeIDs: activeIDs,
            frontVirtualIndex: frontVirtualIndex
        )
        let horizontalRoom = max(proxy.size.width - 40, 0)
        let compactCardWidth = min(horizontalRoom, Self.maximumCollapsedCardWidth)
        // 放大只在 regular 宽度启用，不用窗高阈值判断：iPhone Plus / Max 竖屏窗高 932 / 956pt，
        // 按 362/874 的高度比推导会把它们的卡宽放大 6.6%–9.4%，而这些机型仍是 compact 宽度、
        // 必须与改动前逐像素一致。size class 才是「iPad 全屏 / 竖屏 / 大窗」的准确判据，
        // 窄分屏（compact）自动落回下面的 362 上限口径。
        let widescreenCardWidth: CGFloat = horizontalSizeClass == .regular
            ? min(
                horizontalRoom,
                min(proxy.size.height * Self.collapsedCardWidthPerSceneHeight, Self.widescreenCollapsedCardWidth)
            )
            : 0
        let collapsedCardWidth = max(compactCardWidth, widescreenCardWidth)
        let collapsedCardHeight = collapsedCardWidth * (53.98 / 85.6)
        let cardSize = CGSize(width: collapsedCardWidth, height: collapsedCardHeight)
        let selectedTint = model.selectedID.flatMap { itemDictionary[$0]?.tint }

        return ZStack(alignment: .bottom) {
            DashboardSceneBackground(theme: theme)

            // 指针 / 光晕 / 导轨等场景装饰画在卡片之下：前排（最上层）卡片永远不被遮挡。
            if !activeIDs.isEmpty {
                DashboardSceneChrome(theme: theme, layout: layout, tint: selectedTint)
            }

            ZStack {
                if activeIDs.isEmpty {
                    emptyState
                } else {
                    sceneAccessibilityContainer(
                        renderSlots: renderSlots,
                        activeIDs: activeIDs,
                        frontVirtualIndex: frontVirtualIndex,
                        cardSize: cardSize,
                        sceneSize: proxy.size
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 盘面按卡片等比放大后，远端卡片会伸出场景顶 / 底边；参考里由顶栏盖住，这里直接裁掉。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "dashboardScene")
        .onPreferenceChange(DashboardSceneControlRegionPreferenceKey.self) { regions in
            let valid = regions.filter { dashboardSceneValidFrame($0.value) }
            if controlRegions != valid {
                controlRegions = valid
            }
        }
        .onPreferenceChange(DashboardSceneDeferredRegionPreferenceKey.self) { regions in
            let valid = regions.filter { dashboardSceneValidFrame($0.value) }
            if deferredRegions != valid {
                deferredRegions = valid
            }
        }
        .gesture(
            DashboardSceneGesture(
                isEnabled: gestureIsEnabled,
                movementTolerance: layout == .roulette ? 8 : 10,
                isExcludedTarget: { location in
                    controlRegions.values.contains { $0.contains(location) }
                },
                isReorderTarget: { location in
                    reorderTarget(
                        at: location,
                        renderSlots: renderSlots,
                        frontVirtualIndex: frontVirtualIndex,
                        cardSize: cardSize,
                        sceneSize: proxy.size,
                        activeIDs: activeIDs
                    ) != nil
                },
                isDeferredTarget: { location in
                    deferredRegions.values.contains { $0.contains(location) }
                },
                onEvent: { event in
                    route(
                        event,
                        renderSlots: renderSlots,
                        frontVirtualIndex: frontVirtualIndex,
                        cardSize: cardSize,
                        sceneSize: proxy.size,
                        activeIDs: activeIDs
                    )
                },
                onExcludedTouchBegan: {
                    clearBlankTapCandidate()
                }
            )
        )
        .onAppear {
            model.updateGeometry(cardSize: cardSize, sceneSize: proxy.size)
            model.applyDefaultSpacingIfNeeded()
        }
        .onChange(of: cardSize) { _, newSize in
            updateCollapsedGeometry(cardSize: newSize, sceneSize: proxy.size)
        }
        .onChange(of: proxy.size) { _, sceneSize in
            updateCollapsedGeometry(cardSize: cardSize, sceneSize: sceneSize)
        }
    }

    private var gestureIsEnabled: Bool {
        scenePhase == .active && !voiceOverEnabled
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(theme.metalAccent)
            Text(L10n.tr("providers.empty", language))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryForeground)
            Button(action: onAddProvider) {
                Text(L10n.tr("providers.add", language))
                    .font(.headline)
                    .foregroundStyle(theme.isDark ? theme.primaryForeground : theme.pageBackground)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background {
                        Capsule()
                            .fill(theme.isDark ? theme.surfaceBase : theme.primaryForeground)
                            .overlay {
                                Capsule()
                                    .stroke(
                                        theme.metalAccent.opacity(theme.isDark ? 0.64 : 0.78),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(
                                color: theme.surfaceShadow.opacity(theme.isDark ? 0.32 : 0.12),
                                radius: 10,
                                y: 5
                            )
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .dashboardSceneControlRegion()
            .environment(\.dashboardSceneControlsEnabled, true)

            Text(L10n.tr("privacy.footer", language))
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryForeground)
        }
        .padding(28)
        .frame(maxWidth: 360)
    }

    private func sceneAccessibilityContainer(
        renderSlots: [DashboardRenderSlot],
        activeIDs: [DashboardSceneItemID],
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize
    ) -> some View {
        let selectedItem = model.selectedID.flatMap { itemDictionary[$0] }
        let expansionActionName: String?
        if model.expandedID != nil {
            expansionActionName = L10n.tr("dashboard.action.collapse", language)
        } else if selectedItem?.canExpand == true {
            expansionActionName = L10n.tr("dashboard.action.expand", language)
        } else {
            expansionActionName = nil
        }
        let moveEarlierActionName = model.canAccessibilityMoveSelected(by: -1)
            ? L10n.tr("dashboard.action.moveEarlier", language)
            : nil
        let moveLaterActionName = model.canAccessibilityMoveSelected(by: 1)
            ? L10n.tr("dashboard.action.moveLater", language)
            : nil

        return ZStack {
            ForEach(renderSlots) { slot in
                cardView(
                    for: slot,
                    frontVirtualIndex: frontVirtualIndex,
                    cardSize: cardSize,
                    sceneSize: sceneSize
                )
            }
        }
        .modifier(DashboardSceneAccessibilityModifier(
            isExpanded: model.expandedID != nil,
            label: sceneAccessibilityLabel(for: selectedItem),
            value: sceneAccessibilityValue(for: selectedItem, activeIDs: activeIDs),
            expansionActionName: expansionActionName,
            moveEarlierActionName: moveEarlierActionName,
            moveLaterActionName: moveLaterActionName,
            refreshAllActionName: L10n.tr("dashboard.action.refreshAll", language),
            resetHelixActionName: layout == .helix && model.expandedID == nil
                ? L10n.tr("dashboard.action.resetHelix", language)
                : nil,
            onAdjustSelection: { direction in
                model.accessibilityAdjustSelection(by: direction)
            },
            onToggleExpansion: {
                guard let selectedItem else { return }
                withAnimation(expansionAnimation) {
                    model.toggleExpansion(
                        for: selectedItem.id,
                        canExpand: selectedItem.canExpand,
                        reduceMotion: reduceMotion
                    )
                }
            },
            onMove: { direction in
                dispatchReorderCommit(model.accessibilityMoveSelected(by: direction))
            },
            onRefreshAll: {
                onRefreshAll()
            },
            onResetHelix: {
                model.resetHelix(reduceMotion: reduceMotion)
            }
        ))
    }

    private func sceneAccessibilityLabel(for item: DashboardSceneItem?) -> String {
        guard let item else { return "" }
        return item.title
    }

    private func sceneAccessibilityValue(
        for item: DashboardSceneItem?,
        activeIDs: [DashboardSceneItemID]
    ) -> String {
        guard let item,
              let index = activeIDs.firstIndex(of: item.id)
        else { return "" }

        let position = L10n.tr("dashboard.position", language, index + 1, activeIDs.count)
        let status: String
        if let snapshot = item.snapshot {
            status = snapshot.status.isOK
                ? L10n.tr("dashboard.status.available", language)
                : snapshot.status.displayText(language)
        } else {
            status = SnapshotStatus.needsLogin.displayText(language)
        }
        let metric = collapsedAccessibilityMetric(for: item)
        return [position, status, metric]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func collapsedAccessibilityMetric(for item: DashboardSceneItem) -> String {
        guard let snapshot = item.snapshot, snapshot.status.isOK else { return "" }
        switch item.source {
        case .custom:
            let shown = CustomUsageDisplay.presentation(
                from: snapshot,
                mode: displayMode,
                language: language,
                resetStyle: resetStyle
            )
            guard let tile = CustomUsageDisplay.collapsedTile(from: snapshot, shown: shown) else {
                return ""
            }
            return "\(tile.label) \(tile.valueText)"
        case let .builtin(provider, _), let .demo(provider):
            guard let metric = snapshot.collapsedMetric else { return "" }
            let label = L10n.metricLabel(
                provider: provider,
                id: metric.id,
                fallback: metric.label,
                language: language
            )
            let value = UsagePresentation.valueText(
                for: metric,
                language: language,
                mode: displayMode
            )
            return "\(label) \(value)"
        }
    }


    private func makeRenderSlots(
        activeIDs: [DashboardSceneItemID],
        frontVirtualIndex: Int
    ) -> [DashboardRenderSlot] {
        let count = activeIDs.count
        guard count > 0 else { return [] }

        var slots: [DashboardRenderSlot] = []
        slots.reserveCapacity(count == 1 ? 1 : Self.physicalSlotDeltas.count)

        for delta in Self.physicalSlotDeltas {
            if count == 1, delta != 0 { continue }
            let (virtualIndex, overflowed) = frontVirtualIndex.addingReportingOverflow(delta)
            guard !overflowed else { continue }
            let logicalIndex = DashboardSceneMath.wrappedIndex(virtualIndex, count: count)
            let logicalID = activeIDs[logicalIndex]
            guard let item = itemDictionary[logicalID] else { continue }
            let q = virtualIndex / count
            let cycle = virtualIndex % count < 0 ? q - 1 : q
            let distance = abs(Double(virtualIndex) - model.position)
            var isActionable = true

            for index in slots.indices
            where slots[index].id.logicalID == logicalID && slots[index].isActionable {
                let currentVirtualIndex = slots[index].virtualIndex
                let currentDistance = abs(Double(currentVirtualIndex) - model.position)
                if distance < currentDistance
                    || (distance == currentDistance && virtualIndex < currentVirtualIndex) {
                    slots[index].isActionable = false
                } else {
                    isActionable = false
                }
                break
            }

            slots.append(DashboardRenderSlot(
                id: DashboardRenderSlotID(logicalID: logicalID, cycle: cycle),
                item: item,
                virtualIndex: virtualIndex,
                isActionable: isActionable
            ))
        }

        return slots
    }

    private func scenePose(
        for slot: DashboardRenderSlot,
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize
    ) -> DashboardScenePose {
        let offset = Double(slot.virtualIndex) - model.position
        let isFront = slot.virtualIndex == frontVirtualIndex
        if layout == .roulette {
            return DashboardSceneMath.roulettePose(
                offset: offset,
                reduceMotion: reduceMotion,
                unitScale: cardSize.height / DashboardSceneMath.rouletteReferenceCardHeight
            )
        }
        return DashboardSceneMath.helixPose(
            offset: offset,
            isFront: isFront,
            tiltDegrees: model.tiltDegrees,
            spacing: model.effectiveSpacing,
            coilGain: model.coilGain,
            cardWidth: cardSize.width,
            cardHeight: cardSize.height,
            sceneWidth: sceneSize.width,
            reduceMotion: reduceMotion
        )
    }

    private func measuredCardRegion(
        for slot: DashboardRenderSlot,
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize
    ) -> DashboardMeasuredCardRegion? {
        guard model.expandedID == nil else { return nil }
        let pose = scenePose(
            for: slot,
            frontVirtualIndex: frontVirtualIndex,
            cardSize: cardSize,
            sceneSize: sceneSize
        )
        guard pose.opacity >= Self.visibleOpacityThreshold else { return nil }
        let frame = DashboardSceneMath.projectedCardBounds(
            pose: pose,
            cardWidth: cardSize.width,
            cardHeight: cardSize.height,
            sceneWidth: sceneSize.width,
            sceneHeight: sceneSize.height
        )
        .intersection(CGRect(origin: .zero, size: sceneSize))
        guard dashboardSceneValidFrame(frame) else { return nil }
        return DashboardMeasuredCardRegion(
            slotID: slot.id,
            logicalID: slot.item.id,
            frame: frame,
            depth: pose.z,
            renderOrder: slot.virtualIndex,
            isFront: slot.virtualIndex == frontVirtualIndex,
            isActionable: slot.isActionable
        )
    }

    private func cardView(
        for slot: DashboardRenderSlot,
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize
    ) -> some View {
        let item = slot.item
        let virtualIndex = slot.virtualIndex
        let isFront = virtualIndex == frontVirtualIndex
        let pose = scenePose(
            for: slot,
            frontVirtualIndex: frontVirtualIndex,
            cardSize: cardSize,
            sceneSize: sceneSize
        )
        let isExpanded = model.expandedID == item.id && isFront
        // 展开只到内容高度（上限为场景高度）；宽度只比折叠态略宽，保持"原地展开"。
        let expandedWidth = min(max(0, sceneSize.width - 24), cardSize.width + 24)
        let expandedHeight = max(0, sceneSize.height - 24 - verticalSafeInset * 2)
        let frameWidth = isExpanded ? expandedWidth : cardSize.width
        let frameHeight = isExpanded ? expandedHeight : cardSize.height
        // 展开只在原位撑开选中卡片，其余卡片保持原样可见；展开卡片永远在最上层。
        let visualScale = isExpanded ? 1 : pose.scale
        let visualOpacity = isExpanded ? 1 : pose.opacity
        // 焦点卡永远压在最上层：前景虚化卡（z > 0）再近也不许挡住它（用户裁定）；其余按场景数学给的画顺序
        let visualDepth = isExpanded ? 10_000 : (isFront ? 5_000 : pose.depthOrder)
        let controlsArePublished = isFront
        let nativeHitTesting = isExpanded || controlsArePublished
        let isAccessibilityVisible = model.expandedID != nil && isExpanded
        let effectiveRefreshGlow = item.refreshGlow && !reduceMotion && isFront
        let effectiveBarShimmer = item.barShimmer && !reduceMotion && isFront
        let dimAmount: Double = isExpanded ? 0 : 1 - pose.brightness
        let showsCurrentMarker = differentiateWithoutColor && isFront && model.expandedID == nil

        // 先把卡片构造成局部值再挂修饰符：整条表达式太长会让类型检查超时
        let card = ProviderCardView(
            provider: item.provider ?? .claude,
            snapshot: item.snapshot,
            isRefreshing: item.isRefreshing,
            isExpanded: isExpanded,
            sceneTheme: theme,
            expandedViewportHeight: isExpanded ? expandedHeight : nil,
            // 展开永远不比折叠卡矮（只有一条计量条的卡点开看更新时间也不能缩）；折叠露两条计量条。
            // 折叠前排卡带投影放大（pose.scale），展开卡不放大，下限按放大后的视觉高度算。
            expandedMinimumHeight: isExpanded ? cardSize.height * CGFloat(pose.scale) : nil,
            collapsedMetricLimit: 2,
            onToggleExpanded: {
                clearBlankTapCandidate()
                withAnimation(expansionAnimation) {
                    model.toggleExpansion(for: item.id, canExpand: item.canExpand, reduceMotion: reduceMotion)
                }
            },
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
            refreshGlow: effectiveRefreshGlow,
            tintedBars: item.tintedBars,
            barShimmer: effectiveBarShimmer
        )

        let scenePose = DashboardScenePoseModifier(
            scale: CGFloat(visualScale),
            rotationX: isExpanded ? 0 : pose.rotationX,
            rotationY: isExpanded ? 0 : pose.rotationY,
            rotationZ: isExpanded ? 0 : pose.rotationZ,
            offset: isExpanded ? .zero : CGSize(width: pose.x, height: pose.y),
            blur: reduceMotion ? 0 : CGFloat(pose.blur)
        )

        return card
            .frame(width: frameWidth, height: isExpanded ? nil : frameHeight)
            .environment(\.dashboardSceneControlsEnabled, controlsArePublished)
            .allowsHitTesting(nativeHitTesting)
            .accessibilityHidden(!isAccessibilityVisible)
            .overlay {
                DashboardCardDim(theme: theme, amount: dimAmount)
            }
            .overlay {
                // 展开态没有邻卡需要区分，标记也不许画在最上层卡片上。
                if showsCurrentMarker {
                    DashboardCurrentCardMarker(theme: theme)
                }
            }
            .animation(reduceMotion ? .linear(duration: 0.12) : nil) { content in
                content.opacity(visualOpacity)
            }
            .modifier(scenePose)
            .zIndex(visualDepth)
            .animation(expansionAnimation, value: model.expandedID)
    }

    /// 展开 / 折叠共用的过渡：卡片尺寸、内容切换与 matchedGeometry 都在这一个事务里动起来。
    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.42)
    }

    private func collapseExpandedCard() {
        guard let expandedID = model.expandedID else { return }
        clearBlankTapCandidate()
        withAnimation(expansionAnimation) {
            model.toggleExpansion(for: expandedID, canExpand: true, reduceMotion: reduceMotion)
        }
    }

    private func updateCollapsedGeometry(cardSize: CGSize, sceneSize: CGSize) {
        guard cardSize.width > 0, cardSize.height > 0,
              sceneSize.width > 0, sceneSize.height > 0
        else { return }
        model.updateGeometry(cardSize: cardSize, sceneSize: sceneSize)
        model.applyDefaultSpacingIfNeeded()
    }


    private func topVisibleRegion(
        at location: CGPoint,
        renderSlots: [DashboardRenderSlot],
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize
    ) -> DashboardMeasuredCardRegion? {
        renderSlots
            .compactMap {
                measuredCardRegion(
                    for: $0,
                    frontVirtualIndex: frontVirtualIndex,
                    cardSize: cardSize,
                    sceneSize: sceneSize
                )
            }
            .filter { $0.frame.insetBy(dx: 1, dy: 1).contains(location) }
            .sorted(by: isDrawnAbove)
            .first
    }

    private func isDrawnAbove(
        _ lhs: DashboardMeasuredCardRegion,
        _ rhs: DashboardMeasuredCardRegion
    ) -> Bool {
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }
        return lhs.renderOrder > rhs.renderOrder
    }

    private func reorderTarget(
        at location: CGPoint,
        renderSlots: [DashboardRenderSlot],
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize,
        activeIDs: [DashboardSceneItemID]
    ) -> DashboardMeasuredCardRegion? {
        guard let region = topVisibleRegion(
            at: location,
            renderSlots: renderSlots,
            frontVirtualIndex: frontVirtualIndex,
            cardSize: cardSize,
            sceneSize: sceneSize
        ), region.isActionable
        else { return nil }
        let domainCount = activeIDs.lazy.filter { $0.domain == region.logicalID.domain }.count
        return domainCount >= 2 ? region : nil
    }

    private func route(
        _ event: DashboardSceneGestureEvent,
        renderSlots: [DashboardRenderSlot],
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize,
        activeIDs: [DashboardSceneItemID]
    ) {
        switch event {
        case let .tap(location, timestamp):
            routeTap(
                location: location,
                timestamp: timestamp,
                renderSlots: renderSlots,
                frontVirtualIndex: frontVirtualIndex,
                cardSize: cardSize,
                sceneSize: sceneSize
            )
        case .dragBegan:
            clearBlankTapCandidate()
            // 同一次拖动收起展开卡并接续场景位移，不再要求先点一次卡片。
            collapseExpandedCard()
            model.handle(event, layout: layout, sceneSize: sceneSize, reduceMotion: reduceMotion)
        case .dragChanged, .dragEnded:
            clearBlankTapCandidate()
            model.handle(event, layout: layout, sceneSize: sceneSize, reduceMotion: reduceMotion)
        case let .reorderBegan(location):
            clearBlankTapCandidate()
            guard let target = reorderTarget(
                at: location,
                renderSlots: renderSlots,
                frontVirtualIndex: frontVirtualIndex,
                cardSize: cardSize,
                sceneSize: sceneSize,
                activeIDs: activeIDs
            ) else {
                cancelSceneInteraction()
                return
            }
            model.beginReorder(id: target.logicalID)
        case let .reorderChanged(secondFingerDeltaY):
            clearBlankTapCandidate()
            model.updateReorder(secondFingerDeltaY: secondFingerDeltaY)
        case .reorderEnded:
            clearBlankTapCandidate()
            finishReorderCommit()
        case .cancelled:
            cancelSceneInteraction()
        }
    }

    private func routeTap(
        location: CGPoint,
        timestamp: TimeInterval,
        renderSlots: [DashboardRenderSlot],
        frontVirtualIndex: Int,
        cardSize: CGSize,
        sceneSize: CGSize
    ) {
        if model.expandedID != nil {
            collapseExpandedCard()
            return
        }
        if let region = topVisibleRegion(
            at: location,
            renderSlots: renderSlots,
            frontVirtualIndex: frontVirtualIndex,
            cardSize: cardSize,
            sceneSize: sceneSize
        ) {
            clearBlankTapCandidate()
            guard region.isActionable,
                  let item = itemDictionary[region.logicalID]
            else { return }

            if region.isFront, model.selectedID == item.id {
                withAnimation(expansionAnimation) {
                    model.toggleExpansion(
                        for: item.id,
                        canExpand: item.canExpand,
                        reduceMotion: reduceMotion
                    )
                }
            } else {
                model.focus(id: item.id, reduceMotion: reduceMotion)
            }
            return
        }

        guard layout == .helix else {
            clearBlankTapCandidate()
            return
        }
        if let previous = blankTapCandidate,
           timestamp >= previous.timestamp,
           timestamp - previous.timestamp <= Self.blankDoubleTapInterval,
           hypot(location.x - previous.location.x, location.y - previous.location.y)
                <= Self.blankDoubleTapDistance {
            clearBlankTapCandidate()
            model.resetHelix(reduceMotion: reduceMotion)
        } else {
            blankTapCandidate = DashboardBlankTapCandidate(location: location, timestamp: timestamp)
        }
    }

    private func finishReorderCommit() {
        let commit = model.finishReorder()
        dispatchReorderCommit(commit)
    }

    private func dispatchReorderCommit(_ pendingCommit: DashboardReorderCommit?) {
        guard let commit = pendingCommit else { return }
        switch commit.domain {
        case .accounts:
            var accountIDs: [UUID] = []
            accountIDs.reserveCapacity(commit.orderedIDs.count)
            for id in commit.orderedIDs {
                guard case let .account(accountID) = id else { return }
                accountIDs.append(accountID)
            }
            guard accountIDs.count == commit.orderedIDs.count else { return }
            onCommitAccountOrder(accountIDs)
        case .demoProviders:
            var providers: [ProviderID] = []
            providers.reserveCapacity(commit.orderedIDs.count)
            for id in commit.orderedIDs {
                guard case let .demo(provider) = id else { return }
                providers.append(provider)
            }
            guard providers.count == commit.orderedIDs.count else { return }
            onCommitDemoOrder(providers)
        }
    }

    private func cancelSceneInteraction() {
        clearBlankTapCandidate()
        model.cancelInteraction()
    }

    private func clearBlankTapCandidate() {
        blankTapCandidate = nil
    }
}
@MainActor
private struct DashboardSceneAccessibilityModifier: ViewModifier {
    let isExpanded: Bool
    let label: String
    let value: String
    let expansionActionName: String?
    let moveEarlierActionName: String?
    let moveLaterActionName: String?
    let refreshAllActionName: String
    let resetHelixActionName: String?
    let onAdjustSelection: (Int) -> Void
    let onToggleExpansion: () -> Void
    let onMove: (Int) -> Void
    let onRefreshAll: () -> Void
    let onResetHelix: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: isExpanded ? .contain : .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjustSelection(1)
                case .decrement: onAdjustSelection(-1)
                @unknown default: break
                }
            }
            // 动作集合随展开态增减（展开时没有上移 / 下移），必须用不改变 content 身份的构造器：
            // 若在 ViewModifier body 里按可选名分支，整个卡片栈会被重建（交叉淡入 + @State 归零）。
            .accessibilityActions {
                if let expansionActionName {
                    Button(expansionActionName, action: onToggleExpansion)
                }
                if let moveEarlierActionName {
                    Button(moveEarlierActionName) { onMove(-1) }
                }
                if let moveLaterActionName {
                    Button(moveLaterActionName) { onMove(1) }
                }
                Button(refreshAllActionName, action: onRefreshAll)
                if let resetHelixActionName {
                    Button(resetHelixActionName, action: onResetHelix)
                }
            }
    }
}

/// 卡片在场景中的姿态（缩放 / 三轴旋转 / 位移 / 景深模糊）。三个 rotation3DEffect 共用参考透视值；
/// 抽成 modifier 是为了让 cardView 的修饰链短到类型检查得动。
private struct DashboardScenePoseModifier: ViewModifier {
    let scale: CGFloat
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double
    let offset: CGSize
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotation3DEffect(
                .degrees(rotationX),
                axis: (x: 1, y: 0, z: 0),
                perspective: DashboardSceneMath.roulettePerspective
            )
            .rotation3DEffect(
                .degrees(rotationY),
                axis: (x: 0, y: 1, z: 0),
                perspective: DashboardSceneMath.roulettePerspective
            )
            .rotation3DEffect(
                .degrees(rotationZ),
                axis: (x: 0, y: 0, z: 1),
                perspective: DashboardSceneMath.roulettePerspective
            )
            .offset(x: offset.width, y: offset.height)
            .blur(radius: blur)
    }
}

private struct DashboardCurrentCardMarker: View {
    let theme: DashboardSceneTheme

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.primaryForeground, lineWidth: 3)

            Image(systemName: "arrowtriangle.down.fill")
                .font(.caption.bold())
                .foregroundStyle(theme.pageBackground)
                .padding(5)
                .background(Circle().fill(theme.primaryForeground))
                .offset(y: -12)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


private enum DashboardSceneHaptic {
    @MainActor private static let generator = UISelectionFeedbackGenerator()

    @MainActor
    static func selectionChanged() {
        generator.selectionChanged()
        generator.prepare()
    }
}

struct DashboardSceneControlRegionPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct DashboardSceneControlsEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dashboardSceneControlsEnabled: Bool {
        get { self[DashboardSceneControlsEnabledKey.self] }
        set { self[DashboardSceneControlsEnabledKey.self] = newValue }
    }
}

private struct DashboardSceneControlRegionModifier: ViewModifier {
    @Environment(\.dashboardSceneControlsEnabled) private var isEnabled
    @State private var regionID = UUID()
    @State private var frame = CGRect.null

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named("dashboardScene")).standardized
            } action: { newFrame in
                let validFrame = dashboardSceneValidFrame(newFrame) ? newFrame : .null
                if frame != validFrame {
                    frame = validFrame
                }
            }
            .preference(
                key: DashboardSceneControlRegionPreferenceKey.self,
                value: isEnabled && dashboardSceneValidFrame(frame) ? [regionID: frame] : [:]
            )
    }
}

struct DashboardSceneDeferredRegionPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// 计量条：不排除场景手势（短触 / 拖动照常滚动），只是不从这里起整卡排序的长按；长按由计量条自己的上下文菜单接管。
private struct DashboardSceneDeferredRegionModifier: ViewModifier {
    @Environment(\.dashboardSceneControlsEnabled) private var isEnabled
    @State private var regionID = UUID()
    @State private var frame = CGRect.null

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named("dashboardScene")).standardized
            } action: { newFrame in
                let validFrame = dashboardSceneValidFrame(newFrame) ? newFrame : .null
                if frame != validFrame {
                    frame = validFrame
                }
            }
            .preference(
                key: DashboardSceneDeferredRegionPreferenceKey.self,
                value: isEnabled && dashboardSceneValidFrame(frame) ? [regionID: frame] : [:]
            )
    }
}

extension View {
    func dashboardSceneControlRegion() -> some View {
        modifier(DashboardSceneControlRegionModifier())
    }

    func dashboardSceneDeferredRegion() -> some View {
        modifier(DashboardSceneDeferredRegionModifier())
    }
}

private func dashboardSceneValidFrame(_ frame: CGRect) -> Bool {
    !frame.isNull
        && !frame.isInfinite
        && !frame.isEmpty
        && frame.minX.isFinite
        && frame.minY.isFinite
        && frame.maxX.isFinite
        && frame.maxY.isFinite
        && frame.width > 0
        && frame.height > 0
}

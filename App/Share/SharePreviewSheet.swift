import SwiftUI
import UIKit
import UsageLimitsCore

/// 分享预览：上方可滑动看完整长图；选项芯片在分享目标之上；全局分享可折叠选项。
struct SharePreviewSheet: View {
    let request: ShareRequest
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var options: ShareComposeOptions
    /// 预览用的结构化内容：切开关只改它，不生成任何位图。
    @State private var model: ShareCardModel
    @State private var assets: ShareCardAssets
    /// 全局分享的选项面板是否展开。
    @State private var optionsExpanded: Bool
    @State private var toast: String?
    @State private var activityItems: [Any]?
    /// 朋友圈指引：图片已存相册，引导去微信从相册选图发布。
    @State private var showMomentsGuide = false
    /// 「编辑」：从首页目录里多选要出图的实例。
    @State private var showInstancePicker = false
    @State private var selectedIDs: Set<String>
    /// 预览可用宽度，画布按它对 390pt 等比缩放。
    @State private var previewWidth: CGFloat = ShareLayout.canvasWidth
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// 引用盒保存滚动几何，避免每帧触发画布重绘。
    @State private var viewport = ViewportBox()
    /// 非动画画布高度：滚动目标不能被旧高度夹住。
    @State private var canvasHeight: CGFloat
    /// 滚动跳距累计值（屏幕 pt），作为 AnchorPin 的唯一动画状态。
    @State private var pinBase: CGFloat = 0
    /// 当前动画完整收尾后接续最新选项，防止重排与补偿中途失步。
    @State private var transition = SharePreviewTransition()

    init(request: ShareRequest) {
        self.request = request
        let stored = SharedStore.shared.shareComposeOptions
        _options = State(initialValue: stored)
        _model = State(initialValue: request.model)
        let picked = ShareCardInput.picked(from: request.catalog, ids: request.selectedIDs)
        let inputs = picked.isEmpty ? request.catalog : picked
        _assets = State(initialValue: ShareCardAssets.make(customLogoData: inputs.map(\.customLogoData)))
        _optionsExpanded = State(initialValue: true)
        _selectedIDs = State(initialValue: request.selectedIDs)
        _canvasHeight = State(initialValue: ShareLayout.canvasHeight(of: request.model))
    }

    var body: some View {
        NavigationStack {
            previewContent
        }
        .presentationSizing(.page)
    }

    /// 保留实时画布和滚动补偿；拆短修饰链以控制 Swift 类型检查成本。
    private var previewScroll: some View {
            ScrollView {
                sharePreviewCanvas
                    .padding(.horizontal, 16)
                    .padding(.vertical, Self.canvasVerticalPadding)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: PreviewViewport.self) {
                // containerSize 已扣除导航栏与底部面板，不再减一次 inset。
                PreviewViewport(
                    top: $0.contentOffset.y + $0.contentInsets.top,
                    height: $0.containerSize.height
                )
            } action: { _, geometry in
                viewport.top = geometry.top
                viewport.height = geometry.height
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 底部操作区悬浮在滚动内容之上：长图从液态玻璃面板下方滚过
            .safeAreaInset(edge: .bottom) {
                shareBottomPanel
            }
            .background(Color(.systemGroupedBackground))
    }

    private var titledPreview: some View {
        previewScroll
            .navigationTitle(L10n.tr("share.preview.title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
            }
            // 系统分享面板不能塞进 SwiftUI 的 .sheet：UIActivityViewController 在 iPad 上是
            // popover 形态，被当成 sheet 内容时拿不到 sourceView，UIKit 直接抛异常。
            // 改成挂在滚动区背后的呈现器，由它自己 present 并给锚点。
            .background {
                ActivityShareSheet(items: activityItems) { activityItems = nil }
            }
    }

    /// 第三段：两个 alert、实例多选 sheet 与生命周期回调。
    private var previewContent: some View {
        titledPreview
            .alert(toast ?? "", isPresented: toastPresented) {
                Button(L10n.tr("common.ok", lang), role: .cancel) { toast = nil }
            }
            .alert(
                L10n.tr("share.moments.title", lang),
                isPresented: $showMomentsGuide
            ) {
                Button(L10n.tr("share.openWeChat", lang)) {
                    ShareFlow.openWeChat()
                }
                Button(L10n.tr("login.close", lang), role: .cancel) {}
            } message: {
                Text(L10n.tr("share.moments.guide", lang))
            }
            .sheet(isPresented: $showInstancePicker) {
                ShareInstancePickerSheet(catalog: request.catalog, selectedIDs: $selectedIDs)
            }
            .onChange(of: selectedIDs) { _, _ in
                remodel()
            }
            .onAppear {
                remodel(animated: false)
                Self.tapHaptic.prepare()
            }
    }

    private var toastPresented: Binding<Bool> {
        Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })
    }

    /// 单服务商始终显示选项；全局分享可折叠。
    private var showsOptionChips: Bool {
        !request.isGlobal || optionsExpanded
    }

    /// 底部操作区：液态玻璃面板（iOS 26 Liquid Glass；老系统回退超薄材质）。
    /// 上缘圆角、下缘直达屏幕底部，不与屏幕断开。
    private var shareBottomPanel: some View {
        VStack(spacing: 12) {
            if showsOptionChips {
                optionChips
            }
            if request.isGlobal {
                manageButton
            }
            shareBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        // regular 宽度下把选项芯片与三个分享目标收进可读栏宽居中，别让三个图标横跨整块 iPad 屏；
        // 玻璃面板本身仍铺满容器，所以这里不要底色（传 nil），否则会盖掉液态玻璃。
        .readableWidth(background: nil)
        .frame(maxWidth: .infinity)
        .modifier(LiquidGlassPanel())
    }

    /// 开关一排等宽胶囊、横向可滑：文案精简，不再两排长短不一。
    private var optionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(L10n.tr("share.opt.details", lang), on: options.showMetricDetails) {
                    options.showMetricDetails.toggle()
                    persistAndRemodel()
                }
                if pickedInputs.contains(where: {
                    !$0.snapshot.isCustom && [.openai, .grok].contains($0.snapshot.provider)
                }) {
                    chip(L10n.tr("share.opt.resets", lang), on: options.showAvailableResets) {
                        options.showAvailableResets.toggle()
                        persistAndRemodel()
                    }
                    .accessibilityIdentifier("share.opt.resets")
                }
                chip(L10n.tr("share.opt.hideTime", lang), on: options.hideUpdateTime) {
                    options.hideUpdateTime.toggle()
                    persistAndRemodel()
                }
                chip(L10n.tr("share.opt.hideUnused", lang), on: options.hideUnusedMetrics) {
                    options.hideUnusedMetrics.toggle()
                    persistAndRemodel()
                }
                chip(L10n.tr("share.opt.sameColor", lang), on: options.sameColorBars) {
                    options.sameColorBars.toggle()
                    persistAndRemodel()
                }
                chip(L10n.tr("share.opt.glow", lang), on: options.rainbowGlow) {
                    options.rainbowGlow.toggle()
                    persistAndRemodel()
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    /// 等宽胶囊（92pt），文案放不下再缩一点。
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 92)
                .padding(.vertical, 8)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill)))
                .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var manageButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { optionsExpanded.toggle() }
        } label: {
            Text(L10n.tr(ShareManageLabel.l10nKey(chipsVisible: optionsExpanded), lang))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("share.manage")
    }

    private var shareBar: some View {
        HStack(spacing: 0) {
            shareButton(.edit)
            // 微信入口暂时注释：打开下一行即恢复底栏图标（处理逻辑与 LogoWeChat 仍保留）
            // shareButton(.wechat)
            // 朋友圈入口暂时注释：无 OpenSDK 无法直达发布页，打开下一行即恢复
            // shareButton(.moments)
            shareButton(.more)
            shareButton(.saveToPhotos)
        }
        .accessibilityElement(children: .contain)
    }

    private func shareButton(_ target: ShareTarget) -> some View {
        Button {
            handle(target)
        } label: {
            VStack(spacing: 6) {
                shareTargetGlyph(target)
                Text(L10n.tr(target.l10nKey, lang))
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shareTargetGlyph(_ target: ShareTarget) -> some View {
        if let name = target.assetName {
            // 微信官方标是绿+白双气泡（约 322×266），必须等比，不能压成方块或铺白底。
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: target == .wechat ? 40 : 32, height: target == .wechat ? 33 : 32)
                .frame(width: 52, height: 52)
        } else {
            // 与微信/朋友圈品牌图一样：只留线条图案，不加白底圆
            Image(systemName: target.systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
        }
    }

    /// 有限时长的重排，完整收尾后即可执行最新选择；不让弹簧尾段延长交接等待。
    private static let morph = Animation.easeInOut(duration: 0.32)

    /// 画布上下留白；换算滚动偏移时要把它减掉。
    private static let canvasVerticalPadding: CGFloat = 12

    /// 预览画布相对 390pt 原尺寸的缩放比。
    private var canvasScale: CGFloat { min(previewWidth / ShareLayout.canvasWidth, 1) }

    /// 390pt 画布等比缩放，高度由 ShareLayout 计算。
    private var sharePreviewCanvas: some View {
        VStack(spacing: 0) {
            // 零高的量宽器：只拿父容器宽度，不参与布局高度。
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        previewWidth = width
                    }
            }
            .frame(height: 0)

            ShareCardView(model: model, assets: assets, lang: lang)
                .scaleEffect(canvasScale, anchor: .top)
                .modifier(AnchorPin(live: pinBase, settled: pinBase))
                // 显式动画避免被同次更新的非动画滚动事务覆盖。
                .animation(Self.morph, value: pinBase)
                // 可滚范围必须立即就位，不能参与补偿动画。
                .frame(width: previewWidth,
                       height: canvasHeight * canvasScale,
                       alignment: .top)
        }
    }

    private func persistAndRemodel() {
        SharedStore.shared.shareComposeOptions = options
        remodel()
    }

    /// 固定视口中间卡片的顶边：滚动立即就位，重排位移由 AnchorPin 同步补偿。
    private func remodel(animated: Bool = true) {
        guard transition.request() else { return }
        let use = pickedInputs
        let anchor = SharePreviewScroll.anchor(
            in: model, offset: canvasOffset, viewportHeight: canvasViewportHeight
        )
        let next = ShareFlow.model(
            snapshots: use.map(\.snapshot),
            titles: use.map(\.title),
            tints: use.map { Optional($0.tint) },
            expanded: request.expanded,
            language: lang,
            options: options
        )
        assets.updateCustomMarks(use.map(\.customLogoData))
        guard next != model else {
            finishRemodel()
            return
        }
        canvasHeight = ShareLayout.canvasHeight(of: next)
        let shift = pinScroll(to: anchor, in: next)
        withAnimation(animated ? Self.morph : nil, completionCriteria: .removed) {
            model = next
            pinBase += shift
        } completion: {
            finishRemodel()
        }
    }

    private func finishRemodel() {
        if transition.complete() { remodel() }
    }

    /// 视口顶边的画布坐标；顶部内边距对应负偏移。
    private var canvasOffset: CGFloat {
        (viewport.top - Self.canvasVerticalPadding) / canvasScale
    }

    /// 可见高度换算到画布坐标。
    private var canvasViewportHeight: CGFloat { viewport.height / canvasScale }

    /// 画布外那圈内边距换算到画布坐标。
    private var canvasSlack: CGFloat { Self.canvasVerticalPadding / canvasScale }

    /// 立即恢复滚动位置，返回需要动画补偿的跳距（屏幕 pt）。
    private func pinScroll(to anchor: SharePreviewAnchor?, in next: ShareCardModel) -> CGFloat {
        guard anchor != nil, viewport.height > 0 else { return 0 }
        let target = SharePreviewScroll.restoredOffset(
            for: anchor, in: next, viewportHeight: canvasViewportHeight, slack: canvasSlack
        )
        let y = target * canvasScale + Self.canvasVerticalPadding
        let shift = y - viewport.top
        guard abs(shift) > 0.5 else { return 0 }
        scrollPosition.scrollTo(y: y)
        return shift
    }

    /// `onScrollGeometryChange` 的观察值：只关心视口顶边与可见高度。
    private struct PreviewViewport: Equatable {
        var top: CGFloat = 0
        var height: CGFloat = 0
    }

    /// settled - live 从滚动跳距退到零，与卡片重排共用同一条曲线。
    private struct AnchorPin: GeometryEffect {
        /// 参与插值：从上一拍的累计值走到这一拍。
        var live: CGFloat
        /// 立刻取新值，不插值。
        var settled: CGFloat

        var animatableData: CGFloat {
            get { live }
            set { live = newValue }
        }

        // GeometryEffect 直接施加变换，避免 offset 被二次插值。
        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: 0, y: settled - live))
        }
    }

    /// 存放上一次滚动几何。故意是引用类型：改它不触发重绘。
    @MainActor
    private final class ViewportBox {
        /// 视口顶边距内容顶边的距离（屏幕 pt）。
        var top: CGFloat = 0
        /// 视口可见高度（屏幕 pt），已扣掉导航栏与底部面板占的边距。
        var height: CGFloat = 0
    }

    private var pickedInputs: [ShareCardInput] {
        let items = ShareCardInput.picked(from: request.catalog, ids: selectedIDs)
        return items.isEmpty ? request.catalog : items
    }

    /// 分享 / 保存要真图：此刻才渲一次预览那棵视图树，全程不缓存、不落盘。
    @MainActor
    private func composedPNG() -> Data? {
        let use = pickedInputs
        return ShareFlow.compose(
            snapshots: use.map(\.snapshot),
            titles: use.map(\.title),
            tints: use.map { Optional($0.tint) },
            expanded: request.expanded,
            language: lang,
            options: options,
            customLogos: use.map(\.customLogoData)
        )
    }

    private static let tapHaptic = UIImpactFeedbackGenerator(style: .light)

    private func handle(_ target: ShareTarget) {
        Self.tapHaptic.impactOccurred(intensity: 0.9)
        Self.tapHaptic.prepare()
        switch target {
        case .edit:
            showInstancePicker = true
        case .saveToPhotos:
            Task {
                do {
                    guard let png = composedPNG() else { throw ShareFlow.ShareError.invalidImage }
                    try await ShareFlow.saveToPhotos(png)
                    toast = L10n.tr("share.saved", lang)
                } catch {
                    toast = L10n.tr("share.failed", lang)
                }
            }
        case .wechat:
            // 微信深链已废弃：系统分享面板的微信扩展是唯一能带图直达
            // 「发送给朋友」选人页的入口。传临时文件 URL 避免扩展内存超限。
            guard ShareFlow.isWeChatInstalled else {
                toast = L10n.tr("share.wechat.missing", lang)
                return
            }
            guard let png = composedPNG() else {
                toast = L10n.tr("share.failed", lang)
                return
            }
            if let fileURL = ShareFlow.temporaryImageFile(png) {
                activityItems = [fileURL]
            } else if let image = UIImage(data: png) {
                activityItems = [image]
            }
        case .moments:
            // 朋友圈无法带图直达（需微信 OpenSDK）：存相册 + 指引发布
            guard ShareFlow.isWeChatInstalled else {
                toast = L10n.tr("share.wechat.missing", lang)
                return
            }
            Task {
                do {
                    guard let png = composedPNG() else { throw ShareFlow.ShareError.invalidImage }
                    try await ShareFlow.prepareForMoments(png)
                    showMomentsGuide = true
                } catch {
                    toast = L10n.tr("share.failed", lang)
                }
            }
        case .more:
            if let png = composedPNG(), let image = UIImage(data: png) {
                activityItems = [image]
            } else {
                toast = L10n.tr("share.failed", lang)
            }
        }
    }
}

/// 从首页可见实例里多选要出图的卡片。至少保留一项。
private struct ShareInstancePickerSheet: View {
    let catalog: [ShareCardInput]
    @Binding var selectedIDs: Set<String>
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(catalog) { item in
                Button {
                    toggle(item.id)
                } label: {
                    HStack(spacing: 10) {
                        if item.snapshot.isCustom {
                            if let data = item.customLogoData, let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            } else {
                                Image(systemName: "link")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProviderLogo(provider: item.snapshot.provider, size: 22)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .foregroundStyle(.primary)
                            if !item.snapshot.isCustom,
                               item.title != item.snapshot.provider.localizedName(lang) {
                                Text(item.snapshot.provider.localizedName(lang))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("share.edit.row.\(item.id)")
            }
            .navigationTitle(L10n.tr("share.edit.title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("share.edit.selectAll", lang)) {
                        selectedIDs = Set(catalog.map(\.id))
                    }
                    .disabled(catalog.isEmpty || selectedIDs.count == catalog.count)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("share.edit.done", lang)) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("share.edit.picker")
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            guard selectedIDs.count > 1 else { return }
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

/// 液态玻璃面板：iOS 26 用系统 Liquid Glass（内容折射、随滚动流动）；
/// 更早系统回退到超薄材质。只圆上缘两角，玻璃向下延伸进底部安全区贴住屏幕。
private struct LiquidGlassPanel: ViewModifier {
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
    }

    func body(content: Content) -> some View {
        content.background {
            if #available(iOS 26.0, *) {
                Color.clear
                    // 透明款液态玻璃 + 较重的底色 tint：保留折射高光的通透感，
                    // 但底色足够实，滚过的内容不会与按钮文字混叠（纯 clear 肉眼看不清）
                    .glassEffect(.clear.tint(Color(.systemBackground).opacity(0.7)), in: shape)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}

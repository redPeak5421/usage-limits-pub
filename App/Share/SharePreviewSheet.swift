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
    /// 全局分享：true = 分享展开（显示三选项），false = 分享折叠（隐藏三选项）。
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
    /// 程序化滚动的把手：切开关后把锚点卡片推回原来的屏幕位置。
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// 滚动几何只在切开关那一刻取用，装在引用盒里：
    /// 若写成 `@State` 数值，滚动每一帧都会让二十几张卡的画布重新求值，滑动直接卡。
    @State private var viewport = ViewportBox()
    /// 画布总高（画布 pt）。故意与 `model` 分开保存、不参与动画：
    /// 新滚动偏移是一瞬间落定的，可滚范围必须同一瞬间就位，否则偏移会被旧高度夹住。
    @State private var canvasHeight: CGFloat
    /// 历次滚动跳变的累计值（屏幕 pt）。`AnchorPin` 只认它一个状态：
    /// 拆成「跳多远 + 第几拍」两个状态时，非动画的那个会把动画事务一起带没，补偿恒为 0。
    @State private var pinBase: CGFloat = 0

    init(request: ShareRequest) {
        self.request = request
        let stored = SharedStore.shared.shareComposeOptions
        _options = State(initialValue: stored)
        _model = State(initialValue: request.model)
        _assets = State(initialValue: ShareCardAssets.make())
        _optionsExpanded = State(initialValue: true)
        _selectedIDs = State(initialValue: request.selectedIDs)
        _canvasHeight = State(initialValue: ShareLayout.canvasHeight(of: request.model))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                sharePreviewCanvas
                    .padding(.horizontal, 16)
                    .padding(.vertical, Self.canvasVerticalPadding)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: PreviewViewport.self) {
                // `containerSize` 已经是扣掉导航栏与底部面板之后的净高，别再减一次边距；
                // `visibleRect` 反过来是连遮挡区一起算的整块。实测（iPhone 17）：
                // container 523.3 / insets 70 + 218.7 / visibleRect 812。
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
            .navigationTitle(L10n.tr("share.preview.title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { activityItems.map { ActivityPayload(items: $0) } },
                set: { activityItems = $0?.items }
            )) { payload in
                ActivityShareSheet(items: payload.items)
            }
            .alert(toast ?? "", isPresented: Binding(
                get: { toast != nil },
                set: { if !$0 { toast = nil } }
            )) {
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
    }

    /// 单服务商始终显示三项；全局分享只在「分享展开」态显示。
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

    /// 与首页卡片展开同款：弹性推进，元素各自滑到新位置而不是整块跳变。
    private static let morph = Animation.snappy(duration: 0.32, extraBounce: 0.06)

    /// 画布上下留白；换算滚动偏移时要把它减掉。
    private static let canvasVerticalPadding: CGFloat = 12

    /// 预览画布相对 390pt 原尺寸的缩放比。
    private var canvasScale: CGFloat { min(previewWidth / ShareLayout.canvasWidth, 1) }

    /// 画布按可用宽度等比缩放；`ShareCardView` 内部恒按 390pt 布局。
    /// 高度得先知道原始高度才能缩放，所以用与渲染器同一套几何算出来，不靠测量回读。
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
                // 显式绑到 pinBase。同一次重排里还有不参与动画的写入（画布高度、
                // 滚动偏移），合并出来的事务会把这枚效果的动画一并抹掉，补偿恒为 0。
                .animation(Self.morph, value: pinBase)
                // 外框留在补偿与动画之外：可滚范围必须一瞬间就位，
                // 跟着动画慢慢长，新的滚动偏移会被旧高度夹住。
                .frame(width: previewWidth,
                       height: canvasHeight * canvasScale,
                       alignment: .top)
        }
    }

    private func persistAndRemodel() {
        SharedStore.shared.shareComposeOptions = options
        remodel()
    }

    /// 只重算结构化内容。位图留到真正要分享 / 保存那一刻再合成。
    ///
    /// 画布高度会随开关整体变化。若始终以画布顶边为原点，实例一多，
    /// 正在看的那张卡就会被上方卡片的伸缩推出屏幕；所以先记下视口中心那张卡，
    /// 重排完再把它推回同一屏幕位置，上下两侧各自伸缩。
    ///
    /// 分两拍写：可滚范围与滚动偏移**立刻**到位（不能等动画，否则被旧高度夹住），
    /// 卡片重排走动画；中间那段位移由 `AnchorPin` 先补上再随动画归零。
    private func remodel(animated: Bool = true) {
        let use = pickedInputs
        let anchor = SharePreviewScroll.anchor(
            in: model, offset: canvasOffset, viewportHeight: canvasViewportHeight
        )
        let next = ShareImageComposer.model(
            snapshots: use.map(\.snapshot),
            expanded: request.expanded,
            language: lang,
            hasIcon: !options.hideBrandRow,
            hasQR: !options.hideBrandRow,
            options: options,
            logoProviders: Set(ProviderID.allCases),
            titles: use.map(\.title),
            tints: use.map { Optional($0.tint) },
            displayMode: SharedStore.shared.usageDisplayMode,
            resetTimeStyle: SharedStore.shared.resetTimeStyle
        )
        let nextAssets = ShareCardAssets.make(customLogoData: use.map(\.customLogoData))
        canvasHeight = ShareLayout.canvasHeight(of: next)
        let shift = pinScroll(to: anchor, in: next)
        withAnimation(animated ? Self.morph : nil) {
            model = next
            assets = nextAssets
            pinBase += shift
        }
    }

    /// 视口顶边在画布坐标里的位置（pt，未经预览缩放）。停在最顶上时为负，
    /// 差的正是画布外那圈内边距，`slack` 会把它算回可滚范围。
    private var canvasOffset: CGFloat {
        (viewport.top - Self.canvasVerticalPadding) / canvasScale
    }

    /// 可见高度换算到画布坐标。
    private var canvasViewportHeight: CGFloat { viewport.height / canvasScale }

    /// 画布外那圈内边距换算到画布坐标。
    private var canvasSlack: CGFloat { Self.canvasVerticalPadding / canvasScale }

    /// 把锚点卡片推回原来的屏幕位置，返回这一跳的距离（屏幕 pt）。
    ///
    /// 偏移不能跟着动画慢慢走：`ScrollPosition` 落定是一瞬间的事，
    /// 让它和 0.32 秒的重排各走各的，画面就是先抽一下再回来。
    /// 所以这里一步到位，视觉上的连续交给 `AnchorPin` 补。
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

    /// 换内容时把画布先按老位置摆着，再随卡片重排一起退回 0。
    ///
    /// 只有 `progress` 参与插值：它从上一拍走到这一拍，`tick - progress` 正好 1 → 0，
    /// 与卡片的位移共用同一条曲线。于是每一帧「卡片新位置 - 滚动新偏移 + 补偿」都等于老位置，
    /// 锚点那张卡全程钉住，上下两侧各自伸缩。
    private struct AnchorPin: GeometryEffect {
        /// 参与插值：从上一拍的累计值走到这一拍。
        var live: CGFloat
        /// 立刻取新值，不插值。
        var settled: CGFloat

        var animatableData: CGFloat {
            get { live }
            set { live = newValue }
        }

        // 必须是 `GeometryEffect` 而不是 `ViewModifier` + `.offset`：
        // `.offset` 自己也是可动画的，套在动画子树里会被外层再插值一次，
        // 两次插值互相抵消，body 算出来的位移一点也落不到屏幕上。
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
        )?.pngData
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

private struct ActivityPayload: Identifiable {
    let id = UUID()
    let items: [Any]
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

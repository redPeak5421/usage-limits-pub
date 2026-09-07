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

    init(request: ShareRequest) {
        self.request = request
        let stored = SharedStore.shared.shareComposeOptions
        _options = State(initialValue: stored)
        _model = State(initialValue: request.model)
        _assets = State(initialValue: ShareCardAssets.make())
        _optionsExpanded = State(initialValue: true)
        _selectedIDs = State(initialValue: request.selectedIDs)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                sharePreviewCanvas
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
                withAnimation(Self.morph) { remodel() }
            }
            .onAppear {
                remodel()
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

            let scale = min(previewWidth / ShareLayout.canvasWidth, 1)
            ShareCardView(model: model, assets: assets, lang: lang)
                .scaleEffect(scale, anchor: .top)
                .frame(width: previewWidth,
                       height: ShareLayout.canvasHeight(of: model) * scale,
                       alignment: .top)
        }
    }

    private func persistAndRemodel() {
        SharedStore.shared.shareComposeOptions = options
        withAnimation(Self.morph) { remodel() }
    }

    /// 只重算结构化内容。位图留到真正要分享 / 保存那一刻再合成。
    private func remodel() {
        let use = pickedInputs
        model = ShareImageComposer.model(
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
        assets = ShareCardAssets.make(customLogoData: use.map(\.customLogoData))
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

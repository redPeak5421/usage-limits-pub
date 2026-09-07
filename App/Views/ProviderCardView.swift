import SwiftUI
import UsageLimitsCore

/// 单个服务商的用量卡片。折叠态展示摘要，展开态的切换由外层控制；
/// 场景主题下卡片只负责固定抬头和可滚动的展开内容，平铺（`sceneTheme == nil`）下展开内容直接铺开。
struct ProviderCardView: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let isRefreshing: Bool
    let isExpanded: Bool
    /// nil = 平铺列表（系统卡面、圆角 20、内容直接铺开）；非 nil = 轮盘场景（主题投影、圆角 16、展开内容可滚动）。
    let sceneTheme: DashboardSceneTheme?
    let expandedViewportHeight: CGFloat?
    /// 展开态最小高度（场景传折叠卡高）：只有一条计量条的卡点开看文字信息时不能比折叠态矮。nil = 不限。
    let expandedMinimumHeight: CGFloat?
    /// 折叠态露出的计量条数（平铺 1、轮盘 / 螺旋 2）。
    let collapsedMetricLimit: Int
    let onToggleExpanded: () -> Void
    var onLogin: () -> Void
    var onRefresh: () -> Void
    var onLogout: () -> Void
    var onShare: () -> Void = {}
    /// 附加账号卡片的自定义标题（nil = 用服务商产品名）。
    var titleOverride: String?
    /// 解析后的自定义主题色（nil = 内置品牌色）。影响三种标签、登录按钮与图表线。
    var tint: BrandTint?
    /// 自定义账号：有模板图用落盘图，否则链环；禁止走 LoginSheetView / 占位商标。
    var isCustom: Bool = false
    var customLogoData: Data? = nil
    /// 抬头下元信息：模板名或 host。仅自定义卡使用。
    var customSubtitle: String? = nil
    /// 自定义卡：「…」菜单打开编辑向导。内置卡保持 nil。
    var onEdit: (() -> Void)? = nil
    /// 「…」→ 编辑计量顺序（只有 ≥2 条计量时首页才传入）。
    var onReorderMetrics: (() -> Void)? = nil
    var refreshGlow: Bool = false
    var tintedBars: Bool = false
    var barShimmer: Bool = false
    @EnvironmentObject private var edition: Edition
    @Environment(\.appLanguage) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 折叠 / 展开内容切换用 `.transition(.identity)`（同一张卡从中心缩放，不交叉淡入）；
    /// 这个命名空间只在各自形态内部保留 matchedGeometry 的对应关系。
    @Namespace private var geometry
    @State private var showUnusedMetrics = false
    /// 展开态：量出固定抬头与滚动内容的高度，卡片只长到内容需要的高度，超出视口才滚动。
    @State private var expandedContentHeight: CGFloat = 0
    /// 折叠态抬头高度（只在折叠态记录）与隐藏量出的套餐行高：两者相加就是展开态抬头高度，
    /// 展开前就已知，起步 / 下限不依赖任何「展开后才量得到」的值（否则第一次打开会先缩后长）。
    @State private var collapsedHeaderHeight: CGFloat = 0
    @State private var planPriceRowHeight: CGFloat = 0
    /// 套餐徽章折叠/展开两个位置间的位移动画配对。
    @Namespace private var badgeNS

    init(
        provider: ProviderID,
        snapshot: ProviderSnapshot?,
        isRefreshing: Bool,
        isExpanded: Bool,
        sceneTheme: DashboardSceneTheme?,
        expandedViewportHeight: CGFloat?,
        expandedMinimumHeight: CGFloat? = nil,
        collapsedMetricLimit: Int = 1,
        onToggleExpanded: @escaping () -> Void,
        onLogin: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onLogout: @escaping () -> Void,
        onShare: @escaping () -> Void = {},
        titleOverride: String? = nil,
        tint: BrandTint? = nil,
        isCustom: Bool = false,
        customLogoData: Data? = nil,
        customSubtitle: String? = nil,
        onEdit: (() -> Void)? = nil,
        onReorderMetrics: (() -> Void)? = nil,
        refreshGlow: Bool = false,
        tintedBars: Bool = false,
        barShimmer: Bool = false
    ) {
        self.provider = provider
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.isExpanded = isExpanded
        self.sceneTheme = sceneTheme
        self.expandedViewportHeight = expandedViewportHeight
        self.expandedMinimumHeight = expandedMinimumHeight
        self.collapsedMetricLimit = max(1, collapsedMetricLimit)
        self.onToggleExpanded = onToggleExpanded
        self.onLogin = onLogin
        self.onRefresh = onRefresh
        self.onLogout = onLogout
        self.onShare = onShare
        self.titleOverride = titleOverride
        self.tint = tint
        self.isCustom = isCustom
        self.customLogoData = customLogoData
        self.customSubtitle = customSubtitle
        self.onEdit = onEdit
        self.onReorderMetrics = onReorderMetrics
        self.refreshGlow = refreshGlow
        self.tintedBars = tintedBars
        self.barShimmer = barShimmer
    }

    private var resolvedTint: BrandTint {
        tint ?? (isCustom ? TintResolver.customDefault : provider.builtinTint)
    }

    private static let cardPadding: CGFloat = 16
    private static let headerSpacing: CGFloat = 12

    private var isFlatLayout: Bool { sceneTheme == nil }
    private var cornerRadius: CGFloat { isFlatLayout ? 20 : 16 }

    /// 展开 / 折叠共用的过渡，与场景侧 `expansionAnimation` 一致（Reduce Motion 下不做动画）。
    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.42)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            headerBlock
            // 折叠 / 展开共用同一棵内容子树（只改参数、不换分支）：指标行才能保住身份，
            // 已显示的行平移到新位置、新出现的行淡入并向下归位，而不是整块内容换掉。
            // 平铺：顶边随列表固定，内容直接铺开，卡片只向下长。
            // 场景：折叠态滚动区按内容定高（禁止滚动）、整块内容在固定卡高里垂直居中；展开态定高到内容（超出视口才滚动）。
            Group {
                if isFlatLayout {
                    content
                        .frame(maxWidth: .infinity, minHeight: isExpanded ? 0 : 72, alignment: .topLeading)
                } else {
                    ScrollView(.vertical) {
                        content
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                // 量到新内容高度时卡片正在变尺寸，改目标要接着动，不能跳
                                withAnimation(expansionAnimation) {
                                    expandedContentHeight = height
                                }
                            }
                    }
                    .scrollDisabled(!expandedContentCanScroll)
                    .fixedSize(horizontal: false, vertical: !isExpanded)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: isExpanded ? expandedScrollHeight : nil)
                    .background {
                        // 只有内容确实溢出的长卡才接管内部滚动；短卡的拖动交给场景继续浏览。
                        if expandedContentCanScroll {
                            Color.clear.dashboardSceneControlRegion()
                        }
                    }
                    .layoutPriority(1)
                }
            }
            .environment(\.usageBarDecorator, edition.usageBarDecorator(tint: resolvedTint, tinted: tintedBars, shimmer: barShimmer))
        }
        .padding(Self.cardPadding)
        // 折叠态场景卡：内容整块垂直居中；展开态与平铺按内容定高，顶对齐
        .frame(
            maxWidth: .infinity,
            maxHeight: (isExpanded || isFlatLayout) ? nil : .infinity,
            alignment: (isExpanded || isFlatLayout) ? .topLeading : .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background {
            if let sceneTheme {
                DashboardCardSurface(theme: sceneTheme)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .overlay {
            ZStack {
                if refreshGlow && isRefreshing, let glow = edition.refreshGlowOverlay(cornerRadius: cornerRadius) {
                    glow.transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: refreshGlow && isRefreshing)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var expandedContentCanScroll: Bool {
        isExpanded && expandedContentHeight > expandedScrollHeight + 1
    }

    /// 展开态滚动区上限：视口减去展开态抬头、卡片上下内边距与抬头下间距；无视口则不限。
    private var expandedScrollLimit: CGFloat? {
        guard let viewport = expandedViewportHeight else { return nil }
        return max(0, viewport - expandedHeaderHeight - Self.cardPadding * 2 - Self.headerSpacing)
    }

    /// 展开态滚动区的最小高度：折叠卡高扣掉展开态抬头、内边距与间距；场景没传下限则为 nil。
    private var expandedScrollFloor: CGFloat? {
        guard let minimum = expandedMinimumHeight else { return nil }
        return max(0, minimum - expandedHeaderHeight - Self.cardPadding * 2 - Self.headerSpacing)
    }

    /// 展开态是否多出套餐 / 价格行。
    private var showsPlanPriceRowWhenExpanded: Bool {
        !isCustom && snapshot?.planName != nil && snapshot?.status.isOK == true && snapshot?.isPrepaidCard != true
    }

    /// 展开态抬头高度 = 折叠态抬头高度 + 套餐行高（含行距）；折叠态就已知，展开第一帧不用等测量。
    private var expandedHeaderHeight: CGFloat {
        collapsedHeaderHeight + (showsPlanPriceRowWhenExpanded ? planPriceRowHeight + 6 : 0)
    }

    /// 只用定高，不用 maxHeight（maxHeight 帧会撑到父级提议高度再居中子视图）。
    /// 内容量出来之前先按折叠卡高起步（没有折叠卡高的平铺按 0），卡片在第一帧保持原尺寸，
    /// 量到后再从这个尺寸平滑长到内容高度；不能从 0 起步，否则会先朝「只剩抬头」缩一下再反向长，肉眼就是一抽。
    /// 展开也不比折叠卡矮（只有一条计量条的卡点开看更新时间不能缩）；超过视口才滚动。
    private var expandedScrollHeight: CGFloat {
        let floor = expandedScrollFloor ?? 0
        guard expandedContentHeight > 0 else { return floor }
        let height = max(expandedContentHeight, floor)
        guard let limit = expandedScrollLimit else { return height }
        return min(height, limit)
    }

    /// Scene-item construction and card rendering share this App-owned expansion rule.
    static func canExpand(snapshot: ProviderSnapshot?) -> Bool {
        guard snapshot?.status.isOK == true else { return false }
        if snapshot?.isPrepaidCard == true {
            return !(snapshot?.metrics.isEmpty ?? true)
                || !(snapshot?.timeBreakdowns?.isEmpty ?? true)
                || !(snapshot?.keyBreakdowns?.isEmpty ?? true)
        }
        if snapshot?.provider == .jimeng {
            return !(snapshot?.metrics.isEmpty ?? true)
                || !(snapshot?.creditHistory?.isEmpty ?? true)
        }
        return !(snapshot?.metrics.isEmpty ?? true)
    }

    private var isCollapsible: Bool {
        Self.canExpand(snapshot: snapshot)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded, showsPlanPriceRowWhenExpanded, let plan = snapshot?.planName {
                planPriceRow(plan)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            // 只记折叠态的抬头高度；展开态抬头 = 它 + 套餐行（下面隐藏量出），展开前就能算
            guard !isExpanded else { return }
            collapsedHeaderHeight = height
        }
        .background {
            // 隐藏量一份套餐行的高度（不参与布局、不共享徽章的 matchedGeometry）
            if showsPlanPriceRowWhenExpanded, let plan = snapshot?.planName {
                planPriceRow(plan, measuringOnly: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        planPriceRowHeight = height
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isCustom {
                CustomTemplateLogo(
                    data: customLogoData,
                    size: 18,
                    fallbackTint: resolvedTint.representativeColor
                )
            } else {
                ProviderLogo(provider: provider, size: 18)
            }
            // 头部所有文字严禁换行：名称优先保完整，徽章空间不足时缩字号
            Text(titleOverride ?? (isCustom ? "" : provider.localizedName(lang)))
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(2)
            if isCustom, let subtitle = customSubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 折叠时头部只显示套餐级别徽章（价格在展开后的紧凑行里）；
            // 与展开态的徽章共享 matchedGeometryEffect，切换时滑动过去而非突然出现
            if !isCustom, !isExpanded, let plan = snapshot?.planName, snapshot?.status.isOK == true {
                Text(L10n.tr(plan, lang))
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(resolvedTint.badgeFill))
                    .foregroundStyle(resolvedTint.badgeForeground)
                    .matchedGeometryEffect(id: "planBadge", in: badgeNS)
            }
            Spacer(minLength: 0)
            if isCollapsible {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr(isExpanded ? "dashboard.action.collapse" : "dashboard.action.expand", lang))
                .dashboardSceneControlRegion()
            }
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    cardMenuButtons
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .dashboardSceneControlRegion()
            }
        }
    }

    @ViewBuilder
    private var cardMenuButtons: some View {
        if let onEdit {
            Button(L10n.tr("custom.wizard.editTemplate", lang), systemImage: "pencil", action: onEdit)
                .dashboardSceneControlRegion()
        }
        if let onReorderMetrics {
            Button(L10n.tr("card.reorderMetrics", lang), systemImage: "arrow.up.arrow.down", action: onReorderMetrics)
                .dashboardSceneControlRegion()
        }
        Button(L10n.tr("card.share", lang), systemImage: "square.and.arrow.up", action: onShare)
            .dashboardSceneControlRegion()
        Button(L10n.tr("card.refresh", lang), systemImage: "arrow.clockwise", action: onRefresh)
            .dashboardSceneControlRegion()
        if isCustom {
            Button(L10n.tr("card.updateToken", lang), systemImage: "key", action: onLogin)
                .dashboardSceneControlRegion()
            Button(L10n.tr("custom.logout", lang), systemImage: "trash", role: .destructive, action: onLogout)
                .dashboardSceneControlRegion()
        } else {
            Button(L10n.tr("card.relogin", lang), systemImage: "person.crop.circle.badge.plus", action: onLogin)
                .dashboardSceneControlRegion()
            Button(L10n.tr("card.logout", lang), systemImage: "trash", role: .destructive, action: onLogout)
                .dashboardSceneControlRegion()
        }
    }

    /// 展开态的紧凑信息行：套餐级别 + 周期（月/年）+ 对应金额。
    /// 周期标签仅在展开时出现，紧贴金额前方；三枚徽章同字号（caption2）。
    /// `measuringOnly`：隐藏的量高副本，不参与徽章的 matchedGeometry 配对。
    private func planPriceRow(_ plan: String, measuringOnly: Bool = false) -> some View {
        let cycle = snapshot?.billingCycle
        let price = PlanCatalog.listPrice(
            planName: plan,
            billingCycle: cycle,
            appStoreBilling: snapshot?.billingSource == "app_store",
            productID: snapshot?.planProductID,
            provider: provider
        )
        return HStack(spacing: 6) {
            capsule(plan)
                .matchedGeometryEffect(id: measuringOnly ? "planBadgeMeasure" : "planBadge", in: badgeNS)
            if let price {
                capsule(cycle?.tag ?? BillingCycle.monthly.tag)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                Text(price)
                    .font(.caption2.monospacedDigit().bold())
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(resolvedTint.badgeFill))
                    .foregroundStyle(resolvedTint.badgeForeground)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Spacer(minLength: 0)
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(L10n.tr(text, lang))
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(resolvedTint.badgeFill))
            .foregroundStyle(resolvedTint.badgeForeground)
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot?.status {
        case .ok:
            if let snap = snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    if isCustom {
                        CustomUsageCardBody(
                            snap: snap,
                            isExpanded: isExpanded,
                            accent: resolvedTint.representativeColor,
                            namespace: geometry,
                            onReorderMetrics: onReorderMetrics
                        )
                    } else if snap.isPrepaidCard {
                        DeepSeekCardBody(
                            snap: snap,
                            isExpanded: isExpanded,
                            usesExternalVerticalScroll: isExpanded,
                            accent: resolvedTint.representativeColor,
                            namespace: geometry
                        )
                    } else if snap.provider == .jimeng {
                        JimengCardBody(
                            snap: snap,
                            isExpanded: isExpanded,
                            namespace: geometry
                        )
                    } else if snap.metrics.isEmpty {
                        Text(L10n.tr("card.noNumeric", lang))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        metricsList(snap)
                        if isExpanded {
                            unusedMetricsFooter(snap)
                        } else {
                            expandHint(snap)
                        }
                    }
                    if !isCustom, snap.isAnonymous == true {
                        Button {
                            onLogin()
                        } label: {
                            Label(L10n.tr("card.loginToSee", lang, provider.origin.host ?? ""),
                                  systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(resolvedTint.representativeColor)
                        .dashboardSceneControlRegion()
                    }
                    if isExpanded || snap.metrics.isEmpty {
                        Text(L10n.tr("card.updatedAt", lang, TimeFormat.hourMinute(snap.fetchedAt)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .transition(.opacity.combined(with: .offset(y: -8)))
                    }

                }
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.trError(message, lang), systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button(L10n.tr("card.retry", lang), action: onRefresh)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .dashboardSceneControlRegion()
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr(isCustom ? "custom.noNumeric" : "card.notLoggedIn", lang))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    onLogin()
                } label: {
                    if isCustom {
                        Label(L10n.tr("card.updateToken", lang), systemImage: "key")
                    } else {
                        Label(L10n.tr("card.login", lang, provider.origin.host ?? provider.localizedName(lang)),
                              systemImage: "person.crop.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(resolvedTint.representativeColor)
                .dashboardSceneControlRegion()
            }
        }
    }

    /// 折叠/展开两态共用的指标行数据：折叠画展开顺序前 `collapsedMetricLimit` 条，
    /// 展开画全部有用量的指标（可按需带上未使用的）。行 id 稳定，
    /// 切换时折叠态那几条原地滑到展开后的新位置，其余行淡入淡出。
    private func displayedMetrics(_ snap: ProviderSnapshot) -> [UsageMetric] {
        if isExpanded {
            return showUnusedMetrics ? snap.metrics : snap.activeMetrics
        }
        return snap.collapsedMetrics(limit: collapsedMetricLimit)
    }

    @ViewBuilder
    private func metricsList(_ snap: ProviderSnapshot) -> some View {
        let metrics = displayedMetrics(snap)
        if metrics.isEmpty {
            Text(L10n.tr("card.allUnused", lang))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 10) {
                ForEach(metrics) { metric in
                    MetricRowView(
                        metric: metric,
                        provider: provider,
                        onReorderMetrics: onReorderMetrics
                    )
                        // 新出现的行从上方一点淡入并向下归位；收起时反向
                        .transition(.opacity.combined(with: .offset(y: -12)))
                }
            }
        }
    }

    /// 折叠态底部提示：展开还能看到多少条有用量的指标。
    @ViewBuilder
    private func expandHint(_ snap: ProviderSnapshot) -> some View {
        let shownWithUsage = displayedMetrics(snap).filter(\.hasUsage).count
        let more = snap.activeMetrics.count - shownWithUsage
        if more > 0 {
            Text(L10n.tr("card.expandMore", lang, more))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }

    /// 展开态底部：未使用指标的显示/隐藏开关。
    @ViewBuilder
    private func unusedMetricsFooter(_ snap: ProviderSnapshot) -> some View {
        let unusedCount = snap.metrics.count - snap.activeMetrics.count
        if unusedCount > 0 {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showUnusedMetrics.toggle() }
            } label: {
                Text(showUnusedMetrics
                     ? L10n.tr("card.hideUnused", lang)
                     : L10n.tr("card.showUnused", lang, unusedCount))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .dashboardSceneControlRegion()
            .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }
}

/// 一条指标行：标签 + 进度条 + 数值 + 重置时间。
struct MetricRowView: View {
    let metric: UsageMetric
    var provider: ProviderID
    var now: Date = Date()
    var onReorderMetrics: (() -> Void)? = nil
    @Environment(\.appLanguage) private var lang
    @Environment(\.usageDisplayMode) private var displayMode
    @Environment(\.resetTimeStyle) private var resetStyle
    @Environment(\.usageBarDecorator) private var barDecorator

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(L10n.metricLabel(provider: provider, id: metric.id, fallback: metric.label, language: lang))
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(levelColor)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let percent = metric.usedPercent {
                let barPercent = UsagePresentation.barPercent(used: percent, mode: displayMode)
                if let barDecorator {
                    // Edition 给了装饰（主题色 / 高光）：自绘胶囊条，已用段由装饰绘制；没有则保持系统 ProgressView
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            barDecorator.fill(levelColor)
                                .frame(width: max(proxy.size.width * barPercent / 100, barPercent > 0 ? 4 : 0))
                        }
                    }
                    .frame(height: 4)
                } else {
                    ProgressView(value: barPercent, total: 100)
                        .tint(levelColor)
                }
            }
            HStack {
                if let detail = metric.detail {
                    Text(L10n.trDetail(detail, lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if let resets = metric.resetsAt {
                    TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                        Text("\(L10n.tr("metric.resetPrefix", lang))\(TimeFormat.reset(resets, now: context.date, language: lang, style: resetStyle))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 14)
        }
        .modifier(MetricReorderMenu(action: onReorderMetrics, language: lang))
    }

    private var valueText: String {
        UsagePresentation.valueText(for: metric, language: lang, mode: displayMode)
    }

    private var levelColor: Color {
        usageLevelColor(metric.usedPercent)
    }
}


/// 计量条长按打开顺序编辑；无入口时不挂空菜单，避免拦首页整卡拖动。
/// 场景主题里计量条只登记为「延后判定」区域：手指放上去照样能滑动转盘，只有明确长按才弹顺序菜单（真机反馈）。
struct MetricReorderMenu: ViewModifier {
    var action: (() -> Void)?
    var language: AppLanguage

    func body(content: Content) -> some View {
        if let action {
            content.contextMenu {
                Button(L10n.tr("card.reorderMetrics", language), systemImage: "arrow.up.arrow.down", action: action)
            }
            .dashboardSceneDeferredRegion()
        } else {
            content
        }
    }
}

/// DeepSeek 预充值卡：折叠只画重置余额 + 累计消费，与其他卡内容区登高；
/// 展开后切换时间维度，并展示金额 / 请求次数 / tokens 数值与折线。
struct DeepSeekCardBody: View {
    let snap: ProviderSnapshot
    let isExpanded: Bool
    let usesExternalVerticalScroll: Bool
    let accent: Color
    let namespace: Namespace.ID
    @Environment(\.appLanguage) private var lang
    @State private var periodID: String = "this_month"

    private var currency: String { snap.currency ?? "CNY" }
    private var balance: UsageMetric? { snap.metrics.first { $0.id == "balance" } }
    private var spent: UsageMetric? { snap.metrics.first { $0.id == "total_spent" } }
    private var periods: [UsageBreakdown] { snap.timeBreakdowns ?? [] }
    private var selectedPeriod: UsageBreakdown? {
        periods.first { $0.id == periodID } ?? periods.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            prepaidPair
            if isExpanded {
                if !periods.isEmpty {
                    periodPicker
                        .transition(.opacity)
                    if let period = selectedPeriod {
                        periodNumbers(period)
                            .transition(.opacity)
                        UsageSparkline(points: period.series, color: accent)
                            .frame(height: 56)
                            .transition(.opacity)
                    }
                }
                if let keys = snap.keyBreakdowns, !keys.isEmpty {
                    Text(L10n.tr("deepseek.byKey", lang))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    keyList(keys)
                        .transition(.opacity)
                }
            } else if !(snap.timeBreakdowns?.isEmpty ?? true) || !(snap.keyBreakdowns?.isEmpty ?? true) {
                Text(L10n.tr("deepseek.expandHint", lang))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if periods.contains(where: { $0.id == "this_month" }) {
                periodID = "this_month"
            } else {
                periodID = periods.first?.id ?? periodID
            }
        }
    }

    private var prepaidPair: some View {
        VStack(spacing: 8) {
            amountLine(label: L10n.tr("deepseek.balance", lang), value: balance?.amount ?? 0)
            amountLine(label: L10n.tr("deepseek.spent", lang), value: spent?.amount ?? 0)
        }
    }

    private func amountLine(label: String, value: Double) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(MoneyFormat.string(value, currency: currency))
                .font(.subheadline.monospacedDigit().bold())
                .lineLimit(1)
        }
    }

    private var periodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(periods) { period in
                    let on = period.id == (selectedPeriod?.id ?? "")
                    Button {
                        periodID = period.id
                    } label: {
                        Text(L10n.tr(period.label, lang))
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(accent.opacity(on ? 0.2 : 0.08)))
                            .foregroundStyle(on ? accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .dashboardSceneControlRegion()
                }
            }
        }
        .dashboardSceneControlRegion()
    }

    private func periodNumbers(_ period: UsageBreakdown) -> some View {
        HStack(spacing: 12) {
            stat(L10n.tr("deepseek.cost", lang), MoneyFormat.string(period.cost ?? 0, currency: currency))
            stat(L10n.tr("deepseek.requests", lang), IntegerFormat.string(period.requests))
            stat(L10n.tr("deepseek.tokens", lang), IntegerFormat.string(period.tokens))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.caption.monospacedDigit().bold())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let keyVisibleSlots = 5
    private static let keyRowHeight: CGFloat = 40
    private static let keyRowSpacing: CGFloat = 8

    @ViewBuilder
    private func keyList(_ keys: [UsageBreakdown]) -> some View {
        if usesExternalVerticalScroll {
            LazyVStack(alignment: .leading, spacing: Self.keyRowSpacing) {
                ForEach(keys) { key in
                    keyRow(key)
                }
            }
        } else {
            let visible = min(keys.count, Self.keyVisibleSlots)
            let height = CGFloat(visible) * Self.keyRowHeight
                + CGFloat(max(visible - 1, 0)) * Self.keyRowSpacing
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.keyRowSpacing) {
                    ForEach(keys) { key in
                        keyRow(key)
                    }
                }
            }
            .scrollDisabled(keys.count <= Self.keyVisibleSlots)
            .scrollIndicators(keys.count > Self.keyVisibleSlots ? .visible : .hidden)
            .frame(height: height)
        }
    }

    private func keyRow(_ key: UsageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.label)
                .font(.subheadline)
                .lineLimit(1)
            HStack {
                Text(MoneyFormat.string(key.cost ?? 0, currency: currency))
                Text("·")
                if let requests = IntegerFormat.rounded(key.requests) {
                    Text(L10n.tr("deepseek.reqCount", lang, requests))
                } else {
                    Text("—")
                }
                Text("·")
                Text(MoneyFormat.string(key.tokens ?? 0, currency: nil) + " " + L10n.tr("deepseek.tokens", lang))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(height: Self.keyRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 即梦积分卡：折叠四档积分一行均分；展开后积分明细恒为最多 5 条的内部滚动区。
struct JimengCardBody: View {
    let snap: ProviderSnapshot
    let isExpanded: Bool
    let namespace: Namespace.ID
    @Environment(\.appLanguage) private var lang

    private var remaining: UsageMetric? { snap.metrics.first { $0.id == "remaining" } }
    private var subscription: UsageMetric? { snap.metrics.first { $0.id == "subscription" } }
    private var recharge: UsageMetric? { snap.metrics.first { $0.id == "recharge" } }
    private var gift: UsageMetric? { snap.metrics.first { $0.id == "gift" } }
    private var history: [CreditLedgerEntry] { snap.creditHistory ?? [] }

    private static let historyVisibleSlots = 5
    @ScaledMetric(relativeTo: .subheadline) private var historyRowHeight: CGFloat = 40
    private static let historyRowSpacing: CGFloat = 8

    private var remainingUnavailable: Bool {
        remaining?.amount == nil && (remaining != nil || snap.metrics.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExpanded {
                creditPair
                if remainingUnavailable {
                    unavailableCaption
                        .transition(.opacity)
                }
                if !history.isEmpty {
                    historyPanel
                        .transition(.opacity)
                }
            } else {
                if remainingUnavailable {
                    if let remaining {
                        amountLine(remaining)
                    }
                    unavailableCaption
                        .transition(.opacity)
                } else {
                    collapsedCreditRow
                    if !(snap.creditHistory?.isEmpty ?? true) {
                        Text(L10n.tr("jimeng.expandHint", lang))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private var collapsedCreditRow: some View {
        let tiles = [remaining, subscription, recharge, gift].compactMap { $0 }.filter { $0.amount != nil }
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, metric in
                VStack(spacing: 3) {
                    Text(creditValueText(metric))
                        .font(index == 0 ? .title3.monospacedDigit().bold() : .subheadline.monospacedDigit().bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .matchedGeometryEffect(id: "value.\(metric.id)", in: namespace)
                    Text(L10n.metricLabel(provider: .jimeng, id: metric.id, fallback: metric.label, language: lang))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .matchedGeometryEffect(id: "label.\(metric.id)", in: namespace)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var creditPair: some View {
        VStack(spacing: 8) {
            if let remaining { amountLine(remaining) }
            if let subscription, subscription.amount != nil { amountLine(subscription) }
            if let recharge, recharge.amount != nil { amountLine(recharge) }
            if let gift, gift.amount != nil { amountLine(gift) }
        }
    }

    private var unavailableCaption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("jimeng.creditsUnavailable", lang))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(L10n.tr("jimeng.creditsUnavailableHint", lang))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func amountLine(_ metric: UsageMetric) -> some View {
        HStack {
            Text(L10n.metricLabel(provider: .jimeng, id: metric.id, fallback: metric.label, language: lang))
                .font(.subheadline)
                .lineLimit(1)
                .matchedGeometryEffect(id: "label.\(metric.id)", in: namespace)
            Spacer(minLength: 8)
            Text(creditValueText(metric))
                .font(.subheadline.monospacedDigit().bold())
                .lineLimit(1)
                .matchedGeometryEffect(id: "value.\(metric.id)", in: namespace)
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("jimeng.historyTitle", lang))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            historyList
            Text(L10n.tr("jimeng.historyCaption", lang))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let visible = min(history.count, Self.historyVisibleSlots)
        let height = CGFloat(visible) * historyRowHeight
            + CGFloat(max(visible - 1, 0)) * Self.historyRowSpacing + 16
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Self.historyRowSpacing) {
                ForEach(history) { entry in
                    historyRow(entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // 父卡片较短时会禁用自身滚动；明细仍须独立接收滚动手势。
        .environment(\.isScrollEnabled, history.count > Self.historyVisibleSlots)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollIndicators(history.count > Self.historyVisibleSlots ? .visible : .hidden)
        .frame(height: height)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .background {
            if history.count > Self.historyVisibleSlots {
                Color.clear.dashboardSceneControlRegion()
            }
        }
    }

    private func historyRow(_ entry: CreditLedgerEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(TimeFormat.monthDayHourMinute(entry.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(signedCreditText(entry))
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(entry.isGain ? gainColor : spendColor)
                .lineLimit(1)
        }
        .frame(height: historyRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gainColor: Color { Color(red: 0.16, green: 0.56, blue: 0.50) }
    private var spendColor: Color { Color(red: 0.46, green: 0.36, blue: 0.36) }

    private func creditValueText(_ metric: UsageMetric) -> String {
        if let display = metric.displayValue, !display.isEmpty { return display }
        return IntegerFormat.string(metric.amount)
    }

    private func signedCreditText(_ entry: CreditLedgerEntry) -> String {
        IntegerFormat.signedString(entry.signedAmount)
    }
}

struct UsageSparkline: View {
    let points: [UsagePoint]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let vals = points.map(\.value)
            let maxV = max(vals.max() ?? 0, 0.0001)
            let minV = min(vals.min() ?? 0, 0)
            let span = max(maxV - minV, 0.0001)
            var path = Path()
            if points.count >= 2 {
                for (i, p) in points.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(points.count - 1)
                    let y = size.height - CGFloat((p.value - minV) / span) * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            } else {
                path.move(to: CGPoint(x: 0, y: size.height * 0.7))
                path.addLine(to: CGPoint(x: size.width, y: size.height * 0.7))
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(maxWidth: .infinity)
    }
}

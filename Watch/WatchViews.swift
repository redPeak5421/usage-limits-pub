import SwiftUI
import UsageLimitsCore

/// 根视图：上下翻页——第一页是服务商圆环仪表（页内横滑切换服务商），第二页是设置。
struct WatchRootView: View {
    @EnvironmentObject private var store: WatchStore
    /// --open-settings 启动参数直达设置页（模拟器截图验证用）。
    @State private var page = ProcessInfo.processInfo.arguments.contains("--open-settings") ? 1 : 0

    var body: some View {
        TabView(selection: $page) {
            ProviderRingsPager().tag(0)
            WatchSettingsView().tag(1)
        }
        .tabViewStyle(.verticalPage)
    }
}

private enum WatchPagerPage: Hashable {
    case provider(ProviderID)
    case extra(UUID)
    case custom(UUID)
}

/// 横向翻页：已启用内置供应商后面追加自定义金额页（D2）。设置不加自定义开关。
struct ProviderRingsPager: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.appLanguage) private var lang
    /// --provider <id> 启动参数指定初始页（模拟器截图验证用）。
    @State private var selected: WatchPagerPage? = {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--provider"), idx + 1 < args.count,
              let provider = ProviderID(rawValue: args[idx + 1]) else { return nil }
        return .provider(provider)
    }()

    private var visibleCustomItems: [WatchCustomItem] {
        store.demoMode ? [] : store.customItems
    }

    private var visibleExtraItems: [WatchExtraItem] {
        store.demoMode ? [] : store.extraItems.filter { store.enabled.contains($0.provider) }
    }

    var body: some View {
        if store.activeProviders.isEmpty && visibleExtraItems.isEmpty && visibleCustomItems.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                Text(L10n.tr("widget.allDisabled", lang))
                    .font(.footnote)
                Text(L10n.tr("watch.enableHint", lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
        } else {
            TabView(selection: $selected) {
                ForEach(store.activeProviders) { provider in
                    ProviderRingsPage(
                        provider: provider,
                        snapshot: store.snapshot(for: provider),
                        tint: TintResolver.resolve(
                            accountTint: nil,
                            provider: provider,
                            overrides: store.tintOverrides
                        )
                    )
                        .tag(Optional.some(WatchPagerPage.provider(provider)))
                }
                ForEach(visibleExtraItems) { item in
                    ProviderRingsPage(
                        provider: item.provider,
                        snapshot: item.snapshot,
                        title: item.title,
                        tint: item.tint
                    )
                        .tag(Optional.some(WatchPagerPage.extra(item.id)))
                }
                ForEach(visibleCustomItems) { item in
                    CustomAmountPage(item: item)
                        .tag(Optional.some(WatchPagerPage.custom(item.id)))
                }
            }
            .tabViewStyle(.page)
        }
    }
}

/// 自定义账号金额页：不硬画 0% 环。
struct CustomAmountPage: View {
    let item: WatchCustomItem
    @Environment(\.appLanguage) private var lang
    @Environment(\.usageDisplayMode) private var displayMode
    @Environment(\.resetTimeStyle) private var resetStyle

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle((item.tint ?? TintResolver.customDefault).startColor)
                Text(item.title)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if item.visibleMetrics.isEmpty {
                Spacer(minLength: 0)
                Text(
                    item.status?.isNeedsLogin == true
                        ? L10n.tr("custom.noNumeric", lang)
                        : (item.status ?? .ok).emptyUsageCaption(language: lang, okKey: "custom.noNumeric")
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                ForEach(item.visibleMetrics) { metric in
                    VStack(spacing: 2) {
                        Text(L10n.tr(metric.label, lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if metric.resetsAt != nil {
                            TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                                Text(CustomUsageDisplay.valueText(
                                    for: metric.usageMetric,
                                    mode: displayMode,
                                    language: lang,
                                    resetStyle: resetStyle,
                                    now: context.date
                                ))
                                .font(.title3.monospacedDigit().bold())
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            }
                        } else {
                            Text(CustomUsageDisplay.valueText(
                                for: metric.usageMetric,
                                mode: displayMode,
                                language: lang,
                                resetStyle: resetStyle
                            ))
                            .font(.title3.monospacedDigit().bold())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// 单个服务商的圆环页：纯同心环（外环 = 周期最长的限额，一般是周额度），
/// 点击某一环选中它——选中环亮起、其余变暗，环外侧显示该限额级别名与数值。
struct ProviderRingsPage: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    var title: String? = nil
    var tint: BrandTint? = nil
    @Environment(\.appLanguage) private var lang
    @Environment(\.usageDisplayMode) private var displayMode
    @Environment(\.resetTimeStyle) private var resetStyle
    /// 选中的环（metric id）；nil 表示默认选最外圈。
    /// --select-ring <id> 启动参数可预置选中态（模拟器截图验证点击效果用）。
    @State private var selectedID: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--select-ring"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }()

    private static let maxRings = 3

    /// 外环→内环：按重置时间由远到近（窗口时长降序）排列，最长周期在最外圈；
    /// 优先有实际用量的百分比指标，全未使用时退而画全部百分比指标。
    private var ringMetrics: [UsageMetric] {
        guard let snap = snapshot, snap.status.isOK else { return [] }
        let percent = snap.metrics.filter { $0.usedPercent != nil }
        let usable = percent.filter(\.hasUsage).isEmpty ? percent : percent.filter(\.hasUsage)
        // sorted(by:) 不保证稳定，用原始下标做并列时的次序（总量级指标排在细分前）
        let ranked = usable.enumerated().sorted { a, b in
            let ra = a.element.resetsAt ?? .distantPast
            let rb = b.element.resetsAt ?? .distantPast
            if ra != rb { return ra > rb }
            return a.offset < b.offset
        }
        return Array(ranked.map(\.element).prefix(Self.maxRings))
    }

    private var selectedMetric: UsageMetric? {
        ringMetrics.first { $0.id == selectedID } ?? ringMetrics.first
    }

    private var emptyWatchCaption: String {
        (snapshot?.status ?? .needsLogin).emptyUsageCaption(
            language: lang,
            okKey: provider == .jimeng ? "jimeng.creditsUnavailable" : "card.noNumeric"
        )
    }

    private var emptyWatchHintKey: String? {
        if snapshot?.status.isOK == true {
            return provider == .jimeng ? "jimeng.creditsUnavailableHint" : nil
        }
        if snapshot == nil || snapshot?.status.isNeedsLogin == true {
            return "watch.loginOnPhone"
        }
        return nil
    }

    var body: some View {
        let metrics = ringMetrics
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                ProviderLogo(provider: provider, size: 12)
                Text(title ?? provider.localizedName(lang))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if metrics.isEmpty {
                Spacer(minLength: 0)
                if let snap = snapshot, snap.status.isOK, let metric = snap.primaryMetric, let amount = metric.amount {
                    Text(MoneyFormat.string(amount, currency: metric.currency ?? snap.currency))
                        .font(.title3.monospacedDigit().bold())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(L10n.metricLabel(provider: provider, id: metric.id, fallback: metric.label, language: lang))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(emptyWatchCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let hint = emptyWatchHintKey {
                        Text(L10n.tr(hint, lang))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer(minLength: 0)
            } else {
                SelectableRingStack(
                    metrics: metrics,
                    tint: (tint ?? provider.builtinTint).startColor,
                    selectedID: selectedMetric?.id
                ) { id in
                    withAnimation(.snappy(duration: 0.2)) { selectedID = id }
                }
                .frame(maxHeight: .infinity)
                // 环外侧：选中环对应的限额级别名 + 数值 + 重置时间
                if let metric = selectedMetric {
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Text(L10n.metricLabel(provider: provider, id: metric.id, fallback: metric.label, language: lang))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(UsagePresentation.valueText(for: metric, language: lang, mode: displayMode))
                                .font(.footnote.monospacedDigit().bold())
                                .foregroundStyle(usageLevelColor(metric.usedPercent))
                        }
                        if let resets = metric.resetsAt {
                            TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                                Text("\(L10n.tr("metric.resetPrefix", lang))\(TimeFormat.reset(resets, now: context.date, language: lang, style: resetStyle))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                    .id(metric.id)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// 可点选的同心圆环（外→内依次内缩）：选中环用品牌色实色，其余淡化；
/// 点击按「距最近环中心线」命中，小屏上无需精确点在环上。
struct SelectableRingStack: View {
    let metrics: [UsageMetric]
    let tint: Color
    let selectedID: String?
    let onSelect: (String) -> Void
    @Environment(\.usageDisplayMode) private var displayMode

    private let lineWidth: CGFloat = 8
    private let gap: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    SingleRing(
                        percent: UsagePresentation.barPercent(
                            used: metric.usedPercent ?? 0,
                            mode: displayMode
                        ),
                        color: tint.opacity(metric.id == selectedID ? 1.0 : 0.28),
                        lineWidth: lineWidth
                    )
                    .padding(CGFloat(index) * (lineWidth + gap))
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    select(at: value.location, size: size, in: geo.size)
                }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 环 i 的描边中心线半径：size/2 − i·(线宽+间距) − 线宽/2（SingleRing 内缩线宽/2）。
    private func select(at point: CGPoint, size: CGFloat, in container: CGSize) {
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let distance = hypot(point.x - center.x, point.y - center.y)
        let nearest = metrics.enumerated().min { a, b in
            abs(distance - centerlineRadius(a.offset, size: size))
                < abs(distance - centerlineRadius(b.offset, size: size))
        }
        if let nearest {
            onSelect(nearest.element.id)
        }
    }

    private func centerlineRadius(_ index: Int, size: CGFloat) -> CGFloat {
        size / 2 - CGFloat(index) * (lineWidth + gap) - lineWidth / 2
    }
}

private struct SingleRing: View {
    let percent: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.015, min(percent, 100) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// 设置页：服务商开关 + 长按拖动排序，均与 iPhone App 实时双向同步。
struct WatchSettingsView: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.appLanguage) private var lang

    var body: some View {
        List {
            Section {
                ForEach(store.order) { provider in
                    Toggle(isOn: Binding(
                        get: { store.enabled.contains(provider) },
                        set: { store.setEnabled($0, for: provider) }
                    )) {
                        HStack(spacing: 6) {
                            ProviderLogo(provider: provider, size: 12)
                            Text(provider.localizedName(lang))
                                .lineLimit(1)
                        }
                    }
                }
                .onMove { from, to in
                    store.moveOrder(fromOffsets: from, toOffset: to)
                }
            } header: {
                Text(L10n.tr("settings.providers", lang))
            } footer: {
                Text(L10n.tr("watch.syncFooter", lang))
            }
        }
    }
}

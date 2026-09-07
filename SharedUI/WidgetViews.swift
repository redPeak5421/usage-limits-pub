import SwiftUI
import WidgetKit
import UsageLimitsCore

// App 与小组件扩展共同编译的展示层：2×2 环形视图与 2×4 总览视图。
// （品牌色 / 语言环境键 / 用量阈值配色在 Branding.swift，手表 App 也共用。）

private func resetPrefix(_ lang: AppLanguage) -> String {
    L10n.tr("metric.resetPrefix", lang)
}

/// 2×2 同心环：外圈第一条、内圈第二条；圆心留空。
struct ConcentricUsageRings: View {
    struct Slice: Identifiable {
        let id: String
        let percent: Double
        let tint: Color
    }

    let slices: [Slice]
    @Environment(\.usageDisplayMode) private var displayMode

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = CGFloat(WidgetChrome.smallRingLineWidth)
            let gap: CGFloat = 5
            ZStack {
                ForEach(Array(slices.prefix(WidgetChrome.maxMetersPerSmall).enumerated()), id: \.element.id) { index, slice in
                    let shown = UsagePresentation.barPercent(used: slice.percent, mode: displayMode)
                    let inset = line / 2 + CGFloat(index) * (line + gap)
                    ZStack {
                        Circle()
                            .stroke(slice.tint.opacity(0.18), lineWidth: line)
                        Circle()
                            .trim(from: 0, to: min(max(shown / 100, 0), 1))
                            .stroke(slice.tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(inset)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 2×2：最多两条计量，同心环靠中、标题和标签往四边靠。
public struct SmallUsageView: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let now: Date
    /// 该服务商已在设置中被关闭（区别于「未登录」）。
    let disabled: Bool
    /// 账号自定义名；缺省用服务商名。
    let title: String
    let isCustom: Bool
    let tint: BrandTint?
    let customLogoData: Data?
    let selectedMetricIDs: [String]
    @Environment(\.appLanguage) private var lang
    @Environment(\.resetTimeStyle) private var resetStyle
    @Environment(\.usageDisplayMode) private var displayMode

    public init(
        provider: ProviderID,
        snapshot: ProviderSnapshot?,
        now: Date,
        disabled: Bool = false,
        title: String? = nil,
        isCustom: Bool = false,
        tint: BrandTint? = nil,
        customLogoData: Data? = nil,
        selectedMetricIDs: [String] = []
    ) {
        self.provider = provider
        self.snapshot = snapshot
        self.now = now
        self.disabled = disabled
        self.title = title ?? provider.localizedName(.system)
        self.isCustom = isCustom
        self.tint = tint
        self.customLogoData = customLogoData
        self.selectedMetricIDs = selectedMetricIDs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                if isCustom {
                    CustomTemplateLogo(
                        data: customLogoData,
                        size: WidgetChrome.smallNamePointSize,
                        fallbackTint: (tint ?? TintResolver.customDefault).representativeColor
                    )
                } else {
                    ProviderLogo(provider: provider, size: WidgetChrome.smallNamePointSize)
                }
                Text(title)
                    .font(.system(size: WidgetChrome.smallNamePointSize, weight: .bold))
                    .lineLimit(WidgetChrome.providerNameLineLimit)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if !disabled, let snap = snapshot, snap.status.isOK {
                    RefreshStamp(date: snap.fetchedAt, now: now)
                }
            }
            if disabled {
                Text(L10n.tr("widget.disabled", lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("widget.enableInApp", lang))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else if let snap = snapshot, snap.status.isOK {
                let rows = selectedRows(from: snap)
                if !rows.isEmpty {
                    let slices = ringSlices(from: rows)
                    if !slices.isEmpty {
                        ringBoard(rows: rows, slices: slices)
                    } else {
                        Spacer(minLength: 0)
                        smallMeterFooter(rows)
                    }
                } else if isCustom {
                    let shown = CustomUsageDisplay.presentation(
                        from: snap,
                        mode: displayMode,
                        language: lang,
                        resetStyle: resetStyle,
                        now: now
                    )
                    if let stamp = shown.timestamps.first {
                        Spacer(minLength: 0)
                        customTileValue(stamp, title2: false)
                        Text(stamp.label)
                            .font(.system(size: WidgetChrome.smallTitlePointSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Spacer(minLength: 0)
                        Text(L10n.tr("custom.noNumeric", lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let okKey = provider == .jimeng ? "jimeng.creditsUnavailable" : "widget.noNumeric"
                    Spacer(minLength: 0)
                    Text(snap.status.emptyUsageCaption(language: lang, okKey: okKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isCustom {
                let failedCaption = snapshot.flatMap { snap -> String? in
                    (!snap.status.isOK && !snap.status.isNeedsLogin)
                        ? snap.status.emptyUsageCaption(language: lang, okKey: "custom.noNumeric")
                        : nil
                }
                let caption = failedCaption ?? L10n.tr("custom.noNumeric", lang)
                Spacer(minLength: 0)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let status = snapshot?.status ?? .needsLogin
                let needsLogin = snapshot == nil || status.isNeedsLogin
                let okKey = provider == .jimeng ? "jimeng.creditsUnavailable" : "widget.noNumeric"
                Spacer(minLength: 0)
                Text(status.emptyUsageCaption(language: lang, okKey: okKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if needsLogin {
                    Text(L10n.tr("widget.openToLogin", lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var themeTint: Color {
        if isCustom {
            return (tint ?? TintResolver.customDefault).representativeColor
        }
        return (tint ?? provider.builtinTint).representativeColor
    }

    private func selectedRows(from snap: ProviderSnapshot) -> [WidgetAccountItems.OverviewMeter] {
        WidgetAccountItems.selectedMeters(
            from: snap,
            pickedIDs: selectedMetricIDs,
            cap: WidgetChrome.maxMetersPerSmall,
            mode: displayMode,
            language: lang
        )
    }

    private func ringSlices(from rows: [WidgetAccountItems.OverviewMeter]) -> [ConcentricUsageRings.Slice] {
        rows.compactMap { row in
            let used = row.riskPercent ?? row.metric.usedPercent
            guard let used else { return nil }
            return ConcentricUsageRings.Slice(
                id: row.metric.id,
                percent: used,
                tint: themeTint
            )
        }
    }

    @ViewBuilder
    private func ringBoard(rows: [WidgetAccountItems.OverviewMeter], slices: [ConcentricUsageRings.Slice]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let labelH: CGFloat = 14
            let calloutGap: CGFloat = 3
            let ringSide = min(w, max(h - labelH * 2, 24))
            let line = CGFloat(WidgetChrome.smallRingLineWidth)
            let gap: CGFloat = 5
            let cx = w / 2
            let cy = h / 2
            let outerR = ringSide / 2 - line / 2
            let innerR = max(outerR - (line + gap), line)
            ZStack {
                VStack(spacing: 0) {
                    Color.clear.frame(height: labelH)
                    ConcentricUsageRings(slices: slices)
                        .frame(width: ringSide, height: ringSide)
                        .frame(maxWidth: .infinity, maxHeight: max(h - labelH * 2, 24))
                    Color.clear.frame(height: labelH)
                }
                .frame(width: w, height: h, alignment: .top)
                ringCallouts(
                    hasInner: rows.count > 1,
                    canvas: CGSize(width: w, height: h),
                    center: CGPoint(x: cx, y: cy),
                    outerR: outerR,
                    innerR: innerR,
                    topY: labelH + calloutGap,
                    bottomY: h - labelH - calloutGap
                )
                VStack(spacing: 0) {
                    if !rows.isEmpty {
                        smallMeterCaption(rows[0], alignment: .trailing)
                            .frame(width: w, height: labelH, alignment: .trailing)
                    } else {
                        Color.clear.frame(height: labelH)
                    }
                    Spacer(minLength: 0)
                    if rows.count > 1 {
                        smallMeterCaption(rows[1], alignment: .leading)
                            .frame(width: w, height: labelH, alignment: .leading)
                    } else {
                        Color.clear.frame(height: labelH)
                    }
                }
                .frame(width: w, height: h, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func ringCallouts(
        hasInner: Bool,
        canvas: CGSize,
        center: CGPoint,
        outerR: CGFloat,
        innerR: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat
    ) -> some View {
        let w = canvas.width
        let angle = CGFloat.pi / 5
        let outerEnd = CGPoint(
            x: center.x + outerR * cos(angle),
            y: center.y - outerR * sin(angle)
        )
        let innerEnd = CGPoint(
            x: center.x - innerR * cos(angle),
            y: center.y + innerR * sin(angle)
        )
        let outerStart = CGPoint(x: w - 1.5, y: topY)
        let innerStart = CGPoint(x: 1.5, y: bottomY)
        ZStack {
            Path { path in
                path.move(to: outerEnd)
                path.addLine(to: CGPoint(x: outerStart.x, y: outerEnd.y))
                path.addLine(to: outerStart)
            }
            .stroke(themeTint.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            if hasInner {
                Path { path in
                    path.move(to: innerEnd)
                    path.addLine(to: CGPoint(x: innerStart.x, y: innerEnd.y))
                    path.addLine(to: innerStart)
                }
                .stroke(themeTint.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func smallMeterFooter(_ rows: [WidgetAccountItems.OverviewMeter]) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            smallMeterCaption(rows[0], alignment: .leading)
            if rows.count > 1 {
                smallMeterCaption(rows[1], alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func smallMeterCaption(_ row: WidgetAccountItems.OverviewMeter, alignment: HorizontalAlignment) -> some View {
        let metric = row.metric
        HStack(spacing: 3) {
            Text(isCustom
                ? L10n.tr(metric.label, lang)
                : L10n.metricLabel(provider: provider, id: metric.id, fallback: metric.label, language: lang))
                .font(.system(size: WidgetChrome.smallTitlePointSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
                .layoutPriority(0)
            smallMeterValue(row)
            if let resets = metric.resetsAt, CustomUsageDisplay.fieldRole(metric) != .timestamp {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(TimeFormat.compactRelative(resets, now: context.date, language: lang))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    @ViewBuilder
    private func smallMeterValue(_ row: WidgetAccountItems.OverviewMeter) -> some View {
        let metric = row.metric
        let font = Font.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()
        if isCustom {
            if CustomUsageDisplay.fieldRole(metric) == .timestamp, let date = metric.resetsAt {
                TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                    Text(TimeFormat.reset(date, now: context.date, language: lang, style: resetStyle))
                        .font(font)
                        .fixedSize()
                        .layoutPriority(2)
                        .lineLimit(1)
                }
            } else {
                Text(CustomUsageDisplay.valueText(
                    for: metric,
                    mode: displayMode,
                    language: lang,
                    resetStyle: resetStyle,
                    now: now
                ))
                .font(font)
                .fixedSize()
                .layoutPriority(2)
                .lineLimit(1)
            }
        } else if let percent = metric.usedPercent ?? row.riskPercent {
            Text(UsagePresentation.percentText(used: percent, mode: displayMode))
                .font(font)
                .foregroundStyle(themeTint)
                .fixedSize()
                .layoutPriority(2)
                .lineLimit(1)
        } else if let amount = metric.amount {
            Text(MoneyFormat.string(amount, currency: metric.currency ?? snapshot?.currency))
                .font(font)
                .fixedSize()
                .layoutPriority(2)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func customTileValue(_ tile: CustomUsageDisplay.Tile, title2: Bool) -> some View {
        let font = Font.system(title2 ? .title2 : .caption, design: .rounded).monospacedDigit().bold()
        if tile.role == .timestamp, let date = tile.date {
            TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                Text(TimeFormat.reset(date, now: context.date, language: lang, style: resetStyle))
                    .font(font)
                    .minimumScaleFactor(title2 ? 0.55 : 0.7)
                    .lineLimit(1)
            }
        } else {
            Text(tile.valueText)
                .font(font)
                .minimumScaleFactor(title2 ? 0.55 : 0.7)
                .lineLimit(1)
        }
    }
}

/// 2×4 / 4×4 总览与 2×4 单服务商视图。
/// 按账号成组：名称垂直居中。总览每家最多 2 条；单账号 2×4 最多 4 条。
/// 多家时左侧花括号框定范围。单账号卡不画括号。
/// 小组件是 WidgetKit 静态快照，系统不允许滚动；账号数超上限时截断，末行提示「还有 N 项」。
public struct WidgetAccountDisplay: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let title: String
    public let snapshot: ProviderSnapshot?
    public let isCustom: Bool
    public let tint: BrandTint?
    public let customLogoData: Data?
    /// 该实例在编辑页勾选的计量条，顺序即展示顺序。空 = 跟主页展开顺序。
    public let selectedMetricIDs: [String]

    public init(
        id: String,
        provider: ProviderID,
        title: String,
        snapshot: ProviderSnapshot?,
        isCustom: Bool = false,
        tint: BrandTint? = nil,
        customLogoData: Data? = nil,
        selectedMetricIDs: [String] = []
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.snapshot = snapshot
        self.isCustom = isCustom
        self.tint = tint
        self.customLogoData = customLogoData
        self.selectedMetricIDs = selectedMetricIDs
    }
}

public struct MediumUsageView: View {
    let items: [WidgetAccountDisplay]
    let now: Date
    /// 行数上限；nil 时按 widgetFamily 自动取（medium 3 行 / large 11 行）。
    let maxRowsOverride: Int?
    /// 每家计量条数；nil 时按总览表：2×4 前 4 条，4×4 按实例数 8/4/3/2。
    let maxMetersOverride: Int?
    /// nil 时跟 widgetFamily：large = 4×4 总览表，其余按 2×4 单实例。
    let isLargeOverview: Bool?

    @Environment(\.widgetFamily) private var family
    @Environment(\.appLanguage) private var lang
    @Environment(\.resetTimeStyle) private var resetStyle
    @Environment(\.usageDisplayMode) private var displayMode

    public init(
        items: [WidgetAccountDisplay],
        now: Date,
        maxRows: Int? = nil,
        maxMeters: Int? = nil,
        isLargeOverview: Bool? = nil
    ) {
        self.items = items
        self.now = now
        self.maxRowsOverride = maxRows
        self.maxMetersOverride = maxMeters
        self.isLargeOverview = isLargeOverview
    }

    public init(
        snapshots: [ProviderID: ProviderSnapshot],
        now: Date,
        providers: [ProviderID] = ProviderID.allCases,
        maxRows: Int? = nil,
        maxMeters: Int? = nil,
        isLargeOverview: Bool? = nil
    ) {
        self.init(
            items: providers.map {
                WidgetAccountDisplay(
                    id: $0.rawValue, provider: $0, title: $0.localizedName(.system), snapshot: snapshots[$0]
                )
            },
            now: now,
            maxRows: maxRows,
            maxMeters: maxMeters,
            isLargeOverview: isLargeOverview
        )
    }

    private struct Row: Identifiable {
        let id: String
        /// 所属账号实例；截取后重新决定哪一行显示名称。
        let accountID: String
        let provider: ProviderID
        let title: String
        /// 该账号的第一行才显示名称，多级计量的后续行留空。
        var showName: Bool
        /// nil 表示无可画进度的计量（未登录 / 已登录但官方无数值额度）。
        let metric: UsageMetric?
        let loggedIn: Bool
        let isCustom: Bool
        let tint: BrandTint?
        let customLogoData: Data?
        let displayedPercent: Double?
        let riskPercent: Double?
        let errorText: String?
    }

    private var largeOverview: Bool {
        isLargeOverview ?? (family == .systemLarge)
    }

    private var scopedItems: [WidgetAccountDisplay] {
        Array(items.prefix(WidgetChrome.overviewAccountLimit(isLarge: largeOverview)))
    }

    /// 上次刷新时间：取已登录账号里最近一次成功抓取的时间；全部未登录则不显示。
    private var latestFetchedAt: Date? {
        scopedItems.compactMap { $0.snapshot }.filter { $0.status.isOK }.map(\.fetchedAt).max()
    }

    private struct AccountBlock: Identifiable {
        let id: String
        let provider: ProviderID
        let title: String
        let isCustom: Bool
        let tint: BrandTint?
        let customLogoData: Data?
        let meters: [Row]
        let loggedIn: Bool
        let errorText: String?
    }

    private var accountBlocks: [AccountBlock] {
        scopedItems.map { item in
            let snap = item.snapshot
            guard let snap, snap.status.isOK else {
                let customError: String?
                if item.isCustom {
                    if let snap, !snap.status.isOK, !snap.status.isNeedsLogin {
                        customError = snap.status.displayText(lang)
                    } else {
                        customError = L10n.tr("custom.noNumeric", lang)
                    }
                } else {
                    customError = snap.flatMap { $0.status.isNeedsLogin ? nil : $0.status.displayText(lang) }
                }
                return AccountBlock(
                    id: item.id, provider: item.provider, title: item.title,
                    isCustom: item.isCustom, tint: item.tint, customLogoData: item.customLogoData,
                    meters: [], loggedIn: item.isCustom, errorText: customError
                )
            }
            let meterCap = maxMetersOverride
                ?? WidgetChrome.overviewMetersPerAccount(
                    accountCount: scopedItems.count,
                    isLarge: largeOverview
                )
            let meters = WidgetAccountItems.overviewRows(
                from: snap, mode: displayMode, language: lang,
                pickedIDs: item.selectedMetricIDs, cap: meterCap
            )
            if meters.isEmpty {
                return AccountBlock(
                    id: item.id, provider: item.provider, title: item.title,
                    isCustom: item.isCustom, tint: item.tint, customLogoData: item.customLogoData,
                    meters: [], loggedIn: true,
                    errorText: item.isCustom
                        ? L10n.tr("custom.noNumeric", lang)
                        : item.provider == .jimeng
                        ? L10n.tr("jimeng.creditsUnavailable", lang)
                        : nil
                )
            }
            let rows: [Row] = meters.map { m in
                Row(
                    id: "\(item.id).\(m.metric.id)", accountID: item.id, provider: item.provider, title: item.title,
                    showName: false, metric: m.metric, loggedIn: true,
                    isCustom: item.isCustom, tint: item.tint, customLogoData: item.customLogoData,
                    displayedPercent: m.displayedPercent,
                    riskPercent: m.riskPercent,
                    errorText: nil
                )
            }
            return AccountBlock(
                id: item.id, provider: item.provider, title: item.title,
                isCustom: item.isCustom, tint: item.tint, customLogoData: item.customLogoData,
                meters: rows, loggedIn: true, errorText: nil
            )
        }
    }

    public var body: some View {
        if scopedItems.isEmpty {
            VStack(spacing: 4) {
                Text(L10n.tr("widget.allDisabled", lang))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("widget.enableInApp", lang))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            let blocks = accountBlocks
            let cap = maxRowsOverride ?? (family == .systemLarge ? 4 : 3)
            let overflow = WidgetRowSelection.overflow(rowCount: blocks.count, cap: cap)
            let visible = Array(blocks.prefix(overflow.visible))
            VStack(spacing: 6) {
                ForEach(visible) { block in
                    let stamp = block.id == visible.last?.id ? latestFetchedAt : nil
                    if let accountID = UUID(uuidString: block.id) {
                        Link(destination: AppDeepLink.accountURL(accountID)) {
                            groupView(block, stamp: stamp)
                                .frame(maxHeight: .infinity)
                        }
                    } else {
                        groupView(block, stamp: stamp)
                            .frame(maxHeight: .infinity)
                    }
                }
                if overflow.hidden > 0 {
                    Text(L10n.tr("widget.more", lang, overflow.hidden))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nameLabel(_ block: AccountBlock) -> some View {
        HStack(spacing: 5) {
            if block.isCustom {
                CustomTemplateLogo(
                    data: block.customLogoData,
                    size: WidgetChrome.providerLogoSize,
                    fallbackTint: (block.tint ?? TintResolver.customDefault).representativeColor
                )
            } else {
                ProviderLogo(provider: block.provider, size: WidgetChrome.providerLogoSize)
            }
            // 4×4：整体缩小字号，8 字以内单行不换行（不够宽再等比缩字）；更长的名字仍允许两行。
            let shortName = block.title.count <= WidgetChrome.largeOverviewSingleLineNameLength
            Text(block.title)
                .font(.system(
                    size: largeOverview
                        ? WidgetChrome.largeOverviewNamePointSize
                        : WidgetChrome.providerNamePointSize,
                    weight: .bold
                ))
                .lineLimit(largeOverview && shortName ? 1 : WidgetChrome.providerNameLineLimit)
                .minimumScaleFactor(largeOverview && shortName ? 0.6 : 1)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func valueText(_ metric: UsageMetric, row: Row, now: Date) -> some View {
        let text = row.isCustom
            ? CustomUsageDisplay.valueText(
                for: metric,
                mode: displayMode,
                language: lang,
                resetStyle: resetStyle,
                now: now
            )
            : UsagePresentation.valueText(for: metric, language: lang, mode: displayMode)
        return Text(text)
            .font(
                row.isCustom
                    ? Font.system(.subheadline, design: .rounded).monospacedDigit().weight(.semibold)
                    : Font.caption.monospacedDigit().bold()
            )
            .foregroundStyle(row.isCustom ? Color.primary : usageLevelColor(metric.usedPercent))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: row.isCustom ? 58 : WidgetChrome.percentColumnWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func liveValueText(_ metric: UsageMetric, row: Row) -> some View {
        if row.isCustom, CustomUsageDisplay.fieldRole(metric) == .timestamp, metric.resetsAt != nil {
            TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                valueText(metric, row: row, now: context.date)
            }
        } else {
            valueText(metric, row: row, now: now)
        }
    }

    @ViewBuilder
    private func meterView(_ row: Row) -> some View {
        if let metric = row.metric {
            let barPercent: Double? = {
                if row.isCustom { return row.displayedPercent }
                guard let percent = metric.usedPercent else { return nil }
                return UsagePresentation.barPercent(used: percent, mode: displayMode)
            }()
            VStack(spacing: 2) {
                if let percent = barPercent {
                    HStack(spacing: 6) {
                        QuotaBar(
                            percent: percent,
                            tint: (row.tint ?? (row.isCustom ? TintResolver.customDefault : row.provider.builtinTint)).representativeColor
                        )
                        liveValueText(metric, row: row)
                    }
                }
                HStack {
                    Text(row.isCustom
                        ? L10n.tr(metric.label, lang)
                        : L10n.metricLabel(provider: row.provider, id: metric.id, fallback: metric.label, language: lang))
                        .font(.system(
                            size: row.isCustom ? 10 : WidgetChrome.usageTitlePointSize,
                            weight: .medium
                        ))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let resets = metric.resetsAt, CustomUsageDisplay.fieldRole(metric) != .timestamp {
                        TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                            Text("\(resetPrefix(lang))\(TimeFormat.reset(resets, now: context.date, language: lang, style: resetStyle))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    if barPercent == nil {
                        liveValueText(metric, row: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupView(_ block: AccountBlock, stamp: Date?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .center, spacing: 4) {
                nameLabel(block)
                    .padding(.bottom, stamp == nil ? 0 : 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .overlay(alignment: .bottomLeading) {
                        if let stamp {
                            RefreshStamp(date: stamp, now: now)
                        }
                    }
                if scopedItems.count > 1, block.meters.count > 1 {
                    GroupBrace()
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: WidgetChrome.nameColumnWidth, alignment: .leading)
            .frame(maxHeight: .infinity)

            if block.meters.isEmpty {
                Text(block.errorText ?? L10n.tr(block.loggedIn ? "widget.noNumeric" : "card.notLoggedIn", lang))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 6) {
                    ForEach(block.meters) { row in
                        meterView(row)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

/// 多条计量时框定供应商对应的范围。
struct GroupBrace: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = max(geo.size.height, 1)
            Path { path in
                let mid = h / 2
                path.move(to: CGPoint(x: w, y: 1))
                path.addQuadCurve(to: CGPoint(x: 2, y: mid * 0.4), control: CGPoint(x: 2, y: 1))
                path.addLine(to: CGPoint(x: 2, y: mid - 4))
                path.addLine(to: CGPoint(x: 0.5, y: mid))
                path.addLine(to: CGPoint(x: 2, y: mid + 4))
                path.addLine(to: CGPoint(x: 2, y: h - mid * 0.4))
                path.addQuadCurve(to: CGPoint(x: w, y: h - 1), control: CGPoint(x: 2, y: h - 1))
            }
            .stroke(
                Color.secondary.opacity(0.45),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 8)
        .accessibilityHidden(true)
    }
}

/// 2×4 额度条：比系统 ProgressView×0.8 更粗，着色用首页标签品牌色。
struct QuotaBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geo.size.width * CGFloat(fraction), percent > 0 ? 4 : 0))
            }
        }
        .frame(height: WidgetChrome.quotaBarHeight)
    }
}

/// 「上次刷新」时间戳：小组件不能主动打网，明示数据新鲜度，避免把陈旧额度当成实时值。
struct RefreshStamp: View {
    let date: Date
    let now: Date

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
            Text(TimeFormat.refreshStamp(date, now: now))
                .font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
    }
}

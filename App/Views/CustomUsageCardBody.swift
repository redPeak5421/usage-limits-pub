import SwiftUI
import UsageLimitsCore

/// 自定义账号卡内容区。字段语义（已用 / 余额 / 总额 / 百分比 / 时间）由
/// `CustomUsageDisplay` 推导：折叠态主指标大号 + 其余小格一行；展开态主指标
/// 着色区块（含进度条与说明）+ 2 列网格 + 到期 / 重置时间行。
/// 只画在 `isCustom` body 内，不改整卡 chrome。占比只在展示层计算。
struct CustomUsageCardBody: View {
    let snap: ProviderSnapshot
    let isExpanded: Bool
    var accent: Color = .accentColor
    let namespace: Namespace.ID
    var onReorderMetrics: (() -> Void)? = nil
    @Environment(\.appLanguage) private var lang
    @Environment(\.usageDisplayMode) private var displayMode
    @Environment(\.resetTimeStyle) private var resetStyle

    private var presentation: CustomUsageDisplay.Presentation {
        CustomUsageDisplay.presentation(
            from: snap,
            mode: displayMode,
            language: lang,
            resetStyle: resetStyle
        )
    }

    /// 折叠态主指标旁最多露两格。
    private static let collapsedSecondaryLimit = 2

    var body: some View {
        let shown = presentation
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 8) {
            if shown.tiles.isEmpty {
                Text(L10n.tr("custom.noNumeric", lang))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isExpanded {
                expandedLayout(shown)
            } else {
                collapsedLayout(shown)
            }
        }
    }

    // MARK: - 折叠

    /// 折叠主指标 = 展开顺序第一位（用户计量顺序），不再固定语义 hero。
    private func collapsedHero(_ shown: CustomUsageDisplay.Presentation) -> CustomUsageDisplay.Tile? {
        CustomUsageDisplay.collapsedTile(from: snap, shown: shown)
    }

    @ViewBuilder
    private func collapsedLayout(_ shown: CustomUsageDisplay.Presentation) -> some View {
        let hero = collapsedHero(shown)
        let secondary = Array(shown.tiles.filter { $0.role != .timestamp && $0.id != hero?.id }.prefix(Self.collapsedSecondaryLimit))
        let shownStamp = shown.timestamps.first
        let hiddenCount = shown.tiles.filter { $0.role != .timestamp && $0.id != hero?.id }.count - secondary.count
            + shown.timestamps.count - (shownStamp == nil ? 0 : 1)
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            if let hero {
                heroBlock(hero, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            ForEach(secondary, id: \.id) { tile in
                compactTile(tile)
            }
        }
        if let gauge = shown.gauge, hero?.id == shown.hero?.id {
            gaugeBar(gauge, showCaption: false)
        }
        if let shownStamp {
            timestampRow(shownStamp)
        }
        if hiddenCount > 0 {
            Text(L10n.tr("custom.card.moreFields", lang, hiddenCount))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .transition(.opacity)
        }
    }

    // MARK: - 展开

    @ViewBuilder
    private func expandedLayout(_ shown: CustomUsageDisplay.Presentation) -> some View {
        if let hero = shown.hero {
            VStack(alignment: .leading, spacing: 10) {
                heroBlock(hero, compact: false)
                if let gauge = shown.gauge {
                    gaugeBar(gauge, showCaption: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(accent.opacity(0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.18), lineWidth: 1)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        if !shown.secondary.isEmpty {
            tileGrid(shown.secondary)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        if !shown.timestamps.isEmpty {
            VStack(spacing: 6) {
                ForEach(shown.timestamps, id: \.id) { tile in
                    timestampRow(tile)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - 组件

    /// 主指标：标签小字在上，数字大号；折叠态略小。
    private func heroBlock(_ tile: CustomUsageDisplay.Tile, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(spacing: 4) {
                roleGlyph(tile.role)
                Text(tile.label)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "label.\(tile.id)", in: namespace)
            }
            Text(tile.valueText)
                .font((compact ? Font.title2 : Font.largeTitle).monospacedDigit())
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .matchedGeometryEffect(id: "value.\(tile.id)", in: namespace)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.label) \(tile.valueText)")
        .modifier(MetricReorderMenu(action: onReorderMetrics, language: lang))
    }

    /// 折叠态右侧小格：数字在上、标签在下，右对齐。
    private func compactTile(_ tile: CustomUsageDisplay.Tile) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(tile.valueText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .matchedGeometryEffect(id: "value.\(tile.id)", in: namespace)
            Text(tile.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .matchedGeometryEffect(id: "label.\(tile.id)", in: namespace)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.label) \(tile.valueText)")
        .modifier(MetricReorderMenu(action: onReorderMetrics, language: lang))
    }

    @ViewBuilder
    private func tileGrid(_ tiles: [CustomUsageDisplay.Tile]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(tiles, id: \.id) { tile in
                gridTile(tile)
            }
        }
    }

    /// 展开态网格格：左上角色小图标 + 标签，数字 semibold。
    private func gridTile(_ tile: CustomUsageDisplay.Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                roleGlyph(tile.role)
                Text(tile.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "label.\(tile.id)", in: namespace)
            }
            Text(tile.valueText)
                .font(Font.title3.monospacedDigit())
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .matchedGeometryEffect(id: "value.\(tile.id)", in: namespace)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.label) \(tile.valueText)")
        .modifier(MetricReorderMenu(action: onReorderMetrics, language: lang))
    }

    private func timestampRow(_ tile: CustomUsageDisplay.Tile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tile.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let date = tile.date {
                TimelineView(.periodic(from: .now, by: resetStyle == .absolute ? 3600 : 60)) { context in
                    let live = TimeFormat.reset(date, now: context.date, language: lang, style: resetStyle)
                    let absolute = TimeFormat.reset(date, now: context.date, language: lang, style: .absolute)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(live)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .matchedGeometryEffect(id: "value.\(tile.id)", in: namespace)
                        if resetStyle == .countdown, absolute != live, absolute != "—" {
                            Text(absolute)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text(tile.valueText)
                    .font(.subheadline.monospacedDigit())
                    .matchedGeometryEffect(id: "value.\(tile.id)", in: namespace)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        }
    }

    /// 进度条：颜色按阈值（绿 / 橙 / 红）；展开态下方给出「已用 x / 总额 y」与百分比。
    private func gaugeBar(_ gauge: CustomUsageDisplay.Gauge, showCaption: Bool) -> some View {
        let percent = gauge.displayedPercent
        let riskPercent = gauge.riskPercent
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                        .matchedGeometryEffect(id: "gauge", in: namespace)
                    UsageBarSegment(levelColor: usageLevelColor(riskPercent))
                        .frame(width: max(proxy.size.width * percent / 100, percent > 0 ? 4 : 0))
                }
            }
            .frame(height: showCaption ? 6 : 4)
            if showCaption {
                HStack {
                    if let caption = gauge.caption {
                        Text(caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 8)
                    Text(CustomUsageDisplay.percentText(percent))
                        .monospacedDigit()
                        .foregroundStyle(usageLevelColor(riskPercent))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CustomUsageDisplay.percentText(percent))
    }

    @ViewBuilder
    private func roleGlyph(_ role: CustomFieldRole) -> some View {
        switch role {
        case .used:
            Image(systemName: "arrow.down.right.circle").font(.caption2).foregroundStyle(.secondary)
        case .remaining:
            Image(systemName: "creditcard").font(.caption2).foregroundStyle(accent)
        case .limit:
            Image(systemName: "gauge.with.needle").font(.caption2).foregroundStyle(.secondary)
        case .percent:
            Image(systemName: "percent").font(.caption2).foregroundStyle(.secondary)
        case .count:
            Image(systemName: "number").font(.caption2).foregroundStyle(.secondary)
        case .timestamp:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .other:
            EmptyView()
        }
    }
}

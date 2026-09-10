import SwiftUI
import UsageLimitsCore

struct OpenAIResetCreditsView: View {
    let summary: OpenAIResetCredits
    let isExpanded: Bool
    var compact: Bool = false
    @Environment(\.appLanguage) private var lang
    private static let visibleSlots = 3
    private static let rowSpacing: CGFloat = 8
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 40

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle")
                if let count = summary.availableCount {
                    Text(L10n.tr("openai.reset.available", lang) + " " + L10n.tr("openai.reset.count", lang, count))
                    if let expires = summary.expiresAt {
                        Text("· " + L10n.tr("openai.reset.expires", lang) + " " + expires.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: lang.resolved.rawValue))))
                    }
                } else if let used = summary.usedCount {
                    Text(L10n.tr("openai.reset.used", lang) + " " + L10n.tr(summary.historyComplete ? "openai.reset.count" : "openai.reset.atLeast", lang, used))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.tr("openai.reset.title", lang), systemImage: "arrow.counterclockwise.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count = summary.availableCount {
                row("openai.reset.available", value: L10n.tr("openai.reset.count", lang, count))
                if isExpanded, let dates = summary.availableExpirations, !dates.isEmpty {
                    resetList(dates, available: true)
                } else if let expires = summary.expiresAt {
                    Text(L10n.tr("openai.reset.expires", lang) + " " + expires.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: lang.resolved.rawValue))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if isExpanded || summary.availableCount == nil, let used = summary.usedCount {
                row("openai.reset.used", value: L10n.tr(summary.historyComplete ? "openai.reset.count" : "openai.reset.atLeast", lang, used))
                if isExpanded, let dates = summary.usedDates, !dates.isEmpty {
                    resetList(dates, available: false)
                }
                if let start = summary.windowStart, let end = summary.asOf {
                    Text(start.formatted(date: .numeric, time: .omitted) + " – " + end.formatted(date: .numeric, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ key: String, value: String) -> some View {
        HStack {
            Text(L10n.tr(key, lang))
            Spacer(minLength: 8)
            Text(value).monospacedDigit().bold()
        }
        .font(.subheadline)
    }

    private func resetList(_ dates: [Date], available: Bool) -> some View {
        let visible = min(dates.count, Self.visibleSlots)
        let height = CGFloat(visible) * rowHeight + CGFloat(max(visible - 1, 0)) * Self.rowSpacing + 16
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                // Two different credits may share a timestamp; the stable sorted position identifies each row.
                ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("openai.reset.title", lang))
                                .font(.subheadline)
                            Text(L10n.tr(available ? "openai.reset.expiryDate" : "openai.reset.usedDate", lang) + " " + date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: lang.resolved.rawValue))))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(L10n.tr("openai.reset.count", lang, 1))
                            .font(.subheadline.monospacedDigit().bold())
                    }
                    .lineLimit(1)
                    .frame(height: rowHeight)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .environment(\.isScrollEnabled, dates.count > Self.visibleSlots)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollIndicators(dates.count > Self.visibleSlots ? .visible : .hidden)
        .frame(height: height)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .background {
            if dates.count > Self.visibleSlots {
                Color.clear.dashboardSceneControlRegion()
            }
        }
    }
}

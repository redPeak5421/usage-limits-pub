import SwiftUI
import UsageLimitsCore

struct OpenAIResetCreditsView: View {
    let summary: OpenAIResetCredits
    let isExpanded: Bool
    var compact: Bool = false
    @Environment(\.appLanguage) private var lang
    private static let visibleSlots = 3
    private static let rowSpacing: CGFloat = 2
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 22

    var body: some View {
        if let count = summary.availableCount {
            if compact {
                HStack(spacing: 4) {
                    Text(L10n.tr("openai.reset.available", lang))
                    Text(L10n.tr("openai.reset.count", lang, count))
                    if count > 0, let expires = summary.expiresAt {
                        Text("· " + expiryText(expires))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L10n.tr("openai.reset.available", lang))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(L10n.tr("openai.reset.count", lang, count))
                            .monospacedDigit().bold()
                    }
                    .font(.subheadline)
                    if count > 0 {
                        if isExpanded, let dates = summary.availableExpirations, !dates.isEmpty {
                            resetList(dates)
                        } else if let expires = summary.expiresAt {
                            expiryRow(expires)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func expiryText(_ date: Date) -> String {
        L10n.tr("openai.reset.expiryDate", lang) + " " + date.formatted(
            .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
                .locale(Locale(identifier: lang.resolved.rawValue))
        )
    }

    private func expiryRow(_ date: Date) -> some View {
        Text(expiryText(date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetList(_ dates: [Date]) -> some View {
        let visible = min(dates.count, Self.visibleSlots)
        let height = CGFloat(visible) * rowHeight + CGFloat(max(visible - 1, 0)) * Self.rowSpacing
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                // Different credits may share a timestamp; retain each sorted row.
                ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                    expiryRow(date).frame(height: rowHeight)
                }
            }
        }
        .environment(\.isScrollEnabled, dates.count > Self.visibleSlots)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollIndicators(dates.count > Self.visibleSlots ? .visible : .hidden)
        .frame(height: height)
        .background {
            if dates.count > Self.visibleSlots {
                Color.clear.dashboardSceneControlRegion()
            }
        }
    }
}

import SwiftUI
import UsageLimitsCore

struct OpenAIResetCreditsView: View {
    let summary: OpenAIResetCredits

    var body: some View {
        AvailableResetsView(availableCount: summary.availableCount, expiresAt: summary.expiresAt,
                            availableExpirations: summary.availableExpirations, keyPrefix: "openai.reset")
    }
}

/// ChatGPT 与 Grok 共用次数和到期列表布局，供应商差异只留在解析与文案键中。
struct AvailableResetsView: View {
    let availableCount: Int?
    let expiresAt: Date?
    let availableExpirations: [Date]?
    let keyPrefix: String
    @Environment(\.appLanguage) private var lang
    @Environment(\.timeZone) private var timeZone
    private static let visibleSlots = 3
    private static let rowSpacing: CGFloat = 4
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 20

    var body: some View {
        if let count = availableCount {
            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.45)
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.tr("\(keyPrefix).available", lang))
                    Spacer(minLength: 8)
                    Text(L10n.tr("\(keyPrefix).count", lang, count))
                        .monospacedDigit().bold()
                }
                .font(.subheadline)
                if count > 0 {
                    if let dates = availableExpirations, !dates.isEmpty {
                        resetList(dates)
                    } else if let expires = expiresAt {
                        expiryRow(expires)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func expiryRow(_ date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.tr("\(keyPrefix).expiryDate", lang))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(TimeFormat.localDateTime(date, timeZone: timeZone))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
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

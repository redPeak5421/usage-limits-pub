import SwiftUI
import UsageLimitsCore

struct GrokUsageResetsView: View {
    let summary: GrokUsageResets

    var body: some View {
        AvailableResetsView(availableCount: summary.availableCount, expiresAt: summary.expiresAt,
                            availableExpirations: summary.availableExpirations, keyPrefix: "grok.reset")
    }
}

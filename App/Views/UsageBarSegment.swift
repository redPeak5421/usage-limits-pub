import SwiftUI
import UsageLimitsCore

struct UsageBarSegment: View {
    let levelColor: Color
    @Environment(\.usageBarDecorator) private var decorator

    var body: some View {
        if let decorator {
            decorator.fill(levelColor)
        } else {
            Capsule()
                .fill(levelColor)
                .allowsHitTesting(false)
        }
    }
}

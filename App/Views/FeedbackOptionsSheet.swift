import SwiftUI
import UsageLimitsCore

struct FeedbackOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var lang
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 0
    @State private var bottomSafeAreaInset: CGFloat = 0

    let onSelection: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        optionsContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .presentationDetents([.medium])
                } else {
                    compactPresentation
                }
            }
            .onAppear {
                updateBottomSafeAreaInset(geometry.safeAreaInsets.bottom)
            }
            .onChange(of: geometry.safeAreaInsets.bottom) { _, measuredInset in
                updateBottomSafeAreaInset(measuredInset)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var compactPresentation: some View {
        optionsContent
            .ignoresSafeArea(.container, edges: .bottom)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: FeedbackSheetHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(FeedbackSheetHeightKey.self) { measuredHeight in
                let roundedHeight = measuredHeight.rounded(.up)
                guard roundedHeight > 0,
                      abs(contentHeight - roundedHeight) > 0.5
                else { return }
                contentHeight = roundedHeight
            }
            .presentationDetents([
                contentHeight > 0 ? .height(compactHeight) : .medium,
            ])
    }

    private var compactHeight: CGFloat {
        max(contentHeight - bottomSafeAreaInset, 1)
    }

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge")
                    .font(.title2.bold())
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(L10n.tr("feedback.logs.prompt", lang))
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
            }

            Text(L10n.tr("feedback.logs.disclosure", lang))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                select(includeDiagnostics: true)
            } label: {
                Label(L10n.tr("feedback.logs.include", lang), systemImage: "paperclip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                select(includeDiagnostics: false)
            } label: {
                Label(L10n.tr("feedback.logs.exclude", lang), systemImage: "envelope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                dismiss()
            } label: {
                Text(L10n.tr("feedback.cancel", lang))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func updateBottomSafeAreaInset(_ measuredInset: CGFloat) {
        let roundedInset = measuredInset.rounded(.up)
        guard abs(bottomSafeAreaInset - roundedInset) > 0.5 else { return }
        bottomSafeAreaInset = roundedInset
    }

    private func select(includeDiagnostics: Bool) {
        onSelection(includeDiagnostics)
        dismiss()
    }
}

private struct FeedbackSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


import SwiftUI
import UsageLimitsCore

/// 在 App 内以真实小组件尺寸渲染 2×2 / 2×4 / 4×4。
struct WidgetPreviewView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var edition: Edition
    @Environment(\.appLanguage) private var lang
    @State private var smallAccountID: String = ""
    @State private var overviewSelection: Set<String> = []
    @State private var previewExpanded = false

    /// 没有任何供应商时的模拟预览：固定 Claude / Codex(ChatGPT) / Grok 三家，用演示数据渲染。
    /// 一旦用户添加了任意供应商，就只展示真实账号，不再混入模拟项。
    private static let simulatedProviders: [ProviderID] = [.claude, .openai, .grok]

    private var isSimulated: Bool { state.accounts.isEmpty }

    private var simulatedItems: [WidgetAccountItem] {
        Self.simulatedProviders.map { provider in
            WidgetAccountItem(
                id: "provider.\(provider.rawValue)",
                provider: provider,
                title: provider.localizedName(lang)
            )
        }
    }

    private var previewAccountItems: [WidgetAccountItem] {
        if isSimulated { return simulatedItems }
        return WidgetAccountItems.overview(
            pickedIDs: [],
            accounts: state.accounts,
            providerOrder: state.providerOrder,
            preview: false,
            isProviderEnabled: { state.isEnabled($0) },
            language: lang
        )
    }

    private var selectedSmallItem: WidgetAccountItem? {
        previewAccountItems.first { $0.id == smallAccountID } ?? previewAccountItems.first
    }

    private func customAccount(for item: WidgetAccountItem) -> ProviderAccount? {
        guard let extra = item.extraAccountID else { return nil }
        return state.accounts.first { $0.id == extra }
    }

    private func customTint(for item: WidgetAccountItem) -> BrandTint {
        let account = customAccount(for: item)
        let templateTint = account?.templateID.flatMap { id in
            state.customTemplates.first { $0.id == id }?.tint
        }
        return TintResolver.resolve(accountTint: account?.tint, templateTint: templateTint)
    }

    private func customLogo(for item: WidgetAccountItem) -> Data? {
        customAccount(for: item).flatMap { state.customLogoData(for: $0) }
    }

    private func display(for item: WidgetAccountItem) -> WidgetAccountDisplay {
        WidgetAccountDisplay(
            id: item.id,
            provider: item.provider,
            title: item.title,
            snapshot: isSimulated
                ? SharedStore.demoSnapshots(now: Date()).first { $0.provider == item.provider }
                : WidgetAccountItems.snapshot(for: item, now: Date(), store: state.store),
            isCustom: item.isCustom,
            tint: item.isCustom ? customTint(for: item) : nil,
            customLogoData: customLogo(for: item)
        )
    }

    private var orderedOverviewIDs: [String] {
        let chosen = overviewSelection
        if chosen.isEmpty { return [] }
        return previewAccountItems.map(\.id).filter { chosen.contains($0) }
    }

    private func overviewDisplays(pickedIDs: [String]) -> [WidgetAccountDisplay] {
        if isSimulated {
            let items = simulatedItems
            if pickedIDs.isEmpty { return items.map(display(for:)) }
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return pickedIDs.compactMap { byID[$0] }.map(display(for:))
        }
        return WidgetAccountItems.overview(
            pickedIDs: pickedIDs,
            accounts: state.accounts,
            providerOrder: state.providerOrder,
            preview: false,
            isProviderEnabled: { state.isEnabled($0) },
            language: lang
        ).map(display(for:))
    }

    /// 主屏小组件相对屏幕左右边距（与桌面实际摆放对齐，约 16pt）。
    private static let homeScreenWidgetInset: CGFloat = 16
    private static let smallNative = CGSize(width: 158, height: 158)
    private static let mediumNative = CGSize(width: 338, height: 158)
    private static let largeNative = CGSize(width: 338, height: 354)

    private var showsEffects: Bool { edition.showsCardEffects }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if showsEffects {
                    if let header = edition.widgetPreviewHeader() {
                        header
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { previewExpanded.toggle() }
                    } label: {
                        HStack {
                            Text(L10n.tr("widgets.preview", lang))
                                .font(.subheadline.bold())
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .rotationEffect(.degrees(previewExpanded ? 90 : 0))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("widgets.previewToggle")
                }
                if !showsEffects || previewExpanded {
                    previewContent
                }
            }
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.tr("settings.widgetPreview", lang))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            CrownTick.prepare()
            let ids = previewAccountItems.map(\.id)
            if smallAccountID.isEmpty || !ids.contains(smallAccountID) {
                smallAccountID = ids.first ?? ""
            }
            if !overviewSelection.isEmpty {
                overviewSelection = overviewSelection.intersection(ids)
            }
        }
    }

    private var previewContent: some View {
            VStack(spacing: 20) {
                if isSimulated {
                    Text(L10n.tr("preview.simulated", lang))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else if !state.demoMode && previewAccountItems.isEmpty {
                    Text(L10n.tr("preview.noData", lang))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                VStack(spacing: 10) {
                    Text(L10n.tr("preview.small22", lang))
                        .font(.subheadline.bold())
                    AccountChipScroller(
                        items: previewAccountItems,
                        selection: $smallAccountID
                    )

                    previewCard(native: Self.smallNative, fillWidth: false) {
                        if let item = selectedSmallItem {
                            SmallUsageView(
                                provider: item.provider,
                                snapshot: display(for: item).snapshot,
                                now: Date(),
                                disabled: item.isCustom || isSimulated
                                    ? false
                                    : !state.isEnabled(item.provider),
                                title: item.title,
                                isCustom: item.isCustom,
                                tint: display(for: item).tint,
                                customLogoData: customLogo(for: item)
                            )
                        }
                    }
                }

                VStack(spacing: 10) {
                    Text(L10n.tr("preview.single24", lang))
                        .font(.subheadline.bold())
                    previewCard(native: Self.mediumNative) {
                        MediumUsageView(
                            items: selectedSmallItem.map { [display(for: $0)] } ?? [],
                            now: Date(), maxRows: 3
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("preview.large44", lang))
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                    overviewEditor
                    previewCard(native: Self.largeNative) {
                        MediumUsageView(
                            items: overviewDisplays(pickedIDs: orderedOverviewIDs),
                            now: Date(), maxRows: 4,
                            isLargeOverview: true
                        )
                    }
                }

                Text(L10n.tr("settings.addWidget.footer", lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
    }

    private var overviewEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("preview.pickProviders", lang))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            AccountChipScroller(
                items: previewAccountItems,
                selection: Binding(
                    get: { overviewSelection },
                    set: { overviewSelection = $0 }
                ),
                allowsMultiple: true
            )
        }
    }

    private var widgetBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            if let rim = edition.widgetPreviewRim(cornerRadius: 24) {
                rim
            }
        }
    }

    /// 2×2 用原生尺寸居中；2×4 / 4×4 拉到「屏宽 − 主屏边距」，等比缩放，边距与桌面小组件一致。
    @ViewBuilder
    private func previewCard<Content: View>(
        native: CGSize,
        fillWidth: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let card = content()
            .padding(14)
            .frame(width: native.width, height: native.height)
            .background(widgetBackground)
        if fillWidth {
            Color.clear
                .aspectRatio(native.width / native.height, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        let scale = max(geo.size.width, 1) / native.width
                        card
                            .scaleEffect(scale)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .padding(.horizontal, Self.homeScreenWidgetInset)
        } else {
            card.frame(maxWidth: .infinity)
        }
    }
}

/// 横向滚动的账号名条：同一服务商多个实例各一粒，滚动/点选时模拟表冠一格滴答。
struct AccountChipScroller: View {
    let items: [WidgetAccountItem]
    var allowsMultiple: Bool = false
    @Binding var selection: String
    @Binding var multiSelection: Set<String>
    @State private var scrollID: String?

    init(items: [WidgetAccountItem], selection: Binding<String>) {
        self.items = items
        self.allowsMultiple = false
        self._selection = selection
        self._multiSelection = .constant([])
    }

    init(items: [WidgetAccountItem], selection: Binding<Set<String>>, allowsMultiple: Bool) {
        self.items = items
        self.allowsMultiple = allowsMultiple
        self._selection = .constant(items.first?.id ?? "")
        self._multiSelection = selection
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    chip(item)
                        .id(item.id)
                }
            }
            .padding(.horizontal, 16)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollID)
        .onAppear {
            scrollID = allowsMultiple ? multiSelection.first : selection
        }
        .onChange(of: scrollID) { old, new in
            guard let new, let old, new != old else { return }
            CrownTick.play()
            if !allowsMultiple {
                selection = new
            }
        }
    }

    private func chip(_ item: WidgetAccountItem) -> some View {
        let on = allowsMultiple ? multiSelection.contains(item.id) : selection == item.id
        return Button {
            CrownTick.play()
            if allowsMultiple {
                if multiSelection.contains(item.id) {
                    multiSelection.remove(item.id)
                } else {
                    multiSelection.insert(item.id)
                }
            } else {
                selection = item.id
                scrollID = item.id
            }
        } label: {
            HStack(spacing: 5) {
                if item.isCustom {
                    CustomTemplateLogo(
                        data: item.extraAccountID.flatMap { extra in
                            SharedStore.shared.accounts.first { $0.id == extra }
                        }.flatMap { SharedStore.shared.customLogoData(for: $0) },
                        size: 14
                    )
                } else {
                    ProviderLogo(provider: item.provider, size: 14)
                }
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill)))
            .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("preview.chip.\(item.id)")
    }
}

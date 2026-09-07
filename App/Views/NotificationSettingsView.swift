import SwiftUI
import UsageLimitsCore

/// 提醒设置：每类提醒可选「统一配置」或「按供应商」；按供应商时用服务商下拉单独开关/阈值。
struct NotificationSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @State private var selectedProvider: ProviderID = .claude
    @State private var thresholdDraft: Double = 80
    @State private var prepaidDraft: Double = 10

    private var providers: [ProviderID] { state.providerOrder }

    var body: some View {
        Form {
            thresholdSection
            expirySection
            resetSection
            prepaidSection
        }
        .navigationTitle(L10n.tr("settings.notifications", lang))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadDrafts() }
        .onChange(of: selectedProvider) { _, _ in reloadDrafts() }
        .onChange(of: state.notificationSettings.thresholdScope) { _, new in
            if new == .perProvider { state.notificationSettings.seedProviderIfNeeded(selectedProvider) }
            reloadDrafts()
        }
        .onChange(of: state.notificationSettings.prepaidScope) { _, new in
            if new == .perProvider { state.notificationSettings.seedProviderIfNeeded(selectedProvider) }
            reloadDrafts()
        }
        .onChange(of: state.notificationSettings.expiryScope) { _, new in
            if new == .perProvider { state.notificationSettings.seedProviderIfNeeded(selectedProvider) }
        }
        .onChange(of: state.notificationSettings.resetScope) { _, new in
            if new == .perProvider { state.notificationSettings.seedProviderIfNeeded(selectedProvider) }
        }
    }

    // MARK: - Sections

    private var thresholdSection: some View {
        Section {
            scopePicker($state.notificationSettings.thresholdScope)
            if state.notificationSettings.thresholdScope == .perProvider {
                providerPicker
            }
            Toggle(
                L10n.tr("notify.threshold.toggle", lang),
                isOn: thresholdEnabledBinding
            )
            if thresholdEnabledBinding.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.tr("notify.threshold.percent", lang))
                        Spacer()
                        Text("\(UsagePresentation.roundedUsedPercent(thresholdDraft) ?? 0)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $thresholdDraft, in: 50...100, step: 5) { editing in
                        if !editing { commitThreshold(thresholdDraft) }
                    }
                }
            }
        } header: {
            Text(L10n.tr("notify.threshold.header", lang))
        } footer: {
            Text(L10n.tr("notify.threshold.footer", lang))
        }
    }

    private var expirySection: some View {
        Section {
            scopePicker($state.notificationSettings.expiryScope)
            if state.notificationSettings.expiryScope == .perProvider {
                providerPicker
            }
            Toggle(
                L10n.tr("notify.expiry.toggle", lang),
                isOn: expiryEnabledBinding
            )
            if expiryEnabledBinding.wrappedValue {
                Stepper(
                    L10n.tr("notify.expiry.days", lang, expiryDaysBinding.wrappedValue),
                    value: expiryDaysBinding,
                    in: 1...14
                )
            }
        } header: {
            Text(L10n.tr("notify.expiry.header", lang))
        } footer: {
            Text(L10n.tr("notify.expiry.footer", lang))
        }
    }

    private var resetSection: some View {
        Section {
            scopePicker($state.notificationSettings.resetScope)
            if state.notificationSettings.resetScope == .perProvider {
                providerPicker
            }
            Toggle(
                L10n.tr("notify.reset.toggle", lang),
                isOn: resetEnabledBinding
            )
        } header: {
            Text(L10n.tr("notify.reset.header", lang))
        } footer: {
            Text(L10n.tr("notify.reset.footer", lang))
        }
    }

    private var prepaidSection: some View {
        Section {
            scopePicker($state.notificationSettings.prepaidScope)
            if state.notificationSettings.prepaidScope == .perProvider {
                providerPicker
            }
            Toggle(
                L10n.tr("notify.prepaid.toggle", lang),
                isOn: prepaidEnabledBinding
            )
            if prepaidEnabledBinding.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.tr("notify.prepaid.amount", lang))
                        Spacer()
                        Text(prepaidAmountLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $prepaidDraft, in: 1...200, step: 1) { editing in
                        if !editing { commitPrepaid(prepaidDraft) }
                    }
                }
            }
        } header: {
            Text(L10n.tr("notify.prepaid.header", lang))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("notify.prepaid.footer", lang))
                Text(L10n.tr("notify.general.footer", lang))
            }
        }
    }

    private func scopePicker(_ binding: Binding<AlertScope>) -> some View {
        Picker(L10n.tr("notify.scope.unified", lang), selection: binding) {
            Text(L10n.tr("notify.scope.unified", lang)).tag(AlertScope.unified)
            Text(L10n.tr("notify.scope.perProvider", lang)).tag(AlertScope.perProvider)
        }
        .pickerStyle(.segmented)
    }

    /// Menu 而不是 Form Picker：选项和当前值都能在名称前放小 logo，且不会按素材原尺寸撑开。
    private var providerPicker: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("notify.provider", lang))
            Spacer(minLength: 8)
            Menu {
                ForEach(providers) { provider in
                    Button {
                        selectedProvider = provider
                    } label: {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: provider, size: 16)
                                .frame(width: 16, height: 16)
                                .clipped()
                            Text(provider.localizedName(lang))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    ProviderLogo(provider: selectedProvider, size: 18)
                        .frame(width: 18, height: 18)
                        .clipped()
                    Text(selectedProvider.localizedName(lang))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("notify.providerMenu")
        }
        .frame(maxHeight: 44)
        .accessibilityIdentifier("notify.providerPicker")
    }

    // MARK: - Bindings（每个字段按自己的 scope 读写）

    private var thresholdEnabledBinding: Binding<Bool> {
        fieldBinding(
            scope: state.notificationSettings.thresholdScope,
            getUnified: { $0.thresholdEnabled },
            setUnified: { $0.thresholdEnabled = $1 },
            getOver: { $0.thresholdEnabled },
            setOver: { $0.thresholdEnabled = $1 }
        )
    }

    private var expiryEnabledBinding: Binding<Bool> {
        fieldBinding(
            scope: state.notificationSettings.expiryScope,
            getUnified: { $0.expiryEnabled },
            setUnified: { $0.expiryEnabled = $1 },
            getOver: { $0.expiryEnabled },
            setOver: { $0.expiryEnabled = $1 }
        )
    }

    private var expiryDaysBinding: Binding<Int> {
        fieldBinding(
            scope: state.notificationSettings.expiryScope,
            getUnified: { $0.expiryDaysBefore },
            setUnified: { $0.expiryDaysBefore = $1 },
            getOver: { $0.expiryDaysBefore },
            setOver: { $0.expiryDaysBefore = $1 }
        )
    }

    private var resetEnabledBinding: Binding<Bool> {
        fieldBinding(
            scope: state.notificationSettings.resetScope,
            getUnified: { $0.resetEnabled },
            setUnified: { $0.resetEnabled = $1 },
            getOver: { $0.resetEnabled },
            setOver: { $0.resetEnabled = $1 }
        )
    }

    private var prepaidEnabledBinding: Binding<Bool> {
        fieldBinding(
            scope: state.notificationSettings.prepaidScope,
            getUnified: { $0.prepaidAmountEnabled },
            setUnified: { $0.prepaidAmountEnabled = $1 },
            getOver: { $0.prepaidAmountEnabled },
            setOver: { $0.prepaidAmountEnabled = $1 }
        )
    }

    private func fieldBinding<T>(
        scope: AlertScope,
        getUnified: @escaping (NotificationSettings) -> T,
        setUnified: @escaping (inout NotificationSettings, T) -> Void,
        getOver: @escaping (ProviderAlertConfig) -> T,
        setOver: @escaping (inout ProviderAlertConfig, T) -> Void
    ) -> Binding<T> {
        Binding(
            get: {
                if scope == .perProvider {
                    let cfg = state.notificationSettings.providerConfigs[selectedProvider.rawValue]
                        ?? .seeded(from: state.notificationSettings)
                    return getOver(cfg)
                }
                return getUnified(state.notificationSettings)
            },
            set: { value in
                if scope == .perProvider {
                    var cfg = state.notificationSettings.providerConfigs[selectedProvider.rawValue]
                        ?? .seeded(from: state.notificationSettings)
                    setOver(&cfg, value)
                    state.notificationSettings.upsert(selectedProvider, cfg)
                } else {
                    setUnified(&state.notificationSettings, value)
                }
            }
        )
    }

    private func commitThreshold(_ value: Double) {
        if state.notificationSettings.thresholdScope == .perProvider {
            var cfg = state.notificationSettings.providerConfigs[selectedProvider.rawValue]
                ?? .seeded(from: state.notificationSettings)
            cfg.thresholdPercent = value
            state.notificationSettings.upsert(selectedProvider, cfg)
        } else {
            state.notificationSettings.thresholdPercent = value
        }
    }

    private func commitPrepaid(_ value: Double) {
        if state.notificationSettings.prepaidScope == .perProvider {
            var cfg = state.notificationSettings.providerConfigs[selectedProvider.rawValue]
                ?? .seeded(from: state.notificationSettings)
            cfg.prepaidAmount = value
            state.notificationSettings.upsert(selectedProvider, cfg)
        } else {
            state.notificationSettings.prepaidAmount = value
        }
    }

    private func reloadDrafts() {
        let cfg = state.notificationSettings.resolved(for: selectedProvider)
        thresholdDraft = cfg.thresholdPercent
        prepaidDraft = cfg.prepaidAmount
    }

    /// 按供应商且已拿到额度币种才带符号；未拉取额度接口则只显示数字。
    private var prepaidAmountLabel: String {
        let currency: String?
        if state.notificationSettings.prepaidScope == .perProvider {
            currency = PrepaidCurrency.code(from: state.snapshot(selectedProvider))
        } else {
            currency = nil
        }
        return MoneyFormat.string(prepaidDraft, currency: currency)
    }
}

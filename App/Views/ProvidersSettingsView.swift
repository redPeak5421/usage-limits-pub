import SwiftUI
import UsageLimitsCore

/// 服务商二级菜单：预设服务商开关/排序 + 附加账号管理 + 新增供应商入口。
struct ProvidersSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @State private var showAddSheet = false
    /// 新增账号后立即弹出的登录页；账号行点「登录」也走这里。
    @State private var loginRequest: LoginRequest?
    @State private var tokenAccount: ProviderAccount?
    @State private var renamingAccount: ProviderAccount?
    @State private var renameText = ""
    @State private var tintEditingAccount: ProviderAccount?
    @State private var showResetTintsConfirm = false
    @State private var didHandleAutoRoute = false
    /// 已添加自定义账号长按 / 菜单：复用向导 editTemplate。
    @State private var editTemplate: CustomUsageTemplate?
    @State private var editMode: EditMode = .inactive

    /// 展示顺序即账号存储顺序；不按服务商重新聚组，所以可以穿插不同服务商。
    private var orderedAccounts: [ProviderAccount] {
        state.accounts
    }

    var body: some View {
        Form {
            Section {
                if orderedAccounts.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text(L10n.tr("providers.empty", lang))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else {
                    // 长按空白处拖动排序；长按弹出菜单删除；左滑登录/删除
                    ForEach(orderedAccounts) { account in
                        accountRow(account)
                    }
                    .onMove { from, to in
                        state.applyAccountOrder(
                            AccountOrder.moving(state.accounts, fromOffsets: from, toOffset: to)
                        )
                    }
                }
            } header: {
                Text(L10n.tr("providers.accounts", lang))
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.tr("providers.add", lang), systemImage: "plus.circle.fill")
                }
                Button(role: .destructive) {
                    showResetTintsConfirm = true
                } label: {
                    Label(L10n.tr("providers.resetTints", lang), systemImage: "paintbrush")
                }
            }
        }
        .confirmationDialog(
            L10n.tr("providers.resetTints.confirm", lang),
            isPresented: $showResetTintsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("providers.resetTints", lang), role: .destructive) {
                state.resetAllCustomTints()
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            if orderedAccounts.count >= 2 {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.tr(editMode.isEditing ? "providers.reorderDone" : "providers.reorder", lang)) {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.tr("settings.providers", lang))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet(
                openCustomWizard: {
                    if case .customWizard = state.autoRoute { return true }
                    return ProcessInfo.processInfo.arguments.contains("--open-custom-wizard")
                }()
            ) { provider, name in
                let account = state.addAccount(provider: provider, name: name)
                loginRequest = loginRequestFor(account)
            }
        }
        .sheet(item: $tokenAccount) { account in
            CustomTokenSheet(account: account)
        }
        .sheet(item: $editTemplate) { template in
            CustomUsageWizardView(mode: .editTemplate(template))
        }
        .sheet(item: $loginRequest) { request in
            LoginSheetView(request: request)
                .onDisappear {
                    if let account = request.account {
                        Task { await state.refreshAccount(account) }
                    } else {
                        Task { await state.refresh(request.provider) }
                    }
                }
        }
        .sheet(item: $tintEditingAccount) { account in
            ColorEditorSheet(
                title: state.store.displayName(for: account),
                current: account.tint,
                // 清除账号覆盖后的回落：供应商默认 → 内置品牌色
                fallback: account.isCustom
                    ? TintResolver.resolve(accountTint: nil)
                    : TintResolver.resolve(
                        accountTint: nil,
                        provider: account.provider ?? .claude,
                        overrides: state.providerTintOverrides
                    ),
                onSave: { state.setAccountTint(account, tint: $0) }
            )
        }
        .alert(
            L10n.tr("providers.customName", lang),
            isPresented: Binding(
                get: { renamingAccount != nil },
                set: { if !$0 { renamingAccount = nil } }
            )
        ) {
            TextField(L10n.tr("providers.customName", lang), text: $renameText)
            Button(L10n.tr("account.rename", lang)) {
                if let account = renamingAccount {
                    state.renameAccount(account.id, to: renameText)
                }
                renamingAccount = nil
            }
            Button(L10n.tr("login.close", lang), role: .cancel) { renamingAccount = nil }
        }
        .onAppear {
            // --open-add-provider / --open-custom-wizard：进入本页直接弹出选择器
            if !didHandleAutoRoute {
                switch state.autoRoute {
                case .providersSettings(addSheet: true), .customWizard:
                    didHandleAutoRoute = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        showAddSheet = true
                    }
                default:
                    break
                }
            }
            // --open-tint-editor：直接打开首个账号的主题色编辑器（自动化验证用）
            if ProcessInfo.processInfo.arguments.contains("--open-tint-editor"),
               !didHandleAutoRoute, let first = state.accounts.first {
                didHandleAutoRoute = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    tintEditingAccount = first
                }
            }
        }
    }

    /// 已添加自定义账号：打开现有向导的编辑模板模式。内置账号不走这里。
    private func openEditTemplate(for account: ProviderAccount) {
        guard account.isCustom,
              let templateID = account.templateID,
              let template = state.customTemplates.first(where: { $0.id == templateID }) else { return }
        editTemplate = template
    }

    /// 主账号的登录请求走服务商级（default dataStore），附加账号走独立 dataStore。
    private func loginRequestFor(_ account: ProviderAccount) -> LoginRequest? {
        guard let provider = account.provider else { return nil }
        return account.isPrimary ? LoginRequest(provider: provider) : LoginRequest(account: account)
    }

    private func accountRow(_ account: ProviderAccount) -> some View {
        let snap: ProviderSnapshot?
        if account.isPrimary, let provider = account.provider {
            snap = state.snapshot(provider)
        } else {
            snap = state.accountSnapshots[account.id]
        }
        let loggedIn = snap?.status.isOK == true
        return HStack(spacing: 8) {
            if let provider = account.provider {
                ProviderLogo(provider: provider, size: 16)
            } else {
                CustomTemplateLogo(
                    data: state.customLogoData(for: account),
                    size: 16,
                    fallbackTint: state.resolvedTint(for: account).representativeColor
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.store.displayName(for: account))
                Text(accountSubtitle(account))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 左滑三键已满，改色走这里；放在状态文字前，各行位置对齐，也不夹在 logo 和名称之间。
            accountTintButton(account)
            Text(accountStatusLabel(account, loggedIn: loggedIn))
                .font(.caption)
                .foregroundStyle(isAccountActive(account) ? (loggedIn ? .green : .secondary) : .orange)
        }
        .opacity(isAccountActive(account) ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture {
            renameText = account.name
            renamingAccount = account
        }
        // 长按弹出操作菜单（删除/重命名/登录）；长按后直接拖动仍是排序。
        // 自定义账号：菜单第一项是编辑模板，内置账号不进向导。
        .contextMenu {
            if account.isCustom {
                Button {
                    openEditTemplate(for: account)
                } label: {
                    Label(L10n.tr("custom.wizard.editTemplate", lang), systemImage: "slider.horizontal.3")
                }
            }
            Button {
                renameText = account.name
                renamingAccount = account
            } label: {
                Label(L10n.tr("account.rename", lang), systemImage: "pencil")
            }
            if account.isCustom {
                Button {
                    tokenAccount = account
                } label: {
                    Label(L10n.tr("card.updateToken", lang), systemImage: "key")
                }
            } else {
                Button {
                    loginRequest = loginRequestFor(account)
                } label: {
                    Label(L10n.tr("account.login", lang), systemImage: "person.crop.circle")
                }
            }
            Button {
                tintEditingAccount = account
            } label: {
                Label(L10n.tr("tint.menu", lang), systemImage: "paintpalette")
            }
            Button {
                state.setAccountEnabled(account, enabled: !isAccountActive(account))
            } label: {
                Label(
                    L10n.tr(isAccountActive(account) ? "account.disable" : "account.enable", lang),
                    systemImage: isAccountActive(account) ? "pause.circle" : "play.circle"
                )
            }
            Button(role: .destructive) {
                Task { await state.removeAccount(account) }
            } label: {
                Label(L10n.tr("account.delete", lang), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await state.removeAccount(account) }
            } label: {
                Label(L10n.tr("account.delete", lang), systemImage: "trash")
            }
            Button {
                state.setAccountEnabled(account, enabled: !isAccountActive(account))
            } label: {
                Label(
                    L10n.tr(isAccountActive(account) ? "account.disable" : "account.enable", lang),
                    systemImage: isAccountActive(account) ? "pause.circle" : "play.circle"
                )
            }
            .tint(isAccountActive(account) ? .orange : .green)
            if account.isCustom {
                Button {
                    tokenAccount = account
                } label: {
                    Label(L10n.tr("card.updateToken", lang), systemImage: "key")
                }
                .tint(.blue)
            } else {
                Button {
                    loginRequest = loginRequestFor(account)
                } label: {
                    Label(L10n.tr("account.login", lang), systemImage: "person.crop.circle")
                }
                .tint(.blue)
            }
        }
    }

    private func accountSubtitle(_ account: ProviderAccount) -> String {
        if let templateID = account.templateID,
           let template = state.customTemplates.first(where: { $0.id == templateID }) {
            let host = template.requestHost
            return host.isEmpty ? template.name : "\(template.name) · \(host)"
        }
        return account.provider?.localizedVendor(lang) ?? state.store.displayName(for: account)
    }

    /// 调色盘按当前主题色着色：一看就是改颜色，不会被当成状态圆点。
    private func accountTintButton(_ account: ProviderAccount) -> some View {
        TintPaletteButton(
            tint: state.resolvedTint(for: account),
            accessibilityLabel: L10n.tr("tint.menu", lang),
            accessibilityIdentifier: "account.tintChip"
        ) {
            tintEditingAccount = account
        }
    }

    private func isAccountActive(_ account: ProviderAccount) -> Bool {
        AccountVisibility.shouldShowOnHome(
            account, providerEnabled: state.isProviderEnabled(for: account)
        )
    }

    private func accountStatusLabel(_ account: ProviderAccount, loggedIn: Bool) -> String {
        if !isAccountActive(account) { return L10n.tr("account.disabled", lang) }
        if loggedIn { return L10n.tr("account.loggedIn", lang) }
        return L10n.tr(account.isCustom ? "custom.noNumeric" : "card.notLoggedIn", lang)
    }
}

/// 「新增供应商」选择器：官方供应商按名称排序（logo + 名）+ 已存模板 + Bearer 预设（logo + 名）+ 自定义向导。
/// 选中官方后出现自定义名称与「添加并登录」；选中自定义后「开始配置」。
struct AddProviderSheet: View {
    var onAdd: (ProviderID, String) -> Void
    var openCustomWizard: Bool
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var selected: ProviderID?
    @State private var customSelected: Bool
    @State private var name = ""
    @State private var showWizard: Bool
    /// 左滑「默认颜色」：设供应商级默认色，同供应商后续新增账号自动继承。
    @State private var tintEditingProvider: ProviderID?
    @State private var addAccountTemplate: CustomUsageTemplate?
    @State private var editTemplate: CustomUsageTemplate?
    @State private var tintEditingTemplate: CustomUsageTemplate?
    @State private var templateDeleteBlocked: CustomUsageTemplate?
    @State private var selectedPreset: CustomUsagePreset?
    @FocusState private var nameFocused: Bool

    init(openCustomWizard: Bool = false, onAdd: @escaping (ProviderID, String) -> Void) {
        self.onAdd = onAdd
        self.openCustomWizard = openCustomWizard
        let args = LaunchArguments()
        let startWizard = openCustomWizard || args.contains("--open-custom-wizard")
        _customSelected = State(initialValue: startWizard || args.contains("--select-custom"))
        _showWizard = State(initialValue: startWizard)
        if let raw = args.value(after: "--select-provider"), let provider = ProviderID(rawValue: raw) {
            _selected = State(initialValue: provider)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(catalogEntries) { entry in
                        switch entry {
                        case .official(let provider):
                            presetRow(provider)
                        case .template(let template):
                            savedTemplateRow(template)
                        case .preset(let preset):
                            bearerPresetRow(preset)
                        case .custom:
                            customRow
                        }
                    }
                } header: {
                    Text(L10n.tr("providers.choose", lang))
                } footer: {
                    Text(L10n.tr("providers.choose.tintHint", lang))
                }

            }
            .navigationTitle(L10n.tr("providers.add", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                addActionBar
            }
            .sheet(item: $tintEditingProvider) { provider in
                ColorEditorSheet(
                    title: provider.localizedVendor(lang),
                    current: state.providerTintOverrides[provider.rawValue],
                    fallback: provider.builtinTint,
                    onSave: { state.setProviderTint(provider, tint: $0) }
                )
            }
            .sheet(isPresented: $showWizard) {
                CustomUsageWizardView(mode: .create) { _ in
                    dismiss()
                }
            }
            .sheet(item: $selectedPreset) { preset in
                CustomUsageWizardView(mode: .create, initialPreset: preset) { _ in
                    dismiss()
                }
            }
            .sheet(item: $addAccountTemplate) { template in
                CustomUsageWizardView(mode: .addAccount(template)) { _ in
                    dismiss()
                }
            }
            .sheet(item: $editTemplate) { template in
                CustomUsageWizardView(mode: .editTemplate(template))
            }
            .sheet(item: $tintEditingTemplate) { template in
                ColorEditorSheet(
                    title: template.name,
                    current: template.tint,
                    fallback: TintResolver.customDefault,
                    onSave: { state.setTemplateTint(template, tint: $0) }
                )
            }
            .alert(
                L10n.tr("custom.template.delete", lang),
                isPresented: Binding(
                    get: { templateDeleteBlocked != nil },
                    set: { if !$0 { templateDeleteBlocked = nil } }
                )
            ) {
                Button(L10n.tr("login.close", lang), role: .cancel) { templateDeleteBlocked = nil }
            } message: {
                Text(L10n.tr("custom.template.inUse", lang))
            }
        }
    }

    @ViewBuilder
    private var addActionBar: some View {
        if customSelected {
            VStack(spacing: 8) {
                Text(L10n.tr("providers.custom.footer", lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showWizard = true
                } label: {
                    Text(L10n.tr("providers.startSetup", lang))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        } else if let selected {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("providers.customName", lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: "pencil")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(defaultName(selected), text: $name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .focused($nameFocused)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                        .accessibilityLabel(L10n.tr("providers.customName", lang))
                    if !name.isEmpty {
                        Button {
                            name = ""
                            nameFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle().inset(by: -10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("providers.clearName", lang))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 50)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(nameFocused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.1), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                Button {
                    onAdd(selected, name.isEmpty ? defaultName(selected) : name)
                    dismiss()
                } label: {
                    Text(L10n.tr("providers.addAndLogin", lang))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }


    private var catalogProviders: [ProviderID] {
        ProviderCatalog.sortedProviders(lang)
    }

    private var catalogPresets: [CustomUsagePreset] {
        ProviderCatalog.sortedPresets(lang)
    }

    private var savedTemplates: [CustomUsageTemplate] {
        ProviderCatalog.sortedTemplates(state.customTemplates, language: lang)
    }

    private enum AddCatalogEntry: Identifiable {
        case official(ProviderID)
        case template(CustomUsageTemplate)
        case preset(CustomUsagePreset)
        case custom

        var id: String {
            switch self {
            case .official(let provider): return "official.\(provider.rawValue)"
            case .template(let template): return "template.\(template.id.uuidString)"
            case .preset(let preset): return "preset.\(preset.id)"
            case .custom: return "custom"
            }
        }
    }

    private var catalogEntries: [AddCatalogEntry] {
        let items: [AddCatalogEntry] =
            catalogProviders.map { .official($0) }
            + savedTemplates.map { .template($0) }
            + catalogPresets.map { .preset($0) }
            + [.custom]
        return items.sorted { lhs, rhs in
            ProviderCatalog.compare(catalogTitle(lhs), catalogTitle(rhs), language: lang)
        }
    }

    private func catalogTitle(_ item: AddCatalogEntry) -> String {
        switch item {
        case .official(let provider): return provider.localizedName(lang)
        case .template(let template): return template.name
        case .preset(let preset): return preset.localizedName(lang)
        case .custom: return L10n.tr("providers.custom", lang)
        }
    }

    private func bearerPresetRow(_ preset: CustomUsagePreset) -> some View {
        Button {
            customSelected = false
            selected = nil
            selectedPreset = preset
        } label: {
            HStack(spacing: 10) {
                CatalogMark(assetName: preset.logoAssetName, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.localizedName(lang))
                            .foregroundStyle(.primary)
                        if preset.experimental {
                            Text(L10n.tr("providers.preset.experimental", lang))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(preset.requestURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func savedTemplateRow(_ template: CustomUsageTemplate) -> some View {
        let tint = TintResolver.resolve(accountTint: nil, templateTint: template.tint)
        return HStack(spacing: 8) {
            Button {
                customSelected = false
                selected = nil
                addAccountTemplate = template
            } label: {
                HStack(spacing: 10) {
                    CustomTemplateLogo(
                        data: state.customLogoData(for: template),
                        size: 20,
                        fallbackTint: tint.representativeColor
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                            .foregroundStyle(.primary)
                        Text(template.requestHost)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                tintEditingTemplate = template
            } label: {
                ProviderTintWell(tint: tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.tr("tint.providerDefault", lang))
        }
        .contextMenu {
            Button {
                addAccountTemplate = template
            } label: {
                Label(L10n.tr("custom.template.addAccount", lang), systemImage: "plus.circle")
            }
            Button {
                editTemplate = template
            } label: {
                Label(L10n.tr("custom.wizard.editTemplate", lang), systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTemplate(template)
            } label: {
                Label(L10n.tr("custom.template.delete", lang), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTemplate(template)
            } label: {
                Label(L10n.tr("custom.template.delete", lang), systemImage: "trash")
            }
            Button {
                tintEditingTemplate = template
            } label: {
                Label(L10n.tr("tint.providerDefault", lang), systemImage: "paintpalette")
            }
            .tint(.indigo)
        }
    }

    private func deleteTemplate(_ template: CustomUsageTemplate) {
        if state.store.accounts(referencingTemplate: template.id).isEmpty {
            _ = state.removeCustomTemplate(id: template.id)
        } else {
            templateDeleteBlocked = template
        }
    }

    private func presetRow(_ provider: ProviderID) -> some View {
        // 名称区与色环是并列按钮：点名称选供应商，点色环改默认色，互不抢手势。
        HStack(spacing: 8) {
            Button {
                // 自定义选中时预设仍可点：点选即切回预设流程
                customSelected = false
                selected = provider
                name = ""
            } label: {
                HStack(spacing: 10) {
                    ProviderLogo(provider: provider, size: 20)
                    Text(provider.localizedName(lang))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            providerTintChip(provider)

            if selected == provider, !customSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                tintEditingProvider = provider
            } label: {
                Label(L10n.tr("tint.providerDefault", lang), systemImage: "paintpalette")
            }
            .tint(.indigo)
        }
    }

    /// 实心圆 + 外环；渐变色走外环一圈，纯色则内外同色。
    private func providerTintChip(_ provider: ProviderID) -> some View {
        let tint = TintResolver.resolve(
            accountTint: nil, provider: provider,
            overrides: state.providerTintOverrides
        )
        return Button {
            tintEditingProvider = provider
        } label: {
            ProviderTintWell(tint: tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.tr("tint.providerDefault", lang))
        .accessibilityIdentifier("providers.tintChip.\(provider.rawValue)")
    }

    private var customRow: some View {
        Button {
            customSelected.toggle()
            if customSelected { selected = nil }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(L10n.tr("providers.custom", lang))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if customSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 默认名：首个账号用产品名；同服务商再加时用「供应商名 N」（N 从 2 起）。
    private func defaultName(_ provider: ProviderID) -> String {
        if state.primaryAccount(provider) == nil {
            return provider.localizedName(lang)
        }
        return "\(provider.localizedVendor(lang)) \(state.extraAccounts(of: provider).count + 2)"
    }
}

/// 新增供应商改色：大实心芯 + 细色环。环太粗、芯太小会像单选钮。
private enum AddProviderTintChip {
    static let size: CGFloat = 26
    static let inner: CGFloat = 17
    static let ringWidth: CGFloat = 2
}

private struct ProviderTintWell: View {
    let tint: BrandTint

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ringGradient, lineWidth: AddProviderTintChip.ringWidth)
            Circle()
                .fill(tint.startColor)
                .frame(width: AddProviderTintChip.inner, height: AddProviderTintChip.inner)
        }
        .frame(width: AddProviderTintChip.size, height: AddProviderTintChip.size)
    }

    private var ringGradient: AngularGradient {
        if tint.isGradient {
            return AngularGradient(
                colors: [tint.startColor, tint.endColor, tint.startColor],
                center: .center
            )
        }
        return AngularGradient(colors: [tint.startColor, tint.startColor], center: .center)
    }
}

/// 账号列表改色入口：调色盘按当前色着色。
private struct TintPaletteButton: View {
    let tint: BrandTint
    let accessibilityLabel: String
    var accessibilityIdentifier: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paintpalette.fill")
                .font(.body)
                .foregroundStyle(tint.swatchFill)
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

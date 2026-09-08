import SwiftUI
import PhotosUI
import UIKit
import UsageLimitsCore

/// 自定义用量向导：新建模板、从模板加账号、改模板（须重测）。
struct CustomUsageWizardView: View {
    enum Mode: Identifiable {
        case create
        case addAccount(CustomUsageTemplate)
        case editTemplate(CustomUsageTemplate)

        var id: String {
            switch self {
            case .create: return "create"
            case .addAccount(let template): return "add.\(template.id.uuidString)"
            case .editTemplate(let template): return "edit.\(template.id.uuidString)"
            }
        }
    }

    let mode: Mode
    var initialPreset: CustomUsagePreset? = nil
    var onFinished: ((ProviderAccount?) -> Void)?

    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss

    private struct FieldDraft: Equatable {
        var displayName: String
        var isSelected: Bool
        var role: CustomFieldRole = .other
    }

    /// 本次测试自动勾选的路径（提示用）。
    @State private var autoPicked: [String] = []

    @State private var name = ""
    @State private var urlText = "https://"
    @State private var token = ""
    @State private var drafts: [String: FieldDraft] = [:]
    @State private var testing = false
    @State private var testStatus: Int?
    @State private var testBytes = 0
    @State private var preview: CustomJSONPreviewResult?
    @State private var errorMessage: String?
    @State private var testSucceeded = false
    @State private var logoData: Data?
    @State private var logoIsManual = false
    @State private var photoItem: PhotosPickerItem?

    private var navigationTitle: String {
        switch mode {
        case .create: return L10n.tr("custom.wizard.title", lang)
        case .addAccount: return L10n.tr("custom.template.addAccount", lang)
        case .editTemplate: return L10n.tr("custom.wizard.editTemplate", lang)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                connectSection
                if showsMapping {
                    testSection
                    if let preview {
                        mappingSection(preview)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
                saveSection
            }
            .readableWidth()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var showsMapping: Bool {
        switch mode {
        case .addAccount: return false
        case .create, .editTemplate: return true
        }
    }

    private var connectSection: some View {
        Section {
            TextField(L10n.tr("custom.wizard.name", lang), text: $name)
            if showsMapping {
                TextField(L10n.tr("custom.wizard.url", lang), text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                chipRow
            }
            SecureField(L10n.tr("custom.token.placeholder", lang), text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if showsMapping {
                iconRow
            }
        } footer: {
            if initialPreset != nil {
                Text(L10n.tr("custom.wizard.presetHint", lang))
            } else {
                Text(showsMapping ? L10n.tr("providers.custom.footer", lang) : L10n.tr("custom.token.footer", lang))
            }
        }
    }

    private var iconRow: some View {
        HStack(spacing: 12) {
            CustomTemplateLogo(
                data: logoData,
                size: 36,
                fallbackTint: Color.secondary
            )
            VStack(alignment: .leading, spacing: 6) {
                PhotosPicker(
                    selection: $photoItem,
                    matching: .images
                ) {
                    Text(L10n.tr(logoData == nil ? "custom.wizard.chooseIcon" : "custom.wizard.replaceIcon", lang))
                }
                .onChange(of: photoItem) { _, item in
                    Task { await loadPickedIcon(item) }
                }
                if logoData != nil {
                    Button(L10n.tr("custom.wizard.clearIcon", lang), role: .destructive) {
                        logoData = nil
                        logoIsManual = false
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            chip("/v1/usage")
            chip("/api/usage")
        }
    }

    private func chip(_ path: String) -> some View {
        Button(path) { applyChip(path) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await runTest() }
            } label: {
                if testing {
                    HStack {
                        ProgressView()
                        Text(L10n.tr("custom.wizard.testing", lang))
                    }
                } else {
                    Label(L10n.tr("custom.wizard.test", lang), systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            .disabled(testing || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let testStatus {
                Text(L10n.tr("custom.wizard.status", lang, testStatus, testBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .editTemplate = mode {
                Text(L10n.tr("custom.wizard.retestRequired", lang))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func mappingSection(_ preview: CustomJSONPreviewResult) -> some View {
        Section {
            if preview.leaves.isEmpty {
                Text(preview.error.map { L10n.tr($0, lang) } ?? L10n.tr("custom.wizard.needField", lang))
                    .foregroundStyle(.secondary)
            } else {
                if !autoPicked.isEmpty {
                    Label(L10n.tr("custom.wizard.autoPicked", lang, autoPicked.count), systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(groupedLeaves(preview.leaves), id: \.parent) { group in
                    if !group.parent.isEmpty || groupedLeaves(preview.leaves).count > 1 {
                        Text(group.parent.isEmpty ? L10n.tr("custom.wizard.rootGroup", lang) : group.parent)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(group.leaves, id: \.path) { leaf in
                        leafRow(leaf)
                    }
                }
            }
            if preview.truncated {
                Text(L10n.tr("custom.wizard.truncated", lang))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.tr("custom.wizard.pickHint", lang))
        }
    }

    private struct LeafGroup {
        var parent: String
        var leaves: [JSONNumberLeaf]
    }

    /// 按父路径分组，保持原顺序；深层结构一眼能看出哪些字段属于同一对象。
    private func groupedLeaves(_ leaves: [JSONNumberLeaf]) -> [LeafGroup] {
        var order: [String] = []
        var map: [String: [JSONNumberLeaf]] = [:]
        for leaf in leaves {
            let parent = parentPath(of: leaf.path)
            if map[parent] == nil { order.append(parent) }
            map[parent, default: []].append(leaf)
        }
        return order.map { LeafGroup(parent: $0, leaves: map[$0] ?? []) }
    }

    private func parentPath(of path: String) -> String {
        var s = path
        while s.hasSuffix("]"), let open = s.lastIndex(of: "[") { s = String(s[..<open]) }
        guard let dot = s.lastIndex(of: ".") else { return "" }
        return String(s[..<dot])
    }

    private func leafRow(_ leaf: JSONNumberLeaf) -> some View {
        let selected = drafts[leaf.path]?.isSelected == true
        let role = drafts[leaf.path]?.role ?? leaf.hint.role
        let recommended = autoPicked.contains(leaf.path)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    toggleSelected(leaf.path)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("custom.wizard.pickHint", lang))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                Text(CustomFieldSemantics.lastKey(of: leaf.path))
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                if role != .other {
                    roleBadge(role, highlighted: selected)
                }
                if recommended, !selected {
                    Text(L10n.tr("custom.wizard.recommended", lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text(leaf.rawDisplay)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if selected {
                HStack(spacing: 8) {
                    TextField(
                        L10n.tr("custom.wizard.displayName", lang),
                        text: displayNameBinding(for: leaf.path)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Menu {
                        Picker(L10n.tr("custom.wizard.role", lang), selection: roleBinding(for: leaf.path, fallback: leaf.hint.role)) {
                            ForEach(CustomFieldRole.allCases, id: \.self) { candidate in
                                Text(L10n.tr(candidate.localizationKey, lang)).tag(candidate)
                            }
                        }
                    } label: {
                        roleBadge(role, highlighted: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func roleBadge(_ role: CustomFieldRole, highlighted: Bool) -> some View {
        Text(L10n.tr(role.localizationKey, lang))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(highlighted ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill)))
            .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
            .lineLimit(1)
    }

    private func roleBinding(for path: String, fallback: CustomFieldRole) -> Binding<CustomFieldRole> {
        Binding(
            get: { drafts[path]?.role ?? fallback },
            set: { newValue in
                var draft = drafts[path] ?? FieldDraft(
                    displayName: CustomUsageTemplate.defaultDisplayName(for: path),
                    isSelected: true
                )
                // 展示名仍是旧角色默认值时，跟着角色换
                let oldDefault = CustomFieldSemantics.defaultDisplayName(path: path, role: draft.role, language: lang)
                if draft.displayName == oldDefault {
                    draft.displayName = CustomFieldSemantics.defaultDisplayName(path: path, role: newValue, language: lang)
                }
                draft.role = newValue
                drafts[path] = draft
            }
        )
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                Text(saveTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .disabled(!canSave)
        } footer: {
            if let saveDisabledHint {
                Text(saveDisabledHint)
            }
        }
        .listRowBackground(Color.clear)
    }

    /// 测试已成功但还没勾字段时，把禁用原因写在按钮下方。
    private var saveDisabledHint: String? {
        guard showsMapping, testSucceeded, selectedFields().isEmpty else { return nil }
        if let preview, preview.leaves.isEmpty { return nil }
        return L10n.tr("custom.wizard.saveHint", lang)
    }

    private var saveTitle: String {
        switch mode {
        case .create: return L10n.tr("custom.wizard.save", lang)
        case .addAccount: return L10n.tr("custom.wizard.addAccount", lang)
        case .editTemplate: return L10n.tr("custom.wizard.saveTemplate", lang)
        }
    }

    private var canSave: Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return false }
        switch mode {
        case .addAccount:
            return true
        case .create:
            return testSucceeded && !selectedFields().isEmpty
        case .editTemplate:
            return testSucceeded && !selectedFields().isEmpty
        }
    }

    private func prefill() {
        switch mode {
        case .create:
            if let preset = initialPreset {
                name = preset.localizedName(lang)
                urlText = preset.requestURL
            }
        case .addAccount(let template):
            name = template.name
        case .editTemplate(let template):
            name = template.name
            urlText = template.requestURL
            drafts = Dictionary(uniqueKeysWithValues: template.fields.map {
                ($0.path, FieldDraft(displayName: $0.displayName, isSelected: true, role: $0.role ?? .other))
            })
            logoIsManual = template.logoIsManual
            logoData = state.customLogoData(for: template)
            if let account = state.accounts.first(where: { $0.templateID == template.id }),
               let existing = state.store.accountToken(for: account.id) {
                token = existing
            }
        }
    }

    @MainActor
    private func loadPickedIcon(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let png = image.pngData()
        else { return }
        logoData = png
        logoIsManual = true
    }

    private func applyChip(_ path: String) {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            urlText = "https://example.com\(path)"
            return
        }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.port = url.port
        parts.path = path
        urlText = parts.string ?? trimmed
    }

    @MainActor
    private func runTest() async {
        errorMessage = nil
        testSucceeded = false
        preview = nil
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sanitized = CustomUsageTemplate.sanitizedURLString(urlText),
              let url = URL(string: sanitized) else {
            errorMessage = L10n.tr("custom.wizard.httpsOnly", lang)
            return
        }
        testing = true
        defer { testing = false }
        let client = CustomUsageClient(
            session: CustomUsageClient.makeSession(timeout: CustomUsageClient.wizardTimeout),
            timeout: CustomUsageClient.wizardTimeout
        )
        let probe = await client.fetch(url: url, token: trimmedToken)
        testStatus = probe.status
        testBytes = probe.body.utf8.count
        if !(200..<300).contains(probe.status) {
            errorMessage = CustomUsageClient.wizardFailureMessage(
                status: probe.status, body: probe.body, language: lang
            )
            return
        }
        let result = CustomJSONPreview.preview(body: probe.body)
        preview = result
        if let error = result.error {
            errorMessage = L10n.tr(error, lang)
            return
        }
        testSucceeded = true
        urlText = sanitized
        mergeDrafts(from: result.leaves)
        if CustomUsageLogoPolicy.shouldResolveOnTest(hasExistingLogo: logoData != nil) {
            let resolved = await client.resolveTemplateLogo(from: url)
            if let resolved {
                logoData = resolved
            }
        }
    }

    /// 首次测试（还没有任何勾选）时按语义分数自动勾选前几条；已有勾选只补新叶子。
    private func mergeDrafts(from leaves: [JSONNumberLeaf]) {
        var next = drafts
        let hasSelection = next.values.contains { $0.isSelected }
        let suggested = hasSelection
            ? []
            : CustomFieldSemantics.suggestedPaths(leaves.map { (path: $0.path, hint: $0.hint) })
        for leaf in leaves {
            if var existing = next[leaf.path] {
                if existing.role == .other, leaf.hint.role != .other { existing.role = leaf.hint.role }
                next[leaf.path] = existing
                continue
            }
            next[leaf.path] = FieldDraft(
                displayName: CustomFieldSemantics.defaultDisplayName(path: leaf.path, role: leaf.hint.role, language: lang),
                isSelected: suggested.contains(leaf.path),
                role: leaf.hint.role
            )
        }
        if let preset = initialPreset {
            var matched: [String] = []
            for field in preset.fields {
                guard var draft = next[field.path] else { continue }
                draft.isSelected = true
                let localized = preset.localizedFieldName(path: field.path, language: lang)
                if !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.displayName = localized
                }
                if let role = field.role { draft.role = role }
                next[field.path] = draft
                matched.append(field.path)
            }
            if !matched.isEmpty { autoPicked = matched } else { autoPicked = suggested }
        } else {
            autoPicked = suggested
        }
        drafts = next
    }

    private func toggleSelected(_ path: String) {
        let hint = preview?.leaves.first { $0.path == path }?.hint
        var draft = drafts[path] ?? FieldDraft(
            displayName: CustomFieldSemantics.defaultDisplayName(path: path, role: hint?.role ?? .other, language: lang),
            isSelected: false,
            role: hint?.role ?? .other
        )
        draft.isSelected.toggle()
        drafts[path] = draft
    }

    private func displayNameBinding(for path: String) -> Binding<String> {
        Binding(
            get: {
                drafts[path]?.displayName ?? CustomUsageTemplate.defaultDisplayName(for: path)
            },
            set: { newValue in
                var draft = drafts[path] ?? FieldDraft(displayName: newValue, isSelected: false)
                draft.displayName = newValue
                drafts[path] = draft
            }
        )
    }

    private func selectedFields() -> [CustomUsageField] {
        guard let preview else { return [] }
        return preview.leaves.compactMap { leaf in
            guard let draft = drafts[leaf.path], draft.isSelected else { return nil }
            let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let role = draft.role == .other ? nil : draft.role
            return CustomUsageField(
                path: leaf.path,
                displayName: name.isEmpty
                    ? CustomFieldSemantics.defaultDisplayName(path: leaf.path, role: draft.role, language: lang)
                    : name,
                role: role,
                currency: leaf.hint.currency ?? initialPreset?.fields.first(where: { $0.path == leaf.path })?.currency
            )
        }
    }

    private func save() {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .create:
            guard let template = CustomUsageTemplate(
                name: trimmedName.isEmpty ? L10n.tr("providers.custom", lang) : trimmedName,
                requestURL: urlText,
                fields: selectedFields()
            ) else {
                errorMessage = L10n.tr("custom.wizard.needField", lang)
                return
            }
            let account = state.addCustomAccount(template: template, name: trimmedName, token: trimmedToken)
            persistLogo(templateID: template.id)
            Task { await state.refreshAccount(account, allowWhenDisabled: true) }
            onFinished?(account)
            dismiss()
        case .addAccount(let template):
            let account = state.addCustomAccount(template: template, name: trimmedName, token: trimmedToken)
            Task { await state.refreshAccount(account, allowWhenDisabled: true) }
            onFinished?(account)
            dismiss()
        case .editTemplate(let old):
            guard testSucceeded else {
                errorMessage = L10n.tr("custom.wizard.retestRequired", lang)
                return
            }
            guard let updated = CustomUsageTemplate(
                id: old.id,
                name: trimmedName.isEmpty ? old.name : trimmedName,
                requestURL: urlText,
                fields: selectedFields(),
                createdAt: old.createdAt
            ) else {
                errorMessage = L10n.tr("custom.wizard.needField", lang)
                return
            }
            var next = updated
            next.logoRelativePath = old.logoRelativePath
            next.logoIsManual = old.logoIsManual
            next.tint = old.tint
            if !state.replaceCustomTemplate(next) {
                errorMessage = L10n.tr("custom.wizard.retestRequired", lang)
                return
            }
            persistLogo(templateID: old.id)
            onFinished?(nil)
            dismiss()
        }
    }

    private func persistLogo(templateID: UUID) {
        state.setCustomLogo(templateID: templateID, data: logoData, isManual: logoIsManual)
    }
}

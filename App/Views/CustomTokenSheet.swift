import SwiftUI
import UsageLimitsCore

/// 自定义账号更新令牌。禁止复用 LoginSheetView。
struct CustomTokenSheet: View {
    let account: ProviderAccount
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.tr("custom.token.placeholder", lang), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(state.store.displayName(for: account))
                } footer: {
                    Text(L10n.tr("custom.token.footer", lang))
                }

                Section {
                    Button(L10n.tr("custom.token.save", lang)) {
                        state.updateCustomToken(account, token: token)
                        Task { await state.refreshAccount(account, allowWhenDisabled: true) }
                        dismiss()
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(L10n.tr("custom.token.title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
            }
        }
    }
}

import SwiftUI
import UsageLimitsCore

struct AppearanceSettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var edition: Edition
    @Environment(\.appLanguage) private var lang

    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("settings.language", lang), selection: $state.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option == .system
                             ? L10n.tr("settings.language.system", lang)
                             : option.displayName)
                            .tag(option)
                    }
                }
            } header: {
                Text(L10n.tr("settings.language", lang))
            }

            Section {
                Picker(L10n.tr("settings.theme", lang), selection: $state.theme) {
                    Text(L10n.tr("settings.theme.system", lang)).tag(AppTheme.system)
                    Text(L10n.tr("settings.theme.light", lang)).tag(AppTheme.light)
                    Text(L10n.tr("settings.theme.dark", lang)).tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.tr("settings.theme", lang))
            }

            Section {
                Picker(L10n.tr("settings.dashboardTheme", lang), selection: $state.dashboardTheme) {
                    ForEach(DashboardTheme.allCases) { option in
                        Text(L10n.tr(option.titleKey, lang)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.dashboardTheme")
            } header: {
                Text(L10n.tr("settings.dashboardTheme", lang))
            } footer: {
                Text(L10n.tr("settings.dashboardTheme.footer", lang))
            }

            Section {
                Picker(L10n.tr("settings.usageDisplay", lang), selection: $state.usageDisplayMode) {
                    Text(L10n.tr("settings.usageDisplay.used", lang)).tag(UsageDisplayMode.used)
                    Text(L10n.tr("settings.usageDisplay.remaining", lang)).tag(UsageDisplayMode.remaining)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.tr("settings.usageDisplay", lang))
            } footer: {
                Text(L10n.tr("settings.usageDisplay.footer", lang))
            }

            Section {
                Picker(L10n.tr("settings.resetTime", lang), selection: $state.resetTimeStyle) {
                    Text(L10n.tr("settings.resetTime.countdown", lang)).tag(ResetTimeStyle.countdown)
                    Text(L10n.tr("settings.resetTime.absolute", lang)).tag(ResetTimeStyle.absolute)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.tr("settings.resetTime", lang))
            } footer: {
                Text(L10n.tr("settings.resetTime.footer", lang))
            }

            if let extra = edition.appearanceSection() {
                extra
            }
        }
        .readableWidth()
        .navigationTitle(L10n.tr("settings.appearance", lang))
        .navigationBarTitleDisplayMode(.inline)
    }
}

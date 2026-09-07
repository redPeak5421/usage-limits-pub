import SwiftUI
import UIKit
import UsageLimitsCore

struct AppIconView: View {
    @Environment(\.appLanguage) private var lang
    @State private var selected: String? = UIApplication.shared.alternateIconName
    @State private var errorText: String?

    /// 可选图标：`alternateName == nil` 表示主图标；其它需在 Info.plist `CFBundleIcons` 里登记同名 alternate icon。
    struct AppIconChoice: Identifiable {
        let alternateName: String?
        let titleKey: String
        /// 缩略图 imageset 名；nil 时从 Info.plist 的 CFBundleIcons 取主图标文件。
        var previewAsset: String? = nil
        var id: String { alternateName ?? "primary" }
    }

    static let all: [AppIconChoice] = [
        AppIconChoice(alternateName: nil, titleKey: "appIcon.original"),
    ]

    /// 当前生效图标的文案键（设置页入口行右侧显示）。
    static func currentTitleKey() -> String {
        let name = UIApplication.shared.alternateIconName
        return all.first { $0.alternateName == name }?.titleKey ?? "appIcon.original"
    }

    var body: some View {
        Form {
            Section {
                ForEach(Self.all) { choice in
                    Button {
                        apply(choice)
                    } label: {
                        HStack(spacing: 14) {
                            iconImage(for: choice)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08))
                                )
                            Text(L10n.tr(choice.titleKey, lang))
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected == choice.alternateName {
                                Image(systemName: "checkmark")
                                    .font(.body.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("appIcon.\(choice.id)")
                }
            } footer: {
                Text(errorText ?? L10n.tr("appIcon.footer", lang))
            }
        }
        .navigationTitle(L10n.tr("settings.appIcon", lang))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func iconImage(for choice: AppIconChoice) -> some View {
        if let image = choice.previewAsset.flatMap({ UIImage(named: $0) })
            ?? Self.iconUIImage(alternateName: choice.alternateName) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .overlay(Image(systemName: "app").foregroundStyle(.secondary))
        }
    }

    /// 从 Info.plist 的 CFBundleIcons 取图标文件名（主图标 / alternate 都在这里），再按名字加载。
    static func iconUIImage(alternateName: String?) -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any] else { return nil }
        let dict: [String: Any]?
        if let name = alternateName {
            dict = (icons["CFBundleAlternateIcons"] as? [String: Any])?[name] as? [String: Any]
        } else {
            dict = icons["CFBundlePrimaryIcon"] as? [String: Any]
        }
        guard let files = dict?["CFBundleIconFiles"] as? [String], let file = files.last else { return nil }
        return UIImage(named: file)
    }

    private func apply(_ choice: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        guard choice.alternateName != selected else { return }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            if let error {
                errorText = error.localizedDescription
            } else {
                selected = choice.alternateName
                errorText = nil
            }
        }
    }
}

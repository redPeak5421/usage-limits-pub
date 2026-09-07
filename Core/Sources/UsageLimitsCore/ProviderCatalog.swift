import Foundation

/// 加号页目录排序：拉丁名 A–Z 在前，中文按拼音排在后。
public enum ProviderCatalog {
    public static func sortedProviders(_ language: AppLanguage) -> [ProviderID] {
        ProviderID.allCases.sorted { lhs, rhs in
            compare(lhs.localizedName(language), rhs.localizedName(language), language: language)
        }
    }

    public static func sortedPresets(_ language: AppLanguage) -> [CustomUsagePreset] {
        CustomUsagePreset.all.sorted { lhs, rhs in
            compare(lhs.localizedName(language), rhs.localizedName(language), language: language)
        }
    }

    public static func sortedTemplates(_ templates: [CustomUsageTemplate], language: AppLanguage) -> [CustomUsageTemplate] {
        templates.sorted { lhs, rhs in
            compare(lhs.name, rhs.name, language: language)
        }
    }

    /// 拉丁 / 数字在前（当前语言 collation）；汉字按拼音（`zh_CN`）排在后。
    public static func compare(_ lhs: String, _ rhs: String, language: AppLanguage) -> Bool {
        let lCJK = startsWithCJK(lhs)
        let rCJK = startsWithCJK(rhs)
        if lCJK != rCJK { return !lCJK }
        let locale = lCJK ? Locale(identifier: "zh_CN") : locale(for: language)
        return lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        ) == .orderedAscending
    }

    public static func startsWithCJK(_ string: String) -> Bool {
        guard let scalar = string.unicodeScalars.first(where: { !$0.properties.isWhitespace }) else {
            return false
        }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }

    public static func locale(for language: AppLanguage) -> Locale {
        switch language.resolved {
        case .zh: return Locale(identifier: "en")
        case .ja: return Locale(identifier: "ja")
        case .fr: return Locale(identifier: "fr")
        case .ru: return Locale(identifier: "ru")
        default: return Locale(identifier: "en")
        }
    }
}

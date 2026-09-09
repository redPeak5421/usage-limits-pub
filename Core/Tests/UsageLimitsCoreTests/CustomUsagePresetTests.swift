import XCTest
@testable import UsageLimitsCore

final class CustomUsagePresetTests: XCTestCase {
    func testCatalogHasFiveBearerPresetsAndKeepsCurrency() throws {
        let ids = CustomUsagePreset.all.map(\.id)
        XCTAssertEqual(ids, [
            "kimi-api-intl", "kimi-api-cn", "crof", "poe", "openrouter-key",
        ])
        XCTAssertFalse(ids.contains("neuralwatt"), "Neuralwatt 已下线")
        XCTAssertTrue(CustomUsagePreset.all.contains { $0.id == "crof" && $0.experimental })
        XCTAssertFalse(CustomUsagePreset.all.contains { $0.id != "crof" && $0.experimental })

        let intl = try XCTUnwrap(CustomUsagePreset.all.first { $0.id == "kimi-api-intl" })
        XCTAssertEqual(intl.requestURL, "https://api.moonshot.ai/v1/users/me/balance")
        XCTAssertEqual(Set(intl.fields.map(\.currency)), ["USD"])

        let cn = try XCTUnwrap(CustomUsagePreset.all.first { $0.id == "kimi-api-cn" })
        XCTAssertEqual(cn.requestURL, "https://api.moonshot.cn/v1/users/me/balance")
        XCTAssertEqual(Set(cn.fields.map(\.currency)), ["CNY"])

        let openrouter = try XCTUnwrap(CustomUsagePreset.all.first { $0.id == "openrouter-key" })
        XCTAssertEqual(openrouter.requestURL, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(openrouter.fields.first { $0.path == "data.usage" }?.currency, "USD")
    }

    func testPresetsSanitizeToHttpsAndAreNotProviderIDs() {
        for preset in CustomUsagePreset.all {
            XCTAssertNotNil(CustomUsageTemplate.sanitizedURLString(preset.requestURL), preset.id)
            XCTAssertNil(ProviderID(rawValue: preset.id))
            XCTAssertFalse(preset.fields.isEmpty, preset.id)
        }
    }

    func testAddProviderSheetWiresPresetsIntoWizard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appendingPathComponent("App/Views/ProvidersSettingsView.swift"), encoding: .utf8)
        let wizard = try String(contentsOf: root.appendingPathComponent("App/Views/CustomUsageWizardView.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("catalogPresets") || sheet.contains("ProviderCatalog.sortedPresets"))
        XCTAssertTrue(sheet.contains("catalogProviders") || sheet.contains("ProviderCatalog.sortedProviders"))
        XCTAssertTrue(sheet.contains("preset.logoAssetName"), "明确供应商预设须带 logo")
        XCTAssertFalse(sheet.contains("key.fill"), "预设行不得再用钥匙占位")
        XCTAssertTrue(sheet.contains("initialPreset: preset"))
        XCTAssertTrue(wizard.contains("var initialPreset: CustomUsagePreset?"))
        XCTAssertTrue(wizard.contains("testSucceeded"))
        XCTAssertTrue(wizard.contains("leaf.hint.currency ?? initialPreset"))
        XCTAssertTrue(sheet.contains("preset.localizedName(lang)"), "加号页预设名须走 L10n")
        XCTAssertTrue(wizard.contains("preset.localizedName(lang)"), "向导预填须走本地化预设名")
        XCTAssertTrue(wizard.contains("localizedFieldName"), "向导勾选预设字段须走本地化名")
    }

    func testPresetAndProviderNamesResolveInEnglish() {
        let cn = CustomUsagePreset.all.first { $0.id == "kimi-api-cn" }
        XCTAssertEqual(cn?.localizedName(.en), "Kimi API China")
        XCTAssertNotEqual(cn?.localizedName(.en), cn?.name)
        XCTAssertEqual(
            cn?.localizedFieldName(path: "data.available_balance", language: .en),
            "Available balance"
        )
        XCTAssertEqual(
            cn?.localizedFieldName(path: "data.cash_balance", language: .en),
            "Cash balance"
        )
        XCTAssertEqual(
            cn?.localizedFieldName(path: "data.voucher_balance", language: .en),
            "Voucher"
        )
        let crof = CustomUsagePreset.all.first { $0.id == "crof" }
        XCTAssertEqual(crof?.localizedFieldName(path: "credits", language: .en), "Credits")
        let openrouter = CustomUsagePreset.all.first { $0.id == "openrouter-key" }
        XCTAssertEqual(openrouter?.localizedFieldName(path: "data.usage", language: .en), "Usage")
        XCTAssertEqual(openrouter?.localizedFieldName(path: "data.limit", language: .en), "Limit")
        XCTAssertEqual(ProviderID.zhipu.localizedVendor(.en), "Zhipu")
        XCTAssertNotEqual(ProviderID.zhipu.localizedVendor(.en), "智谱")
        XCTAssertEqual(ProviderID.zhipu.localizedName(.en), "Zhipu")
        XCTAssertEqual(ProviderID.jimeng.localizedName(.en), "Jimeng")
        XCTAssertEqual(ProviderID.minimaxGlobal.localizedName(.en), "MiniMax International")
        XCTAssertEqual(ProviderID.zhipu.displayName, "智谱", "displayName 保持中文品牌回落")
        XCTAssertEqual(CustomFieldRole.timestamp.defaultLabel, "到期时间")
        XCTAssertEqual(CustomFieldRole.timestamp.defaultLabel(.en), "Expires")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            for key in [
                "provider.name.zhipu", "provider.name.jimeng", "provider.name.minimax_global",
                "provider.vendor.zhipu",
                "custom.preset.kimi-api-cn.name", "custom.role.timestamp.default",
                "custom.preset.crof.field.credits",
            ] {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) \(lang)")
            }
        }
    }

    func testPresetLogoAssetsExistAndAreNotGenericKey() {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/Assets.xcassets")
        XCTAssertEqual(CustomUsagePreset.all.first { $0.id == "kimi-api-intl" }?.logoAssetName, "LogoKimi")
        XCTAssertEqual(CustomUsagePreset.all.first { $0.id == "kimi-api-cn" }?.logoAssetName, "LogoKimi")
        XCTAssertEqual(CustomUsagePreset.all.first { $0.id == "crof" }?.logoAssetName, "LogoCrof")
        XCTAssertEqual(CustomUsagePreset.all.first { $0.id == "poe" }?.logoAssetName, "LogoPoe")
        XCTAssertEqual(CustomUsagePreset.all.first { $0.id == "openrouter-key" }?.logoAssetName, "LogoOpenRouter")
        for preset in CustomUsagePreset.all {
            let path = catalog.appendingPathComponent("\(preset.logoAssetName).imageset/logo.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "缺少预设商标 \(preset.logoAssetName)")
        }
    }

    func testCatalogSortsProvidersAndPresetsByLocalizedName() {
        let zh = ProviderCatalog.sortedProviders(.zh)
        XCTAssertEqual(Set(zh), Set(ProviderAvailability.providers))
        let zhNames = zh.map { $0.localizedName(.zh) }
        let latin = zhNames.filter { !ProviderCatalog.startsWithCJK($0) }
        let cjk = zhNames.filter { ProviderCatalog.startsWithCJK($0) }
        XCTAssertEqual(zhNames, latin + cjk, "拉丁名在前，中文在后")
        XCTAssertEqual(zh.first?.localizedName(.zh), "ChatGPT")
        XCTAssertEqual(cjk, ["即梦", "智谱"], "中文按拼音：即梦 ji、智谱 zhi")
        XCTAssertFalse(ProviderCatalog.startsWithCJK("Kimi"))
        XCTAssertFalse(ProviderCatalog.startsWithCJK("MiniMax 国际"))
        XCTAssertTrue(ProviderCatalog.startsWithCJK("即梦"))
        let presets = ProviderCatalog.sortedPresets(.en).map { $0.localizedName(.en) }
        XCTAssertEqual(
            presets,
            presets.sorted { $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")) == .orderedAscending }
        )
        XCTAssertTrue(ProviderCatalog.compare("Alpha", "zeta", language: .en))
        XCTAssertTrue(
            ProviderCatalog.compare("Kimi", "Kimi API", language: .zh),
            "Kimi 须排在 Kimi API 前"
        )
        XCTAssertTrue(ProviderCatalog.compare("Kimi API", "即梦", language: .zh))
    }
}

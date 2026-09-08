import XCTest
@testable import UsageLimitsCore

final class LaunchStoreConfigTests: XCTestCase {
    func testEngineeringNamesAndPersistentWidgetKinds() throws {
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.hasPrefix("name: UsageLimits\n"))
        XCTAssertTrue(yml.contains("schemes:\n  UsageLimits:"))
        XCTAssertTrue(yml.contains("postGenCommand: swift scripts/configure_workspace.swift"))
        XCTAssertFalse(yml.contains("AIUsage"))
        let package = try String(contentsOf: root.appendingPathComponent("Core/Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("name: \"UsageLimitsCore\""))
        let widget = try String(contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8)
        for kind in ["SingleProviderWidget", "SingleProviderMediumWidget", "OverviewLargeWidget"] {
            XCTAssertTrue(widget.contains("kind: \"\(kind)\""), "已保存的 Widget kind 必须保留")
        }
        XCTAssertFalse(widget.contains("kind: \"OverviewWidget\""), "2×4 总览已下线（DEVLOG #99）")
        let appInfo = try String(contentsOf: root.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        XCTAssertTrue(appInfo.contains("<string>usagelimits</string>"))
        XCTAssertTrue(appInfo.contains("<string>aiusage</string>"))
    }

    /// 小组件深浅色跟随 App 主题（DEVLOG #111）：三个 widget 都挂 `widgetAppearance()`，改主题要 reload 时间线。
    func testWidgetsFollowAppThemeAndAppReloadsTimelinesOnThemeChange() throws {
        let widget = try String(contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8)
        XCTAssertTrue(widget.contains("SharedStore.shared.appTheme"))
        XCTAssertTrue(widget.contains("content.environment(\\.colorScheme, .dark)"))
        XCTAssertTrue(widget.contains("content.environment(\\.colorScheme, .light)"))
        XCTAssertEqual(widget.components(separatedBy: ".containerBackground(for: .widget) { WidgetAppearance.background }").count - 1, 3)
        XCTAssertFalse(widget.contains(".containerBackground(for: .widget) { Color(.systemBackground) }"))
        XCTAssertEqual(widget.components(separatedBy: "\n                .widgetAppearance()").count - 1
                       + widget.components(separatedBy: "\n            .widgetAppearance()").count - 1, 3)
        let appState = try String(contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8)
        let themeBlock = appState.components(separatedBy: "@Published var theme: AppTheme {")[1]
            .components(separatedBy: "}\n    }")[0]
        XCTAssertTrue(themeBlock.contains("store.appTheme = theme"))
        XCTAssertTrue(themeBlock.contains("WidgetCenter.shared.reloadAllTimelines()"))
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPrivacyManifestsDeclareUserDefaultsOnly() throws {
        for rel in ["App/PrivacyInfo.xcprivacy", "Widget/PrivacyInfo.xcprivacy", "Watch/PrivacyInfo.xcprivacy"] {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertTrue(text.contains("NSPrivacyTracking"), rel)
            XCTAssertTrue(text.contains("<false/>"), "\(rel) 不得声明跟踪")
            XCTAssertTrue(text.contains("NSPrivacyAccessedAPICategoryUserDefaults"), rel)
            XCTAssertTrue(text.contains("CA92.1"), rel)
            XCTAssertFalse(text.contains("<true/>"), "\(rel) 不得打开跟踪")
        }
    }

    /// 工程文件由 XcodeGen 生成、不入库，只看 `project.yml`（工程源）。
    /// App/Widget 自 2026-09 起适配 iPad（TARGETED_DEVICE_FAMILY = "1,2"），Watch 仍是 4。
    func testAppAndWidgetSupportIPadFamily() throws {
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(
            yml.components(separatedBy: "TARGETED_DEVICE_FAMILY: \"1,2\"").count - 1, 3,
            "顶层默认 + App 目标 + Widget 目标三处都应是 iPhone+iPad"
        )
        XCTAssertTrue(yml.contains("TARGETED_DEVICE_FAMILY: \"4\""), "Watch 仍是 4")
        XCTAssertTrue(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.canonforge.usagelimits.widget"))
        XCTAssertFalse(
            yml.contains("TARGETED_DEVICE_FAMILY: \"1\"\n"),
            "不应再残留仅 iPhone 的旧声明（App/Widget 已改 1,2，Watch 用的是 4）"
        )
        XCTAssertFalse(yml.contains("DEVELOPMENT_TEAM"), "团队 ID 只放 project.local.yml，不入库")
    }

    /// 对外发布的 Apple 标识必须是 com.canonforge.usagelimits 一家，且不得再写旧前缀。
    func testShippingIdentifiersAreCanonforgeUsageLimitsFamily() throws {
        XCTAssertEqual(SharedStore.appGroupID, "group.com.canonforge.usagelimits")

        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("bundleIdPrefix: com.canonforge"))
        XCTAssertTrue(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.canonforge.usagelimits\n"))
        XCTAssertTrue(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.canonforge.usagelimits.widget"))
        XCTAssertTrue(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.canonforge.usagelimits.watchkitapp"))
        XCTAssertTrue(yml.contains("WKCompanionAppBundleIdentifier: com.canonforge.usagelimits"))
        XCTAssertTrue(yml.contains("group.com.canonforge.usagelimits"))
        XCTAssertTrue(yml.contains("com.canonforge.usagelimits.refresh"))
        XCTAssertTrue(yml.contains("CFBundleURLSchemes:\n              - aiusage"))

        let appEntitlements = try String(
            contentsOf: root.appendingPathComponent("App/UsageLimits.entitlements"), encoding: .utf8
        )
        let widgetEntitlements = try String(
            contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.entitlements"), encoding: .utf8
        )
        XCTAssertTrue(appEntitlements.contains("group.com.canonforge.usagelimits"))
        XCTAssertTrue(widgetEntitlements.contains("group.com.canonforge.usagelimits"))

        let appInfo = try String(contentsOf: root.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        XCTAssertTrue(appInfo.contains("com.canonforge.usagelimits.refresh"))
        XCTAssertTrue(appInfo.contains("<string>aiusage</string>"))

        let watchInfo = try String(contentsOf: root.appendingPathComponent("Watch/Info.plist"), encoding: .utf8)
        XCTAssertTrue(watchInfo.contains("com.canonforge.usagelimits"))

        let bg = try String(contentsOf: root.appendingPathComponent("App/BackgroundRefresh.swift"), encoding: .utf8)
        XCTAssertTrue(bg.contains("\"com.canonforge.usagelimits.refresh\""))

        let store = try String(
            contentsOf: root.appendingPathComponent("Core/Sources/UsageLimitsCore/SharedStore.swift"), encoding: .utf8
        )
        XCTAssertTrue(store.contains("\"group.com.canonforge.usagelimits\""))
    }
}

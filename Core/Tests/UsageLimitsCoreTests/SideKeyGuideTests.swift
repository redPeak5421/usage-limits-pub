import XCTest
@testable import UsageLimitsCore

final class SideKeyGuideTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 设置页「侧边键」说明：五语都有；步骤分行（一步一段，方便看清）；写的是系统里显示的快捷指令名。
    func testGuideCopyIsLocalizedAndSteppedWithLineBreaks() {
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            for key in ["settings.sideKey.guideTitle", "settings.sideKey.guideSteps", "settings.sideKey.open"] {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) missing \(lang.rawValue)")
            }
            let steps = L10n.tr("settings.sideKey.guideSteps", lang)
            XCTAssertEqual(steps.components(separatedBy: "\n\n").count, 4, "四步各占一段 \(lang.rawValue)")
            XCTAssertTrue(steps.hasPrefix("1."), lang.rawValue)
            XCTAssertTrue(steps.contains("侧边菜单"), "步骤须写系统里显示的快捷指令名 \(lang.rawValue)")
            let firstStep = steps.components(separatedBy: "\n\n")[0]
            XCTAssertTrue(firstStep.contains(L10n.tr("settings.sideKey.open", lang)),
                          "第一步要点名「前往设置」按钮并说明落在设置首页（系统不允许直达操作按钮页） \(lang.rawValue)")
        }
    }

    /// 设置页有「侧边键」入口：弹窗 → 「前往设置」打开系统设置首页；打不开退到本 App 设置页。
    /// iOS 26 把任何带路径的 `App-prefs:<X>` 改写成「App 列表 → X」，只有不带路径才停在首页（DEVLOG #97），
    /// 所以链接必须是裸 `App-prefs:`，不能再带 `ACTION_BUTTON`。
    func testSettingsOffersSideKeyGuideThatOpensSystemSettings() throws {
        let settings = try String(contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("accessibilityIdentifier(\"settings.sideKey\")"))
        XCTAssertTrue(settings.contains("isPresented: $showSideKeyGuide"), "说明用弹窗")
        XCTAssertTrue(settings.contains("Text(L10n.tr(\"settings.sideKey.guideSteps\", lang))"), "弹窗正文是分步说明")
        XCTAssertTrue(settings.contains("SideKeySettingsLink.open()"), "确定后跳设置")
        let link = try String(contentsOf: root.appendingPathComponent("App/SideKeySettingsLink.swift"), encoding: .utf8)
        XCTAssertTrue(link.contains("URL(string: \"App-prefs:\")"), "裸 App-prefs: 才停在设置首页")
        XCTAssertFalse(link.contains("App-prefs:ACTION_BUTTON"), "带路径会被 iOS 26 改写到 App 列表页")
        XCTAssertTrue(link.contains("UIApplication.openSettingsURLString"), "打不开时退到本 App 设置页")
    }

    /// `--open-side-key-guide`：设置页直接弹出说明（模拟器验证弹窗排版与「前往设置」落点用）。
    func testLaunchArgumentOpensSideKeyGuide() throws {
        let appState = try String(contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8)
        XCTAssertTrue(appState.contains("args.contains(\"--open-side-key-guide\")"))
        XCTAssertTrue(appState.contains("autoRoute = .sideKeyGuide"))
        let settings = try String(contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("case .sideKeyGuide = state.autoRoute"), "设置页出现时按启动参数弹说明")
    }
}

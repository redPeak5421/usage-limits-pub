import XCTest
@testable import UsageLimitsCore

/// 首页侧边键状态机（操作按钮驱动）：按下弹出「设置 / 分享 / 主题」；`pick` 换选中；按下或点菜单项确认；
/// 「主题」进入三级小菜单，选中主题后按下切换。
final class DashboardSideKeyTests: XCTestCase {
    func testIdleTapOpensRootMenuWithSettingsSelected() {
        var state = DashboardSideKeyState()
        XCTAssertEqual(state.reduce(.tap, currentTheme: .flat), [.menuOpened])
        XCTAssertEqual(state.menu, .root(selected: .settings))
    }

    func testPickSetsAbsoluteSelectionOnlyInsideAMenu() {
        var idle = DashboardSideKeyState()
        XCTAssertEqual(idle.reduce(.pick(index: 2), currentTheme: .flat), [])
        XCTAssertNil(idle.menu)

        var root = DashboardSideKeyState()
        _ = root.reduce(.tap, currentTheme: .flat)
        XCTAssertEqual(root.reduce(.pick(index: 2), currentTheme: .flat), [.selectionChanged])
        XCTAssertEqual(root.menu, .root(selected: .theme))
        XCTAssertEqual(root.reduce(.pick(index: 2), currentTheme: .flat), [], "同一项不重复反馈")
        XCTAssertEqual(root.reduce(.pick(index: 9), currentTheme: .flat), [], "越界忽略")
        XCTAssertEqual(root.reduce(.pick(index: -1), currentTheme: .flat), [])
        XCTAssertEqual(root.menu, .root(selected: .theme))
    }

    func testRootTapActivatesTheSelectedEntry() {
        var settings = DashboardSideKeyState()
        _ = settings.reduce(.tap, currentTheme: .flat)
        XCTAssertEqual(settings.reduce(.tap, currentTheme: .flat), [.openSettings, .menuClosed])
        XCTAssertNil(settings.menu)

        var share = DashboardSideKeyState()
        _ = share.reduce(.tap, currentTheme: .flat)
        _ = share.reduce(.pick(index: 1), currentTheme: .flat)
        XCTAssertEqual(share.reduce(.tap, currentTheme: .flat), [.openShare, .menuClosed])
        XCTAssertNil(share.menu)

        var theme = DashboardSideKeyState()
        _ = theme.reduce(.tap, currentTheme: .roulette)
        _ = theme.reduce(.pick(index: 2), currentTheme: .roulette)
        XCTAssertEqual(theme.reduce(.tap, currentTheme: .roulette), [.themeMenuOpened])
        XCTAssertEqual(theme.menu, .theme(selected: .roulette), "三级菜单预选当前主题")
    }

    func testChoosingAnEntryDirectlySkipsTheSelection() {
        var state = DashboardSideKeyState()
        _ = state.reduce(.tap, currentTheme: .flat)
        XCTAssertEqual(state.reduce(.chooseItem(.theme), currentTheme: .flat), [.themeMenuOpened])
        XCTAssertEqual(state.menu, .theme(selected: .flat))
        XCTAssertEqual(state.reduce(.chooseTheme(.helix), currentTheme: .flat), [.applyTheme(.helix), .menuClosed])
        XCTAssertNil(state.menu)
    }

    func testThemeMenuPickSelectsAndTapApplies() {
        var state = DashboardSideKeyState()
        _ = state.reduce(.tap, currentTheme: .flat)
        _ = state.reduce(.chooseItem(.theme), currentTheme: .flat)
        XCTAssertEqual(state.reduce(.pick(index: 1), currentTheme: .flat), [.selectionChanged])
        XCTAssertEqual(state.menu, .theme(selected: .roulette))
        XCTAssertEqual(state.reduce(.pick(index: 2), currentTheme: .flat), [.selectionChanged])
        XCTAssertEqual(state.menu, .theme(selected: .helix))
        XCTAssertEqual(state.reduce(.pick(index: 3), currentTheme: .flat), [])
        XCTAssertEqual(state.reduce(.tap, currentTheme: .flat), [.applyTheme(.helix), .menuClosed])
        XCTAssertNil(state.menu)
    }

    func testDismissClosesAnyMenuAndIsSilentWhenIdle() {
        var idle = DashboardSideKeyState()
        XCTAssertEqual(idle.reduce(.dismiss, currentTheme: .flat), [])

        var root = DashboardSideKeyState()
        _ = root.reduce(.tap, currentTheme: .flat)
        XCTAssertEqual(root.reduce(.dismiss, currentTheme: .flat), [.menuClosed])
        XCTAssertNil(root.menu)

        var theme = DashboardSideKeyState()
        _ = theme.reduce(.tap, currentTheme: .flat)
        _ = theme.reduce(.chooseItem(.theme), currentTheme: .flat)
        XCTAssertEqual(theme.reduce(.dismiss, currentTheme: .flat), [.menuClosed])
        XCTAssertNil(theme.menu)
    }

    func testChoiceInputsAreIgnoredOutsideTheirMenuLevel() {
        var idle = DashboardSideKeyState()
        XCTAssertEqual(idle.reduce(.chooseItem(.share), currentTheme: .flat), [])
        XCTAssertEqual(idle.reduce(.chooseTheme(.helix), currentTheme: .flat), [])
        XCTAssertNil(idle.menu)

        var root = DashboardSideKeyState()
        _ = root.reduce(.tap, currentTheme: .flat)
        XCTAssertEqual(root.reduce(.chooseTheme(.helix), currentTheme: .flat), [])
        XCTAssertEqual(root.menu, .root(selected: .settings))

        var theme = DashboardSideKeyState()
        _ = theme.reduce(.tap, currentTheme: .flat)
        _ = theme.reduce(.chooseItem(.theme), currentTheme: .flat)
        XCTAssertEqual(theme.reduce(.chooseItem(.share), currentTheme: .flat), [])
        XCTAssertEqual(theme.menu, .theme(selected: .flat))
    }

    func testMenuEntriesAndThemesKeepTheirDisplayOrder() {
        XCTAssertEqual(DashboardSideKeyItem.allCases, [.settings, .share, .theme])
        XCTAssertEqual(DashboardSideKeyItem.settings.titleKey, "settings.title")
        XCTAssertEqual(DashboardSideKeyItem.share.titleKey, "sideKey.menu.share")
        XCTAssertEqual(DashboardSideKeyItem.theme.titleKey, "sideKey.menu.theme")
        XCTAssertEqual(DashboardSideKeyMenu.root(selected: .share).selectedIndex, 1)
        XCTAssertEqual(DashboardSideKeyMenu.theme(selected: .helix).selectedIndex, 2)
        for key in ["sideKey.label", "sideKey.hint", "sideKey.menu.share", "sideKey.menu.theme",
                    "sideKey.menu.rootHint", "sideKey.menu.themeHint"] {
            for lang in AppLanguage.concrete {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
        XCTAssertEqual(L10n.tr("sideKey.label", .zh), "侧边键")
    }
}

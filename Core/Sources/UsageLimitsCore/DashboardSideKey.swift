import Foundation

/// 首页侧边键的菜单项：设置 / 分享 / 主题，按显示顺序排列。
public enum DashboardSideKeyItem: String, CaseIterable, Equatable, Sendable {
    case settings
    case share
    case theme

    /// 菜单文案键。「设置」沿用设置页标题，另外两项是侧边键自己的键。
    public var titleKey: String {
        switch self {
        case .settings: return "settings.title"
        case .share: return "sideKey.menu.share"
        case .theme: return "sideKey.menu.theme"
        }
    }
}

/// 侧边键当前弹出的菜单层级：一级（设置 / 分享 / 主题）或三级主题小菜单。nil = 空闲。
public enum DashboardSideKeyMenu: Equatable, Sendable {
    case root(selected: DashboardSideKeyItem)
    case theme(selected: DashboardTheme)

    /// 选中项在本层列表里的下标（按 `allCases` 顺序）。
    public var selectedIndex: Int {
        switch self {
        case .root(let item):
            return DashboardSideKeyItem.allCases.firstIndex(of: item) ?? 0
        case .theme(let theme):
            return DashboardTheme.allCases.firstIndex(of: theme) ?? 0
        }
    }
}

/// 侧边键收到的原始输入：`tap` = 按下操作按钮（空闲弹菜单、菜单内确认）；`pick` = 直接指定本层选中项下标；
/// `chooseItem` / `chooseTheme` = 点屏幕菜单项；`dismiss` = 点菜单外。
public enum DashboardSideKeyInput: Equatable, Sendable {
    case tap
    case pick(index: Int)
    case chooseItem(DashboardSideKeyItem)
    case chooseTheme(DashboardTheme)
    case dismiss
}

/// 状态机对外发出的效果，由视图层执行（触感、跳转、切主题）。
public enum DashboardSideKeyEffect: Equatable, Sendable {
    case menuOpened
    case selectionChanged
    case openSettings
    case openShare
    case themeMenuOpened
    case applyTheme(DashboardTheme)
    case menuClosed
}

/// 首页侧边键状态机（纯逻辑，三种首页主题共用）：
/// - 空闲：按下弹出一级菜单（设置 / 分享 / 主题，预选第一项）。
/// - 一级菜单：`pick` 换选中；按下确认——设置进设置页、分享进分享页、主题进三级小菜单（预选当前主题）。
/// - 三级主题菜单：`pick` 换主题；按下切换到选中主题。
/// - 直接点菜单项等于选中并确认；点菜单外 = `dismiss`。
public struct DashboardSideKeyState: Equatable, Sendable {
    public private(set) var menu: DashboardSideKeyMenu?

    public init() {}

    public mutating func reduce(
        _ input: DashboardSideKeyInput,
        currentTheme: DashboardTheme
    ) -> [DashboardSideKeyEffect] {
        switch menu {
        case nil:
            return reduceIdle(input)
        case .root(let selected):
            return reduceRoot(input, selected: selected, currentTheme: currentTheme)
        case .theme(let selected):
            return reduceTheme(input, selected: selected)
        }
    }

    private mutating func reduceIdle(_ input: DashboardSideKeyInput) -> [DashboardSideKeyEffect] {
        switch input {
        case .tap:
            menu = .root(selected: .settings)
            return [.menuOpened]
        case .pick, .chooseItem, .chooseTheme, .dismiss:
            return []
        }
    }

    private mutating func reduceRoot(
        _ input: DashboardSideKeyInput,
        selected: DashboardSideKeyItem,
        currentTheme: DashboardTheme
    ) -> [DashboardSideKeyEffect] {
        switch input {
        case .tap:
            return activate(selected, currentTheme: currentTheme)
        case .chooseItem(let item):
            return activate(item, currentTheme: currentTheme)
        case .pick(let index):
            guard DashboardSideKeyItem.allCases.indices.contains(index) else { return [] }
            let next = DashboardSideKeyItem.allCases[index]
            guard next != selected else { return [] }
            menu = .root(selected: next)
            return [.selectionChanged]
        case .dismiss:
            return close()
        case .chooseTheme:
            return []
        }
    }

    private mutating func reduceTheme(
        _ input: DashboardSideKeyInput,
        selected: DashboardTheme
    ) -> [DashboardSideKeyEffect] {
        switch input {
        case .tap:
            return apply(selected)
        case .chooseTheme(let theme):
            return apply(theme)
        case .pick(let index):
            guard DashboardTheme.allCases.indices.contains(index) else { return [] }
            let next = DashboardTheme.allCases[index]
            guard next != selected else { return [] }
            menu = .theme(selected: next)
            return [.selectionChanged]
        case .dismiss:
            return close()
        case .chooseItem:
            return []
        }
    }

    private mutating func activate(
        _ item: DashboardSideKeyItem,
        currentTheme: DashboardTheme
    ) -> [DashboardSideKeyEffect] {
        switch item {
        case .settings:
            menu = nil
            return [.openSettings, .menuClosed]
        case .share:
            menu = nil
            return [.openShare, .menuClosed]
        case .theme:
            menu = .theme(selected: currentTheme)
            return [.themeMenuOpened]
        }
    }

    private mutating func apply(_ theme: DashboardTheme) -> [DashboardSideKeyEffect] {
        menu = nil
        return [.applyTheme(theme), .menuClosed]
    }

    private mutating func close() -> [DashboardSideKeyEffect] {
        menu = nil
        return [.menuClosed]
    }
}

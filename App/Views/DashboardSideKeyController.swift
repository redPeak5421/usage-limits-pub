import SwiftUI
import UIKit
import UsageLimitsCore

/// 首页侧边键 = 机身的操作按钮（Action Button）+ 快捷指令，App 不碰相机（相机控制键方案已废，DEVLOG #89 / #90）。
/// 用户在 设置 → 操作按钮 → 快捷指令 里绑 Usage Limits 的「侧边菜单」（`OpenSideKeyMenuIntent`）：
/// 按下弹出「设置 / 分享 / 主题」镜像菜单，再按轮换选中，点菜单项确认；切主题 / 打开设置 / 分享用量也各有一条快捷指令。
/// 状态机在 Core（`DashboardSideKeyState`），这里只做桥接、触感与诊断；跳转 / 切主题由首页执行 `onEffect`。
@MainActor
final class DashboardSideKeyController: ObservableObject {
    @Published private(set) var menu: DashboardSideKeyMenu?

    var onEffect: (@MainActor (DashboardSideKeyEffect) -> Void)?
    var currentTheme: DashboardTheme = .flat

    private var machine = DashboardSideKeyState()

    /// 操作按钮按下：空闲时弹菜单；菜单已开就把选中项往下轮换一格（到底回到第一项）。
    func pressSideKey() {
        guard let menu = machine.menu else {
            send(.tap)
            return
        }
        let count: Int
        switch menu {
        case .root: count = DashboardSideKeyItem.allCases.count
        case .theme: count = DashboardTheme.allCases.count
        }
        send(.pick(index: (menu.selectedIndex + 1) % max(count, 1)))
    }

    /// 屏幕上的镜像菜单被直接点到。
    func choose(_ item: DashboardSideKeyItem) {
        send(.chooseItem(item))
    }

    func choose(_ theme: DashboardTheme) {
        send(.chooseTheme(theme))
    }

    func dismiss() {
        send(.dismiss)
    }

    /// `--open-side-key`：弹出镜像菜单（自动化截图用）。控制器随首页常驻，整个 App 生命周期只弹一次——
    /// 首页从设置页返回、或换主题重建视图时 `onAppear` 会再触发，不能再弹（真机反馈）。
    private var didOpenForAutomation = false

    func openMenuForAutomation() {
        guard !didOpenForAutomation, machine.menu == nil else { return }
        didOpenForAutomation = true
        send(.tap)
    }

    private func send(_ input: DashboardSideKeyInput) {
        let effects = machine.reduce(input, currentTheme: currentTheme)
        if machine.menu != menu {
            menu = machine.menu
        }
        for effect in effects {
            switch effect {
            case .menuOpened, .themeMenuOpened:
                DashboardSideKeyHaptic.impact(.light)
            case .selectionChanged:
                DashboardSideKeyHaptic.selection()
            case .openSettings, .openShare:
                DashboardSideKeyHaptic.impact(.medium)
            case .applyTheme(let theme):
                if theme != currentTheme {
                    DashboardSideKeyHaptic.success()
                }
            case .menuClosed:
                break
            }
            // 轮换选中不记（一按一行会把 500 行诊断挤掉）；其余效果各记一行，真机反馈「菜单点不动」时分得清 dismiss 与 choose（DEVLOG #95）。
            if effect != .selectionChanged {
                SharedStore.shared.appendDiagnostic("sideKey: effect \(effect)")
            }
            onEffect?(effect)
        }
    }
}

/// 侧边键触感：换选中项用选择反馈，弹菜单 / 确认用冲击反馈，切主题成功用通知反馈。
@MainActor
enum DashboardSideKeyHaptic {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        notificationGenerator.notificationOccurred(.success)
    }
}

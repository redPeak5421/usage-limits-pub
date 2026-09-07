import AppIntents
import Foundation
import UsageLimitsCore

/// 操作按钮 / 快捷指令 发给首页的命令。意图在 App 进程里执行（`openAppWhenRun`），
/// 先存进总线再广播：冷启动时首页还没出现，出现后再消费。
enum SideKeyCommand: Equatable {
    case menu
    case settings
    case share
    case theme(DashboardTheme)
}

@MainActor
final class SideKeyCommandBus {
    static let shared = SideKeyCommandBus()
    static let notification = Notification.Name("usagelimits.sideKeyCommand")

    private(set) var pending: SideKeyCommand?

    func post(_ command: SideKeyCommand) {
        pending = command
        // 进诊断日志：真机反馈「按了没反应」时，能分清是快捷指令没到 App 还是首页没消费
        SharedStore.shared.appendDiagnostic("sideKey: intent \(command)")
        NotificationCenter.default.post(name: Self.notification, object: nil)
    }

    func take() -> SideKeyCommand? {
        defer { pending = nil }
        return pending
    }
}

/// 设置 → 操作按钮 → 快捷指令 里选这条：按下机身侧键弹出「设置 / 分享 / 主题」菜单，再按一次轮换选中。
struct OpenSideKeyMenuIntent: AppIntent {
    static var title: LocalizedStringResource = "打开侧边菜单"
    static var description = IntentDescription("在首页弹出「设置 / 分享 / 主题」菜单；菜单已开时按一次轮换选中项。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SideKeyCommandBus.shared.post(.menu)
        return .result()
    }
}

struct OpenSettingsIntent: AppIntent {
    static var title: LocalizedStringResource = "打开设置"
    static var description = IntentDescription("直接进入 Usage Limits 的设置页。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SideKeyCommandBus.shared.post(.settings)
        return .result()
    }
}

struct ShareUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "分享用量"
    static var description = IntentDescription("打开首页全部用量的分享预览。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SideKeyCommandBus.shared.post(.share)
        return .result()
    }
}

enum DashboardThemeOption: String, AppEnum {
    case flat
    case roulette
    case helix

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "首页主题")
    static var caseDisplayRepresentations: [DashboardThemeOption: DisplayRepresentation] = [
        .flat: "平铺",
        .roulette: "轮盘",
        .helix: "螺旋",
    ]

    var theme: DashboardTheme {
        switch self {
        case .flat: .flat
        case .roulette: .roulette
        case .helix: .helix
        }
    }
}

struct SwitchDashboardThemeIntent: AppIntent {
    static var title: LocalizedStringResource = "切换首页主题"
    static var description = IntentDescription("把首页切到平铺 / 轮盘 / 螺旋。")
    static var openAppWhenRun = true

    @Parameter(title: "主题")
    var theme: DashboardThemeOption

    static var parameterSummary: some ParameterSummary {
        Summary("把首页切到 \(\.$theme)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SideKeyCommandBus.shared.post(.theme(theme.theme))
        return .result()
    }
}

/// 让这些意图出现在 快捷指令 App 和 操作按钮 的选择器里。
struct UsageLimitsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSideKeyMenuIntent(),
            phrases: ["打开 \(.applicationName) 侧边菜单", "Open \(.applicationName) side menu"],
            shortTitle: "侧边菜单",
            systemImageName: "line.3.horizontal"
        )
        AppShortcut(
            intent: SwitchDashboardThemeIntent(),
            phrases: ["切换 \(.applicationName) 主题", "Switch \(.applicationName) theme"],
            shortTitle: "切换主题",
            systemImageName: "paintpalette"
        )
        AppShortcut(
            intent: ShareUsageIntent(),
            phrases: ["分享 \(.applicationName) 用量", "Share \(.applicationName) usage"],
            shortTitle: "分享用量",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: OpenSettingsIntent(),
            phrases: ["打开 \(.applicationName) 设置", "Open \(.applicationName) settings"],
            shortTitle: "设置",
            systemImageName: "gearshape"
        )
    }
}

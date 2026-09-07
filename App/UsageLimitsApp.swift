import SwiftUI
import UsageLimitsCore

@main
struct UsageLimitsApp: App {
    @StateObject private var edition: Edition = EditionFactory.make()
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 主线程卡顿看门狗：≥300 ms 无响应就抓主线程栈进诊断日志（DEVLOG #89）
        MainThreadHangWatchdog.shared.start()
        // BGTaskScheduler 要求在启动完成前注册 handler
        BackgroundRefresh.register()
        // 尽早接管通知前台展示（不设 delegate 时前台收到通知不显示）
        NotificationManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(edition)
                .environmentObject(state)
                .environment(\.appLanguage, state.language)
                .environment(\.usageDisplayMode, state.usageDisplayMode)
                .environment(\.resetTimeStyle, state.resetTimeStyle)
                .preferredColorScheme(state.theme.colorScheme)
                .onOpenURL { state.handleOpenURL($0) }
                .task { await edition.onForeground() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                state.expireShareBrandUnlockIfNeeded()
                Task { await edition.onForeground() }
                Task { await state.autoRefreshIfStale() }
            } else if phase == .background {
                state.sceneDidEnterBackground()
                BackgroundRefresh.schedule()
            }
        }
    }
}

private extension AppTheme {
    /// system 返回 nil（不覆盖系统外观）。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

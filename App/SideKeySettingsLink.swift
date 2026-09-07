import UIKit

/// 设置页「侧边键」说明弹窗的「前往设置」：只发不带路径的 `App-prefs:`，落在系统设置首页（「操作按钮」在首页第三行）。
/// iOS 26 把带路径的 `App-prefs:<X>` 改写到 App 列表页，`prefs:` / `settings-navigation:` 是私有 scheme，
/// 没有公开 API 能直达操作按钮页（DEVLOG #97）。打不开就退到公开的 `openSettingsURLString`。
enum SideKeySettingsLink {
    static let settingsHomeURL = URL(string: "App-prefs:")

    @MainActor
    static func open() {
        guard let settingsHomeURL else { return openAppSettings() }
        UIApplication.shared.open(settingsHomeURL) { opened in
            if !opened { Task { @MainActor in openAppSettings() } }
        }
    }

    @MainActor
    private static func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

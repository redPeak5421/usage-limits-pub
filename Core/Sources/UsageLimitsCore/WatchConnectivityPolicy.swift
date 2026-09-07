import Foundation

/// 手表同步门闩。未配对或未安装手表 App 时调用 `updateApplicationContext`
/// 会刷屏 `WCErrorCodeWatchAppNotInstalled`（系统在 API 内部打日志，`try?` 挡不住）。
public enum WatchConnectivityPolicy {
    public static func canPushApplicationContext(
        sessionSupported: Bool,
        sessionActivated: Bool,
        watchPaired: Bool,
        watchAppInstalled: Bool
    ) -> Bool {
        sessionSupported && sessionActivated && watchPaired && watchAppInstalled
    }
}

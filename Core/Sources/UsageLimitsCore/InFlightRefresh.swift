import Foundation

/// 在飞刷新对抗 logout / remove / 停用：探针返回后决定要不要丢弃本轮结果。
///
/// 登录探测可以在还没有主账号时开刷（`startAccountPresent == false`），
/// 那种路径不得因为「现在仍然没有账号」而中止。
public enum InFlightRefresh {
    public static func shouldAbort(
        startAccountPresent: Bool,
        currentAccountPresent: Bool,
        startFingerprint: String?,
        currentFingerprint: String?,
        startGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        if startGeneration != currentGeneration { return true }
        if startAccountPresent && !currentAccountPresent { return true }
        if startFingerprint != nil && currentFingerprint == nil { return true }
        return false
    }
}

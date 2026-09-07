import Foundation

/// OpenCode 离屏探针的页面就绪判定（纯函数，可单测）。
///
/// 登录前的静默探测会把离屏 WebView 从 `/auth` 一路 302 带到 `auth.opencode.ai`（OAuth 页）。
/// 它与站点源 `opencode.ai` 只差一个子域，通用的「后缀匹配」会把它当成「已在源上」而永不重载，
/// 登录成功后探针仍在 OAuth 页上跑，`/auth/status` 拿不到 workspace，永远判未登录（2026-08-26 真机）。
/// 因此 host 必须**正好**是 `opencode.ai`，且不能停在 `/auth*`；其余任何 `opencode.ai` 页面都算就绪。
///
/// 从「必须停在 `/workspace/<wrk_id>`」放宽到「任意非 auth 页」的前提：探针在路径里取不到 workspace 时
/// 会调 `workspaces()` server fn 兜底（见 `providers/opencode.md`），不再依赖 URL 里有 `wrk_`。
public enum OpenCodeSession {
    public static func isProbeReady(url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        guard host == "opencode.ai" else { return false }
        return !isAuthPath(url.path)
    }

    /// `/auth`、`/auth/authorize` 及其子路径：登录流程页，一律重载 `/auth` 而不是复用。
    static func isAuthPath(_ path: String) -> Bool {
        let normalized = path.isEmpty ? "/" : path
        return normalized == "/auth" || normalized.hasPrefix("/auth/")
    }
}

import Foundation

/// 登录确认只消费当前文档的新响应；可用的游客用量并不是账号会话。
public enum LoginProbePolicy {
    /// 只有确实进入官网重新认证流程才解除「否」的抑制，普通刷新/加载不算退出。
    public static func isAuthenticationPage(provider: ProviderID, url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        let paths = url.pathComponents.map { $0.lowercased() }
        switch provider {
        case .grok:
            guard host == "accounts.x.ai" || host == "grok.com" || host == "www.grok.com" else { return false }
            return paths.contains { ["login", "sign-in", "sign-up", "sign-out"].contains($0) }
        case .cursor:
            if host == "authenticator.cursor.sh" { return true }
            guard host == "cursor.com" || host == "www.cursor.com" else { return false }
            return paths.contains { ["login", "signin", "sign-in", "logout"].contains($0) }
        default:
            return false
        }
    }

    public static func isAuthenticated(_ snapshot: ProviderSnapshot?) -> Bool {
        snapshot?.status.isOK == true && snapshot?.isAnonymous != true
    }

    public static func isReady(provider: ProviderID, url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        switch provider {
        case .cursor:
            guard host == "cursor.com" || host == "www.cursor.com" else { return false }
            // 含本地化前缀的 /en/dashboard 也可；登录成功中转页不算 Dashboard。
            return url.pathComponents.contains("dashboard")
        case .grok:
            guard host == "grok.com" || host == "www.grok.com" else { return false }
            let authenticationPaths = ["login", "sign-in", "sign-up", "auth"]
            return !url.pathComponents.contains { authenticationPaths.contains($0.lowercased()) }
        case .jimeng:
            return host == "jimeng.jianying.com" || host.hasSuffix(".jimeng.jianying.com")
        default:
            return false
        }
    }
}

import Foundation

/// Ollama 离屏页已经落到登录流程时的纯 URL 判定。
public enum OllamaSession {
    public static func isLoginLanding(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        let path = url.path.lowercased()

        if host == "ollama.com" || host == "www.ollama.com" {
            return path == "/signin" || path.hasPrefix("/signin/")
        }
        if host == "signin.ollama.com" {
            return true
        }
        return host.hasSuffix(".workos.com")
            && (path == "/user_management/authorize" || path.hasPrefix("/user_management/authorize/"))
    }
}

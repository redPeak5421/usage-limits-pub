import Foundation

/// Grok 登录只使用网页会话，不将认证回跳交给已安装的原生 App。
public enum GrokWebLoginPolicy {
    public static func isWebOnlyLogin(_ loginPage: URL?) -> Bool {
        guard loginPage?.scheme?.lowercased() == "https", let host = loginPage?.host else { return false }
        return LoginWebViewScripts.host(host, matches: ["grok.com", "x.ai"])
    }

    public static func blocksExternalNavigation(_ url: URL?, loginPage: URL?) -> Bool {
        guard isWebOnlyLogin(loginPage), let url else { return false }
        if let host = url.host,
           LoginWebViewScripts.host(host, matches: ["apps.apple.com", "itunes.apple.com"]) { return true }
        guard let scheme = url.scheme?.lowercased() else { return true }
        return !["https", "http", "about", "blob", "data"].contains(scheme)
    }

    /// WebKit 主动 load 原始 GET 请求，避免用户链接 / 跨域回跳触发 Universal Link。
    /// target=_blank 先由 WebKit 创建带 opener 的弹窗；不将它改载到父页面。
    public static func shouldLoadInWebView(
        _ url: URL?, sourceURL: URL?, loginPage: URL?,
        isMainFrame: Bool, isLinkActivated: Bool, httpMethod: String?
    ) -> Bool {
        guard isWebOnlyLogin(loginPage), isMainFrame,
              (httpMethod ?? "GET").uppercased() == "GET",
              let url, url.scheme?.lowercased() == "https", let host = url.host,
              LoginWebViewScripts.host(host, matches: ["grok.com", "x.ai"]) else { return false }
        return isLinkActivated || sourceURL?.host?.lowercased() != host.lowercased()
    }
}

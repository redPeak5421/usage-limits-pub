import Foundation

/// Safari 形态 iPhone UA。WKWebView 默认 UA 没有 `Version/x Safari/y`，
/// Google OAuth 会按 embedded webview 拒绝；系统版本必须与真机一致，
/// 写死旧版本会被风控打回登录页。
public enum SafariUserAgent {
    public static func make(systemVersion: String) -> String {
        let osToken = systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(systemVersion) Mobile/15E148 Safari/604.1"
    }
}

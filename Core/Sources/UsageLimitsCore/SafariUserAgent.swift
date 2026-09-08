import Foundation

/// Safari 形态 iPhone UA。WKWebView 默认 UA 没有 `Version/x Safari/y`，
/// Google OAuth 会按 embedded webview 拒绝；系统版本必须与真机一致，
/// 写死旧版本会被风控打回登录页。
///
/// iPad 上**照样发这一条 UA**，不按设备类型分叉：登录页与离屏探针共用同一条
/// （`.cursor/rules/login-webview.mdc` 的硬约束）。适配 iPad 不改 UA 是保守选择——
/// `providers/` 里的探针脚本与解析器都是照现有 UA 校准出来的，换 UA 等于一次性动了
/// 25 家的抓取口径，得逐家重新验证。
///
/// 别把这条读成「所有页面和接口必然是移动版」：站点还会看视口宽度、客户端提示等信号，
/// 而即梦接管页的视口是跟着 iPad 窗口走的（见 `WebViewFetcher.safeContentFrame`）。
/// 各家在 iPad 上的实际响应形状以真机验证为准。
public enum SafariUserAgent {
    public static func make(systemVersion: String) -> String {
        let osToken = systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(systemVersion) Mobile/15E148 Safari/604.1"
    }
}

import CryptoKit
import Foundation

/// 内嵌 WebView（登录页、OAuth 弹窗兜底、离屏探针页、即梦接管页）共用的内容拦截规则。
///
/// 为什么要拦（DEVLOG 2026-09-16）：WebKit 公开的 `evaluateJavaScript` / `callAsyncJavaScript`
/// 一律按「用户手势」执行（`forceUserGesture:YES`，没有不带手势的公开变体），页面因此拿到
/// transient activation；iPhone 上 `allowsInlineMediaPlayback` 默认 false，站点在这段时间里
/// `play()` 的 `<video>` 会被系统全屏播放器接管，盖住整个 App。即梦 `/ai-tool/home` 有 9 个
/// 自动播放视频，前后台切换都会重试起播，撞上探针轮询就弹全屏。
///
/// 规则表把媒体资源整类拦掉（不下载、不解码、readyState 到不了起播），顺带把登录页常见广告
/// 网络的子资源也拦掉（导航层的 `isAdHost` 只拦得住跳转，拦不住脚本 / 像素）。
/// 不拦站点自己的接口：SPA 的 SSR、签名器、登录态都依赖它们，泛匹配只许限定 `media`。
public enum EmbeddedWebContentPolicy {
    /// `WKContentRuleListStore` 里的 identifier 前缀；完整 identifier 由规则内容派生，
    /// 规则一变旧编译结果自然作废。
    public static let identifierPrefix = "usagelimits.embedded."

    /// WKContentRuleList 语法的 JSON。键排序固定，同样的规则永远得到同样的字符串。
    public static var contentRuleListJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static var ruleListIdentifier: String { identifier(forJSON: contentRuleListJSON) }

    /// identifier 会落成规则库里的文件名：前缀 + 内容 SHA-256 前 8 字节的十六进制。
    public static func identifier(forJSON json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return identifierPrefix + hex
    }

    /// `[/:]` 收尾避免 `adnxs.com` 误伤 `adnxs.company.example`；`([^/]+\.)?` 覆盖任意子域。
    /// 语法只用 WebKit 规则正则支持的子集（2026-09-16 macOS WebKit 编译通过）。
    static var rules: [[String: Any]] {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*", "resource-type": ["media"]], "action": ["type": "block"]],
        ]
        for host in LoginWebViewScripts.adHosts {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[/:]"],
                "action": ["type": "block"],
            ])
        }
        return rules
    }
}

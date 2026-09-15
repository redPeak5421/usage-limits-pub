import XCTest
@testable import UsageLimitsCore

/// 内嵌 WebView 内容策略：媒体整类拦截 + 广告网络子资源拦截。
///
/// 背景（DEVLOG 2026-09-16）：`evaluateJavaScript` / `callAsyncJavaScript` 在 WebKit 里一律按用户手势执行，
/// 页面因此拿到 transient activation；iPhone 上 `allowsInlineMediaPlayback` 默认 false，
/// 站点这时 `play()` 的视频会被系统全屏播放器接管，盖住整个 App（即梦首页 9 个自动播放视频）。
final class EmbeddedWebContentPolicyTests: XCTestCase {
    private func rules() throws -> [[String: Any]] {
        let data = Data(EmbeddedWebContentPolicy.contentRuleListJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]], "规则表必须是 WKContentRuleList 的顶层数组")
    }

    private func isBlock(_ rule: [String: Any]) -> Bool {
        (rule["action"] as? [String: Any])?["type"] as? String == "block"
    }

    func testRuleListBlocksMediaOnEveryURL() throws {
        let mediaRules = try rules().filter { rule in
            guard isBlock(rule), let trigger = rule["trigger"] as? [String: Any] else { return false }
            let types = trigger["resource-type"] as? [String] ?? []
            return trigger["url-filter"] as? String == ".*" && types == ["media"]
        }
        XCTAssertEqual(mediaRules.count, 1, "必须恰有一条对所有 URL 拦 media 资源的规则；不拦 script / fetch，SPA 自己的接口要留着")
        let trigger = try XCTUnwrap(mediaRules.first?["trigger"] as? [String: Any])
        XCTAssertNil(trigger["if-domain"], "if-domain 匹配的是页面域名，媒体拦截不得按页面域收窄")
    }

    func testRuleListBlocksEveryAdHostAsSubresource() throws {
        let all = try rules()
        for host in LoginWebViewScripts.adHosts {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            let matching = all.filter { rule in
                guard isBlock(rule), let trigger = rule["trigger"] as? [String: Any],
                      let filter = trigger["url-filter"] as? String else { return false }
                // 精确到整条正则：pagead2.googlesyndication.com 的规则也包含父域的转义串，子串匹配会数重
                return filter == "^https?://([^/]+\\.)?\(escaped)[/:]"
                    && trigger["resource-type"] == nil && trigger["if-domain"] == nil
            }
            XCTAssertEqual(matching.count, 1, "\(host) 必须有一条按资源 URL 拦所有类型的规则（导航层的 isAdHost 拦不到子资源）")
            let filter = try XCTUnwrap((matching.first?["trigger"] as? [String: Any])?["url-filter"] as? String)
            XCTAssertTrue(filter.hasPrefix("^"), "广告域名正则必须锚定协议开头，不能靠 .* 在查询串里误伤同站接口：\(filter)")
        }
    }

    func testRuleListDoesNotBlockSiteOwnRequests() throws {
        for rule in try rules() where isBlock(rule) {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let types = trigger["resource-type"] as? [String]
            let filter = try XCTUnwrap(trigger["url-filter"] as? String)
            if filter == ".*" {
                XCTAssertEqual(types, ["media"], "泛匹配只允许拦 media；拦 fetch / xhr / script 会打断 SSR、签名器与登录态")
            }
        }
    }

    func testRuleListIdentifierFollowsContent() {
        let a = EmbeddedWebContentPolicy.identifier(forJSON: "[]")
        XCTAssertEqual(a, EmbeddedWebContentPolicy.identifier(forJSON: "[]"), "同一内容必须得到同一 identifier，才能命中 WKContentRuleListStore 缓存")
        XCTAssertNotEqual(a, EmbeddedWebContentPolicy.identifier(forJSON: "[1]"), "规则改了 identifier 必须跟着变，旧编译结果不能被复用")
        XCTAssertTrue(a.hasPrefix(EmbeddedWebContentPolicy.identifierPrefix))
        XCTAssertEqual(
            EmbeddedWebContentPolicy.ruleListIdentifier,
            EmbeddedWebContentPolicy.identifier(forJSON: EmbeddedWebContentPolicy.contentRuleListJSON)
        )
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        XCTAssertTrue(a.unicodeScalars.allSatisfy { allowed.contains($0) }, "identifier 会落成文件名，只许字母数字与 ._-")
    }

    // MARK: - 源码契约：三处建 WKWebViewConfiguration 的地方都必须套策略

    func testFetcherAppliesPolicyToProbeWebViews() throws {
        let src = try String(contentsOf: repositoryURL().appendingPathComponent("App/Networking/WebViewFetcher.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("static func applyEmbeddedContentPolicy(to config: WKWebViewConfiguration)"), "策略入口必须是 WebViewFetcher 的静态方法，登录页与探针共用")
        XCTAssertTrue(src.contains("config.allowsInlineMediaPlayback = true"), "iPhone 默认 false：任何起播都会走系统全屏播放器")
        XCTAssertTrue(src.contains("WKContentRuleListStore"), "规则表必须经 WKContentRuleListStore 编译")
        XCTAssertTrue(src.contains("EmbeddedWebContentPolicy.ruleListIdentifier"), "编译 / 查缓存必须用内容派生的 identifier")
        XCTAssertTrue(src.contains("EmbeddedWebContentPolicy.contentRuleListJSON"))
        XCTAssertTrue(src.contains("static func prepareEmbeddedContentRules()"), "规则表要能在建 WebView 之前先编译好")
        let factory = try XCTUnwrap(src.range(of: "private func webView(for target: FetchTarget) -> WKWebView {"))
        let body = src[factory.upperBound...].prefix(600)
        XCTAssertTrue(body.contains("applyEmbeddedContentPolicy(to: config)"), "离屏探针页建配置时必须套策略")
        let probes = try XCTUnwrap(src.range(of: "private func executeProbes("))
        let probeBody = src[probes.upperBound...].prefix(700)
        XCTAssertTrue(probeBody.contains("prepareEmbeddedContentRules()"), "跑探针前必须等规则表就绪，否则冷页第一轮没有拦截")
    }

    func testLoginSheetAppliesPolicyToLoginAndPopupWebViews() throws {
        let src = try String(contentsOf: repositoryURL().appendingPathComponent("App/Auth/LoginSheetView.swift"), encoding: .utf8)
        XCTAssertEqual(
            src.components(separatedBy: "let config = WKWebViewConfiguration()").count - 1, 2,
            "登录页与 OAuth 弹窗兜底各建一次配置；新增建配置处必须同步套策略并更新本测试"
        )
        XCTAssertEqual(
            src.components(separatedBy: "WebViewFetcher.applyEmbeddedContentPolicy(to: config)").count - 1, 2,
            "两处 WKWebViewConfiguration() 都必须套策略：接管的即梦页就是登录页这张配置"
        )
        XCTAssertFalse(src.contains("allowsInlineMediaPlayback"), "inline 开关只在 applyEmbeddedContentPolicy 一处维护")
    }

    func testAppPrecompilesRulesAtLaunch() throws {
        let src = try String(contentsOf: repositoryURL().appendingPathComponent("App/UsageLimitsApp.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("WebViewFetcher.prepareEmbeddedContentRules()"), "启动即编译，登录页（同步建 WebView）才能拿到现成规则表")
    }

    private func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

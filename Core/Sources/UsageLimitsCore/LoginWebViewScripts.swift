import Foundation

/// 登录 WKWebView 注入脚本。与 I/O 分离，便于单测约束「能挡通行密钥、不能拆掉 WebAuthn 全局」。
public enum LoginWebViewScripts {
    /// 无浏览器专属权限的 WKWebView 拿不到 iCloud 钥匙串通行密钥。
    /// 只把可用性探测打成 false、并拒绝 publicKey 请求；不得把 `PublicKeyCredential`
    /// 整段删掉——ChatGPT 的 Google / Apple / 电话按钮会因此 onClick 空转。
    public static let hideWebAuthn = """
    (function () {
        try {
            var C = window.PublicKeyCredential;
            if (C) {
                C.isUserVerifyingPlatformAuthenticatorAvailable = function () {
                    return Promise.resolve(false);
                };
                C.isConditionalMediationAvailable = function () {
                    return Promise.resolve(false);
                };
            }
        } catch (e) {}
        try {
            if (navigator.credentials) {
                var reject = function () {
                    return Promise.reject(new DOMException('Passkeys unavailable in embedded web view', 'NotSupportedError'));
                };
                var origGet = navigator.credentials.get.bind(navigator.credentials);
                var origCreate = navigator.credentials.create.bind(navigator.credentials);
                navigator.credentials.get = function (o) { return o && o.publicKey ? reject() : origGet(o); };
                navigator.credentials.create = function (o) { return o && o.publicKey ? reject() : origCreate(o); };
            }
        } catch (e) {}
    })();
    """

    /// 去掉 Smart App Banner /「打开 App」条，避免把用户从内置登录页踢到商店。
    /// 不得改 `PublicKeyCredential`。
    public static let hideSmartAppBanner = """
    (function () {
        try {
            document.querySelectorAll('meta[name="apple-itunes-app"]').forEach(function (n) { n.remove(); });
        } catch (e) {}
        try {
            var css = document.createElement('style');
            css.textContent = '.smartbanner,.smart-banner,[class*="smart-app-banner"],[id*="smartbanner"],[class*="SmartAppBanner"]{display:none!important;height:0!important;overflow:hidden!important}';
            (document.head || document.documentElement).appendChild(css);
        } catch (e) {}
    })();
    """


    /// 即梦等站把 Apple / 字节护照放在 iframe 里。WKWebView 会走系统
    /// `SOAuthorizationCoordinator` 拦子框导航，结果是 NSURLErrorCancelled（-999），
    /// 会话 Cookie 落不到 `jimeng.jianying.com`，登录页看起来过了、探针仍当未登录。
    /// 这些主机的子框必须提到顶层弹窗（主框 SSO 系统才能接住）。
    public static let ssoPopupHosts = [
        "appleid.apple.com",
        "idmsa.apple.com",
        "appleid.cdn-apple.com",
        "gsa.apple.com",
        "login.oceanengine.com",
        "sso.oceanengine.com",
        "passport.oceanengine.com",
        "sso.douyin.com",
        "open.douyin.com",
        "login.douyin.com",
        "passport.douyin.com",
        "login.capcut.com",
        "sso.capcut.com",
        "login.jianying.com",
        "sso.jianying.com",
        "passport.jianying.com",
        "login.bytedance.com",
        "sso.bytedance.com",
        "passport.bytedance.com",
    ]

    public static func shouldPromoteIFrameToPopup(host: String) -> Bool {
        shouldPromoteIFrameToPopup(urlHost: host, path: "/")
    }

    public static func shouldPromoteIFrameToPopup(url: URL) -> Bool {
        shouldPromoteIFrameToPopup(urlHost: url.host ?? "", path: url.path)
    }

    /// `www.douyin.com` 上只有登录 / 护照路径才提升；视频页 iframe 不要动。
    /// Google / Microsoft / GitHub 等第三方登录弹窗；不得与广告域名混为一谈。
    public static let authPopupHosts = ssoPopupHosts + [
        "accounts.google.com",
        "accounts.youtube.com",
        "oauth2.googleapis.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "github.com",
        "gitlab.com",
        "accounts.x.ai",
        "x.com",
    ]

    /// 登录页常见广告网络。只拦导航/弹窗，不碰 Cookie、不拦同站接口。
    public static let adHosts = [
        "googlesyndication.com",
        "doubleclick.net",
        "googleadservices.com",
        "adservice.google.com",
        "pagead2.googlesyndication.com",
        "adnxs.com",
        "adsrvr.org",
        "criteo.com",
        "taboola.com",
        "outbrain.com",
        "pubmatic.com",
        "ads-twitter.com",
        "amazon-adsystem.com",
        "adsafeprotected.com",
        "moatads.com",
    ]

    public static func host(_ host: String, matches roots: [String]) -> Bool {
        let host = host.lowercased()
        return roots.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    public static func isAdHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        return Self.host(host, matches: adHosts)
    }

    /// App Store / iTunes 深链。登录页 Smart App Banner 的「打开」走这些 scheme。
    public static func isAppStoreNavigation(_ url: URL?) -> Bool {
        guard let url else { return false }
        switch url.scheme?.lowercased() {
        case "itms", "itms-apps", "itms-appss", "itms-services", "macappstore":
            return true
        default:
            return false
        }
    }

    public static func isSameSite(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return true }
        if a.hasSuffix("." + b) || b.hasSuffix("." + a) { return true }
        let ra = a.split(separator: ".").suffix(2).joined(separator: ".")
        let rb = b.split(separator: ".").suffix(2).joined(separator: ".")
        return ra.contains(".") && ra == rb
    }

    /// `window.open` / 弹窗导航：OAuth 与同站登录放行；广告域名一律拒绝。
    /// `about:blank` 先放行（Google 常先开空白再跳转），后续导航再审。
    public static func shouldPresentLoginPopup(url: URL?, loginPage: URL?) -> Bool {
        guard let url else { return true }
        // 安装链接经常没有 host，必须在空 host / OAuth 路径放行之前拒绝。
        if isAppStoreNavigation(url) { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || url.absoluteString == "about:blank" { return true }
        guard let host = url.host, !host.isEmpty else { return true }
        if isAdHost(host) { return false }
        if Self.host(host, matches: authPopupHosts) { return true }
        if let loginHost = loginPage?.host, isSameSite(host, loginHost) { return true }
        // 官网登录会跨两个自有域回跳。不能在响应设置会话 Cookie 前取消导航。
        if let loginHost = loginPage?.host {
            for sites in [["x.ai", "grok.com"], ["cursor.com", "cursor.sh"]] {
                if Self.host(loginHost, matches: sites), Self.host(host, matches: sites) { return true }
            }
        }
        let hay = (url.path + "?" + (url.query ?? "")).lowercased()
        let authHints = ["oauth", "sso", "authorize", "auth", "signin", "callback", "passport", "login"]
        if authHints.contains(where: { hay.contains($0) }) { return true }
        return false
    }

    public static func shouldPromoteIFrameToPopup(urlHost: String, path: String) -> Bool {
        let host = urlHost.lowercased()
        if ssoPopupHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }
        if host == "douyin.com" || host.hasSuffix(".douyin.com") {
            let path = path.lowercased()
            return ["login", "passport", "ucenter", "sso", "oauth", "apple"].contains { path.contains($0) }
        }
        return false
    }

    /// 系统 SOAuthorization 可能在 `decidePolicyFor` 之前就取消子框。
    /// 页面一插入护照 iframe，立刻 `window.open` 提到顶层，交给 `createWebViewWith`。
    public static var promoteSSOIframes: String {
        let roots = ssoPopupHosts.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        (function () {
            var roots = [\(roots)];
            function match(host, path) {
                host = String(host || '').toLowerCase();
                path = String(path || '').toLowerCase();
                if (roots.some(function (root) {
                    return host === root || host.slice(-root.length - 1) === '.' + root;
                })) return true;
                if (host === 'douyin.com' || host.slice(-11) === '.douyin.com') {
                    return /login|passport|ucenter|sso|oauth|apple/.test(path);
                }
                return false;
            }
            function promote(iframe) {
                try {
                    if (!iframe || iframe.getAttribute('data-aiusg-sso') === '1') return;
                    var src = iframe.getAttribute('src') || '';
                    if (!src) return;
                    var parsed = new URL(src, location.href);
                    if (!match(parsed.hostname, parsed.pathname)) return;
                    iframe.setAttribute('data-aiusg-sso', '1');
                    window.open(src);
                    if (iframe.parentNode) { iframe.parentNode.removeChild(iframe); }
                } catch (e) {}
            }
            function scan(node) {
                if (!node) return;
                if (node.tagName === 'IFRAME') promote(node);
                if (!node.querySelectorAll) return;
                var list = node.querySelectorAll('iframe');
                for (var i = 0; i < list.length; i++) { promote(list[i]); }
            }
            var obs = new MutationObserver(function (muts) {
                for (var i = 0; i < muts.length; i++) {
                    var m = muts[i];
                    if (m.type === 'attributes' && m.target && m.target.tagName === 'IFRAME') {
                        promote(m.target);
                    }
                    var nodes = m.addedNodes || [];
                    for (var j = 0; j < nodes.length; j++) {
                        if (nodes[j].nodeType === 1) scan(nodes[j]);
                    }
                }
            });
            try { scan(document.documentElement); } catch (e) {}
            try {
                obs.observe(document.documentElement || document, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src']
                });
            } catch (e) {}
        })();
        """
    }
}

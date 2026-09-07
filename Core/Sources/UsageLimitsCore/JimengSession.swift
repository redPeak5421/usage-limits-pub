import Foundation

/// 即梦登录态的本机旁证：会话 Cookie 与 CSRF。
/// `passport_csrf_token` 经常是 HttpOnly，页面 `document.cookie` 读不到，
/// 必须从 WKHTTPCookieStore 取出再交给探针当 `x-tt-passport-csrf-token`。
public enum JimengSession {
    public static let csrfCookieNames = [
        "passport_csrf_token",
        "passport_csrf_token_default",
        "csrf_token",
    ]

    /// 有这些 Cookie 之一，说明字节护照已经写下会话（不是匿名 ttwid）。
    public static let sessionCookieNames: Set<String> = [
        "sessionid", "sessionid_ss", "sid_tt", "sid_guard",
    ]

    public static func cookieValue(names: [String], from cookies: [(name: String, value: String)]) -> String? {
        var map: [String: String] = [:]
        for cookie in cookies {
            map[cookie.name.lowercased()] = cookie.value
        }
        for name in names {
            if let value = map[name.lowercased()], !value.isEmpty { return value }
        }
        return nil
    }

    public static func csrfToken(from cookies: [(name: String, value: String)]) -> String? {
        cookieValue(names: csrfCookieNames, from: cookies)
    }

    public static func msToken(from cookies: [(name: String, value: String)]) -> String? {
        cookieValue(names: ["mstoken"], from: cookies)
    }

    /// 官网 secsdk 也会把运行时 `uifid` 写成 Cookie。只从本机 Cookie 库取，禁止写死。
    public static func uifid(from cookies: [(name: String, value: String)]) -> String? {
        cookieValue(names: ["uifid"], from: cookies)
    }

    /// 官网 Web 客户端公开常量（不是用户凭据）：`Appvr`、`Pf: 7`；`Appid: 513695` 直接写在探针脚本里。
    public static let appVersion = "5.8.0"
    public static let platform = "7"

    /// commerce 接口（`/commerce/v1/benefits/*`）的请求签名。官网 secsdk `webSignBody`
    /// 产出的就是这三个头：`Device-Time`（Unix 秒）、`Sign`、`Sign-Ver: 1`。
    /// `Sign = md5("9e2c|" + uri 末 7 位 + "|" + Pf + "|" + Appvr + "|" + deviceTime + "||11ac")`。
    /// 页面签名器没挂上（匿名 SSR / 离屏冷页）时由 native 算好注入探针；
    /// 不签名会稳定回 `ret=1014 system busy`（2026-08-24/25 模拟器日志）。
    public static func signPayload(uri: String, deviceTime: Int) -> String {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let tail = String(path.suffix(7))
        return "9e2c|\(tail)|\(platform)|\(appVersion)|\(deviceTime)||11ac"
    }

    /// 探针要签的两个 commerce 路径。
    public static let creditPath = "/commerce/v1/benefits/user_credit"
    public static let historyPath = "/commerce/v1/benefits/user_credit_history"

    public static func indicatesLogin(cookieNames: [String]) -> Bool {
        let set = Set(cookieNames.map { $0.lowercased() })
        return !set.isDisjoint(with: sessionCookieNames)
    }

    /// 官网 `/ai-tool/home` SSR 写入的登录标志。未登录是 `window.__isLogined=false`，
    /// 已登录会变成 true，并注入 `window.__userInfo`。只回报布尔，不带回账号 id。
    public static let pageLoginScript = """
    (function () {
        var user = (typeof window !== 'undefined' && window.__userInfo) || null;
        var hasUserInfo = !!(user && (user.sec_uid || user.sec_user_id || user.secUid || user.user_id || user.userId || user.uid));
        return (typeof window !== 'undefined' && window.__isLogined === true) || hasUserInfo;
    })()
    """

    public static func pageIndicatesLogin(isLogined: Bool, hasUserInfo: Bool) -> Bool {
        isLogined || hasUserInfo
    }

    /// Cookie / 通行证旁证只能弹确认。额度 POST 必须等官网 SSR 已登录且签名器挂上。
    public static func isCommerceReady(isLogined: Bool, hasSigner: Bool) -> Bool {
        isLogined && hasSigner
    }

    /// 已经停在产品首页且 SSR 已登录：复用这张文档，不要另开离屏冷页。
    public static func shouldReuseWarmDocument(isOnHome: Bool, isLogined: Bool) -> Bool {
        isOnHome && isLogined
    }

    /// 不在 /ai-tool/home，或仍是匿名 SSR：重载官网首页，等 `__isLogined`。
    public static func shouldReloadWarmHome(isOnHome: Bool, isLogined: Bool, hasSigner: Bool) -> Bool {
        !isOnHome || (!isLogined && !hasSigner)
    }
}

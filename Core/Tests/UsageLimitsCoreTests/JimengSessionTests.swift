import XCTest
@testable import UsageLimitsCore

final class JimengSessionTests: XCTestCase {
    func testSessionCookiesIndicateLoginAndIgnoreAnonymousTtwid() {
        XCTAssertTrue(JimengSession.indicatesLogin(cookieNames: ["sessionid"]))
        XCTAssertTrue(JimengSession.indicatesLogin(cookieNames: ["sid_tt", "ttwid"]))
        XCTAssertTrue(JimengSession.indicatesLogin(cookieNames: ["sessionid_ss"]))
        XCTAssertFalse(JimengSession.indicatesLogin(cookieNames: ["ttwid"]))
        XCTAssertFalse(JimengSession.indicatesLogin(cookieNames: []))
    }

    func testCsrfTokenPrefersPassportCookie() {
        XCTAssertEqual(
            JimengSession.csrfToken(from: [
                (name: "ttwid", value: "x"),
                (name: "passport_csrf_token", value: "abc"),
            ]),
            "abc"
        )
        XCTAssertEqual(
            JimengSession.csrfToken(from: [(name: "passport_csrf_token_default", value: "def")]),
            "def"
        )
        XCTAssertNil(JimengSession.csrfToken(from: [(name: "sessionid", value: "sid")]))
    }

    func testOfficialPageFlagIndicatesLogin() {
        XCTAssertTrue(JimengSession.pageIndicatesLogin(isLogined: true, hasUserInfo: false))
        XCTAssertTrue(JimengSession.pageIndicatesLogin(isLogined: false, hasUserInfo: true))
        XCTAssertFalse(JimengSession.pageIndicatesLogin(isLogined: false, hasUserInfo: false))
        XCTAssertTrue(JimengSession.pageLoginScript.contains("window.__isLogined"))
        XCTAssertTrue(JimengSession.pageLoginScript.contains("window.__userInfo"))
        XCTAssertFalse(JimengSession.pageLoginScript.contains("sec_uid ="), "登录脚本不得写死账号 id")
    }

    func testMsTokenReadsCookieStoreValue() {
        XCTAssertEqual(
            JimengSession.msToken(from: [(name: "msToken", value: "runtime-token")]),
            "runtime-token"
        )
        XCTAssertNil(JimengSession.msToken(from: [(name: "sessionid", value: "sid")]))
    }

    func testUifidReadsCookieStoreValue() {
        XCTAssertEqual(
            JimengSession.uifid(from: [(name: "uifid", value: "runtime-uifid")]),
            "runtime-uifid"
        )
        XCTAssertNil(JimengSession.uifid(from: [(name: "sessionid", value: "sid")]))
    }

    /// 13:23 真机：sessionCookie=true 但 __isLogined=false。Cookie 只能弹确认，不能当额度已就绪。
    func testCookieSessionAloneIsNotCommerceReady() {
        XCTAssertFalse(
            JimengSession.isCommerceReady(isLogined: false, hasSigner: false),
            "jianying 会话 Cookie 不是即梦 SSR 已接受"
        )
        XCTAssertFalse(
            JimengSession.isCommerceReady(isLogined: false, hasSigner: true),
            "有签名器但首页仍匿名时，不能声称已拿到用量"
        )
        XCTAssertFalse(
            JimengSession.isCommerceReady(isLogined: true, hasSigner: false),
            "SSR 已登录但 webSignBody 未挂上时，commerce POST 仍会 1014"
        )
        XCTAssertTrue(JimengSession.isCommerceReady(isLogined: true, hasSigner: true))
    }

    /// 首页下拉必须复用已经跑过官网 SPA 的文档，不能每次新建离屏冷页。
    func testWarmHomeDocumentShouldBeReused() {
        XCTAssertTrue(
            JimengSession.shouldReuseWarmDocument(isOnHome: true, isLogined: true),
            "登录页已 hydrate 就复用，签名器稍后才挂上也不得重载冷文档"
        )
        XCTAssertFalse(JimengSession.shouldReuseWarmDocument(isOnHome: false, isLogined: false))
        XCTAssertFalse(
            JimengSession.shouldReloadWarmHome(isOnHome: true, isLogined: true, hasSigner: true),
            "热文档在 /ai-tool/home 且已登录时禁止再 load 一次"
        )
        XCTAssertTrue(
            JimengSession.shouldReloadWarmHome(isOnHome: false, isLogined: false, hasSigner: false),
            "不在产品首页就必须回到 /ai-tool/home"
        )
        XCTAssertTrue(
            JimengSession.shouldReloadWarmHome(isOnHome: true, isLogined: false, hasSigner: false),
            "停在匿名 SSR 时，护照 SSO 之后必须重载 home 等 __isLogined"
        )
    }

    /// commerce 签名串：官网 Web 客户端公开算法，uri 只取路径末 7 位，不含 query。
    func testCommerceSignPayloadMatchesOfficialWebClient() {
        XCTAssertEqual(
            JimengSession.signPayload(uri: "/commerce/v1/benefits/user_credit", deviceTime: 1733966964),
            "9e2c|_credit|7|5.8.0|1733966964||11ac"
        )
        XCTAssertEqual(
            JimengSession.signPayload(uri: "/commerce/v1/benefits/user_credit_history?timestamp=1", deviceTime: 1),
            "9e2c|history|7|5.8.0|1||11ac"
        )
    }

    func testUserLoggedInBooleanIsLoginProofWithoutRawIDs() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let loggedIn = JimengParser.parse(results: [
            "user": ProbeResult(status: 200, body: #"{"loggedIn":true}"#)
        ], now: now)
        XCTAssertEqual(loggedIn.status, .ok)

        let loggedOut = JimengParser.parse(results: [
            "user": ProbeResult(status: 200, body: #"{"loggedIn":false}"#)
        ], now: now)
        XCTAssertEqual(loggedOut.status, .needsLogin)

        let legacy = JimengParser.parse(results: [
            "user": ProbeResult(status: 200, body: #"{"data":{"sec_uid":"MS4wLjABAAAAPLACEHOLDER"}}"#)
        ], now: now)
        XCTAssertEqual(legacy.status, .ok)
    }
}

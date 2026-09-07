import JavaScriptCore
import XCTest
@testable import UsageLimitsCore

/// 已登录探测不得直接关页：确认/拒绝决策与文案契约。
final class LoginConfirmTests: XCTestCase {
    func testGrokWaitingPageChecksFreshSharedWebsiteSession() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Auth/LoginSheetView.swift"))
        let appState = try String(contentsOf: root.appendingPathComponent("App/AppState.swift"))
        XCTAssertTrue(source.contains("if provider == .grok {"))
        XCTAssertTrue(source.contains("let checkedPage = loginPage.activeWebView"))
        XCTAssertTrue(source.contains("using: live)"))
        XCTAssertTrue(appState.contains("using webView: WKWebView?"), "认证中转页必须可在同账号离屏网页重新获取会话证据")
        let check = try XCTUnwrap(appState.range(of: "func checkLogin("))
        let next = try XCTUnwrap(appState.range(of: "private func appendProbeDiagnostics", range: check.upperBound..<appState.endIndex))
        let body = String(appState[check.lowerBound..<next.lowerBound])
        XCTAssertTrue(body.contains("fetcher.runProbes"))
        XCTAssertFalse(body.contains("store.snapshot"), "禁止拿旧快照假装新登录成功")
        XCTAssertFalse(body.contains("store.save"), "用户确认前只验证会话")
    }

    func testGrokWebNavigationKeepsPopupAndCancelsAppHandoff() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Auth/LoginSheetView.swift"))
        XCTAssertEqual(source.components(separatedBy: "GrokWebLoginPolicy.blocksExternalNavigation").count - 1, 2)
        XCTAssertTrue(source.contains("webView.load(navigationAction.request)"), "在原视图重载完整回跳请求")
        XCTAssertTrue(source.contains("webOnlyReloads.removeValue(forKey: viewID)"), "程序重载只能放行一次，避免循环")
        XCTAssertFalse(source.contains("WKNavigationActionPolicy(rawValue:"), "不得使用私有的 allowWithoutTryingAppLink 枚举值")
        for key in ["login.webOnlyBlocked", "login.continueOnWeb"] {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] { XCTAssertNotEqual(L10n.tr(key, lang), key) }
        }
    }

    func testProviderLoginPopupsKeepCrossDomainCallbacks() {
        let grok = URL(string: "https://accounts.x.ai/sign-in")!
        XCTAssertTrue(LoginWebViewScripts.shouldPresentLoginPopup(
            url: URL(string: "https://grok.com/"), loginPage: grok
        ), "xAI 登录回到 Grok 后必须继续导航，不能在会话落盘前关闭弹窗")
        let cursor = URL(string: "https://cursor.com/dashboard")!
        XCTAssertTrue(LoginWebViewScripts.shouldPresentLoginPopup(
            url: URL(string: "https://authenticator.cursor.sh/"), loginPage: cursor
        ), "Cursor 跨域认证页面必须保留")
        XCTAssertFalse(LoginWebViewScripts.shouldPresentLoginPopup(
            url: URL(string: "https://grok.com.evil.example/"), loginPage: grok
        ))
        XCTAssertFalse(LoginWebViewScripts.shouldPresentLoginPopup(
            url: URL(string: "https://authenticator.cursor.sh.evil.example/"), loginPage: cursor
        ))
    }

    func testGrokAndCursorChecksUseCurrentLoginDocumentAndFreshResults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Auth/LoginSheetView.swift"))
        XCTAssertTrue(source.contains("LoginProbePolicy.isReady"), "登录文档就绪前不得用离屏游客页验证")
        XCTAssertTrue(source.contains("LoginProbePolicy.isAuthenticated"), "游客额度不能当成已登录")
        XCTAssertTrue(source.contains("state.checkLogin"), "检测必须读本次探针，不能接受 last-good 缓存")
        XCTAssertTrue(source.contains("loginPage.activeWebView"), "OAuth 弹窗中的已登录文档也应参与检测")
        XCTAssertTrue(source.contains("LoginProbePolicy.isAuthenticationPage"),
                      "拒绝账号 A 后进入认证页时应解除自动提示抑制，允许账号 B 再次确认")
    }

    func testAccountLabelPrefersSiteIdentityOverDisplayName() {
        XCTAssertEqual(
            LoginConfirm.accountLabel(siteIdentity: "user@example.com", displayName: "Claude"),
            "user@example.com"
        )
        XCTAssertEqual(
            LoginConfirm.accountLabel(siteIdentity: "  ", displayName: "Claude"),
            "Claude"
        )
        XCTAssertEqual(
            LoginConfirm.accountLabel(siteIdentity: nil, displayName: "个人号"),
            "个人号"
        )
    }

    func testProbeOKWithoutSuppressionPromptsConfirmation() {
        let action = LoginConfirm.action(
            probeOK: true,
            alreadyDetected: false,
            confirmationVisible: false,
            autoPromptSuppressed: false,
            siteIdentity: "a@b.com",
            displayName: "Claude"
        )
        XCTAssertEqual(action, .prompt(accountLabel: "a@b.com"))
    }

    func testProbeNotOKWaits() {
        let action = LoginConfirm.action(
            probeOK: false,
            alreadyDetected: false,
            confirmationVisible: false,
            autoPromptSuppressed: false,
            siteIdentity: nil,
            displayName: "Claude"
        )
        XCTAssertEqual(action, .wait)
    }

    func testDeclineDoesNotMarkDetectedAndSuppressesAutoAccept() {
        let outcome = LoginConfirm.Outcome.applying(.decline)
        XCTAssertFalse(outcome.markDetected)
        XCTAssertFalse(outcome.dismissAsSuccess)
        XCTAssertTrue(outcome.suppressFurtherAutoAccept)

        let suppressed = LoginConfirm.action(
            probeOK: true,
            alreadyDetected: false,
            confirmationVisible: false,
            autoPromptSuppressed: true,
            siteIdentity: "a@b.com",
            displayName: "Claude"
        )
        XCTAssertEqual(suppressed, .wait, "否之后不得立刻把同一会话当成功登录")
    }

    func testSuppressionStaysUntilSessionDrops() {
        XCTAssertTrue(
            LoginConfirm.stillSuppressAutoPrompt(probeOK: true, currentlySuppressed: true),
            "点否后只要仍是已登录会话，就必须继续抑制自动接受"
        )
        XCTAssertFalse(
            LoginConfirm.stillSuppressAutoPrompt(probeOK: false, currentlySuppressed: true),
            "用户退出当前会话后应允许下一次登录再确认"
        )
        XCTAssertFalse(LoginConfirm.stillSuppressAutoPrompt(probeOK: true, currentlySuppressed: false))
    }

    func testAcceptMarksDetectedAndDismisses() {
        let outcome = LoginConfirm.Outcome.applying(.accept)
        XCTAssertTrue(outcome.markDetected)
        XCTAssertTrue(outcome.dismissAsSuccess)
        XCTAssertFalse(outcome.suppressFurtherAutoAccept)
    }

    func testConfirmationCopyKeysResolveInAllLanguages() {
        let keys = [
            "login.alreadySignedIn",
            "login.signedInAccount",
            "login.confirmUse",
            "login.confirm.yes",
            "login.confirm.no",
        ]
        for key in keys {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                let value = L10n.tr(key, lang)
                XCTAssertFalse(value.isEmpty, "\(key) \(lang) 缺文案")
                XCTAssertNotEqual(value, key, "\(key) \(lang) 未翻译")
            }
        }
        XCTAssertEqual(L10n.tr("login.alreadySignedIn", .zh), "已经登录")
        XCTAssertEqual(L10n.tr("login.signedInAccount", .zh, "xxxx"), "登录账号：xxxx")
        XCTAssertEqual(L10n.tr("login.confirmUse", .zh), "是否登录")
    }

    /// 源码契约：探到 ok 必须走 LoginConfirm，不得仅因探针成功就 detected+dismiss。
    func testLoginSheetDoesNotAutoDismissOnProbeOK() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Auth/LoginSheetView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("LoginConfirm.action"), "登录探测必须走可测试的确认决策")
        XCTAssertTrue(src.contains("login.alreadySignedIn"))
        XCTAssertTrue(src.contains("login.signedInAccount"))
        XCTAssertTrue(src.contains("login.confirmUse"))
        XCTAssertTrue(src.contains("LoginConfirm.Outcome.applying"))
        XCTAssertTrue(src.contains("LoginConfirm.Choice.decline") || src.contains(".decline"))
        XCTAssertTrue(src.contains("LoginConfirm.stillSuppressAutoPrompt"),
                      "否之后的抑制必须走可测试决策，不能靠下一次 didFinish 立刻清掉")
        XCTAssertFalse(
            src.contains("suppressAutoPrompt = false\n                    Task { await runCheck"),
            "页面加载完成不得把点否的抑制清掉，否则同一会话会立刻再弹/再接受"
        )
        XCTAssertFalse(
            src.contains("if snap?.status.isOK == true {\n            detected = true"),
            "不得仅因探针 ok 就把 detected 置位并关页"
        )
    }

    /// Google / Apple 登录走 window.open；iOS WKWebView 默认禁弹窗，必须显式打开并接住新窗口。
    func testLoginWebViewHandlesOAuthPopups() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Auth/LoginSheetView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("javaScriptCanOpenWindowsAutomatically = true"),
                      "不打开 JS 弹窗，Google 按钮会立刻失败并停在登录页")
        XCTAssertTrue(src.contains("WKUIDelegate"), "必须接住 window.open 才能走完 OAuth")
        XCTAssertTrue(src.contains("createWebViewWith"), "必须用 WebKit 给的 configuration 建弹窗")
        XCTAssertTrue(src.contains("shouldPresentLoginPopup"), "广告弹窗不得盖住登录页")
        XCTAssertTrue(src.contains("isAdHost"), "登录页广告主机必须取消导航")
        XCTAssertTrue(src.contains("webViewDidClose"), "OAuth 完成后要拆掉弹窗，避免挡登录页")
        XCTAssertTrue(src.contains("decidePolicyFor"), "护照 iframe 必须在导航策略里提到弹窗")
        XCTAssertTrue(src.contains("shouldPromoteIFrameToPopup"), "子框提升名单必须可单测")
        XCTAssertTrue(src.contains("promoteSSOIframes"), "护照 iframe 必须在系统 SOAuthorization 之前 window.open")
        XCTAssertTrue(src.contains("window.open('"), "提升 iframe 必须 window.open，不能自己 new WKWebView（会丢 opener）")
        XCTAssertTrue(src.contains("jimengIndicatesLogin"), "即梦会话 Cookie 必须能作为登录旁证")
        XCTAssertTrue(src.contains("jimengPageIndicatesLogin"), "即梦必须读官网 window.__isLogined")
        XCTAssertTrue(src.contains("reloadJimengHomeAfterSSO"), "护照弹窗关闭后必须重载 home，SSR 标志才会变成 true")
        XCTAssertTrue(src.contains("liveProbeWebView"), "即梦登录页同源时必须在这张 WebView 里跑探针")
        XCTAssertTrue(src.contains("prepareJimengLivePage"), "确认后必须先等登录页签名，不能对冷文档立刻 fetch")
        XCTAssertTrue(src.contains("refreshUsageAfterConfirm"), "cookiesOK 提前返回后，点确认仍必须刷新用量")
        XCTAssertTrue(src.contains("adoptLiveJimengWebView"), "确认后必须把登录页 WKWebView 交给探针复用")
        XCTAssertFalse(
            src.contains("WKWebView(frame: .zero"),
            "登录页/弹窗不得用零尺寸初始化，否则 Invalid frame dimension"
        )
    }

    func testIFrameSSOHostsArePromotedToPopup() {
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "appleid.apple.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "gsa.apple.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "login.oceanengine.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "sso.oceanengine.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "sso.douyin.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "passport.jianying.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "passport.bytedance.com"))
        XCTAssertTrue(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "passport.douyin.com"))
        XCTAssertTrue(
            LoginWebViewScripts.shouldPromoteIFrameToPopup(
                url: URL(string: "https://www.douyin.com/ucenter_web/login/callback")!
            ),
            "抖音 Apple 回跳必须提到弹窗，且走 window.open 保留 opener"
        )
        XCTAssertFalse(
            LoginWebViewScripts.shouldPromoteIFrameToPopup(
                url: URL(string: "https://www.douyin.com/video/123")!
            ),
            "不要提升抖音视频 iframe"
        )
        XCTAssertFalse(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "jimeng.jianying.com"))
        XCTAssertFalse(LoginWebViewScripts.shouldPromoteIFrameToPopup(host: "www.google.com"))
    }

    func testLoginPopupsAllowOAuthAndBlockAds() {
        let login = URL(string: "https://claude.ai/login")!
        XCTAssertTrue(LoginWebViewScripts.isAdHost("pagead2.googlesyndication.com"))
        XCTAssertTrue(LoginWebViewScripts.isAdHost("ad.doubleclick.net"))
        XCTAssertFalse(LoginWebViewScripts.isAdHost("accounts.google.com"))
        XCTAssertTrue(
            LoginWebViewScripts.shouldPresentLoginPopup(
                url: URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
                loginPage: login
            )
        )
        XCTAssertTrue(
            LoginWebViewScripts.shouldPresentLoginPopup(
                url: URL(string: "about:blank"),
                loginPage: login
            ),
            "Google 先开空白窗，必须先建 WebView 才能保留 opener"
        )
        XCTAssertFalse(
            LoginWebViewScripts.shouldPresentLoginPopup(
                url: URL(string: "https://pagead2.googlesyndication.com/pagead/ads"),
                loginPage: login
            )
        )
        XCTAssertFalse(
            LoginWebViewScripts.shouldPresentLoginPopup(
                url: URL(string: "https://random-promo.example/offer"),
                loginPage: login
            )
        )
    }


    func testPromoteSSOIframesScriptOpensListedHostsOnly() {
        let js = LoginWebViewScripts.promoteSSOIframes
        XCTAssertTrue(js.contains("MutationObserver"))
        XCTAssertTrue(js.contains("window.open"))
        for host in LoginWebViewScripts.ssoPopupHosts {
            XCTAssertTrue(js.contains(host), "提升脚本必须含 \(host)")
        }
        XCTAssertFalse(js.contains("jimeng.jianying.com"), "不要提升即梦自己的 iframe")
        XCTAssertTrue(js.contains("ucenter") && js.contains(".douyin.com"), "抖音登录回跳路径必须提升")
    }

    func testJimengFetcherWaitsForSessionAndCanReuseLoginWebView() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Networking/WebViewFetcher.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("waitForJimengSession"), "home 加载完必须等会话 Cookie / msToken")
        XCTAssertTrue(src.contains("waitForJimengHomeReady"), "必须等 window.use / webSignBody")
        XCTAssertTrue(src.contains("typeof window.use"), "native 必须探测 window.use")
        XCTAssertTrue(src.contains("webSignBody"), "native 必须探测 webSignBody")
        XCTAssertTrue(src.contains("adoptLiveJimengWebView"), "登录确认后必须接管可见 WKWebView")
        XCTAssertTrue(src.contains("retainedLiveJimengWebView"), "首页下拉必须能取出已接管的热文档")
        XCTAssertTrue(src.contains("insertSubview"), "即梦探针必须挂进现有窗口层次，全尺寸，不能再造 alpha 0.02 窗")
        XCTAssertFalse(
            src.contains("alpha = 0.02") || src.contains("window.alpha = 0.02"),
            "13:23 真机 freezer 会杀掉近乎透明 WebContent，禁止再走 alpha 0.02"
        )
        XCTAssertFalse(src.contains("windowLevel"), "不得再靠 windowLevel 藏窗")
        XCTAssertTrue(src.contains("isUserInteractionEnabled = false"), "挡在首页后面的探针页不得拦截点击")
        XCTAssertFalse(src.contains("makeKeyAndVisible"), "不得抢 key window")
        XCTAssertFalse(src.contains("-2400"), "不得再把窗移到屏幕外")
        XCTAssertTrue(src.contains("waitForJimengHomeReady"), "SSO 后必须等 __isLogined，不能只等 webSignBody")
        XCTAssertTrue(src.contains("shouldReuseWarmDocument"), "已在 /ai-tool/home 的热文档禁止再冷加载")
        XCTAssertTrue(src.contains("appleid.apple.com"), "离屏 decidePolicy 只取消 Apple SSO")
        XCTAssertTrue(src.contains("idmsa.apple.com"))
        XCTAssertTrue(src.contains("appleid.cdn-apple.com"))
        XCTAssertTrue(src.contains("gsa.apple.com"))
        XCTAssertFalse(
            src.contains("LoginWebViewScripts.shouldPromoteIFrameToPopup"),
            "离屏探针不得按登录页提升名单一律 cancel iframe"
        )
        XCTAssertTrue(src.contains(#"{"hasSession":true}"#), "session 探针只许布尔 true")
        XCTAssertTrue(src.contains(#"{"hasSession":false}"#), "session 探针只许布尔 false")
        XCTAssertTrue(src.contains("results[\"session\"]"), "探针成功后注入 session")
        XCTAssertFalse(src.contains("return window._secsdk_uifid"), "就绪探测不得回报 uifid")
        XCTAssertFalse(src.contains("return uifid"), "就绪探测不得回报 uifid")
        XCTAssertFalse(src.contains("return hasUifid"), "就绪等待不得要求 uifid")
        XCTAssertTrue(src.contains("JimengSession.msToken"), "HttpOnly 之外的 msToken 也要从 Cookie 库注入")
        XCTAssertTrue(src.contains("JimengSession.uifid"), "Cookie 库里的 uifid 也要运行时注入，禁止写死")
        XCTAssertTrue(src.contains("using existingWebView"), "登录页同源探针不得另开冷文档")
        XCTAssertTrue(src.contains("pageLoginScript"), "必须能在登录页直接读官网 SSR 登录标志")
        XCTAssertTrue(src.contains("discardHostWindow"), "离屏窗必须在 discard/clear 时拆掉")
        XCTAssertTrue(src.contains("prepareJimengLivePage"), "确认后的可见页必须等加载/签名再探针")
        XCTAssertTrue(src.contains("waitUntilJimengPageSettled"), "复用登录页时必须等 isLoading 结束")
        XCTAssertTrue(src.contains("ownsJimengLiveWebView"), "登录页 dismantle 不得停掉已接管的热文档")
        XCTAssertFalse(
            src.contains("WKWebView(frame: .zero"),
            "离屏 WKWebView 不得用零尺寸，否则 Invalid frame dimension"
        )
    }

    func testDashboardRefreshReusesAdoptedJimengWebView() throws {
        let appState = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/AppState.swift")
        let login = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Auth/LoginSheetView.swift")
        let appSrc = try String(contentsOf: appState, encoding: .utf8)
        let loginSrc = try String(contentsOf: login, encoding: .utf8)
        XCTAssertTrue(appSrc.contains("retainedLiveJimengWebView"), "首页 refresh 在 existingWebView 为空时必须复用已接管的即梦页")
        XCTAssertTrue(loginSrc.contains("adoptLiveJimengWebView"), "确认用量后必须 adopt 登录页，不能等 sheet dismiss 拆掉")
        XCTAssertTrue(loginSrc.contains("ownsJimengLiveWebView"), "dismantleUIView 发现已被接管时不得 stopLoading / 清空 delegate")
    }

    func testSafariUserAgentMatchesDeviceVersionAndLooksLikeSafari() {
        XCTAssertEqual(
            SafariUserAgent.make(systemVersion: "26.6"),
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"
        )
        XCTAssertEqual(
            SafariUserAgent.make(systemVersion: "18.5.1"),
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5.1 Mobile/15E148 Safari/604.1"
        )
        let ua = SafariUserAgent.make(systemVersion: "26.6")
        XCTAssertTrue(ua.contains("Version/26.6"))
        XCTAssertTrue(ua.contains("Safari/604.1"))
        XCTAssertFalse(ua.contains("OS 18_5"), "不得写死旧系统版本，否则 Google 风控会打回登录页")
    }

    /// ChatGPT 三个社交按钮依赖 `PublicKeyCredential` 仍在：只能 stub 可用性，不能删全局。
    func testHideWebAuthnKeepsPublicKeyCredentialDefined() {
        let js = LoginWebViewScripts.hideWebAuthn
        XCTAssertFalse(js.contains("return undefined"), "删掉 PublicKeyCredential 会让 ChatGPT 的 Google/Apple/电话 onClick 空转")
        XCTAssertTrue(js.contains("isConditionalMediationAvailable"))
        XCTAssertTrue(js.contains("isUserVerifyingPlatformAuthenticatorAvailable"))
        XCTAssertTrue(js.contains("o.publicKey"), "仍须拒绝 publicKey，避免被带进跨设备通行密钥")

        let ctx = JSContext()!
        var exception: String?
        ctx.exceptionHandler = { _, err in exception = err?.toString() }
        ctx.evaluateScript("""
        var window = this;
        function PublicKeyCredential() {}
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(true); };
        PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(true); };
        window.PublicKeyCredential = PublicKeyCredential;
        var navigator = { credentials: {
            get: function (o) { return 'passthrough-get'; },
            create: function (o) { return 'passthrough-create'; }
        }};
        """)
        ctx.evaluateScript(js)
        XCTAssertNil(exception)
        XCTAssertEqual(ctx.evaluateScript("typeof window.PublicKeyCredential")?.toString(), "function")
        XCTAssertEqual(ctx.evaluateScript("navigator.credentials.get({})")?.toString(), "passthrough-get")
        let rejected = ctx.evaluateScript("navigator.credentials.get({publicKey: {}})")
        XCTAssertNotEqual(rejected?.toString(), "passthrough-get", "publicKey 必须被拒绝")
    }

    func testLoginSheetUsesSharedHideWebAuthnScript() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Auth/LoginSheetView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("LoginWebViewScripts.hideWebAuthn"),
                      "登录页必须用可测试的共享脚本，不能再内联删掉 PublicKeyCredential")
        XCTAssertFalse(
            src.contains("get: function () { return undefined; }"),
            "不得再把 PublicKeyCredential 定义成 undefined"
        )
    }

    func testLoginBannerNoLongerClaimsGoogleIsUnavailable() {
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            let value = L10n.tr("login.banner", lang)
            XCTAssertFalse(value.isEmpty, "login.banner \(lang) 缺文案")
            XCTAssertNotEqual(value, "login.banner")
        }
        XCTAssertFalse(
            L10n.tr("login.banner", .zh).contains("Google 登录在此不可用"),
            "弹窗接通后不得再写 Google 不可用"
        )
        XCTAssertFalse(L10n.tr("login.banner", .en).contains("Google sign-in don't work"))
    }

    func testHideSmartAppBannerDoesNotTouchWebAuthn() {
        let js = LoginWebViewScripts.hideSmartAppBanner
        XCTAssertTrue(js.contains("apple-itunes-app"))
        XCTAssertTrue(js.contains("smartbanner") || js.contains("smart-app-banner"))
        XCTAssertFalse(js.contains("PublicKeyCredential"))
        XCTAssertFalse(js.contains("return undefined"))
    }

    func testAppStoreNavigationIsCancelledWithoutBlockingOAuth() {
        XCTAssertTrue(LoginWebViewScripts.isAppStoreNavigation(URL(string: "itms-apps://itunes.apple.com/app/id123")))
        XCTAssertTrue(LoginWebViewScripts.isAppStoreNavigation(URL(string: "itms://itunes.apple.com/app/id123")))
        XCTAssertFalse(LoginWebViewScripts.isAppStoreNavigation(URL(string: "https://accounts.google.com/o/oauth2/v2/auth")))
        XCTAssertFalse(LoginWebViewScripts.isAppStoreNavigation(URL(string: "https://appleid.apple.com/auth/authorize")))
        XCTAssertFalse(LoginWebViewScripts.isAppStoreNavigation(URL(string: "about:blank")))
        XCTAssertTrue(LoginWebViewScripts.authPopupHosts.contains("accounts.x.ai"))
        XCTAssertTrue(LoginWebViewScripts.authPopupHosts.contains("x.com"))
    }

    func testLoginSheetHidesSmartAppBannerAndCancelsStoreLinks() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Auth/LoginSheetView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("LoginWebViewScripts.hideSmartAppBanner"))
        XCTAssertTrue(src.contains("isAppStoreNavigation"))
    }
}

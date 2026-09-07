import XCTest
@testable import UsageLimitsCore

final class LoginProbePolicyTests: XCTestCase {
    func testDeclineThenAuthenticationAllowsNextAccountPrompt() {
        for (provider, loginURL, dashboardURL) in [
            (ProviderID.grok, "https://accounts.x.ai/sign-in", "https://grok.com/"),
            (.cursor, "https://authenticator.cursor.sh/", "https://cursor.com/dashboard")
        ] {
            var suppressed = LoginConfirm.Outcome.applying(.decline).suppressFurtherAutoAccept
            XCTAssertFalse(LoginProbePolicy.isAuthenticationPage(provider: provider, url: URL(string: dashboardURL)))
            XCTAssertTrue(LoginProbePolicy.isAuthenticationPage(provider: provider, url: URL(string: loginURL)))
            suppressed = LoginConfirm.stillSuppressAutoPrompt(probeOK: false, currentlySuppressed: suppressed)
            XCTAssertEqual(LoginConfirm.action(probeOK: true, alreadyDetected: false, confirmationVisible: false,
                                               autoPromptSuppressed: suppressed, siteIdentity: nil, displayName: "B"),
                           .prompt(accountLabel: "B"))
        }
        XCTAssertFalse(LoginProbePolicy.isAuthenticationPage(provider: .cursor,
            url: URL(string: "https://authenticator.cursor.sh.evil.example/")))
    }

    func testGuestQuotaIsNotAnAuthenticatedSession() {
        var snapshot = ProviderSnapshot(provider: .grok, metrics: [
            UsageMetric(id: "auto", label: "Auto", usedPercent: 0)
        ], fetchedAt: Date(), status: .ok, isAnonymous: true)
        XCTAssertFalse(LoginProbePolicy.isAuthenticated(snapshot))
        snapshot.isAnonymous = false
        XCTAssertTrue(LoginProbePolicy.isAuthenticated(snapshot))
        snapshot.isAnonymous = nil
        XCTAssertTrue(LoginProbePolicy.isAuthenticated(snapshot))
        snapshot.status = .needsLogin
        XCTAssertFalse(LoginProbePolicy.isAuthenticated(snapshot))
        snapshot.status = .error("HTTP 503")
        XCTAssertFalse(LoginProbePolicy.isAuthenticated(snapshot))
        XCTAssertFalse(LoginProbePolicy.isAuthenticated(nil))
    }

    func testCursorMustFinishReturningToDashboard() {
        for url in ["https://cursor.com/dashboard", "https://www.cursor.com/en/dashboard/usage"] {
            XCTAssertTrue(LoginProbePolicy.isReady(provider: .cursor, url: URL(string: url)))
        }
        for url in ["https://cursor.com/", "https://cursor.com/loginDeepControl", "https://authenticator.cursor.sh/",
                    "https://cursor.com/?next=/dashboard", "https://cursor.com.evil.example/dashboard", "http://cursor.com/dashboard"] {
            XCTAssertFalse(LoginProbePolicy.isReady(provider: .cursor, url: URL(string: url)), url)
        }
        XCTAssertEqual(ProviderID.cursor.probeURL.absoluteString, "https://cursor.com/dashboard")
    }

    func testGrokMustReturnFromAccountsAndJimengKeepsSameOriginPolicy() {
        XCTAssertTrue(LoginProbePolicy.isReady(provider: .grok, url: URL(string: "https://grok.com/")))
        XCTAssertTrue(LoginProbePolicy.isReady(provider: .grok, url: URL(string: "https://www.grok.com/c/example")))
        for url in ["https://accounts.x.ai/sign-in", "https://grok.com/sign-in", "https://grok.com.evil.example/"] {
            XCTAssertFalse(LoginProbePolicy.isReady(provider: .grok, url: URL(string: url)))
        }
        XCTAssertTrue(LoginProbePolicy.isReady(provider: .jimeng, url: ProviderID.jimeng.loginURL))
        XCTAssertFalse(LoginProbePolicy.isReady(provider: .jimeng, url: URL(string: "https://appleid.apple.com/")))
        XCTAssertFalse(LoginProbePolicy.isReady(provider: .cursor, url: nil))
    }

    func testFailureMessagesAreLocalized() {
        for raw in [GrokParser.browserVerificationError, "请先完成官网登录并进入用量页面",
                    "检测到游客额度，请先登录账号", "尚未检测到登录会话"] {
            for lang in [AppLanguage.en, .ja, .fr, .ru] {
                XCTAssertNotEqual(SnapshotStatus.error(raw).displayText(lang), raw)
            }
        }
    }
}

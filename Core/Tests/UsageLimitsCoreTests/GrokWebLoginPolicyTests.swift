import XCTest
@testable import UsageLimitsCore

final class GrokWebLoginPolicyTests: XCTestCase {
    private let home = URL(string: "https://grok.com/")!

    func testWebEntryAndExternalAppSchemes() {
        XCTAssertEqual(ProviderID.grok.loginURL, home)
        for target in ["grok://auth/callback?code=fixture", "x://login", "itms-apps://itunes.apple.com/app/id123", "https://apps.apple.com/app/id123"] {
            XCTAssertTrue(GrokWebLoginPolicy.blocksExternalNavigation(URL(string: target), loginPage: home))
        }
        for target in ["https://accounts.x.ai/sign-in", "https://accounts.google.com/o/oauth2/auth", "https://appleid.apple.com/auth/authorize", "https://x.com/i/oauth2/authorize", "about:blank", "blob:https://grok.com/fixture"] {
            XCTAssertFalse(GrokWebLoginPolicy.blocksExternalNavigation(URL(string: target), loginPage: home))
        }
        XCTAssertFalse(GrokWebLoginPolicy.blocksExternalNavigation(URL(string: "cursor://auth"), loginPage: ProviderID.cursor.loginURL))
        XCTAssertFalse(GrokWebLoginPolicy.isWebOnlyLogin(URL(string: "https://grok.com.evil.example/")))
    }

    func testOwnWebsiteLinksAndCrossHostCallbacksUseNativeWebLoad() {
        for source in ["https://accounts.x.ai/sign-in", "https://accounts.google.com/o/oauth2/auth"] {
            XCTAssertTrue(reloads("https://grok.com/auth/callback?code=fixture&state=fixture", from: source))
        }
        XCTAssertTrue(reloads("https://accounts.x.ai/sign-in", from: home.absoluteString))
        XCTAssertTrue(reloads(home.absoluteString, from: home.absoluteString, clicked: true))
        XCTAssertFalse(reloads(home.absoluteString, from: home.absoluteString))
        XCTAssertFalse(reloads("https://accounts.google.com/o/oauth2/auth", from: home.absoluteString, clicked: true))
        XCTAssertFalse(reloads("https://grok.com.evil.example/callback", from: home.absoluteString, clicked: true))
        XCTAssertFalse(reloads(home.absoluteString, from: "https://accounts.x.ai/sign-in", mainFrame: false))
        XCTAssertFalse(reloads(home.absoluteString, from: "https://accounts.x.ai/sign-in", method: "POST"))
    }

    private func reloads(_ target: String, from source: String, clicked: Bool = false,
                         mainFrame: Bool = true, method: String = "GET") -> Bool {
        GrokWebLoginPolicy.shouldLoadInWebView(
            URL(string: target), sourceURL: URL(string: source), loginPage: home,
            isMainFrame: mainFrame, isLinkActivated: clicked, httpMethod: method
        )
    }
}

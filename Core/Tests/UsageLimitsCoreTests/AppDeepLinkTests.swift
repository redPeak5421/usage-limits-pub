import XCTest
@testable import UsageLimitsCore

final class AppDeepLinkTests: XCTestCase {
    func testCanonicalAndLegacySchemesHaveIdenticalRouting() {
        let id = UUID()
        for scheme in ["usagelimits", "UsageLimits", "aiusage", "AIUsage"] {
            XCTAssertEqual(AppDeepLink.parse(URL(string: "\(scheme)://open")!), .home)
            XCTAssertEqual(AppDeepLink.parse(URL(string: "\(scheme)://open/claude")!), .provider(.claude))
            XCTAssertEqual(AppDeepLink.parse(URL(string: "\(scheme)://open/account/\(id)")!), .account(id))
            XCTAssertEqual(AppDeepLink.parse(URL(string: "\(scheme)://open/account/invalid")!), .home)
            XCTAssertNil(AppDeepLink.parse(URL(string: "\(scheme)://unrelated")!))
        }
        XCTAssertEqual(AppDeepLink.accountURL(id).scheme, "usagelimits")
        XCTAssertNil(AppDeepLink.parse(URL(string: "https://open/account/\(id)")!))
    }

    /// 已保存的小组件旧链接 `aiusage://open/<provider>` 必须继续定位主账号。
    func testParsesBuiltinProviderPath() {
        XCTAssertEqual(AppDeepLink.parse(URL(string: "aiusage://open/claude")!), .provider(.claude))
        XCTAssertEqual(AppDeepLink.parse(URL(string: "aiusage://open/OpenAI")!), .provider(.openai))
        XCTAssertEqual(AppDeepLink.parse(URL(string: "aiusage://open/not-a-provider")!), .home)
        XCTAssertEqual(AppDeepLink.parse(URL(string: "aiusage://open")!), .home)
        XCTAssertNil(AppDeepLink.parse(URL(string: "https://example.com/open/claude")!))
        let id = UUID()
        XCTAssertEqual(AppDeepLink.parse(AppDeepLink.accountURL(id)), .account(id))
    }

    func testProviderLinkRevealsThatProvidersPrimaryAccountCard() {
        let primary = ProviderAccount(provider: .claude, name: "Claude", isPrimary: true)
        let extra = ProviderAccount(provider: .claude, name: "Claude 2")
        let other = ProviderAccount(provider: .openai, name: "ChatGPT", isPrimary: true)
        let accounts = [extra, other, primary]
        XCTAssertEqual(
            AppDeepLink.provider(.claude).revealTarget(accounts: accounts, demoMode: false),
            .account(primary.id)
        )
        XCTAssertEqual(
            AppDeepLink.provider(.openai).revealTarget(accounts: accounts, demoMode: true),
            .account(other.id),
            "有真实账号时演示态也定位到账号卡"
        )
        XCTAssertEqual(
            AppDeepLink.provider(.claude).revealTarget(accounts: [extra], demoMode: false),
            .account(extra.id),
            "没有主账号时退到该服务商任一账号卡"
        )
    }

    func testProviderLinkFallsBackToDemoCardOnlyInDemoMode() {
        XCTAssertEqual(AppDeepLink.provider(.grok).revealTarget(accounts: [], demoMode: true), .demo(.grok))
        XCTAssertNil(AppDeepLink.provider(.grok).revealTarget(accounts: [], demoMode: false))
    }

    func testAccountLinkRevealsThatAccountAndHomeRevealsNothing() {
        let id = UUID()
        XCTAssertEqual(AppDeepLink.account(id).revealTarget(accounts: [], demoMode: true), .account(id))
        XCTAssertNil(AppDeepLink.home.revealTarget(accounts: [], demoMode: true))
    }
}

import XCTest
@testable import UsageLimitsCore

final class OpenCodeSessionTests: XCTestCase {
    func testWorkspacePageIsReady() {
        XCTAssertTrue(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/workspace/wrk_01ABCxyz")))
        XCTAssertTrue(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/workspace/wrk_01ABCxyz/go")))
    }

    /// 放宽后：路径里没有 wrk_ 也算就绪，探针会调 workspaces() server fn 兜底取 workspace。
    func testAnyNonAuthPageOnOriginIsReady() {
        XCTAssertTrue(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/")))
        XCTAssertTrue(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/workspace")))
        XCTAssertTrue(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/docs/go")))
        XCTAssertTrue(OpenCodeSession.isProbeReady(url: URL(string: "https://OpenCode.ai/workspace/wrk_1/billing")))
    }

    func testAuthSubdomainIsNotReadyEvenThoughItSharesSuffix() {
        XCTAssertFalse(
            OpenCodeSession.isProbeReady(url: URL(string: "https://auth.opencode.ai/authorize?client_id=app")),
            "auth.opencode.ai 与源同后缀，必须重载而不是复用"
        )
        XCTAssertFalse(OpenCodeSession.isProbeReady(url: URL(string: "https://github.com/login")))
        XCTAssertFalse(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/auth")))
        XCTAssertFalse(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/auth/authorize")))
        XCTAssertFalse(OpenCodeSession.isProbeReady(url: URL(string: "https://opencode.ai/auth/callback?code=x")))
        XCTAssertFalse(OpenCodeSession.isProbeReady(url: nil))
    }


    /// 离屏探针必须用这条就绪判定决定是否重载，否则 `hostMatches` 的后缀匹配会复用 OAuth 页。
    func testFetcherReloadsOpenCodeUnlessOnWorkspace() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Networking/WebViewFetcher.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("OpenCodeSession.isProbeReady"), "ensureLoaded 必须按 workspace 路径判 OpenCode 就绪")
    }
}

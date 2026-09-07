import XCTest
@testable import UsageLimitsCore

final class OllamaSessionTests: XCTestCase {
    func testRecognizesOllamaAndWorkOSLoginLandings() {
        let loginURLs = [
            "https://ollama.com/signin",
            "https://ollama.com/signin/",
            "https://www.ollama.com/signin?return_to=%2Fsettings",
            "https://signin.ollama.com/",
            "https://signin.ollama.com/callback?authorization_session_id=secret",
            "https://api.workos.com/user_management/authorize?client_id=placeholder",
            "https://auth.workos.com/user_management/authorize/continue?client_id=placeholder",
        ]

        for raw in loginURLs {
            XCTAssertTrue(OllamaSession.isLoginLanding(URL(string: raw)), raw)
        }
    }

    func testRejectsOrdinaryInsecureAndLookalikeURLs() {
        let ordinaryURLs: [URL?] = [
            URL(string: "https://ollama.com/settings"),
            URL(string: "https://www.ollama.com/settings"),
            URL(string: "https://ollama.com/signin-something"),
            URL(string: "https://example.com/signin"),
            URL(string: "https://evilworkos.com/user_management/authorize"),
            URL(string: "https://workos.com/user_management/authorize"),
            URL(string: "https://api.workos.com/other"),
            URL(string: "http://ollama.com/signin"),
            URL(string: "http://signin.ollama.com/"),
            URL(string: "http://api.workos.com/user_management/authorize"),
            nil,
        ]

        for url in ordinaryURLs {
            XCTAssertFalse(OllamaSession.isLoginLanding(url), url?.absoluteString ?? "nil")
        }
    }

    func testFetcherClassifiesOllamaLoginLandingBeforeGenericOriginGate() throws {
        let source = try String(contentsOf: webViewFetcherURL(), encoding: .utf8)
        let landing = try XCTUnwrap(
            source.range(of: "if provider == .ollama, OllamaSession.isLoginLanding(wv.url)")
        )
        let originGate = try XCTUnwrap(
            source.range(of: "if let host = wv.url?.host, !hostMatches(host, provider: provider)")
        )
        XCTAssertLessThan(landing.lowerBound, originGate.lowerBound, "登录落地判定必须先于通用 origin gate")
        let prefix = String(source[landing.lowerBound..<originGate.lowerBound])
        XCTAssertTrue(prefix.contains(#"return ["settings": ProbeResult(status: 401, body: "{}")]"#))
    }

    private func webViewFetcherURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Networking/WebViewFetcher.swift")
    }
}

import XCTest
@testable import UsageLimitsCore

private final class CustomUsageMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (status, headers, data) = try handler!(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://invalid.example")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requests = []
        handler = nil
        lock.unlock()
    }
}

final class CustomUsageClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CustomUsageMockProtocol.reset()
    }

    override func tearDown() {
        CustomUsageMockProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> CustomUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomUsageMockProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: CustomUsageRedirectDelegate(),
            delegateQueue: nil
        )
        return CustomUsageClient(session: session, timeout: 2)
    }

    func testGETBearerAcceptAndSuccessBody() async {
        CustomUsageMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let data = Data(#"{"data":{"used":1}}"#.utf8)
            return (200, ["Content-Type": "application/json"], data)
        }
        let result = await makeClient().fetch(
            url: URL(string: "https://api.example.com/v1/usage")!,
            token: "sk-test"
        )
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.body.contains("used"))
        XCTAssertFalse(result.body.contains("sk-test"))
        XCTAssertEqual(CustomUsageMockProtocol.requests.count, 1)
    }

    func testRejectsHTTPWithoutSending() async {
        CustomUsageMockProtocol.handler = { _ in
            XCTFail("http 不得发请求")
            return (200, [:], Data())
        }
        let result = await makeClient().fetch(
            url: URL(string: "http://api.example.com/v1/usage")!,
            token: "sk-test"
        )
        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.body, "明文被拦")
        XCTAssertTrue(CustomUsageMockProtocol.requests.isEmpty)
    }

    func testCrossHostRedirectDoesNotForwardAuthorization() async {
        CustomUsageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "a.example.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-redirect")
            return (
                302,
                ["Location": "https://b.example.com/v1/usage"],
                Data()
            )
        }
        let result = await makeClient().fetch(
            url: URL(string: "https://a.example.com/v1/usage")!,
            token: "sk-redirect"
        )
        XCTAssertEqual(CustomUsageMockProtocol.requests.count, 1)
        XCTAssertEqual(CustomUsageMockProtocol.requests[0].url?.host, "a.example.com")
        XCTAssertFalse(
            CustomUsageMockProtocol.requests.contains { $0.url?.host == "b.example.com" }
        )
        XCTAssertEqual(result.status, 302)
        XCTAssertFalse(result.body.contains("sk-redirect"))
    }

    func testSameHostRedirectMayFollow() async {
        CustomUsageMockProtocol.handler = { request in
            if request.url?.path == "/v1/usage" {
                return (302, ["Location": "https://a.example.com/v1/usage2"], Data())
            }
            return (200, [:], Data(#"{"ok":1}"#.utf8))
        }
        let result = await makeClient().fetch(
            url: URL(string: "https://a.example.com/v1/usage")!,
            token: "sk-same"
        )
        XCTAssertGreaterThanOrEqual(CustomUsageMockProtocol.requests.count, 1)
        XCTAssertTrue(CustomUsageMockProtocol.requests.allSatisfy { $0.url?.host == "a.example.com" })
        XCTAssertTrue(result.status == 200 || result.status == 302)
    }

    func testCertificateErrorIsNotNeedsLogin() async {
        CustomUsageMockProtocol.handler = { _ in
            throw URLError(.serverCertificateUntrusted)
        }
        let result = await makeClient().fetch(
            url: URL(string: "https://api.example.com/v1/usage")!,
            token: "sk-cert"
        )
        XCTAssertLessThanOrEqual(result.status, 0)
        XCTAssertEqual(result.body, "证书不受信任")
        let parsed = CustomUsageParser.parse(
            status: result.status,
            body: result.body,
            template: CustomUsageTemplate(
                name: "t",
                requestURL: "https://api.example.com/v1/usage",
                fields: [CustomUsageField(path: "used", displayName: "已用")]
            )!
        )
        XCTAssertFalse(parsed.status.isNeedsLogin)
        if case .error(let message) = parsed.status {
            XCTAssertFalse(message.contains("sk-cert"))
        } else {
            XCTFail("证书失败应是 error")
        }
    }

    func testErrorBodyDoesNotContainToken() async {
        CustomUsageMockProtocol.handler = { _ in
            return (500, [:], Data("echo sk-secret-token".utf8))
        }
        let result = await makeClient().fetch(
            url: URL(string: "https://api.example.com/v1/usage")!,
            token: "sk-secret-token"
        )
        XCTAssertEqual(result.status, 500)
        XCTAssertFalse(result.body.contains("sk-secret-token"))
        XCTAssertTrue(result.body.contains("***"))
    }

    func testHomepageFetchHitsOriginWithoutBearer() async {
        CustomUsageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://dragoncode.codes/")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "GET")
            let html = #"<link rel="icon" type="image/svg+xml" href="/favicon.svg">"#
            return (200, ["Content-Type": "text/html"], Data(html.utf8))
        }
        let page = await makeClient().fetchHomepage(
            from: URL(string: "https://dragoncode.codes/v1/usage")!
        )
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.body.contains("favicon.svg"))
        XCTAssertEqual(CustomUsageMockProtocol.requests.count, 1)
        XCTAssertEqual(CustomUsageMockProtocol.requests[0].url?.path, "/")
    }

    func testResolveLogoFetchesHomepageThenImage() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 16))
        CustomUsageMockProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url?.path == "/" {
                let html = #"<link rel="icon" type="image/png" href="/mark.png">"#
                return (200, ["Content-Type": "text/html"], Data(html.utf8))
            }
            XCTAssertEqual(request.url?.path, "/mark.png")
            return (200, ["Content-Type": "image/png"], png)
        }
        let data = await makeClient().resolveTemplateLogo(
            from: URL(string: "https://api.example.com/v1/usage")!
        )
        XCTAssertEqual(data, png)
        XCTAssertEqual(CustomUsageMockProtocol.requests.count, 2)
        XCTAssertFalse(
            CustomUsageMockProtocol.requests.contains { $0.url?.path.contains("usage") == true }
        )
    }

    func testHomepageRejectsHTTP() async {
        CustomUsageMockProtocol.handler = { _ in
            XCTFail("http 首页不得发请求")
            return (200, [:], Data())
        }
        let page = await makeClient().fetchHomepage(from: URL(string: "http://example.com/v1/usage")!)
        XCTAssertEqual(page.status, -1)
        XCTAssertTrue(CustomUsageMockProtocol.requests.isEmpty)
    }

    func testDiagnosticHostStripsQuery() {
        let url = URL(string: "https://api.example.com/v1/usage?key=secret")!
        XCTAssertEqual(CustomUsageClient.diagnosticHost(from: url), "api.example.com")
    }

    func testWizardFailureMessageNeverShowsResponseBody() {
        let leak = #"{"email":"user@example.com","name":"Ada"}"#
        XCTAssertEqual(
            CustomUsageClient.wizardFailureMessage(status: 500, body: leak, language: .en),
            "HTTP 500"
        )
        XCTAssertEqual(
            CustomUsageClient.wizardFailureMessage(status: 401, body: leak, language: .en),
            L10n.tr("card.updateToken", .en)
        )
        XCTAssertEqual(
            CustomUsageClient.wizardFailureMessage(status: -1, body: "证书不受信任", language: .en),
            "Untrusted certificate"
        )
        let wizard = try! String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("App/Views/CustomUsageWizardView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(wizard.contains("wizardFailureMessage"), "向导失败须走统一文案")
        XCTAssertFalse(wizard.contains("trError(probe.body"), "向导不得把失败 body 画到界面")
    }
}

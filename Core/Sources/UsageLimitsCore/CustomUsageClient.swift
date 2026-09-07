import Foundation

/// 跨 host 重定向不转发 Bearer：只允许同 host 跟随。
public final class CustomUsageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host
        let nextHost = request.url?.host
        guard let originalHost, let nextHost,
              originalHost.caseInsensitiveCompare(nextHost) == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// 自定义用量 HTTP：仅 HTTPS GET + Bearer，无共享 Cookie。
public struct CustomUsageClient: Sendable {
    public static let wizardTimeout: TimeInterval = 15
    public static let refreshTimeout: TimeInterval = 10

    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession, timeout: TimeInterval = refreshTimeout) {
        self.session = session
        self.timeout = timeout
    }

    public static func makeSession(timeout: TimeInterval = refreshTimeout) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: CustomUsageRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// 打用量 URL 的 origin 首页，不带 Bearer，截断 HTML。
    public func fetchHomepage(from usageURL: URL) async -> (status: Int, body: String) {
        guard let home = CustomFaviconParser.homepageURL(from: usageURL) else {
            return (-1, "明文被拦")
        }
        let result = await fetchPlain(
            url: home,
            accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
            maxBytes: CustomFaviconParser.maxHTMLBytes
        )
        let body = String(data: result.data, encoding: .utf8)
            ?? String(decoding: result.data, as: UTF8.self)
        return (result.status, body)
    }

    /// 下载 favicon 字节，不带 Bearer。
    public func fetchImage(url: URL) async -> (status: Int, data: Data) {
        await fetchPlain(
            url: url,
            accept: "image/*,*/*;q=0.8",
            maxBytes: CustomFaviconParser.maxLogoBytes
        )
    }

    /// 测试连接成功后解析 logo：先 GET origin 首页，再 GET 选用的 icon。失败返回 nil。
    public func resolveTemplateLogo(from usageURL: URL) async -> Data? {
        let page = await fetchHomepage(from: usageURL)
        guard (200..<300).contains(page.status), !page.body.isEmpty else { return nil }
        guard let home = CustomFaviconParser.homepageURL(from: usageURL),
              let href = CustomFaviconParser.pickBestHref(html: page.body, baseURL: home)
        else { return nil }
        let image = await fetchImage(url: href)
        guard (200..<300).contains(image.status),
              CustomFaviconParser.looksLikeImage(image.data)
        else { return nil }
        return image.data
    }

    public func fetch(url: URL, token: String) async -> ProbeResult {
        guard url.scheme?.lowercased() == "https" else {
            return ProbeResult(status: -1, body: "明文被拦")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            return ProbeResult(status: status, body: redact(body, token: token))
        } catch {
            return ProbeResult(status: -1, body: mapError(error, token: token))
        }
    }

    public static func diagnosticHost(from url: URL) -> String {
        url.host ?? ""
    }

    /// 向导失败文案：传输层走已映射键；HTTP 失败只报状态码，不把响应正文（邮箱/姓名）画到界面。
    public static func wizardFailureMessage(status: Int, body: String, language: AppLanguage) -> String {
        if status < 100 {
            return L10n.tr(body, language)
        }
        if status == 401 || status == 403 {
            return L10n.tr("card.updateToken", language)
        }
        return L10n.trError("HTTP \(status)", language)
    }

    private func fetchPlain(url: URL, accept: String, maxBytes: Int) async -> (status: Int, data: Data) {
        guard url.scheme?.lowercased() == "https" else {
            return (-1, Data())
        }
        var request = URLRequest(url: url, timeoutInterval: min(timeout, CustomFaviconParser.homepageTimeout))
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let clipped = data.count > maxBytes ? data.prefix(maxBytes) : data
            return (status, Data(clipped))
        } catch {
            return (-1, Data())
        }
    }

    private func redact(_ body: String, token: String) -> String {
        guard !token.isEmpty, body.contains(token) else { return body }
        return body.replacingOccurrences(of: token, with: "***")
    }

    private func mapError(_ error: Error, token: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "证书不受信任"
            case .appTransportSecurityRequiresSecureConnection:
                return "明文被拦"
            case .timedOut:
                return "超时"
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .networkConnectionLost,
                 .internationalRoamingOff, .dataNotAllowed:
                return "无网络"
            default:
                break
            }
        }
        return redact(error.localizedDescription, token: token)
    }
}

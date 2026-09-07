import CryptoKit
import UIKit
import WebKit
import UsageLimitsCore

/// 在服务商站点源内执行探针 JS 的离屏 WebView 执行器。
///
/// 为什么不用 URLSession 直连：这些站点有浏览器指纹级防护（Cloudflare 等），
/// 裸请求会被拦截。JS fetch 从已登录页面的源内发出，与真实浏览器行为一致。
/// 登录凭据（Cookie）全程只存在系统 WebKit 存储与 App Group 沙盒里，不出本机。
@MainActor
final class WebViewFetcher: NSObject {
    static let shared = WebViewFetcher()

    static var safariUA: String {
        SafariUserAgent.make(systemVersion: UIDevice.current.systemVersion)
    }

    /// 抓取身份：主账号 = 服务商本身（共享 default dataStore）；
    /// 附加账号 = 服务商 + UUID（独立 dataStore，同域 Cookie 互不覆盖）。
    struct FetchTarget: Hashable {
        let provider: ProviderID
        let accountID: UUID?

        var key: String { accountID?.uuidString ?? provider.rawValue }
    }

    /// 附加账号的登录态容器：探针 WebView 与登录页 WebView 用同一 identifier 才互通。
    static func dataStore(accountID: UUID?) -> WKWebsiteDataStore {
        accountID.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }

    private var webViews: [String: WKWebView] = [:]
    /// 登录确认后接管的即梦页：首页下拉复用这张已经跑过官网 SPA 的文档。
    private var adoptedLiveKeys: Set<String> = []
    private var loadWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var loadGeneration: [String: UInt64] = [:]

    /// 并发探针的上限。探针本质是 IO 等待（页面加载 + 站内 fetch），每个目标
    /// 一张独立 WebView、各自独立的 WebContent 进程，主线程只做调度，可以并发；
    /// 但同时拉起太多 WebContent 进程会挤爆内存与主线程调度，所以设上限，
    /// 超出的排队等空位（调用方的转圈状态在排队期间就已显示，不影响并发观感）。
    private static let maxConcurrentProbes = 4
    private var runningProbes = 0
    private var probeSlotWaiters: [CheckedContinuation<Void, Never>] = []
    /// 同一 FetchTarget 同时只能跑一路 JS。后台刷新与前台 autoRefresh 会抢同一张 WebView。
    private var runningTargets: Set<FetchTarget> = []
    private var targetWaiters: [FetchTarget: [CheckedContinuation<Void, Never>]] = [:]

    private func acquireProbeSlot() async {
        if runningProbes < Self.maxConcurrentProbes {
            runningProbes += 1
            return
        }
        await withCheckedContinuation { probeSlotWaiters.append($0) }
        // 名额由 releaseProbeSlot 直接转交，计数不变
    }

    private func releaseProbeSlot() {
        if probeSlotWaiters.isEmpty {
            runningProbes -= 1
        } else {
            probeSlotWaiters.removeFirst().resume()
        }
    }

    private func webView(for target: FetchTarget) -> WKWebView {
        if let existing = webViews[target.key] { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore(accountID: target.accountID)
        let wv = WKWebView(frame: Self.safeContentFrame(), configuration: config)
        wv.customUserAgent = Self.safariUA
        wv.navigationDelegate = self
        #if DEBUG
        wv.isInspectable = true
        #endif
        webViews[target.key] = wv
        attachBehindDashboardIfNeeded(for: target, webView: wv)
        return wv
    }

    /// 登录确认后接管可见即梦页。首页下拉走这张文档，不再新建离屏冷页。
    func adoptLiveJimengWebView(_ webView: WKWebView, accountID: UUID?) {
        let target = FetchTarget(provider: .jimeng, accountID: accountID)
        if let existing = webViews[target.key], existing !== webView {
            discardWebView(for: target)
        }
        webViews[target.key] = webView
        adoptedLiveKeys.insert(target.key)
        webView.navigationDelegate = self
        attachBehindDashboardIfNeeded(for: target, webView: webView)
    }

    func retainedLiveJimengWebView(accountID: UUID?) -> WKWebView? {
        let target = FetchTarget(provider: .jimeng, accountID: accountID)
        guard adoptedLiveKeys.contains(target.key) else { return webViews[target.key] }
        return webViews[target.key]
    }

    func ownsJimengLiveWebView(_ webView: WKWebView) -> Bool {
        webViews.contains { adoptedLiveKeys.contains($0.key) && $0.value === webView }
    }

    /// 即梦 SPA 在近乎透明的独立宿主窗里会被 iOS freezer 杀掉。
    /// 挂进当前 key window 最底层，全尺寸、不透明、不抢点击。
    private func attachBehindDashboardIfNeeded(for target: FetchTarget, webView: WKWebView) {
        guard target.provider == .jimeng else { return }
        guard let keyWindow = UIApplication.usagelimitsKeyWindow else { return }
        if webView.superview === keyWindow { return }
        let frame = keyWindow.bounds
        webView.frame = frame.isEmpty ? Self.safeContentFrame() : frame
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isUserInteractionEnabled = false
        webView.removeFromSuperview()
        keyWindow.insertSubview(webView, at: 0)
    }

    private func discardHostWindow(forKey key: String) {
        webViews[key]?.removeFromSuperview()
        adoptedLiveKeys.remove(key)
    }

    /// 运行某服务商的全部探针，返回 探针名 → 原始结果。
    /// `accountID` 非空时在该附加账号的独立 dataStore 中执行。
    /// 不同目标并发执行（上限内）。同一目标串行：后台刷新与前台 autoRefresh
    /// 都走这里，AppState.refreshing 挡不住 BGAppRefresh。
    func runProbes(
        for provider: ProviderID,
        accountID: UUID? = nil,
        using existingWebView: WKWebView? = nil
    ) async -> [String: ProbeResult] {
        let target = FetchTarget(provider: provider, accountID: accountID)
        await acquireTargetLock(target)
        defer { releaseTargetLock(target) }
        await acquireProbeSlot()
        defer { releaseProbeSlot() }
        return await executeProbes(for: target, using: existingWebView)
    }

    private func acquireTargetLock(_ target: FetchTarget) async {
        if runningTargets.contains(target) {
            await withCheckedContinuation { targetWaiters[target, default: []].append($0) }
            return
        }
        runningTargets.insert(target)
    }

    private func releaseTargetLock(_ target: FetchTarget) {
        if var waiters = targetWaiters[target], !waiters.isEmpty {
            let next = waiters.removeFirst()
            targetWaiters[target] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            runningTargets.remove(target)
            targetWaiters[target] = nil
        }
    }

    private func executeProbes(for target: FetchTarget, using existingWebView: WKWebView?) async -> [String: ProbeResult] {
        let provider = target.provider
        let wv: WKWebView
        let retained = provider == .jimeng ? retainedLiveJimengWebView(accountID: target.accountID) : nil
        if let existingWebView {
            // 登录页已经停在同源：不要另开冷文档，也不要从 sheet 里拆走。
            wv = existingWebView
            if provider == .jimeng {
                await waitUntilJimengPageSettled(wv)
            }
        } else if let retained {
            wv = retained
            attachBehindDashboardIfNeeded(for: target, webView: wv)
            await waitUntilJimengPageSettled(wv)
        } else {
            wv = webView(for: target)
            await ensureLoaded(wv, target: target)
        }
        if provider == .jimeng {
            await waitForJimengHomeReady(in: wv)
        }
        if provider == .ollama, OllamaSession.isLoginLanding(wv.url) {
            // `/settings` 可能在执行 JS 前已经落到 Ollama / WorkOS 登录页。
            // 必须先于通用 origin gate 判未登录，避免在登录子域误发相对请求。
            return ["settings": ProbeResult(status: 401, body: "{}")]
        }
        if let host = wv.url?.host, !hostMatches(host, provider: provider) {
            // 站点把探针页重定向出了同源（如 claude.ai 未登录时 302 到 claude.com）。
            // 相对路径探针必然打偏，再跑 JS 只会带回 200 HTML / 404，被当成「已退出」。
            return ["origin_drift": ProbeResult(status: 0, body: "源漂移：当前停留在 \(host)")]
        }
        let script = ProviderScripts.script(for: provider)
        do {
            let arguments = await probeArguments(for: target)
            let value = try await withTimeout(seconds: 30) { @MainActor in
                try await wv.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
            }
            guard let dict = value as? [String: Any],
                  let probes = dict["probes"] as? [String: Any] else {
                return ["script": ProbeResult(status: -2, body: "脚本返回值形状异常")]
            }
            var results: [String: ProbeResult] = [:]
            for (name, raw) in probes {
                guard let p = raw as? [String: Any] else { continue }
                let status = (p["status"] as? NSNumber)?.intValue ?? -1
                let body = p["body"] as? String ?? ""
                var capturedHeaders: [String: String] = [:]
                if let grpc = p["grpcStatus"] as? String {
                    capturedHeaders["grpc-status"] = grpc
                    capturedHeaders["grpc-message"] = (p["grpcMessage"] as? String) ?? ""
                }
                if let vercel = p["vercelMitigated"] as? String {
                    capturedHeaders["x-vercel-mitigated"] = vercel
                }
                let headers = capturedHeaders.isEmpty ? nil : capturedHeaders
                results[name] = ProbeResult(status: status, body: body, headers: headers)
            }
            if provider == .jimeng {
                let hasSession = await jimengIndicatesLogin(accountID: target.accountID)
                results["session"] = ProbeResult(
                    status: 200,
                    body: hasSession ? #"{"hasSession":true}"# : #"{"hasSession":false}"#
                )
            }
            // 附加账号的 Cookie 留在各自 dataStore，不并入共享存储（同域会互相覆盖）。
            if target.accountID == nil {
                await syncCookiesToSharedStorage(for: provider)
            }
            return results
        } catch {
            // JS 超时后 WK 往往还占着主线程：丢掉这张 WebView，下一轮换新的。
            // 已接管的即梦登录页不要拆：首页下拉还要复用这张热文档。
            if !adoptedLiveKeys.contains(target.key) {
                discardWebView(for: target)
            }
            return ["script": ProbeResult(status: -3, body: "执行失败：\(error.localizedDescription)")]
        }
    }

    /// 即梦 CSRF 在 HttpOnly Cookie 里，页面 JS 读不到；从 WK 的 Cookie 库取出再注入探针。
    private func probeArguments(for target: FetchTarget) async -> [String: Any] {
        guard target.provider == .jimeng else { return [:] }
        let cookies = await Self.dataStore(accountID: target.accountID).httpCookieStore.allCookies()
        let pairs = cookies.map { (name: $0.name, value: $0.value) }
        // 页面 webSignBody 缺席时的兜底签名（官网 Web 客户端同一套公开算法，非用户凭据）。
        let deviceTime = IntegerFormat.truncating(Date().timeIntervalSince1970) ?? 0
        return [
            "csrf": JimengSession.csrfToken(from: pairs) ?? "",
            "msToken": JimengSession.msToken(from: pairs) ?? "",
            "uifid": JimengSession.uifid(from: pairs) ?? "",
            "deviceTime": String(deviceTime),
            "signCredit": Self.md5Hex(JimengSession.signPayload(uri: JimengSession.creditPath, deviceTime: deviceTime)),
            "signHistory": Self.md5Hex(JimengSession.signPayload(uri: JimengSession.historyPath, deviceTime: deviceTime)),
        ]
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 确认登录后：在可见登录页上等加载结束；文档仍是匿名 SSR 时只重载这一张页。
    func prepareJimengLivePage(_ webView: WKWebView, homeURL: URL) async {
        await waitUntilJimengPageSettled(webView)
        let pageOK = await jimengPageIndicatesLogin(in: webView)
        let signerOK = await jimengSignerIsReady(in: webView)
        if JimengSession.shouldReloadWarmHome(
            isOnHome: isJimengHome(webView),
            isLogined: pageOK,
            hasSigner: signerOK
        ) {
            webView.load(URLRequest(url: homeURL))
            await waitUntilJimengPageSettled(webView)
        }
        await waitForJimengHomeReady(in: webView)
    }

    func jimengIndicatesLogin(accountID: UUID?) async -> Bool {
        let names = await jimengObservedCookieNames(accountID: accountID)
        return JimengSession.indicatesLogin(cookieNames: names)
    }

    /// 只回 Cookie **名**，用于诊断。不回 value。
    func jimengObservedCookieNames(accountID: UUID?) async -> [String] {
        let cookies = await Self.dataStore(accountID: accountID).httpCookieStore.allCookies()
        let domains = ProviderID.jimeng.cookieDomains
        return cookies
            .filter { cookie in
                domains.contains { cookie.domain.hasSuffix($0) }
            }
            .map(\.name)
            .sorted()
    }

    /// 读官网首页自己的登录标志，不发请求。
    func jimengPageIndicatesLogin(in webView: WKWebView?) async -> Bool {
        guard let webView else { return false }
        do {
            let value = try await webView.evaluateJavaScript(JimengSession.pageLoginScript)
            if let flag = value as? Bool { return flag }
            if let number = value as? NSNumber { return number.boolValue }
        } catch {
            return false
        }
        return false
    }

    private func discardWebView(for target: FetchTarget) {
        resumeWaiters(forKey: target.key)
        discardHostWindow(forKey: target.key)
        if let wv = webViews[target.key] {
            wv.stopLoading()
            wv.navigationDelegate = nil
        }
        webViews[target.key] = nil
    }

    /// 确保该服务商的离屏页面已加载到其站点源（否则相对路径 fetch 无从谈起）。
    private func ensureLoaded(_ wv: WKWebView, target: FetchTarget) async {
        var alreadyOnHost = wv.url?.host.map { hostMatches($0, provider: target.provider) } == true && !wv.isLoading
        if target.provider == .opencode {
            // auth.opencode.ai 与源同后缀，后缀匹配会把 OAuth 页当成「已在源上」永不重载；
            // 登录成功后探针仍在 OAuth 页跑，永远判未登录。只有停在 /workspace/<wrk_id> 才算就绪。
            alreadyOnHost = alreadyOnHost && OpenCodeSession.isProbeReady(url: wv.url)
        }
        if alreadyOnHost, target.provider != .jimeng {
            return
        }
        if alreadyOnHost, target.provider == .jimeng {
            let pageOK = await jimengPageIndicatesLogin(in: wv)
            let signerOK = await jimengSignerIsReady(in: wv)
            if JimengSession.shouldReuseWarmDocument(isOnHome: isJimengHome(wv), isLogined: pageOK) {
                return
            }
            if !JimengSession.shouldReloadWarmHome(
                isOnHome: isJimengHome(wv),
                isLogined: pageOK,
                hasSigner: signerOK
            ) {
                return
            }
        }
        let key = target.key
        let generation = (loadGeneration[key] ?? 0) + 1
        loadGeneration[key] = generation
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadWaiters[key, default: []].append(cont)
                wv.load(URLRequest(url: target.provider.probeURL))
                // 兜底：20 秒后无论加载结果如何都继续（探针自身还有超时与状态码兜底）
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard self.loadGeneration[key] == generation else { return }
                    self.resumeWaiters(forKey: key)
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.loadGeneration[key] == generation else { return }
                self.resumeWaiters(forKey: key)
            }
        }
        if target.provider == .jimeng {
            await waitForJimengSession(accountID: target.accountID)
        }
    }

    /// 等会话 Cookie 落盘，并再留一小段给官网 SPA 写 msToken，否则额度接口会当未登录。
    private func waitForJimengSession(accountID: UUID?) async {
        for _ in 0..<8 {
            if await jimengIndicatesLogin(accountID: accountID) { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// 只回报布尔：`window.use` + `webSignBody` 是否就绪。不要求 uifid
    ///（匿名 SSR 永远没有 uifid，等它会烧满 8s）。绝不回报 uifid 值。
    private static let jimengSignerReadyScript = """
    (function () {
        try {
            if (typeof window.use !== 'function') { return false; }
            var sign = window.use('webSignBody');
            return typeof sign === 'function';
        } catch (e) {
            return false;
        }
    })()
    """

    /// WKWebView / 宿主窗必须用有限正尺寸。CGRect.zero 会触发 Invalid frame dimension。
    static func safeContentFrame(in scene: UIWindowScene? = nil) -> CGRect {
        let raw = scene?.screen.bounds.size ?? CGSize(width: 390, height: 844)
        let width = raw.width.isFinite && raw.width >= 320 ? raw.width : 390
        let height = raw.height.isFinite && raw.height >= 568 ? raw.height : 844
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// 复用登录页时：等当前导航结束，最多约 10s。
    private func waitUntilJimengPageSettled(_ webView: WKWebView) async {
        for _ in 0..<40 {
            if !webView.isLoading, webView.url != nil { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func isJimengHome(_ webView: WKWebView) -> Bool {
        guard let url = webView.url, let host = url.host?.lowercased() else { return false }
        let hostOK = host == "jimeng.jianying.com" || host.hasSuffix(".jimeng.jianying.com")
        return hostOK && url.path.contains("/ai-tool/")
    }

    /// SSO / 首页复用：先给 SSR `__isLogined` + 页面签名器约 3s。等不到也放行——
    /// 探针带 native 签名头（Device-Time / Sign / Sign-Ver），不再依赖页面签名器；
    /// 以前等满 10s+8s 再裸发，结果永远 1014。
    private func waitForJimengHomeReady(in webView: WKWebView) async {
        for _ in 0..<12 {
            let pageOK = await jimengPageIndicatesLogin(in: webView)
            let signerOK = await jimengSignerIsReady(in: webView)
            if JimengSession.isCommerceReady(isLogined: pageOK, hasSigner: signerOK) { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func jimengSignerIsReady(in webView: WKWebView) async -> Bool {
        do {
            let value = try await webView.evaluateJavaScript(Self.jimengSignerReadyScript)
            if let flag = value as? Bool { return flag }
            if let number = value as? NSNumber { return number.boolValue }
        } catch {
            return false
        }
        return false
    }

    private func hostMatches(_ host: String, provider: ProviderID) -> Bool {
        // 必须停在探针/源站主机上，才能读到官网写在该源下的 localStorage Token。
        // 不能用 cookieDomains：登录跳到 auth.kimi.com 时 Cookie 域匹配，但 Token 在 www.kimi.com。
        let hosts = [provider.origin.host, provider.probeURL.host].compactMap { $0 }
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private func resumeWaiters(forKey key: String) {
        let waiters = loadWaiters[key] ?? []
        loadWaiters[key] = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Cookie 同步与清除（全部只在本机进行）

    /// 把该服务商的 Cookie 复制到 App Group 共享 CookieStorage（仍在本机沙盒内），
    /// 供小组件将来做后台刷新等扩展能力使用。
    func syncCookiesToSharedStorage(for provider: ProviderID) async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let shared = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: SharedStore.appGroupID)
        for cookie in cookies where provider.cookieDomains.contains(where: { cookie.domain.hasSuffix($0) }) {
            shared.setCookie(cookie)
        }
    }

    /// 退出登录（主账号）：清掉该服务商的全部站点数据与共享 Cookie。
    /// 只清 default dataStore，不会波及附加账号的独立 dataStore。
    func clearWebsiteData(for provider: ProviderID) async {
        let store = WKWebsiteDataStore.default()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: allTypes)
        let matching = records.filter { record in
            provider.cookieDomains.contains { record.displayName.hasSuffix($0) }
        }
        await store.removeData(ofTypes: allTypes, for: matching)
        let shared = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: SharedStore.appGroupID)
        for cookie in shared.cookies ?? [] where provider.cookieDomains.contains(where: { cookie.domain.hasSuffix($0) }) {
            shared.deleteCookie(cookie)
        }
        discardHostWindow(forKey: provider.rawValue)
        webViews[provider.rawValue]?.navigationDelegate = nil
        webViews[provider.rawValue] = nil
    }

    /// 退出登录 / 删除附加账号：清空该账号独立 dataStore 的全部站点数据。
    /// `removeStore` 在删除账号时一并销毁磁盘上的 dataStore 容器。
    func clearAccountData(provider: ProviderID, accountID: UUID, removeStore: Bool = false) async {
        let key = FetchTarget(provider: provider, accountID: accountID).key
        discardHostWindow(forKey: key)
        webViews[key]?.stopLoading()
        webViews[key]?.navigationDelegate = nil
        webViews[key] = nil
        let store = WKWebsiteDataStore(forIdentifier: accountID)
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: allTypes)
        await store.removeData(ofTypes: allTypes, for: records)
        if removeStore {
            // 正被引用时会抛错；数据已清空，容器留壳无碍，尽力而为。
            try? await WKWebsiteDataStore.remove(forIdentifier: accountID)
        }
    }

    // MARK: - 超时

    private struct TimeoutError: Error, LocalizedError {
        var errorDescription: String? { "请求超时" }
    }

    /// 超时必须立刻返回。`withThrowingTaskGroup` 在子任务抛错后仍会等另一个
    /// 子任务结束，而 `callAsyncJavaScript` 不响应取消，下拉刷新就会一直转。
    private func withTimeout<T>(seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        guard let delay = SafeDuration.nanoseconds(seconds: seconds) else { throw TimeoutError() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = OnceResume(cont)
            Task { @MainActor in
                do {
                    let value = try await operation()
                    once.resume(returning: value)
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task {
                try await Task.sleep(nanoseconds: delay)
                once.resume(throwing: TimeoutError())
            }
        }
    }
}

/// 只 resume 一次，超时与成功赛跑时丢弃后来者。
private final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

extension WebViewFetcher: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resumeWaiters(matching: webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeWaiters(matching: webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeWaiters(matching: webView) }
    }

    /// 离屏探针没有弹窗 UI：只取消 Apple SSO iframe，避免系统 SOAuthorization 搅页。
    /// 不得按登录页提升名单一律 cancel——那会干掉 bytedance / jianying / douyin 的 secsdk 初始化 iframe。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // 官网的重定向或 iframe 同样可能发起安装链接，离屏页不能交给系统处理。
        if LoginWebViewScripts.isAppStoreNavigation(navigationAction.request.url) {
            decisionHandler(.cancel)
            return
        }
        if LoginWebViewScripts.isAdHost(navigationAction.request.url?.host) {
            decisionHandler(.cancel)
            return
        }
        let isIFrame = navigationAction.targetFrame?.isMainFrame == false
        if isIFrame, let host = navigationAction.request.url?.host?.lowercased() {
            let appleSSOHosts = [
                "appleid.apple.com",
                "idmsa.apple.com",
                "appleid.cdn-apple.com",
                "gsa.apple.com",
            ]
            if appleSSOHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    private func resumeWaiters(matching webView: WKWebView) {
        if let key = webViews.first(where: { $0.value === webView })?.key {
            resumeWaiters(forKey: key)
        }
    }
}

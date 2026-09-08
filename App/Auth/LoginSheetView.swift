import SwiftUI
import UIKit
import WebKit
import UsageLimitsCore

/// 一次登录请求：主账号（account == nil，共享 default dataStore）
/// 或附加账号（独立 dataStore，Cookie 与主账号互不覆盖）。
struct LoginRequest: Identifiable {
    let provider: ProviderID
    let account: ProviderAccount?

    var id: String { account?.id.uuidString ?? provider.rawValue }

    init(provider: ProviderID, account: ProviderAccount? = nil) {
        self.provider = provider
        self.account = account
    }

    init?(account: ProviderAccount) {
        guard let provider = account.provider else { return nil }
        self.provider = provider
        self.account = account
    }
}

/// 内置浏览器登录页：用户在官方站点完成登录，Cookie 留在本机 WebKit 存储。
/// 探测到已有会话时先弹确认（已经登录 / 登录账号：xxxx / 是否登录）；点否可继续换号。
struct LoginSheetView: View {
    let request: LoginRequest
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var lang

    @State private var detected = false
    @State private var checking = false
    @State private var probing = false
    @State private var pendingAccountLabel: String?
    @State private var suppressAutoPrompt = false
    @State private var loginPage = LoginPageBox()
    @State private var checkFailure: SnapshotStatus?
    @State private var externalAppBlocked = false
    @State private var loadProgress = LoginLoadProgress()
    @State private var hideProgressTask: Task<Void, Never>?

    private var provider: ProviderID { request.provider }

    init(request: LoginRequest) {
        self.request = request
    }

    init(provider: ProviderID) {
        self.request = LoginRequest(provider: provider)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                loadingBar
                LoginWebView(
                    url: provider.loginURL, accountID: request.account?.id, page: loginPage,
                    onPageFinished: { Task { await runCheck(silent: true) } },
                    onExternalAppBlocked: { externalAppBlocked = true },
                    onProgress: { applyLoadProgress($0) }
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(L10n.tr("card.login", lang, request.account?.displayName(language: lang) ?? provider.localizedName(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await runCheck(silent: false) }
                    } label: {
                        if checking {
                            ProgressView()
                        } else {
                            Text(L10n.tr("login.check", lang))
                        }
                    }
                    .disabled(checking)
                }
            }
        }
        .alert(
            L10n.tr("login.alreadySignedIn", lang),
            isPresented: Binding(
                get: { pendingAccountLabel != nil },
                set: { if !$0, pendingAccountLabel != nil { applyConfirm(.decline) } }
            )
        ) {
            Button(L10n.tr("login.confirm.yes", lang)) { applyConfirm(.accept) }
            Button(L10n.tr("login.confirm.no", lang), role: .cancel) { applyConfirm(.decline) }
        } message: {
            Text(
                L10n.tr("login.signedInAccount", lang, pendingAccountLabel ?? "")
                + "\n"
                + L10n.tr("login.confirmUse", lang)
            )
        }
        .task { await monitorLoop() }
        // iPad regular 宽度下 sheet 默认是 540×620 的表单卡片，官网登录页会被挤成窄条。
        // .page 让 sheet 撑到接近整页（iOS 18+，工程 deploymentTarget 就是 18.0）；
        // iPhone 的 compact 宽度本来就是整宽 sheet，这个修饰符在那边是空操作。
        .presentationSizing(.page)
    }

    /// 登录页打开期间持续轮询登录态；探到已登录只弹确认，点是才关页。
    private func monitorLoop() async {
        while !Task.isCancelled, !detected {
            await runCheck(silent: true)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if detected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.tr("login.detected", lang))
            } else if externalAppBlocked {
                Text(L10n.tr("login.webOnlyBlocked", lang))
                Button(L10n.tr("login.continueOnWeb", lang)) {
                    externalAppBlocked = false
                    checkFailure = nil
                    loginPage.activeWebView?.load(URLRequest(url: provider.loginURL))
                }
            } else if checking {
                ProgressView().controlSize(.small)
                Text(L10n.tr("login.checking", lang))
            } else if let checkFailure {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(checkFailure.displayText(lang))
            } else {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text(L10n.tr("login.banner", lang))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 顶部加载条：官方站首屏慢时原本只有空白页，这条按 WebKit 的真实进度给出反馈。
    /// 渐变主题色按整条轨道铺开、再由进度揭开前段（`BrandTint` 对条状元素的约定），
    /// 压进已用长度的话低进度时首尾两色会挤成一小截。纯色的 `barFill` 就是实底，行为不变。
    private var loadingBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(loadingBarTint.barFill)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: geo.size.width * loadProgress.value)
                }
        }
        .frame(height: 2)
        .opacity(loadProgress.isVisible ? 1 : 0)
        .animation(.linear(duration: 0.15), value: loadProgress.value)
        .animation(.easeOut(duration: 0.2), value: loadProgress.isVisible)
        .allowsHitTesting(false)
    }

    /// 加载条取本账号 / 本供应商的品牌色，与首页卡片同一套解析。
    private var loadingBarTint: BrandTint {
        if let account = request.account { return state.resolvedTint(for: account) }
        return state.resolvedTint(provider: provider)
    }

    /// 满格后留 `hideDelay` 再归零；期间开了新导航就取消计时，免得登录多跳转时一路闪烁。
    private func applyLoadProgress(_ value: Double) {
        let justFinished = loadProgress.apply(value)
        if loadProgress.phase == .loading {
            hideProgressTask?.cancel()
            hideProgressTask = nil
        }
        guard justFinished else { return }
        hideProgressTask = Task { @MainActor in
            try? await Task.sleep(for: LoginLoadProgress.hideDelay)
            guard !Task.isCancelled else { return }
            loadProgress.settle()
        }
    }

    /// 探测一次登录态。silent 的自动轮询不去闪动工具栏按钮，手动点按才显示 spinner。
    @MainActor
    private func runCheck(silent: Bool) async {
        guard !detected, !probing, pendingAccountLabel == nil else { return }
        probing = true
        if !silent { checking = true }
        defer {
            probing = false
            checking = false
        }
        // 即梦：官网 SSR 标志或会话 Cookie 任一成立就认登录，不要等离屏探针失败后再弹。
        if provider == .jimeng {
            let cookiesOK = await WebViewFetcher.shared.jimengIndicatesLogin(accountID: request.account?.id)
            let pageOK = await WebViewFetcher.shared.jimengPageIndicatesLogin(in: loginPage.webView)
            if cookiesOK || pageOK {
                probing = false
                checking = false
                presentConfirmIfNeeded(probeOK: true, silent: silent)
                return
            }
        }
        let live = liveProbeWebView
        let snap: ProviderSnapshot?
        if provider == .grok {
            // xAI 中转页可能没有回跳，但同一 Cookie store 的官网会话已经生效。
            // 用可见 Grok 页，或同账号离屏 Grok 页重新请求；两条路径均不读旧快照。
            guard let checkedPage = loginPage.activeWebView, !checkedPage.isLoading else { return }
            let checkedURL = checkedPage.url
            snap = await state.checkLogin(provider, accountID: request.account?.id, using: live)
            guard checkedPage === loginPage.activeWebView, checkedPage.url == checkedURL,
                  !checkedPage.isLoading, !Task.isCancelled else { return }
        } else if provider == .cursor {
            guard let live, !live.isLoading else {
                if LoginProbePolicy.isAuthenticationPage(provider: provider, url: loginPage.activeWebView?.url) {
                    presentConfirmIfNeeded(probeOK: false, silent: silent)
                }
                if !silent { checkFailure = .error("请先完成官网登录并进入用量页面") }
                return
            }
            let checkedURL = live.url
            snap = await state.checkLogin(provider, accountID: request.account?.id, using: live)
            // OAuth 仍可能继续回跳；旧文档的响应不能确认新页面的会话。
            guard live === liveProbeWebView, live.url == checkedURL, !live.isLoading, !Task.isCancelled else { return }
        } else if let account = request.account {
            snap = await state.refreshAccount(account, allowWhenDisabled: true, using: live)
        } else {
            snap = await state.refresh(provider, using: live)
        }
        probing = false
        checking = false
        var probeOK = LoginProbePolicy.isAuthenticated(snap)
        if !probeOK, provider == .jimeng {
            probeOK = await WebViewFetcher.shared.jimengIndicatesLogin(accountID: request.account?.id)
        }
        if probeOK {
            checkFailure = nil
            externalAppBlocked = false
        } else if !silent || snap?.status == .error(GrokParser.browserVerificationError) {
            if snap?.isAnonymous == true {
                checkFailure = .error("检测到游客额度，请先登录账号")
            } else if let status = snap?.status, case .error = status {
                checkFailure = status
            } else {
                checkFailure = .error("尚未检测到登录会话")
            }
        }
        presentConfirmIfNeeded(probeOK: probeOK, silent: silent)
    }

    /// 使用当前可见的官网登录文档，包括仍在 OAuth 弹窗中的 Dashboard。
    private var liveProbeWebView: WKWebView? {
        guard let webView = loginPage.activeWebView,
              LoginProbePolicy.isReady(provider: provider, url: webView.url) else { return nil }
        return webView
    }

    private func presentConfirmIfNeeded(probeOK: Bool, silent: Bool) {
        suppressAutoPrompt = LoginConfirm.stillSuppressAutoPrompt(
            probeOK: probeOK, currentlySuppressed: suppressAutoPrompt
        )
        let action = LoginConfirm.action(
            probeOK: probeOK,
            alreadyDetected: detected,
            confirmationVisible: pendingAccountLabel != nil,
            autoPromptSuppressed: silent && suppressAutoPrompt,
            siteIdentity: nil,
            displayName: request.account?.displayName(language: lang) ?? provider.localizedName(lang)
        )
        if case .prompt(let label) = action {
            pendingAccountLabel = label
        }
    }

    private func applyConfirm(_ choice: LoginConfirm.Choice) {
        let outcome = LoginConfirm.Outcome.applying(choice)
        pendingAccountLabel = nil
        if outcome.suppressFurtherAutoAccept {
            suppressAutoPrompt = true
        }
        if outcome.markDetected {
            detected = true
        }
        if outcome.dismissAsSuccess {
            Task {
                await refreshUsageAfterConfirm()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
        }
    }

    /// cookiesOK 只负责弹出确认，不能当成已经抓过积分。点是之后必须在可见登录页刷新。
    private func refreshUsageAfterConfirm() async {
        var live = liveProbeWebView
        if provider == .jimeng, let webView = loginPage.webView {
            await WebViewFetcher.shared.prepareJimengLivePage(webView, homeURL: provider.loginURL)
            WebViewFetcher.shared.adoptLiveJimengWebView(webView, accountID: request.account?.id)
            live = liveProbeWebView ?? webView
        }
        if let account = request.account {
            await state.refreshAccount(account, allowWhenDisabled: true, using: live)
        } else {
            await state.refresh(provider, using: live)
        }
    }
}

/// 可见的登录 WebView。与离屏探针 WebView 共用同一个 WKWebsiteDataStore
/// （主账号 default、附加账号按 UUID 隔离），登录产生的 Cookie 对探针即时可见。
private final class LoginPageBox {
    weak var webView: WKWebView?
    weak var popupWebView: WKWebView?
    var activeWebView: WKWebView? { popupWebView ?? webView }
}

private struct LoginWebView: UIViewRepresentable {
    let url: URL
    var accountID: UUID?
    var page: LoginPageBox
    var onPageFinished: () -> Void
    var onExternalAppBlocked: () -> Void
    var onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPageFinished: onPageFinished, onExternalAppBlocked: onExternalAppBlocked,
            onProgress: onProgress, page: page, homeURL: url
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebViewFetcher.dataStore(accountID: accountID)
        // iOS 默认 false：Google / Apple 的 window.open 会立刻失败，登录页只剩红框。
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(WKUserScript(
            source: LoginWebViewScripts.hideWebAuthn,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: LoginWebViewScripts.hideSmartAppBanner,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: LoginWebViewScripts.promoteSSOIframes,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let wv = WKWebView(frame: WebViewFetcher.safeContentFrame(), configuration: config)
        wv.customUserAgent = WebViewFetcher.safariUA
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        if GrokWebLoginPolicy.isWebOnlyLogin(url) { wv.allowsLinkPreview = false }
        #if DEBUG
        wv.isInspectable = true
        #endif
        page.webView = wv
        context.coordinator.trackProgress(of: wv)
        wv.load(URLRequest(url: url))
        return wv
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.page.webView = nil
        coordinator.stopTrackingProgress()
        if WebViewFetcher.shared.ownsJimengLiveWebView(uiView) {
            return
        }
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onPageFinished: () -> Void
        let onExternalAppBlocked: () -> Void
        let onProgress: (Double) -> Void
        let page: LoginPageBox
        let homeURL: URL
        var popupContainers: [OAuthPopupContainer] = []
        private var webOnlyReloads: [ObjectIdentifier: URL] = [:]
        private var progressObservation: NSKeyValueObservation?

        init(onPageFinished: @escaping () -> Void, onExternalAppBlocked: @escaping () -> Void,
             onProgress: @escaping (Double) -> Void, page: LoginPageBox, homeURL: URL) {
            self.onPageFinished = onPageFinished
            self.onExternalAppBlocked = onExternalAppBlocked
            self.onProgress = onProgress
            self.page = page
            self.homeURL = homeURL
        }

        /// 加载条只读 WebKit 的真实进度，不自己造动画；KVO 在主线程投递。
        /// 观察对象始终是当前在屏的那个 WebView：弹窗盖上来就跟弹窗，弹窗拆掉再回主页面。
        func trackProgress(of webView: WKWebView) {
            progressObservation = webView.observe(
                \.estimatedProgress, options: [.initial, .new]
            ) { [weak self] view, _ in
                self?.onProgress(view.estimatedProgress)
            }
        }

        func stopTrackingProgress() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webOnlyReloads.removeValue(forKey: ObjectIdentifier(webView))
            onPageFinished()
        }

        /// 即梦把 Apple / 字节护照放在 iframe 里时，系统 SOAuthorization 会把子框导航取消（-999）。
        /// 提到顶层弹窗后，主框 SSO 才能走完，会话 Cookie 才能落到 jimeng.jianying.com。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if GrokWebLoginPolicy.blocksExternalNavigation(navigationAction.request.url, loginPage: homeURL) {
                decisionHandler(.cancel)
                onExternalAppBlocked()
                return
            }
            if LoginWebViewScripts.isAppStoreNavigation(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }
            if LoginWebViewScripts.isAdHost(navigationAction.request.url?.host) {
                decisionHandler(.cancel)
                if popupContainers.contains(where: { $0.webView === webView }) {
                    if let container = popupContainers.first(where: { $0.webView === webView }) {
                        finishPopup(container)
                    }
                }
                return
            }
            if popupContainers.contains(where: { $0.webView === webView }),
               navigationAction.targetFrame?.isMainFrame != false,
               let url = navigationAction.request.url,
               !LoginWebViewScripts.shouldPresentLoginPopup(url: url, loginPage: homeURL) {
                decisionHandler(.cancel)
                if let container = popupContainers.first(where: { $0.webView === webView }) {
                    finishPopup(container)
                }
                return
            }
            // 在原 WebView（包括 OAuth 弹窗）内重载完整请求，保留 query / state / Cookie / opener。
            // 下一次由 load 发起的导航只放行一次，不能反复 cancel → load。
            let viewID = ObjectIdentifier(webView)
            let isWebOnlyReload = navigationAction.navigationType == .other
                && navigationAction.request.url != nil
                && webOnlyReloads[viewID] == navigationAction.request.url
            if isWebOnlyReload {
                webOnlyReloads.removeValue(forKey: viewID)
            } else if GrokWebLoginPolicy.shouldLoadInWebView(
                navigationAction.request.url, sourceURL: navigationAction.sourceFrame.request.url,
                loginPage: homeURL, isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                isLinkActivated: navigationAction.navigationType == .linkActivated,
                httpMethod: navigationAction.request.httpMethod
            ), let url = navigationAction.request.url {
                webOnlyReloads[viewID] = url
                decisionHandler(.cancel)
                webView.load(navigationAction.request)
                return
            }
            if let currentHost = webView.url?.host,
               LoginWebViewScripts.shouldPromoteIFrameToPopup(host: currentHost) {
                decisionHandler(.allow)
                return
            }
            let isIFrame = navigationAction.targetFrame?.isMainFrame == false
            if isIFrame,
               let url = navigationAction.request.url,
               LoginWebViewScripts.shouldPromoteIFrameToPopup(url: url) {
                decisionHandler(.cancel)
                // 必须走 window.open → createWebViewWith，才能保留 opener。
                // 自己 new WKWebView 没有 opener，抖音 Apple 回跳到不了即梦页。
                let escaped = url.absoluteString
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("window.open('\(escaped)', '_blank')")
                return
            }
            decisionHandler(.allow)
        }

        /// Google / Apple 登录会 `window.open`。必须返回用 WebKit 给定 configuration
        /// 建的 WebView（共享进程与 Cookie），不能改成当前页 load，否则没有 opener。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let url = navigationAction.request.url
            if LoginWebViewScripts.isAppStoreNavigation(url) {
                return nil
            }
            if GrokWebLoginPolicy.blocksExternalNavigation(url, loginPage: homeURL) {
                onExternalAppBlocked()
                return nil
            }
            if LoginWebViewScripts.isAdHost(url?.host) {
                return nil
            }
            return presentPopup(
                from: webView,
                configuration: configuration,
                request: nil,
                attach: LoginWebViewScripts.shouldPresentLoginPopup(url: url, loginPage: homeURL)
            )
        }

        @discardableResult
        func presentPopup(
            from webView: WKWebView,
            configuration: WKWebViewConfiguration?,
            request: URLRequest?,
            attach: Bool = true
        ) -> WKWebView {
            let popup: WKWebView
            if let configuration {
                popup = WKWebView(frame: WebViewFetcher.safeContentFrame(), configuration: configuration)
            } else {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = webView.configuration.websiteDataStore
                config.preferences.javaScriptCanOpenWindowsAutomatically = true
                config.userContentController.addUserScript(WKUserScript(
                    source: LoginWebViewScripts.hideWebAuthn,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
                config.userContentController.addUserScript(WKUserScript(
                    source: LoginWebViewScripts.hideSmartAppBanner,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
                config.userContentController.addUserScript(WKUserScript(
                    source: LoginWebViewScripts.promoteSSOIframes,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
                popup = WKWebView(frame: WebViewFetcher.safeContentFrame(), configuration: config)
            }
            popup.customUserAgent = webView.customUserAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.allowsBackForwardNavigationGestures = true
            if GrokWebLoginPolicy.isWebOnlyLogin(homeURL) { popup.allowsLinkPreview = false }
            #if DEBUG
            popup.isInspectable = true
            #endif
            let container = OAuthPopupContainer(webView: popup)
            container.translatesAutoresizingMaskIntoConstraints = false
            if attach, let host = webView.superview {
                host.addSubview(container)
                NSLayoutConstraint.activate([
                    container.topAnchor.constraint(equalTo: host.topAnchor),
                    container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                ])
            }
            popupContainers.append(container)
            if attach {
                page.popupWebView = popup
                // 弹窗盖住整个网页区，这段加载不接管进度条就完全没有反馈。
                trackProgress(of: popup)
            }
            if let request, configuration == nil {
                popup.load(request)
            }
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            if let container = popupContainers.first(where: { $0.webView === webView }) {
                finishPopup(container)
            }
        }

        private func finishPopup(_ container: OAuthPopupContainer) {
            guard popupContainers.contains(where: { $0 === container }) else { return }
            webOnlyReloads.removeValue(forKey: ObjectIdentifier(container.webView))
            container.removeFromSuperview()
            popupContainers.removeAll { $0 === container }
            page.popupWebView = popupContainers.last(where: { $0.superview != nil })?.webView
            if let active = page.activeWebView { trackProgress(of: active) }
            reloadJimengHomeAfterSSO()
            onPageFinished()
        }

        /// 官网 `__isLogined` 写在 SSR 里。护照在弹窗里完成后，主页仍是登录前的文档，
        /// 必须重新加载 `/ai-tool/home`，标志才会变成 true。
        private func reloadJimengHomeAfterSSO() {
            guard homeURL.host == "jimeng.jianying.com" else { return }
            page.webView?.load(URLRequest(url: homeURL))
        }
    }
}

/// OAuth 弹窗容器：铺满网页区、不带任何 chrome，看上去就是登录页自己跳了一步。
/// 加载反馈统一交给顶部加载条；弹窗由站点 `window.close()`、导航策略或工具栏「关闭」收场。
private final class OAuthPopupContainer: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

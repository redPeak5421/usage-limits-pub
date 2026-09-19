import XCTest

/// 演示模式 = 纯橱窗：首页没有服务商时空态给开关（关闭只能去设置）；添加任一服务商自动关闭；
/// 开着时首页隐藏用户自己的服务商，只铺演示卡。
final class DemoModeSourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func slice(_ source: String, from startToken: String, to endToken: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken), "missing \(startToken)")
        let end = try XCTUnwrap(
            source.range(of: endToken, range: start.upperBound..<source.endIndex),
            "missing \(endToken) after \(startToken)"
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func testAddingAnyProviderExitsDemoModeBeforeWritingAccounts() throws {
        let appState = try source("App/AppState.swift")

        // 退出演示靠 demoMode 的 didSet 落盘、重载、推小组件与手表
        let demoProperty = try slice(appState, from: "@Published var demoMode: Bool", to: "@Published var language")
        for token in [
            "store.demoMode = demoMode",
            "reloadFromStore()",
            "WidgetCenter.shared.reloadAllTimelines()",
            "WatchSync.shared.pushState()",
        ] {
            XCTAssertTrue(demoProperty.contains(token), "demoMode didSet omitted \(token)")
        }

        let helper = try slice(
            appState,
            from: "private func exitDemoModeForNewAccount()",
            to: "func renameAccount("
        )
        XCTAssertTrue(helper.contains("guard demoMode else { return }"))
        XCTAssertTrue(helper.contains("demoMode = false"), "新增服务商须自动关闭演示模式")

        let bodies = [
            try slice(
                appState,
                from: "func addAccount(provider: ProviderID, name: String)",
                to: "private func exitDemoModeForNewAccount()"
            ),
            try slice(
                appState,
                from: "func addCustomAccount(template: CustomUsageTemplate, name: String, token: String)",
                to: "func updateCustomToken("
            ),
        ]
        for body in bodies {
            let exit = try XCTUnwrap(body.range(of: "exitDemoModeForNewAccount()"), "添加路径须先退出演示模式")
            let append = try XCTUnwrap(body.range(of: "accounts.append("))
            XCTAssertLessThan(
                exit.lowerBound,
                append.lowerBound,
                "先关演示再写账号，后续重载读到的才是真实数据"
            )
        }
    }

    func testDemoModeHidesUsersOwnProvidersOnHome() throws {
        let dashboard = try source("App/Views/DashboardView.swift")
        let scene = try slice(
            dashboard,
            from: "private var sceneItems: [DashboardSceneItem]",
            to: "private func displayedShareItems(from items: [DashboardSceneItem])"
        )
        XCTAssertTrue(
            scene.contains("for account in state.visibleAccounts where !state.demoMode {"),
            "演示模式须整体跳过真实账号（内置主号、附加号、自定义）"
        )
        XCTAssertFalse(scene.contains("seenPrimaryProviders"), "演示卡不再与真实主号去重")
        let demoBlock = try slice(scene, from: "if state.demoMode {", to: "return items")
        // 演示卡须按全部可用服务商铺开：会话内排序只留仍可用的，缺的补到末尾
        for token in [
            "let available = state.availableProviders",
            "(demoProviderOrder ?? []).filter { available.contains($0) }",
            "for provider in available where !demoProviders.contains(provider)",
        ] {
            XCTAssertTrue(demoBlock.contains(token), "demo loop omitted \(token)")
        }
        let demoLoop = try XCTUnwrap(demoBlock.range(of: "for provider in demoProviders {"))
        XCTAssertTrue(demoBlock[demoLoop.upperBound...].contains("DashboardSceneItemID.demo(provider)"))

        let body = try slice(dashboard, from: "var body: some View", to: "private var sceneItems: [DashboardSceneItem]")
        XCTAssertTrue(body.contains("showsEmptyHint: state.visibleAccounts.isEmpty && !state.demoMode"))
        XCTAssertTrue(body.contains("showsDemoToggle: state.visibleAccounts.isEmpty && !state.demoMode"))
        XCTAssertEqual(
            body.components(separatedBy: "demoMode: $state.demoMode").count - 1,
            2,
            "平铺与场景空态都要拿到演示模式开关"
        )
    }

    func testFlatEmptyStateOffersDemoButtonUnderAddButton() throws {
        let flat = try source("App/Views/DashboardFlatView.swift")
        let hint = try slice(flat, from: "private var allDisabledHint: some View", to: "private var demoBanner: some View")
        for token in [
            "L10n.tr(\"home.demo.enable\", lang)",
            "L10n.tr(\"home.demo.toggle.hint\", lang)",
            "demoMode = true",
            ".modifier(EmptyStateButtonStyle(prominent: false))",
            ".controlSize(.large)",
            ".accessibilityIdentifier(\"home.demoToggle\")",
        ] {
            XCTAssertTrue(hint.contains(token), "flat empty state omitted \(token)")
        }
        XCTAssertFalse(hint.contains("Toggle("), "演示按钮不再是 Toggle")
        let add = try XCTUnwrap(hint.range(of: "Button(action: onAddProvider)"))
        let demoButton = try XCTUnwrap(hint.range(of: "L10n.tr(\"home.demo.enable\", lang)"))
        XCTAssertLessThan(add.lowerBound, demoButton.lowerBound, "演示按钮排在添加按钮下面")
        let demoButtonStyle = try XCTUnwrap(
            hint.range(of: ".modifier(EmptyStateButtonStyle(prominent: false))", range: demoButton.upperBound..<hint.endIndex)
        )
        let addButtonStyle = try XCTUnwrap(hint.range(of: ".modifier(EmptyStateButtonStyle(prominent: true))"))
        XCTAssertLessThan(addButtonStyle.lowerBound, demoButtonStyle.lowerBound, "演示按钮样式紧跟在添加按钮之后")
        XCTAssertTrue(flat.contains("@Binding var demoMode: Bool"))

        // 两颗按钮的系统样式在 EmptyStateButtonStyle 里挑：iOS 26 液态玻璃，iOS 18–25 落回描边样式。
        XCTAssertTrue(flat.contains("#available(iOS 26.0, *)"), "empty state buttons must gate on iOS 26")
        XCTAssertTrue(flat.contains(".buttonStyle(.glassProminent)"), "add button must use glassProminent on iOS 26")
        XCTAssertTrue(flat.contains(".buttonStyle(.glass)"), "demo button must use glass on iOS 26")
        XCTAssertTrue(flat.contains(".buttonStyle(.borderedProminent)"), "add button must fall back to borderedProminent below iOS 26")
        XCTAssertTrue(flat.contains(".buttonStyle(.bordered)"), "demo button must fall back to bordered below iOS 26")
    }

    func testSceneEmptyStateDemoButtonIsTappableAndThemed() throws {
        let carousel = try source("App/Views/DashboardCarouselView.swift")
        XCTAssertTrue(carousel.contains("let showsDemoToggle: Bool"))
        XCTAssertTrue(carousel.contains("@Binding private var demoMode: Bool"))
        let emptyState = try slice(
            carousel,
            from: "private var emptyState: some View",
            to: "private func sceneAccessibilityContainer("
        )
        // 账号全停用也会落到场景空态，那时不给按钮
        let block = try slice(emptyState, from: "if showsDemoToggle {", to: "L10n.tr(\"privacy.footer\", language)")
        for token in [
            "L10n.tr(\"home.demo.enable\", language)",
            "L10n.tr(\"home.demo.toggle.hint\", language)",
            "demoMode = true",
            "theme.secondaryForeground",
            ".contentShape(Capsule())",
            ".modifier(EmptyStateCapsuleSurface(prominent: false, theme: theme, reduceTransparency: reduceTransparency))",
            // 场景手势会吞掉控件之外的点按，按钮必须登记为控件区
            ".dashboardSceneControlRegion()",
            ".environment(\\.dashboardSceneControlsEnabled, true)",
            "home.demoToggle",
        ] {
            XCTAssertTrue(block.contains(token), "scene demo button omitted \(token)")
        }
        XCTAssertFalse(block.contains("Toggle("), "演示按钮不再是 Toggle")
        let add = try XCTUnwrap(emptyState.range(of: "Button(action: onAddProvider)"))
        let toggle = try XCTUnwrap(emptyState.range(of: "if showsDemoToggle {"))
        XCTAssertLessThan(add.lowerBound, toggle.lowerBound, "演示按钮排在添加按钮下面")
        // 场景空态宽度受限，提示须能换行，不能被截成一行
        XCTAssertTrue(block.contains(".fixedSize(horizontal: false, vertical: true)"))

        // 两颗按钮共用 EmptyStateCapsuleSurface：iOS 26 且未关闭透明度走液态玻璃，
        // 主按钮按 theme.metalAccent 着色；老系统 / 关闭透明度落回原来的胶囊描边填充。
        XCTAssertTrue(carousel.contains("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency"))
        let surface = try slice(
            carousel,
            from: "private struct EmptyStateCapsuleSurface: ViewModifier {",
            to: "@MainActor\nprivate struct DashboardSceneAccessibilityModifier"
        )
        XCTAssertTrue(surface.contains("#available(iOS 26.0, *), !reduceTransparency"), "glass surface must gate on iOS 26 and reduceTransparency")
        XCTAssertTrue(surface.contains(".glassEffect("))
        XCTAssertTrue(surface.contains(".interactive()"))
        XCTAssertTrue(surface.contains("theme.metalAccent"))
        XCTAssertTrue(surface.contains("theme.pageBackground"))
        XCTAssertTrue(surface.contains("theme.primaryForeground"))
        // 命中形状须在玻璃效果之前声明，否则液态玻璃不参与命中测试，胶囊空白处点不到（DEVLOG #95）。
        let shape = try XCTUnwrap(carousel.range(of: ".contentShape(Capsule())"))
        let glass = try XCTUnwrap(carousel.range(of: ".glassEffect("))
        XCTAssertLessThan(shape.lowerBound, glass.lowerBound, "contentShape 必须先于液态玻璃声明")
    }

    /// 纯色底上液态玻璃无物可折射、看着像实色胶囊：两套空态的按钮组背后垫静态彩色光晕，
    /// 只在真正渲染玻璃时出现（iOS 26 且未开「降低透明度」），不拦点击、不是场景控件区、没有常驻动画。
    func testEmptyStateButtonsSitOnStaticGlowOnlyWhenGlassRenders() throws {
        let flat = try source("App/Views/DashboardFlatView.swift")
        XCTAssertTrue(flat.contains("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency"))
        let hint = try slice(flat, from: "private var allDisabledHint: some View", to: "private var demoBanner: some View")

        let carousel = try source("App/Views/DashboardCarouselView.swift")
        let emptyState = try slice(
            carousel,
            from: "private var emptyState: some View",
            to: "private func sceneAccessibilityContainer("
        )

        for (name, body) in [("flat", hint), ("scene", emptyState)] {
            XCTAssertEqual(
                body.components(separatedBy: "EmptyStateGlowBackdrop(").count - 1,
                1,
                "\(name) empty state must place exactly one glow backdrop"
            )
            // 光晕挂在按钮组的 .background 上（不是栈里多出来的子视图，不改布局），并按玻璃是否渲染来开关
            let gate = try slice(body, from: ".background {", to: "EmptyStateGlowBackdrop(")
            XCTAssertTrue(
                gate.contains("if #available(iOS 26.0, *), !reduceTransparency {"),
                "\(name) glow must only render with iOS 26 glass and without reduce transparency"
            )
            let demoButton = try XCTUnwrap(body.range(of: "home.demoToggle"))
            let backdrop = try XCTUnwrap(body.range(of: "EmptyStateGlowBackdrop("))
            XCTAssertLessThan(demoButton.lowerBound, backdrop.lowerBound, "\(name) glow backs the whole button group")
        }

        // 场景空态：光晕在隐私页脚之前收口，且光晕自身不登记为控件区（按钮仍各自登记）
        let sceneBackdrop = try slice(emptyState, from: ".background {", to: "L10n.tr(\"privacy.footer\", language)")
        XCTAssertFalse(sceneBackdrop.contains("dashboardSceneControlRegion"), "glow must not become a scene control region")
        XCTAssertFalse(sceneBackdrop.contains("dashboardSceneControlsEnabled"))

        // 调用处只传一个色相：多色色块叠在无色玻璃后显脏（用户反馈「像猴子屁股」）
        for (name, body) in [("flat", hint), ("scene", emptyState)] {
            let call = try slice(body, from: "EmptyStateGlowBackdrop(", to: ")")
            XCTAssertTrue(call.hasPrefix("EmptyStateGlowBackdrop(tint:"), "\(name) glow must take a single tint")
            XCTAssertFalse(body.contains("palette:"), "\(name) glow must not take a multi-color palette")
        }

        let glow = try source("App/Views/EmptyStateGlowBackdrop.swift")
        for token in [
            "struct EmptyStateGlowBackdrop: View",
            "let tint: Color",
            "@Environment(\\.colorScheme) private var colorScheme",
            "EllipticalGradient(",
            ".allowsHitTesting(false)",
            ".accessibilityHidden(true)",
        ] {
            XCTAssertTrue(glow.contains(token), "glow backdrop omitted \(token)")
        }
        // 单色柔光：一种渐变、一个色相，不再有多色色块
        for forbidden in ["palette", "[Color]", "RadialGradient(", "LinearGradient(", "AngularGradient(", "MeshGradient(", "Ellipse()", ".blur(radius:"] {
            XCTAssertFalse(glow.contains(forbidden), "glow backdrop must be one single-hue gradient, found \(forbidden)")
        }
        XCTAssertNil(
            glow.range(of: #"Color\(|\.(blue|purple|pink|orange|red|yellow|indigo|teal|cyan|mint|green)\b"#, options: .regularExpression),
            "glow backdrop must take its only hue from the caller's tint"
        )
        for forbidden in ["repeatForever", "TimelineView", "withAnimation", "phaseAnimator", "keyframeAnimator", ".animation("] {
            XCTAssertFalse(glow.contains(forbidden), "glow backdrop must stay static, found \(forbidden)")
        }
    }

    /// 演示卡与同服务商的真实账号共用 provider：卡上的登录 / 刷新 / 登出会落到被隐藏的真实账号上，必须惰性。
    func testDemoCardsAreInertTowardHiddenRealAccounts() throws {
        let dashboard = try source("App/Views/DashboardView.swift")
        let scene = try slice(
            dashboard,
            from: "private var sceneItems: [DashboardSceneItem]",
            to: "private func displayedShareItems(from items: [DashboardSceneItem])"
        )
        let demoBlock = try slice(scene, from: "if state.demoMode {", to: "return items")
        for forbidden in ["state.logout(", "LoginRequest(", "state.refresh(", "resolvedTint("] {
            XCTAssertFalse(demoBlock.contains(forbidden), "demo card must not reach real account via \(forbidden)")
        }
        for token in [
            "onLogin: {}",
            "onRefresh: {}",
            "onLogout: {}",
            "isRefreshing: false",
            // 品牌默认色，不透出用户给主号 / 服务商设的自定义色
            "TintResolver.resolve(accountTint: nil, provider: provider, overrides: [:])",
        ] {
            XCTAssertTrue(demoBlock.contains(token), "demo card omitted \(token)")
        }

        let item = try source("App/Views/DashboardSceneItem.swift")
        XCTAssertTrue(item.contains("var isDemo: Bool"))
        for path in ["App/Views/DashboardFlatView.swift", "App/Views/DashboardCarouselView.swift"] {
            XCTAssertTrue(try source(path).contains("isDemo: item.isDemo"), "\(path) must pass isDemo into ProviderCardView")
        }

        let card = try source("App/Views/ProviderCardView.swift")
        XCTAssertTrue(card.contains("var isDemo: Bool = false"))
        let menu = try slice(card, from: "private var cardMenuButtons: some View", to: "private func planPriceRow(")
        let share = try XCTUnwrap(menu.range(of: "L10n.tr(\"card.share\", lang)"))
        let gate = try XCTUnwrap(menu.range(of: "if !isDemo {"), "演示卡菜单只留分享")
        XCTAssertLessThan(share.lowerBound, gate.lowerBound, "分享在演示闸门之外")
        for key in ["card.refresh", "card.relogin", "card.logout", "card.updateToken", "custom.logout"] {
            let button = try XCTUnwrap(menu.range(of: "L10n.tr(\"\(key)\", lang)"), "menu omitted \(key)")
            XCTAssertLessThan(gate.lowerBound, button.lowerBound, "\(key) must sit behind the demo gate")
        }

        // 卡内登录 / 重试按钮同样不对演示卡开放
        let content = try slice(card, from: "private var content: some View", to: "private func displayedMetrics(")
        XCTAssertTrue(content.contains("if !isCustom, !isDemo, snap.isAnonymous == true {"))
        let retry = try XCTUnwrap(content.range(of: "L10n.tr(\"card.retry\", lang)"))
        let retryGate = try XCTUnwrap(content.range(of: "if !isDemo {"))
        XCTAssertLessThan(retryGate.lowerBound, retry.lowerBound, "retry must sit behind the demo gate")
        let defaultBranch = try XCTUnwrap(content.range(of: "default:"))
        let loginGate = try XCTUnwrap(
            content.range(of: "if !isDemo {", range: defaultBranch.upperBound..<content.endIndex),
            "not-logged-in login button must sit behind the demo gate"
        )
        let login = try XCTUnwrap(content.range(of: "onLogin()", range: defaultBranch.upperBound..<content.endIndex))
        XCTAssertLessThan(loginGate.lowerBound, login.lowerBound)
    }

    /// 演示拖动排序只活在会话内：真实 providerOrder 会落盘并推到手表，不能被演示卡改写。
    func testDemoReorderStaysInSessionAndResetsWhenDemoTurnsOff() throws {
        let dashboard = try source("App/Views/DashboardView.swift")
        XCTAssertTrue(dashboard.contains("@State private var demoProviderOrder: [ProviderID]?"))

        let commit = try slice(dashboard, from: "private func commitDemoOrder(", to: "private func rollbackCarouselOrder()")
        XCTAssertFalse(commit.contains("state.setOrder"), "演示排序不得写回真实 providerOrder")
        XCTAssertTrue(commit.contains("demoProviderOrder = orderedProviders"))
        for token in [
            "orderedProviders.count == visibleDemoProviders.count",
            "Set(orderedProviders).count == orderedProviders.count",
            "Set(orderedProviders) == Set(visibleDemoProviders)",
            "rollbackCarouselOrder()",
        ] {
            XCTAssertTrue(commit.contains(token), "demo commit omitted \(token)")
        }

        let reset = try slice(dashboard, from: ".onChange(of: state.demoMode)", to: "}\n")
        XCTAssertTrue(reset.contains("demoProviderOrder = nil"), "关闭演示须清掉会话内演示排序")

        let flatMove = try slice(
            dashboard,
            from: "private func moveFlatDemoProvider(",
            to: "private func reorderAction("
        )
        XCTAssertTrue(flatMove.contains("commitDemoOrder(order)"), "平铺拖动走同一套校验")
    }

    /// 演示模式是纯橱窗：全量刷新不对首页隐藏的真实账号发探针。
    func testRefreshAllSkipsProbesInDemoMode() throws {
        let appState = try source("App/AppState.swift")
        let head = try slice(appState, from: "func refreshAll() async {", to: "if let inFlight = refreshAllTask")
        XCTAssertTrue(head.contains("guard !demoMode else { return }"), "refreshAll 须先挡住演示模式")
    }
}

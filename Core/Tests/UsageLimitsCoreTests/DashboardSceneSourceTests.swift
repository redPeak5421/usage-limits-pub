import XCTest

final class DashboardSceneSourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func slice(_ source: String, from startToken: String, to endToken: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken))
        let end = try XCTUnwrap(source.range(of: endToken, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func normalized(_ source: String) -> String {
        source.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    /// 场景配色只看外观深浅色（浅 Atelier Vault / 深 Night Reel）；布局（轮盘 / 螺旋）由首页主题偏好决定，平铺没有场景；主题文件自身不碰持久化。
    func testSceneThemeFollowsColorSchemeAndLayoutFollowsDashboardPreference() throws {
        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(theme.contains("init(colorScheme: ColorScheme)"))
        XCTAssertTrue(theme.contains("enum DashboardSceneLayout: Equatable"))
        XCTAssertTrue(theme.contains("init?(preference: DashboardTheme)"))
        let compact = normalized(theme)
        XCTAssertTrue(compact.contains("case.flat:returnnil"))
        XCTAssertTrue(compact.contains("case.roulette:self=.roulette"))
        XCTAssertTrue(compact.contains("case.helix:self=.helix"))
        XCTAssertTrue(theme.contains("case atelierVault"))
        XCTAssertTrue(theme.contains("case nightReel"))
        for hex in [
            "F2F1EE", "E7E5E0", "2C2A26", "6A6660", "8A6D45",
            "070709", "101014", "F3F4F6", "9AA0A8",
        ] {
            XCTAssertTrue(theme.contains(hex), "missing theme token \(hex)")
        }
        XCTAssertFalse(theme.contains("SharedStore"))
        XCTAssertFalse(theme.contains("UserDefaults"))
    }

    func testCardSurfaceStaysSystemNeutralWhileContentKeepsProviderTint() throws {
        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )
        let surface = try slice(theme, from: "struct DashboardCardSurface: View", to: "struct DashboardCardDim")
        XCTAssertEqual(
            surface.components(separatedBy: "shape.fill(Color(.secondarySystemGroupedBackground))").count - 1,
            1,
            "the card must keep exactly one default white / black system fill for every appearance / accessibility branch"
        )
        XCTAssertFalse(surface.contains("theme.surfaceBase"))
        XCTAssertFalse(surface.contains("theme.pageDepth"))
        for banned in [
            "DashboardCardTintLayer",
            "DashboardCardHalo",
            "DashboardCardSheen",
            "DashboardCardInnerDepth",
            "DashboardCardFineTexture",
            "DashboardCardReadability",
            "var cardBase: Color",
            "var cardForeground: Color",
            ".blendMode(.color)",
            "tint.swatchFill",
        ] {
            XCTAssertFalse(theme.contains(banned), "theme file must not keep theme-case card layers: \(banned)")
        }
        for banned in [
            "cardReadability",
            "sceneTheme.cardForeground",
            ".environment(\\.colorScheme",
            ".blendMode(.color)",
            "swatchFill",
        ] {
            XCTAssertFalse(card.contains(banned), "card content must use default system colors: \(banned)")
        }
        for contract in [
            "DashboardCardSurface(theme: sceneTheme)",
            "resolvedTint.badgeFill",
            "resolvedTint.badgeForeground",
            "resolvedTint.representativeColor",
            ".environment(\\.usageBarDecorator, edition.usageBarDecorator(tint: resolvedTint, tinted: tintedBars, shimmer: barShimmer))",
            "usageLevelColor(metric.usedPercent)",
        ] {
            XCTAssertTrue(card.contains(contract), "card must keep provider tint support: \(contract)")
        }
        XCTAssertEqual(
            card.components(separatedBy: "DashboardCardSurface(theme: sceneTheme)").count - 1,
            1,
            "the card must install exactly one neutral surface"
        )
    }

    func testSceneChromeAndMarkerNeverDrawOverTheFrontCard() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let canvas = try slice(carousel, from: "private func sceneCanvas(", to: "private var gestureIsEnabled")
        let chrome = try XCTUnwrap(canvas.range(of: "DashboardSceneChrome(theme: theme, layout: layout, tint: selectedTint)"))
        let cards = try XCTUnwrap(canvas.range(of: "sceneAccessibilityContainer("))
        XCTAssertLessThan(
            chrome.lowerBound,
            cards.lowerBound,
            "selection chrome (needle / halo / rails) must render before the card stack, never over the front card"
        )
        XCTAssertTrue(
            normalized(carousel).contains("letshowsCurrentMarker=differentiateWithoutColor&&isFront&&model.expandedID==nil")
                && normalized(carousel).contains("ifshowsCurrentMarker{DashboardCurrentCardMarker(theme:theme)}"),
            "the differentiate-without-color marker must not paint over the expanded card"
        )
        let marker = try slice(carousel, from: "private struct DashboardCurrentCardMarker", to: "private enum DashboardSceneHaptic")
        XCTAssertFalse(marker.contains("cardForeground"))
        XCTAssertFalse(marker.contains("cardBase"))
        XCTAssertTrue(marker.contains("theme.primaryForeground"))

        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )
        let chromeView = try slice(theme, from: "struct DashboardSceneChrome: View", to: "struct DashboardCardSurface: View")
        XCTAssertTrue(
            normalized(chromeView).contains("varbody:someView{iflayout==.helix{"),
            "roulette must render no scene chrome at all; helix chrome is keyed on layout, not on the palette"
        )
        XCTAssertFalse(chromeView.contains("Needle"))
    }

    func testNightHaloRemainsCompact() throws {
        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )
        let compact = normalized(theme)
        XCTAssertTrue(compact.contains("haloColor.opacity(0.14)"))
        XCTAssertTrue(
            compact.contains(
                ".frame(width:min(proxy.size.width*0.72,280),height:min(proxy.size.height*0.38,210))"
            ),
            "Night Reel must keep its tint in a compact light well over desk ink"
        )
    }
    func testSceneHasNoBottomPlateAndKeepsReferenceCardMaterial() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )
        for banned in ["scenePlate(", "DashboardScenePlate", "sceneContentMask", ".mask { scene", "dashboard.hint."] {
            XCTAssertFalse(carousel.contains(banned), "the scene must have no bottom plate, text, or mask: \(banned)")
        }
        XCTAssertEqual(
            carousel.components(separatedBy: "privacy.footer").count - 1,
            1,
            "privacy.footer survives only in the empty state"
        )
        for banned in ["DashboardScenePlate", "DashboardPlateDecoration"] {
            XCTAssertFalse(theme.contains(banned), "theme must not keep plate chrome: \(banned)")
        }
        XCTAssertTrue(
            normalized(carousel).contains("letvisualOpacity=isExpanded?1:pose.opacity"),
            "expansion must leave the other cards visible in place"
        )
        XCTAssertFalse(carousel.contains("hasExpansion"))
        // 参考主题：card border-radius 16px
        XCTAssertTrue(theme.contains("RoundedRectangle(cornerRadius: 16, style: .continuous)"))
        // 卡片圆角随布局：场景 16（参考主题）、平铺 20（原版列表）
        XCTAssertTrue(normalized(card).contains("privatevarcornerRadius:CGFloat{isFlatLayout?20:16}"))
        XCTAssertTrue(card.contains(".clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))"))
        XCTAssertTrue(card.contains(".contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))"))
        XCTAssertTrue(carousel.contains("RoundedRectangle(cornerRadius: 16, style: .continuous)"))
        for file in [theme, card, carousel] {
            XCTAssertFalse(file.contains("cornerRadius: 22"))
            XCTAssertFalse(file.contains("cornerRadius: 20"))
        }
        // 参考主题：邻卡按 brightness 曲线变暗，白卡上用墨色覆盖层实现暖调变暗，而不是发灰
        XCTAssertTrue(
            normalized(carousel).contains("letdimAmount:Double=isExpanded?0:1-pose.brightness")
                && normalized(carousel).contains("DashboardCardDim(theme:theme,amount:dimAmount)")
        )
        XCTAssertFalse(carousel.contains(".brightness(pose.brightness - 1)"))
        XCTAssertTrue(theme.contains("struct DashboardCardDim: View"))
    }

    func testExpandedCardSizesToContentAndCollapsesOnTap() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )
        let compact = normalized(carousel)
        for contract in [
            "letexpandedWidth=min(max(0,sceneSize.width-24),cardSize.width+24)",
            "letexpandedHeight=max(0,sceneSize.height-24-verticalSafeInset*2)",
            ".frame(width:frameWidth,height:isExpanded?nil:frameHeight)",
            "expandedViewportHeight:isExpanded?expandedHeight:nil",
            "ifmodel.expandedID!=nil{collapseExpandedCard()return}",
            "withAnimation(expansionAnimation){model.toggleExpansion(",
            ".animation(expansionAnimation,value:model.expandedID)",
            "privatefunccollapseExpandedCard()",
        ] {
            XCTAssertTrue(compact.contains(contract), "missing expansion contract \(contract)")
        }
        XCTAssertEqual(
            normalized(carousel).components(separatedBy: "withAnimation(expansionAnimation){model.toggleExpansion(").count - 1,
            4,
            "chevron, card tap, blank / body tap and VoiceOver toggles must share one animated transaction"
        )
        XCTAssertTrue(normalized(carousel).contains("letnativeHitTesting=isExpanded||controlsArePublished"))
        XCTAssertTrue(
            normalized(carousel).contains(".frame(maxWidth:.infinity,maxHeight:.infinity).clipped()}"),
            "the card stack must be clipped to the scene so far cards never draw over the banner / toolbar"
        )
        let cardCompact = normalized(card)
        for contract in [
            "@StateprivatevarexpandedContentHeight:CGFloat=0",
            "@StateprivatevarcollapsedHeaderHeight:CGFloat=0",
            "@StateprivatevarplanPriceRowHeight:CGFloat=0",
            "privatevarexpandedHeaderHeight:CGFloat{collapsedHeaderHeight+(showsPlanPriceRowWhenExpanded?planPriceRowHeight+6:0)}",
            ".fixedSize(horizontal:false,vertical:!isExpanded)",
            ".onGeometryChange(for:CGFloat.self)",
            ".frame(height:isExpanded?expandedScrollHeight:nil)",
            ".scrollDisabled(!expandedContentCanScroll)",
            "privatevarexpandedScrollLimit:CGFloat?",
            // 未量到内容前按折叠卡高起步，不从 0 起步（否则先缩后长，肉眼是一抽）
            "privatevarexpandedScrollHeight:CGFloat{letfloor=expandedScrollFloor??0guardexpandedContentHeight>0else{returnfloor}",
            "letheight=max(expandedContentHeight,floor)",
            ".frame(maxWidth:.infinity,maxHeight:(isExpanded||isFlatLayout)?nil:.infinity,alignment:(isExpanded||isFlatLayout)?.topLeading:.leading)",
            "@Environment(\\.accessibilityReduceMotion)privatevarreduceMotion",
            "withAnimation(expansionAnimation){expandedContentHeight=height}",
            "guard!isExpandedelse{return}collapsedHeaderHeight=height",
            "planPriceRow(plan,measuringOnly:true).fixedSize(horizontal:false,vertical:true).hidden()",
            "viewport-expandedHeaderHeight-Self.cardPadding*2-Self.headerSpacing",
            "minimum-expandedHeaderHeight-Self.cardPadding*2-Self.headerSpacing",
            ".padding(Self.cardPadding)",
            "VStack(alignment:.leading,spacing:Self.headerSpacing)",
        ] {
            XCTAssertTrue(cardCompact.contains(contract), "missing content-sized expansion contract \(contract)")
        }
        XCTAssertFalse(card.contains("withAnimation(.snappy(duration: 0.42))"), "the card must not hardcode the expansion animation and ignore Reduce Motion")
        let contentSwitch = try slice(card, from: "Group {", to: ".environment(\\.usageBarDecorator")
        // 折叠 / 展开共用同一棵内容子树：分支只按布局分，不按展开态分，指标行才能保住身份做行级动画
        XCTAssertFalse(contentSwitch.contains("if isExpanded"), "content subtree must not re-identify on expansion")
        XCTAssertTrue(
            normalized(contentSwitch).contains("ifisFlatLayout{content.frame(maxWidth:.infinity,minHeight:isExpanded?0:72,alignment:.topLeading)}else{ScrollView(.vertical){")
        )
        XCTAssertTrue(card.contains(".transition(.opacity.combined(with: .offset(y: -12)))"), "new metric rows fade in and settle downward")
        XCTAssertFalse(card.contains(".onTapGesture"))
    }

    func testNonexpandableDashboardTitleRemainsStaticAndReadable() throws {
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"),
            encoding: .utf8
        )
        let toolbar = try slice(
            dashboard,
            from: "ToolbarItem(placement: .principal)",
            to: "ToolbarItem(placement: .topBarTrailing)"
        )
        let compact = normalized(toolbar)
        XCTAssertTrue(compact.contains("ifselectedItem?.canExpand==true"))
        XCTAssertTrue(compact.contains("Button(action:toggleSelectedCard){dashboardTitleLabel}"))
        XCTAssertTrue(compact.contains("else{dashboardTitleLabel}"))
        XCTAssertFalse(
            compact.contains(".disabled(selectedItem?.canExpand!=true)"),
            "a disabled principal button dims the title in an empty or nonexpandable scene"
        )
    }

    func testEmptyDashboardAddActionUsesThemeOwnedMaterials() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let emptyState = try slice(
            carousel,
            from: "private var emptyState: some View",
            to: "private func sceneAccessibilityContainer("
        )
        let compact = normalized(emptyState)
        XCTAssertTrue(compact.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(compact.contains("Capsule()"))
        XCTAssertTrue(compact.contains("theme.metalAccent"))
        XCTAssertTrue(compact.contains("theme.primaryForeground"))
        XCTAssertFalse(
            compact.contains(".buttonStyle(.borderedProminent)"),
            "the empty CTA must not fall back to system-blue styling"
        )
    }




    func testSceneItemUsesStableAccountOrDemoIdentity() throws {
        let item = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneItem.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(item.contains("DashboardSceneItemID"))
        XCTAssertTrue(item.contains("ProviderSnapshot?"))
        XCTAssertTrue(item.contains("BrandTint"))
        XCTAssertTrue(item.contains("let canExpand: Bool"))
        XCTAssertTrue(item.contains("onRefresh"))
        XCTAssertTrue(item.contains("onLogout"))
        XCTAssertTrue(item.contains("onShare"))
        XCTAssertTrue(item.contains("let refreshGlow: Bool"))
        XCTAssertTrue(item.contains("let tintedBars: Bool"))
        XCTAssertTrue(item.contains("let barShimmer: Bool"))
    }

    func testProviderCardExpansionIsSceneControlled() throws {
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )
        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )

        for contract in [
            "let isExpanded: Bool",
            "let sceneTheme: DashboardSceneTheme?",
            "let expandedViewportHeight: CGFloat?",
            "onToggleExpanded",
            "static func canExpand(snapshot:",
            "Button(action: onToggleExpanded)",
            "ScrollView(.vertical)",
            "usesExternalVerticalScroll",
            "DashboardCardSurface(theme: sceneTheme)",
            "maxHeight: (isExpanded || isFlatLayout) ? nil : .infinity,",
            "alignment: (isExpanded || isFlatLayout) ? .topLeading : .leading",
            ".dashboardSceneControlRegion()",
        ] {
            XCTAssertTrue(card.contains(contract), "missing controlled-card contract \(contract)")
        }
        XCTAssertTrue(card.contains("Self.canExpand(snapshot: snapshot)"))
        XCTAssertTrue(card.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertFalse(card.contains("@State private var isExpanded"))
        XCTAssertFalse(card.contains("initiallyExpanded"))
        XCTAssertFalse(card.contains("globalExpand"))
        XCTAssertFalse(card.contains("expandVersion"))
        XCTAssertFalse(card.contains(".onTapGesture"))
        XCTAssertFalse(card.contains("card.contextMenu"))
        XCTAssertEqual(
            card.components(separatedBy: "DashboardCardSurface(theme: sceneTheme)").count - 1,
            1,
            "the card must install exactly one decorative surface"
        )

        XCTAssertTrue(theme.contains("struct DashboardCardSurface: View"))
        XCTAssertTrue(theme.contains("let theme: DashboardSceneTheme"))
        XCTAssertFalse(theme.contains("struct DashboardCardSurface<"))
    }

    func testProviderCardPreservesExactExpansionRuleAndFixedHeaderBoundary() throws {
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )
        let canExpand = try slice(
            card,
            from: "static func canExpand(snapshot:",
            to: "private var isCollapsible"
        )
        let expectedRule = """
        static func canExpand(snapshot: ProviderSnapshot?) -> Bool {
            guard snapshot?.status.isOK == true else { return false }
            if snapshot?.isPrepaidCard == true {
                return !(snapshot?.metrics.isEmpty ?? true)
                    || !(snapshot?.timeBreakdowns?.isEmpty ?? true)
                    || !(snapshot?.keyBreakdowns?.isEmpty ?? true)
            }
            if snapshot?.provider == .jimeng {
                return !(snapshot?.metrics.isEmpty ?? true)
                    || !(snapshot?.creditHistory?.isEmpty ?? true)
            }
            if snapshot?.provider == .openai, snapshot?.isCustom != true,
               snapshot?.openAIResetCredits != nil { return true }
            return !(snapshot?.metrics.isEmpty ?? true)
        }
        """
        XCTAssertEqual(normalized(canExpand), normalized(expectedRule))

        let body = try slice(card, from: "var body: some View {", to: "static func canExpand(snapshot:")
        let header = try XCTUnwrap(body.range(of: "headerBlock"))
        let verticalScroll = try XCTUnwrap(body.range(of: "ScrollView(.vertical)"))
        XCTAssertLessThan(header.lowerBound, verticalScroll.lowerBound, "the fixed header must precede the expanded scroll")
        let expandedScroll = try slice(body, from: "ScrollView(.vertical)", to: ".environment(\\.usageBarDecorator")
        XCTAssertFalse(expandedScroll.contains("headerBlock"), "the header must not move inside the expanded scroll")
        let expandedScrollCompact = normalized(expandedScroll)
        XCTAssertTrue(expandedScrollCompact.contains(".frame(height:isExpanded?expandedScrollHeight:nil)"))
        XCTAssertFalse(
            expandedScrollCompact.contains(".frame(maxHeight:"),
            "a maxHeight frame would stretch to the proposal and centre the scroll; only the measured height may size it"
        )
        XCTAssertTrue(expandedScroll.contains(".layoutPriority(1)"))
        XCTAssertFalse(expandedScroll.contains("- 84"))
    }

    func testSceneGestureTracksExactTouchIdentityThroughTheSupportedBridge() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneGesture.swift"),
            encoding: .utf8
        )
        for token in [
            "UIGestureRecognizerRepresentable",
            "UIKit.UIGestureRecognizerSubclass",
            "override func touchesBegan",
            "override func touchesMoved",
            "override func touchesEnded",
            "override func touchesCancelled",
            "isExcludedTarget",
            "primaryTouch",
            "secondaryTouch",
            "minimumPressDuration",
            "makeCoordinator(converter:",
            "func makeUIGestureRecognizer(context:",
            "func updateUIGestureRecognizer(_ recognizer:",
            "func handleUIGestureRecognizerAction(_ recognizer:",
            "convert(globalPoint:",
            ".named(\"dashboardScene\")",
            "RunLoop.main.add",
            "forMode: .common",
            "replacementBaseline",
            "onExcludedTouchBegan",
        ] {
            XCTAssertTrue(source.contains(token), "missing \(token)")
        }
        XCTAssertFalse(source.contains("UILongPressGestureRecognizer"))
        XCTAssertFalse(source.contains("UIPanGestureRecognizer"))
        XCTAssertFalse(source.contains("Timer.scheduledTimer"))
    }

    func testSceneGestureSourcePreservesReorderAndCancellationInvariants() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneGesture.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)
        for token in [
            "touches.contains(where:{$0===primaryTouch})",
            "touches.contains(where:{$0===secondaryTouch})",
            "touch.location(in:nil)",
            "cachedInitialReorderEligibility",
            "replacementBaseline=lastReorderDelta",
            "cancelsTouchesInView=false",
            "ifrecognizer.isEnabled!=isEnabled",
            "super.reset()",
        ] {
            XCTAssertTrue(compact.contains(token), "missing lifecycle contract \(token)")
        }
        XCTAssertFalse(compact.contains("state=.possible"))
    }
    func testReorderIgnoresInvalidSecondaryTouchesWithoutCancellingPrimaryHold() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneGesture.swift"),
            encoding: .utf8
        )
        let secondary = normalized(
            try slice(
                source,
                from: "private func beginReorderSecondary(",
                to: "private func moveTapCandidate("
            )
        )
        XCTAssertFalse(
            secondary.contains("cancelActiveInteraction()"),
            "an invalid or control-targeted second finger must not tear down the held reorder"
        )
        XCTAssertTrue(
            secondary.contains(
                "guard!isExcludedTarget(location)else{onExcludedTouchBegan()return}"
            )
        )
    }


    func testSceneDragPreservesOriginalExactTouchOriginAndIncrementalVectors() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneGesture.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)
        for token in [
            "privatevarinitialPrimaryTimestamp:TimeInterval?",
            "initialPrimaryTimestamp=touch.timestamp",
            "initialPrimaryTimestamp=nil",
            "output=.dragBegan(location:initialPrimaryPoint,timestamp:initialPrimaryTimestamp)",
            "caselet.dragBegan(location,timestamp):onEvent(.dragBegan(location:location,timestamp:timestamp))",
            "caselet.dragChanged(delta,location,timestamp):onEvent(.dragChanged(delta:delta,location:location,timestamp:timestamp))",
            "converter.velocity(in:.named(\"dashboardScene\"))",
        ] {
            XCTAssertTrue(compact.contains(token), "missing drag origin contract \(token)")
        }
        XCTAssertFalse(source.contains("converter.location(in:"))
        XCTAssertFalse(source.contains("converter.translation(in:"))
        XCTAssertFalse(source.contains("lastTranslation"))
        XCTAssertFalse(source.contains("convertedLocation"))
    }

    func testCarouselModelStopsItsFrameDriverOnDemandWithoutRetainCycles() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)

        for token in [
            "CADisplayLink",
            "funcstop()",
            "displayLink?.invalidate()",
            "deinit",
            "lastFrameTimestamp=nil",
            "link.add(to:.main,forMode:.common)",
            "lettarget=Target{[weakself]timein",
            "frameDriver.start{[weakself]timestampin",
            "min(32",
        ] {
            XCTAssertTrue(compact.contains(token), "missing display-link contract \(token)")
        }
        XCTAssertEqual(compact.components(separatedBy: "[weakself]").count - 1, 2)
        XCTAssertFalse(source.contains("TimelineView(.animation"))
    }

    func testCarouselModelUsesMillisecondPhysicsAndChangedPointSamplesOnly() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)

        for token in [
            "DashboardSceneDragSample(",
            "DashboardSceneMath.sampledVelocity(samples:samples,releaseTimestamp:timestamp)",
            "samples.count>8",
            "caselet.dragEnded(_,timestamp)",
        ] {
            XCTAssertTrue(compact.contains(token), "missing sampling contract \(token)")
        }
        XCTAssertFalse(compact.contains("dragEnded(velocity:"))
        XCTAssertFalse(compact.contains("letcutoff="))
        XCTAssertFalse(compact.contains("letelapsed="))
    }

    func testCarouselModelReordersFromAStableFullBaselineAndCommitsOneDomain() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)

        for token in [
            "ids!=orderedIDs",
            "funcupdateReorder(secondFingerDeltaY:CGFloat)",
            "previewOrder(orderedIDs)",
            "Set(preview)==Set(orderedIDs)",
            "preview.filter{$0.domain==domain}",
            "reorder.primaryEnded()",
            "reorder.cancel()",
        ] {
            XCTAssertTrue(compact.contains(token), "missing reorder contract \(token)")
        }
        XCTAssertFalse(compact.contains("previewOrder(reorderPreview"))
        XCTAssertEqual(
            compact.components(separatedBy: "reorder.primaryEnded()").count - 1,
            1
        )
    }

    func testCarouselModelCachesGeometryAndTerminatesMotionExplicitly() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)

        for token in [
            "minimumHelixSpacing(",
            "maximumHelixSpacing(",
            "effectiveHelixSpacing(",
            "abs(positionVelocity)<0.0008",
            "abs(tiltVelocity)<0.0008",
            "abs(spacingVelocity)<0.004",
            "abs(diff)<0.002",
            "returnhasActiveMotion",
        ] {
            XCTAssertTrue(compact.contains(token), "missing motion contract \(token)")
        }
        let refresh = normalized(
            try slice(
                source,
                from: "private func refreshHelixGeometryCache()",
                to: "private func refreshEffectiveSpacing()"
            )
        )
        let setTilt = normalized(
            try slice(source, from: "private func setTilt(", to: "private func setSpacing(")
        )
        let geometryUpdate = normalized(
            try slice(source, from: "func updateGeometry(", to: "func resetHelix(")
        )
        let resetHelix = try slice(source, from: "func resetHelix(", to: "func applyDefaultSpacingIfNeeded(")
        XCTAssertTrue(resetHelix.contains("setCoilGain(0)"), "双击空白须把螺旋还原为竖直（拧度 0），不是默认拧度")
        XCTAssertTrue(resetHelix.contains("clampedBaseSpacing(defaultSpacing)"), "还原时螺距回默认值")
        XCTAssertTrue(
            resetHelix.contains("helixResetAnimation = HelixResetAnimation(") && resetHelix.contains("restartFrameDriver()"),
            "还原须走逐帧缓动，不能瞬间到位（减弱动态除外）"
        )
        XCTAssertTrue(resetHelix.contains("if reduceMotion {"), "减弱动态时直接到位")
        XCTAssertTrue(source.contains("var tween = Tween(durationMilliseconds: 480)"), "还原动画 480 ms，与其它目标动画共用 Tween 时钟")
        let helixStep = try slice(source, from: "private func stepHelixReset(", to: "private func stepVelocity(")
        XCTAssertTrue(helixStep.contains("tween.advance(by: deltaMilliseconds)"), "逐帧推进走 Tween")
        XCTAssertFalse(refresh.contains("spacing="))
        XCTAssertTrue(geometryUpdate.contains("clampBaseSpacingToCachedBounds()"))
        XCTAssertFalse(setTilt.contains("spacing="))
        XCTAssertFalse(setTilt.contains("clampBaseSpacingToCachedBounds()"))
        XCTAssertFalse(setTilt.contains("setSpacing("))
    }

    func testCarouselModelKeepsSingleItemCollapsedAndMotionless() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)

        XCTAssertTrue(compact.contains("guardorderedIDs.count>1else{"))
        XCTAssertTrue(compact.contains("matchingIndices.count>=2"))
    }

    func testCarouselModelReconcileAndFocusDiscardStaleInteractionState() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)
        let focus = normalized(
            try slice(source, from: "private func installFocus(", to: "private func completePendingExpansion")
        )

        XCTAssertTrue(compact.contains("guardids!=orderedIDselse{return}"))
        XCTAssertTrue(focus.contains("clearDrag()"))
        XCTAssertTrue(focus.contains("isInteracting=false"))
    }

    func testCarouselModelHandlerOwnsOnlyDragEvents() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let handler = normalized(
            try slice(source, from: "func handle(", to: "func updateGeometry(")
        )

        XCTAssertTrue(handler.contains("caselet.dragBegan"))
        XCTAssertTrue(handler.contains("caselet.dragChanged"))
        XCTAssertTrue(handler.contains("caselet.dragEnded"))
        XCTAssertTrue(
            handler.contains(
                "case.tap,.reorderBegan,.reorderChanged,.reorderEnded,.cancelled:break"
            )
        )
        XCTAssertFalse(handler.contains("updateReorder("))
        XCTAssertFalse(handler.contains("cancelInteraction()"))
    }

    func testCarouselModelRejectsDuplicateIDsAndBoundsPositionBeforeIndexConversion() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)
        let reconcile = normalized(
            try slice(source, from: "func reconcile(", to: "func focus(")
        )

        XCTAssertTrue(reconcile.contains("guardSet(ids).count==ids.countelse{"))
        XCTAssertTrue(reconcile.contains("cancelInteraction()"))
        XCTAssertTrue(reconcile.contains("return"))
        XCTAssertTrue(compact.contains("truncatingRemainder(dividingBy:"))
        XCTAssertFalse(compact.contains("Int(position.rounded())"))
        XCTAssertFalse(compact.contains("position+="))
        XCTAssertFalse(compact.contains("dragLastLocation"))
    }

    func testCarouselModelUsesWallTimeForReferenceTargetDurations() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let compact = normalized(source)

        XCTAssertTrue(
            compact.contains("stepFocus(deltaMilliseconds:animationDeltaMilliseconds)")
        )
        XCTAssertTrue(compact.contains("lethadTargetAnimation="))
        XCTAssertTrue(compact.contains("Tween(durationMilliseconds:420)"), "聚焦动画 420 ms，走共用 Tween 时钟")
        XCTAssertTrue(compact.contains("Tween(durationMilliseconds:480)"), "螺旋还原 480 ms，同一套时钟")
    }

    func testCarouselRendersBoundedNativeWindowAndBothPoses() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("DashboardSceneMath.roulettePose"))
        XCTAssertTrue(source.contains("DashboardSceneMath.helixPose"))
        XCTAssertTrue(source.contains("rotation3DEffect"))
        XCTAssertTrue(source.contains("DashboardSceneMath.projectedCardBounds"))
        XCTAssertFalse(source.contains("onGeometryChange(for: DashboardMeasuredCardRegion"))
        XCTAssertTrue(source.contains("DashboardSceneGesture"))
        XCTAssertTrue(source.contains("stride(from: -4, through: 4, by: 1)"))
        XCTAssertTrue(source.contains("Double(virtualIndex) - model.position"))
        XCTAssertTrue(source.contains("virtualIndex == frontVirtualIndex"))
        XCTAssertTrue(source.contains("model.reorderPreview ?? model.orderedIDs"))
        XCTAssertTrue(source.contains("model.expandedID == item.id && isFront"))
        XCTAssertTrue(source.contains("updateReorder(secondFingerDeltaY:"))
        XCTAssertTrue(source.contains("measuredCardRegion"))
        XCTAssertTrue(source.contains("frame.insetBy(dx: 1, dy: 1).contains(location)"))
        XCTAssertFalse(source.contains("@State private var visibleCardRegions"))
        XCTAssertFalse(source.contains("@State private var actionableCardRegions"))
        XCTAssertFalse(source.contains(".offset(z:"))
        XCTAssertFalse(source.contains("shortestOffset(itemIndex: logicalIndex"))
        XCTAssertTrue(source.contains("53.98 / 85.6"))
        XCTAssertTrue(source.contains("maximumCollapsedCardWidth"))
        XCTAssertTrue(source.contains("privacy.footer"))
        XCTAssertTrue(source.contains("demo.banner"))
        XCTAssertFalse(source.contains("WKWebView"))
        XCTAssertTrue(source.contains("let onRefreshAll: @MainActor () -> Void"))
        XCTAssertFalse(source.contains("private var refreshButton"))
        XCTAssertFalse(source.contains("Button(action: onRefreshAll)"))
        let compact = normalized(source)
        XCTAssertTrue(source.contains("safeRoundedVirtualIndex"))
        XCTAssertTrue(
            compact.contains("letfrontVirtualIndex=Self.safeRoundedVirtualIndex(model.position)")
        )
        XCTAssertTrue(
            compact.contains(
                "returnInt(exactly:roundedPosition)??(roundedPosition.sign==.minus?Int.min:Int.max)"
            )
        )
        XCTAssertFalse(compact.contains("Int(model.position.rounded())"))
        XCTAssertTrue(source.contains("private let stableIDs: [DashboardSceneItemID]"))
        XCTAssertTrue(source.contains("private let expandableIDs: [DashboardSceneItemID]"))
        XCTAssertTrue(source.contains("private let itemDictionary: [DashboardSceneItemID: DashboardSceneItem]"))
        XCTAssertTrue(source.contains("private static let physicalSlotDeltas"))
        XCTAssertTrue(source.contains("slots.reserveCapacity"))
        XCTAssertFalse(source.contains("var candidates"))
        XCTAssertFalse(source.contains("winnerByLogicalID"))
        XCTAssertFalse(source.contains("let renderSlotIDs"))
        XCTAssertFalse(source.contains("items.first(where:"))
        XCTAssertFalse(source.contains("expandedHeight - 84"))
        XCTAssertTrue(
            compact.contains(
                "whereslots[index].id.logicalID==logicalID&&slots[index].isActionable"
            )
        )
        XCTAssertTrue(
            compact.contains(
                "ifdistance<currentDistance||(distance==currentDistance&&virtualIndex<currentVirtualIndex){slots[index].isActionable=false}else{isActionable=false}"
            )
        )
        XCTAssertFalse(source.contains("pruneCardRegions"))
        XCTAssertFalse(source.contains("updateCardRegion"))
        XCTAssertTrue(source.contains("expandedViewportHeight: isExpanded ? expandedHeight : nil"))
        XCTAssertTrue(source.contains("expandedMinimumHeight: isExpanded ? cardSize.height * CGFloat(pose.scale) : nil"), "the expansion floor must account for the front card's projection scale")
        for contract in [
            "letq=virtualIndex/count",
            "letcycle=virtualIndex%count<0?q-1:q",
            "model.updateGeometry(cardSize:cardSize,sceneSize:proxy.size)",
            "letdimAmount:Double=isExpanded?0:1-pose.brightness",
            "DashboardCardDim(theme:theme,amount:dimAmount)",
            "funcfinishReorderCommit()",
            "case.accounts:",
            "case.demoProviders:",
            "onCommitAccountOrder",
            "onCommitDemoOrder",
            "controlRegions.values.contains{$0.contains(location)}",
        ] {
            XCTAssertTrue(compact.contains(contract), "missing bounded renderer contract \(contract)")
        }
        XCTAssertEqual(
            compact.components(separatedBy: "letcommit=model.finishReorder()").count - 1,
            1
        )
        let finishCommit = try slice(
            source,
            from: "private func finishReorderCommit()",
            to: "private func clearBlankTapCandidate()"
        )
        XCTAssertFalse(finishCommit.contains("compactMap"))
        XCTAssertFalse(source.contains("TimelineView(.animation"))
    }

    func testDashboardCutoverUsesOneCanonicalSceneTraversalAndRenderer() throws {
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"),
            encoding: .utf8
        )
        let scene = try slice(
            dashboard,
            from: "private var sceneItems: [DashboardSceneItem]",
            to: "private func displayedShareItems(from items: [DashboardSceneItem])"
        )
        XCTAssertEqual(
            scene.components(separatedBy: "for account in state.visibleAccounts").count - 1,
            1,
            "visible scene order must come from one direct account traversal"
        )
        for token in [
            "state.accounts",
            "state.showsPrimaryCard(account.provider)",
            "state.showsAccount(account)",
            "DashboardSceneItemID.account",
            "DashboardSceneItemID.demo",
            "seenPrimaryProviders.insert(provider)",
            "let snapshot = state.snapshot(provider)",
            "let snapshot = state.accountSnapshots[account.id]",
            "ProviderCardView.canExpand(snapshot: snapshot)",
            "refreshGlow: refreshGlowEnabled",
            "tintedBars: tintedBarsEnabled",
            "barShimmer: barShimmerEnabled",
        ] {
            XCTAssertTrue(scene.contains(token), "missing canonical scene contract \(token)")
        }
        let recordedPrimary = try XCTUnwrap(scene.range(of: "seenPrimaryProviders.insert(provider)"))
        let primaryGate = try XCTUnwrap(scene.range(of: "state.showsPrimaryCard(account.provider)"))
        XCTAssertLessThan(
            recordedPrimary.lowerBound,
            primaryGate.lowerBound,
            "hidden primary providers must still suppress duplicate demo cards"
        )

        XCTAssertTrue(dashboard.contains("@StateObject private var carousel = DashboardCarouselModel()"))
        // 布局来自首页主题偏好，配色跟随外观深浅色；平铺时导航栏回到系统默认
        XCTAssertTrue(dashboard.contains("@Environment(\\.colorScheme) private var colorScheme"))
        XCTAssertFalse(normalized(dashboard).contains(".colorScheme(theme.colorScheme)"))
        XCTAssertTrue(normalized(dashboard).contains(".toolbarColorScheme(theme.map{$0.isDark?.dark:.light},for:.navigationBar)"))
        // 顶栏底色由渐进磨砂接管：顶边不透明、导航栏区域磨砂到透明；系统底色隐藏
        XCTAssertTrue(normalized(dashboard).contains(".dashboardTopFade(solid:theme?.pageBackground??Color(.systemGroupedBackground))"))
        XCTAssertFalse(dashboard.contains(".toolbarBackground("), "the dashboard must not paint an opaque system bar")
        let fade = try String(contentsOf: root.appendingPathComponent("App/Views/DashboardTopFade.swift"), encoding: .utf8)
        for token in [".toolbarBackground(.hidden, for: .navigationBar)", ".fill(.regularMaterial)", "proxy.safeAreaInsets.top",
                      ".ignoresSafeArea(edges: .top)", ".allowsHitTesting(false)", "scrollEdgeEffectHidden(true, for: .top)"] {
            XCTAssertTrue(fade.contains(token), "top fade omitted \(token)")
        }
        XCTAssertTrue(dashboard.contains("DashboardFlatView("))
        XCTAssertFalse(dashboard.contains("sceneTheme: nil"), "flat card chrome is DashboardFlatView's job")
        let body = try slice(
            dashboard,
            from: "var body: some View",
            to: "private var sceneItems: [DashboardSceneItem]"
        )
        for token in [
            "let items = sceneItems",
            "let sceneIDs = items.map(\\.id)",
            "let shareItems = displayedShareItems(from: items)",
            "let selectedItem",
            "let layout = DashboardSceneLayout(preference: state.dashboardTheme)",
            "let theme = layout == nil ? nil : DashboardSceneTheme(colorScheme: colorScheme)",
            "if let layout, let theme {",
            "items: items",
            "layout: layout",
            "theme: theme",
            ".onChange(of: sceneIDs)",
            "onRefreshAll: { Task { await state.refreshAll() } }",
            "onCommitAccountOrder: commitAccountOrder",
            "onCommitDemoOrder: commitDemoOrder",
        ] {
            XCTAssertTrue(body.contains(token), "body must bind and reuse canonical input \(token)")
        }
        XCTAssertEqual(body.components(separatedBy: "sceneItems").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "displayedShareItems(from:").count - 1, 1)

        let sharing = try slice(
            dashboard,
            from: "private func displayedShareItems(from items: [DashboardSceneItem])",
            to: "private var refreshGlowEnabled: Bool"
        )
        XCTAssertTrue(sharing.contains("items.compactMap"))
        XCTAssertTrue(sharing.contains("item.snapshot"))
        XCTAssertTrue(sharing.contains("ShareCardInput.accountID"))
        XCTAssertTrue(sharing.contains("ShareCardInput.demoID"))
        XCTAssertFalse(sharing.contains("sceneItems"), "share mapping must use the body-bound scene catalog")
        XCTAssertFalse(dashboard.contains("AnyView"))
        XCTAssertFalse(dashboard.contains("ForEach(state.accounts)"))
    }

    /// 平铺主题是原版列表：系统卡面、下拉刷新、整卡拖动排序（容器级中线判定）、深链滚到卡；排序只交回首页校验落盘。
    func testFlatDashboardKeepsOriginalListBehaviours() throws {
        let flat = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardFlatView.swift"),
            encoding: .utf8
        )
        for token in [
            "ScrollViewReader",
            "LazyVStack(spacing: 14)",
            ".refreshable { await onRefreshAll() }",
            "sceneTheme: nil",
            "expandedViewportHeight: nil",
            ".onTapGesture { toggleExpansion(item) }",
            ".coordinateSpace(name: \"dashboardList\")",
            "AccountListDropDelegate",
            "ProviderCardDropDelegate",
            "DragReorder.decision",
            "DragSessionItemProvider",
            "onMoveAccount(moving, target)",
            "onMoveDemoProvider(moving, provider)",
            "onMove(dragging)",
            "validateDrop(info: DropInfo) -> Bool {\n            dragging != nil",
            "proxy.scrollTo(target, anchor: .center)",
            "Color(.systemGroupedBackground)",
            "privacy.footer",
        ] {
            XCTAssertTrue(flat.contains(token), "flat dashboard omitted \(token)")
        }
        XCTAssertFalse(flat.contains("SharedStore"), "flat view must not persist order itself")
        XCTAssertFalse(flat.contains("withAnimation(.snappy"), "flat reorder must honour Reduce Motion via expansionAnimation")
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"),
            encoding: .utf8
        )
        // 相对移动交回首页，用当下的 sceneItems 重新算可见顺序再走同一套校验落盘
        for token in ["private func moveFlatAccount(_ moving: UUID, before target: UUID?)",
                      "private func moveFlatDemoProvider(_ moving: ProviderID, over target: ProviderID)",
                      "onMoveAccount: moveFlatAccount",
                      "onMoveDemoProvider: moveFlatDemoProvider"] {
            XCTAssertTrue(dashboard.contains(token), "dashboard omitted \(token)")
        }
        XCTAssertFalse(flat.contains("DashboardSceneTheme("), "flat view has no scene theme")

        let appearance = try String(
            contentsOf: root.appendingPathComponent("App/Views/AppearanceSettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(normalized(appearance).contains("selection:$state.dashboardTheme"))
        XCTAssertTrue(appearance.contains("ForEach(DashboardTheme.allCases)"))
        let appState = try String(
            contentsOf: root.appendingPathComponent("App/AppState.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appState.contains("\"--dashboard-theme\""))
        XCTAssertTrue(normalized(appState).contains("didSet{store.dashboardTheme=dashboardTheme}"))
    }

    func testDashboardCutoverValidatesCommitsAndRollsBackInvalidPreview() throws {
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"),
            encoding: .utf8
        )
        let accountCommit = try slice(
            dashboard,
            from: "private func commitAccountOrder(",
            to: "private func commitDemoOrder("
        )
        for token in [
            "orderedIDs.count == visibleAccountIDs.count",
            "Set(orderedIDs).count == orderedIDs.count",
            "Set(orderedIDs) == Set(visibleAccountIDs)",
            "accountsByID.updateValue(account, forKey: account.id) == nil",
            "guard let account = accountsByID[accountID]",
            "for index in next.indices where visibleSet.contains(next[index].id)",
            "guard replacements.indices.contains(replacementIndex)",
            "guard replacementIndex == replacements.count",
            "rollbackCarouselOrder()",
            "state.applyAccountOrder(next)",
        ] {
            XCTAssertTrue(accountCommit.contains(token), "account commit omitted \(token)")
        }
        XCTAssertFalse(accountCommit.contains("compactMap"))
        let accountCompletion = try XCTUnwrap(
            accountCommit.range(of: "guard replacementIndex == replacements.count")
        )
        let accountPersistence = try XCTUnwrap(accountCommit.range(of: "state.applyAccountOrder(next)"))
        XCTAssertLessThan(accountCompletion.lowerBound, accountPersistence.lowerBound)
        XCTAssertEqual(accountCommit.components(separatedBy: "state.applyAccountOrder").count - 1, 1)
        XCTAssertGreaterThanOrEqual(
            accountCommit.components(separatedBy: "rollbackCarouselOrder()").count - 1,
            4,
            "every account validation/resolution/replacement failure must roll preview back"
        )

        let demoCommit = try slice(
            dashboard,
            from: "private func commitDemoOrder(",
            to: "private func rollbackCarouselOrder()"
        )
        for token in [
            "orderedProviders.count == visibleDemoProviders.count",
            "Set(orderedProviders).count == orderedProviders.count",
            "Set(orderedProviders) == Set(visibleDemoProviders)",
            "for index in next.indices where visibleSet.contains(next[index])",
            "guard orderedProviders.indices.contains(replacementIndex)",
            "guard replacementIndex == orderedProviders.count",
            "rollbackCarouselOrder()",
            "state.setOrder(next)",
        ] {
            XCTAssertTrue(demoCommit.contains(token), "demo commit omitted \(token)")
        }
        XCTAssertFalse(demoCommit.contains("compactMap"))
        let demoCompletion = try XCTUnwrap(
            demoCommit.range(of: "guard replacementIndex == orderedProviders.count")
        )
        let demoPersistence = try XCTUnwrap(demoCommit.range(of: "state.setOrder(next)"))
        XCTAssertLessThan(demoCompletion.lowerBound, demoPersistence.lowerBound)
        XCTAssertEqual(demoCommit.components(separatedBy: "state.setOrder").count - 1, 1)
        XCTAssertGreaterThanOrEqual(
            demoCommit.components(separatedBy: "rollbackCarouselOrder()").count - 1,
            3,
            "every demo validation/replacement failure must roll preview back"
        )

        let rollback = try slice(
            dashboard,
            from: "private func rollbackCarouselOrder()",
            to: "private func reorderAction("
        )
        XCTAssertTrue(rollback.contains("carousel.reconcile(ids: sceneItems.map(\\.id))"))
    }

    func testDashboardCutoverOwnsRefreshExpansionAndDeepLinkCoordination() throws {
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("App/AppState.swift"),
            encoding: .utf8
        )
        let accounts = try String(
            contentsOf: root.appendingPathComponent("Core/Sources/UsageLimitsCore/Accounts.swift"),
            encoding: .utf8
        )

        for token in [
            "ToolbarItem(placement: .topBarLeading)",
            "state.refreshAll()",
            "state.isRefreshingAll",
            "carousel.selectedID",
            "carousel.toggleExpansion",
            "Task.yield()",
            "didConsumeLaunchExpansion = true",
            "carousel.collapseAndFocus(target",
            "carousel.cancelInteraction()",
            ".onChange(of: sceneIDs)",
            ".onChange(of: blocksAccountDeepLink)",
            ".onChange(of: scenePhase)",
            "autoRoutePending = true",
            "autoRoutePending = false",
        ] {
            XCTAssertTrue(dashboard.contains(token), "missing dashboard coordination contract \(token)")
        }
        let compactDashboard = normalized(dashboard)
        XCTAssertTrue(
            compactDashboard.contains(
                "case.sharePreview:beginShare(selected:displayedShareItems(from:sceneItems),isGlobal:true)"
            ),
            "auto-route share preview must invoke the canonical share helper with fresh scene items"
        )
        XCTAssertFalse(
            compactDashboard.contains(
                "case.sharePreview:beginShare(selected:displayedShareItems,isGlobal:true)"
            ),
            "auto-route must not pass the share helper function as a card array"
        )
        let onAppear = try slice(
            dashboard,
            from: ".onAppear {",
            to: ".onChange(of: state.pendingDeepLink)"
        )
        let launchCall = try XCTUnwrap(onAppear.range(of: "scheduleLaunchExpansion()"))
        let revealCall = try XCTUnwrap(onAppear.range(of: "revealPendingDeepLink()"))
        XCTAssertLessThan(launchCall.lowerBound, revealCall.lowerBound)

        let launch = try slice(
            dashboard,
            from: "private func scheduleLaunchExpansion()",
            to: "private func toggleSelectedCard()"
        )
        for token in [
            "guard state.expandCardsOnLaunch",
            "state.pendingRevealTarget",
            "let preservedTarget",
            "let items = sceneItems",
            "let ids = items.map(\\.id)",
            "ids.contains(preservedTarget)",
            "carousel.selectedID",
            "carousel.reconcile(ids: ids, preferredID: target)",
            "didConsumeLaunchExpansion = true",
            "if targetItem.canExpand",
            "for: target",
            "canExpand: true",
            "carousel.collapseAndFocus(target, reduceMotion: reduceMotion)",
        ] {
            XCTAssertTrue(launch.contains(token), "launch ordering contract omitted \(token)")
        }
        let launchGuard = try XCTUnwrap(launch.range(of: "guard state.expandCardsOnLaunch"))
        let launchTask = try XCTUnwrap(launch.range(of: "Task { @MainActor in"))
        let launchYield = try XCTUnwrap(launch.range(of: "await Task.yield()"))
        let launchReread = try XCTUnwrap(launch.range(of: "let items = sceneItems"))
        let launchReconcile = try XCTUnwrap(launch.range(of: "carousel.reconcile(ids: ids, preferredID: target)"))
        let launchConsumed = try XCTUnwrap(launch.range(of: "didConsumeLaunchExpansion = true"))
        let launchToggle = try XCTUnwrap(launch.range(of: "carousel.toggleExpansion("))
        XCTAssertLessThan(launchGuard.lowerBound, launchTask.lowerBound)
        XCTAssertLessThan(launchTask.lowerBound, launchYield.lowerBound)
        XCTAssertLessThan(launchYield.lowerBound, launchReread.lowerBound)
        XCTAssertLessThan(launchReread.lowerBound, launchReconcile.lowerBound)
        XCTAssertLessThan(launchReconcile.lowerBound, launchConsumed.lowerBound)
        XCTAssertLessThan(launchConsumed.lowerBound, launchToggle.lowerBound)
        let launchBranch = try XCTUnwrap(launch.range(of: "if targetItem.canExpand"))
        let launchFocusFallback = try XCTUnwrap(
            launch.range(of: "carousel.collapseAndFocus(target, reduceMotion: reduceMotion)")
        )
        XCTAssertLessThan(launchConsumed.lowerBound, launchBranch.lowerBound)
        XCTAssertLessThan(launchConsumed.lowerBound, launchFocusFallback.lowerBound)
        let terminalBranch = String(launch[launchBranch.lowerBound...])
        XCTAssertTrue(
            normalized(terminalBranch).contains(
                "iftargetItem.canExpand{carousel.toggleExpansion(for:target,canExpand:true,reduceMotion:reduceMotion)}else{carousel.collapseAndFocus(target,reduceMotion:reduceMotion)}"
            ),
            "non-expandable focus restoration must remain the explicit else-only alternative to expansion"
        )
        let terminalToggle = try XCTUnwrap(terminalBranch.range(of: "carousel.toggleExpansion("))
        let terminalElse = try XCTUnwrap(terminalBranch.range(of: "} else {"))
        let terminalFallback = try XCTUnwrap(terminalBranch.range(of: "carousel.collapseAndFocus(target"))
        XCTAssertLessThan(terminalToggle.lowerBound, terminalElse.lowerBound)
        XCTAssertLessThan(terminalElse.lowerBound, terminalFallback.lowerBound)

        let reveal = try slice(
            dashboard,
            from: "private func revealPendingDeepLink()",
            to: "private func scheduleLaunchExpansion()"
        )
        let revealReconcile = try XCTUnwrap(
            reveal.range(of: "carousel.reconcile(ids: ids, preferredID: target)")
        )
        let revealFocus = try XCTUnwrap(reveal.range(of: "carousel.collapseAndFocus(target"))
        let revealConsume = try XCTUnwrap(reveal.range(of: "state.pendingDeepLink = nil"))
        XCTAssertLessThan(revealReconcile.lowerBound, revealFocus.lowerBound)
        XCTAssertLessThan(revealFocus.lowerBound, revealConsume.lowerBound)
        XCTAssertFalse(dashboard.contains(".refreshable"))
        XCTAssertFalse(dashboard.contains("ScrollViewReader"))
        XCTAssertFalse(dashboard.contains("AccountListDropDelegate"))
        XCTAssertFalse(dashboard.contains("ProviderCardDropDelegate"))
        XCTAssertFalse(dashboard.contains("DragSessionItemProvider"))

        let blockers = try slice(
            dashboard,
            from: "private var blocksAccountDeepLink: Bool",
            to: "private func loginRequestFor"
        )
        for token in [
            "showSettings",
            "showNotificationSettings",
            "showProvidersSettings",
            "showWidgetPreview",
            "showEditionRoute",
            "showAppearance",
            "showAddProvider",
            "loginRequest",
            "tokenAccount",
            "pendingShare",
            "editTemplate",
            "metricOrderTarget",
            "scenePhase != .active",
            "autoRoutePending",
        ] {
            XCTAssertTrue(blockers.contains(token), "deep-link blocker omitted \(token)")
        }

        XCTAssertTrue(appState.contains("@Published private(set) var isRefreshingAll = false"))
        let refreshAll = try slice(appState, from: "func refreshAll() async", to: "func refresh(")
        XCTAssertTrue(normalized(refreshAll).contains("ifletinFlight=refreshAllTask{awaitinFlight.valuereturn}"), "re-entrant refreshAll must await the in-flight run so pull-to-refresh keeps its spinner")
        XCTAssertTrue(refreshAll.contains("isRefreshingAll = true"))
        XCTAssertTrue(refreshAll.contains("defer { isRefreshingAll = false }"))
        XCTAssertFalse(appState.contains("func moveActiveProvider"))
        XCTAssertFalse(appState.contains("func moveAccount("))
        XCTAssertFalse(accounts.contains("public enum DragReorder"))
        XCTAssertFalse(accounts.contains("id movingID"))
        XCTAssertTrue(accounts.contains("fromOffsets: IndexSet"))
    }
    func testTaskNineUsesOneStableAccessibilityOwnerAndExactFrontExpandedChildren() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let compact = normalized(carousel)
        for environment in [
            "@Environment(\\.accessibilityVoiceOverEnabled)",
            "@Environment(\\.accessibilityReduceMotion)",
            "@Environment(\\.accessibilityDifferentiateWithoutColor)",
            "@Environment(\\.usageDisplayMode)",
            "@Environment(\\.resetTimeStyle)",
        ] {
            XCTAssertTrue(carousel.contains(environment), "missing \(environment)")
        }
        XCTAssertFalse(
            carousel.contains(".environment(\\.accessibilityReduceTransparency"),
            "the read-only system accessibility environment must propagate without a write"
        )

        let container = normalized(
            try slice(
                carousel,
                from: "private func sceneAccessibilityContainer(",
                to: "private func sceneAccessibilityLabel("
            )
        )
        XCTAssertTrue(container.contains("ForEach(renderSlots)"))
        XCTAssertEqual(
            container.components(separatedBy: "DashboardSceneAccessibilityModifier(").count - 1,
            1,
            "the nonempty scene must install one stable accessibility owner outside physical slots"
        )
        XCTAssertTrue(
            compact.contains(
                "letisAccessibilityVisible=model.expandedID!=nil&&isExpanded"
            )
        )
        XCTAssertEqual(
            compact.components(separatedBy: ".accessibilityActions{").count - 1,
            1,
            "all conditional named actions live in one non-branching accessibilityActions builder"
        )
        XCTAssertFalse(
            carousel.contains("DashboardConditionalAccessibilityAction"),
            "a ViewModifier whose body branches on an optional re-identifies the whole card stack (crossfade + @State reset) when the action set changes with expansion"
        )
        XCTAssertFalse(compact.contains("iflet\(name){content."))
        XCTAssertTrue(
            compact.contains(
                "ifactiveIDs.isEmpty{emptyState}else{sceneAccessibilityContainer("
            ),
            "the empty CTA must bypass the nonempty scene accessibility wrapper"
        )
        XCTAssertTrue(
            compact.contains(
                "if!activeIDs.isEmpty{DashboardSceneChrome(theme:theme,layout:layout,tint:selectedTint)}"
            ),
            "selection chrome must not render without a selected scene item"
        )
        XCTAssertTrue(compact.contains(".gesture(DashboardSceneGesture("))
        XCTAssertTrue(compact.contains(".accessibilityHidden(!isAccessibilityVisible)"))
        XCTAssertTrue(compact.contains(".accessibilityElement(children:isExpanded?.contain:.ignore)"))
        XCTAssertTrue(compact.contains(".accessibilityLabel(Text(label))"))
        XCTAssertTrue(compact.contains(".accessibilityValue(Text(value))"))
        XCTAssertTrue(compact.contains(".accessibilityAdjustableAction"))
        XCTAssertTrue(compact.contains("case.increment:onAdjustSelection(1)"))
        XCTAssertTrue(compact.contains("case.decrement:onAdjustSelection(-1)"))
        XCTAssertTrue(compact.contains("@unknowndefault:break"))
        XCTAssertFalse(container.contains("emptyState"))

        for key in [
            "dashboard.action.expand",
            "dashboard.action.collapse",
            "dashboard.action.moveEarlier",
            "dashboard.action.moveLater",
            "dashboard.action.refreshAll",
            "dashboard.action.resetHelix",
        ] {
            XCTAssertTrue(carousel.contains(key), "missing named action \(key)")
        }
        XCTAssertTrue(compact.contains("layout==.helix"))
        XCTAssertTrue(compact.contains("selectedItem?.canExpand==true"))
        XCTAssertTrue(compact.contains("model.expandedID!=nil"))
        XCTAssertTrue(
            compact.contains(
                "letmoveEarlierActionName=model.canAccessibilityMoveSelected(by:-1)?L10n.tr(\"dashboard.action.moveEarlier\",language):nil"
            )
        )
        XCTAssertTrue(
            compact.contains(
                "letmoveLaterActionName=model.canAccessibilityMoveSelected(by:1)?L10n.tr(\"dashboard.action.moveLater\",language):nil"
            )
        )
        XCTAssertTrue(compact.contains("refreshAllActionName:L10n.tr(\"dashboard.action.refreshAll\",language)"))
        XCTAssertTrue(compact.contains("action:onRefreshAll"))
    }

    func testTaskNineAccessibilitySummaryUsesCanonicalVisibleMetricPresentation() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let summary = try slice(
            carousel,
            from: "private func sceneAccessibilityLabel(",
            to: "private func dispatchReorderCommit("
        )
        let compact = normalized(summary)

        XCTAssertTrue(compact.contains("returnitem.title"))
        XCTAssertTrue(compact.contains("L10n.tr(\"dashboard.position\",language,index+1,activeIDs.count)"))
        XCTAssertTrue(compact.contains("L10n.tr(\"dashboard.status.available\",language)"))
        XCTAssertTrue(compact.contains("snapshot.status.displayText(language)"))
        XCTAssertTrue(compact.contains("snapshot.collapsedMetric"))
        XCTAssertTrue(compact.contains("L10n.metricLabel("))
        XCTAssertTrue(compact.contains("UsagePresentation.valueText("))
        XCTAssertTrue(compact.contains("CustomUsageDisplay.presentation("))
        XCTAssertTrue(compact.contains("CustomUsageDisplay.collapsedTile("))
        XCTAssertTrue(compact.contains("mode:displayMode"))
        XCTAssertTrue(compact.contains("resetStyle:resetStyle"))
        XCTAssertFalse(compact.contains("String(describing:"))
        let collapsedMetric = normalized(
            try slice(
                summary,
                from: "private func collapsedAccessibilityMetric(",
                to: "private func makeRenderSlots("
            )
        )
        let statusGuard = try XCTUnwrap(
            collapsedMetric.range(
                of: "guardletsnapshot=item.snapshot,snapshot.status.isOKelse{return\"\"}"
            )
        )
        let sourceSwitch = try XCTUnwrap(collapsedMetric.range(of: "switchitem.source"))
        XCTAssertLessThan(
            statusGuard.lowerBound,
            sourceSwitch.lowerBound,
            "status must suppress stale builtin and custom metrics before either source branch"
        )
    }
    func testTaskNineAccessibilityMoveIsBoundedAndSharesTouchCommitDispatch() throws {
        let model = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let carouselCompact = normalized(carousel)

        let adjust = normalized(
            try slice(
                model,
                from: "func accessibilityAdjustSelection(by direction: Int)",
                to: "func canAccessibilityMoveSelected(by direction: Int)"
            )
        )
        XCTAssertTrue(adjust.contains("DashboardSceneMath.wrappedIndex"))
        XCTAssertTrue(adjust.contains("collapseAndFocus(orderedIDs[targetIndex],reduceMotion:true)"))

        let canMove = normalized(
            try slice(
                model,
                from: "func canAccessibilityMoveSelected(by direction: Int)",
                to: "func accessibilityMoveSelected(by direction: Int)"
            )
        )
        for invariant in [
            "expandedID==nil",
            "!reorder.isActive",
            "Set(orderedIDs).count==orderedIDs.count",
            "direction==(-1)||direction==1",
            "matchingIndices.count==last-first+1",
            "matchingIndices.contains(targetIndex)",
        ] {
            XCTAssertTrue(canMove.contains(invariant), "missing move invariant \(invariant)")
        }
        XCTAssertFalse(canMove.contains("!isInteracting"))
        XCTAssertFalse(canMove.contains("!hasActiveMotion"))

        let move = normalized(
            try slice(
                model,
                from: "func accessibilityMoveSelected(by direction: Int)",
                to: "func cancelInteraction()"
            )
        )
        let begin = try XCTUnwrap(move.range(of: "beginReorder(id:selectedID)"))
        let update = try XCTUnwrap(move.range(of: "updateReorder(secondFingerDeltaY:CGFloat(direction)*64)"))
        let finish = try XCTUnwrap(move.range(of: "returnfinishReorder()"))
        XCTAssertLessThan(begin.lowerBound, update.lowerBound)
        XCTAssertLessThan(update.lowerBound, finish.lowerBound)

        XCTAssertEqual(
            carouselCompact.components(separatedBy: "switchcommit.domain").count - 1,
            1,
            "touch and accessibility reorder must share one domain dispatcher"
        )
        XCTAssertTrue(carouselCompact.contains("letcommit=model.finishReorder()"))
        XCTAssertTrue(carouselCompact.contains("dispatchReorderCommit(commit)"))
        XCTAssertTrue(
            carouselCompact.contains(
                "dispatchReorderCommit(model.accessibilityMoveSelected(by:direction))"
            )
        )
        XCTAssertTrue(
            carouselCompact.contains(
                "resetHelixActionName:layout==.helix&&model.expandedID==nil?L10n.tr(\"dashboard.action.resetHelix\",language):nil"
            )
        )
    }
    func testReorderStartInterruptsMotionAndDragBeforeBeginning() throws {
        let model = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselModel.swift"),
            encoding: .utf8
        )
        let start = normalized(
            try slice(
                model,
                from: "func beginReorder(id:",
                to: "func updateReorder("
            )
        )
        XCTAssertFalse(start.contains("!isInteracting"))
        XCTAssertFalse(start.contains("!hasActiveMotion"))
        let stop = try XCTUnwrap(start.range(of: "stopMotion(clearTargets:true)"))
        let clear = try XCTUnwrap(start.range(of: "clearDrag()"))
        let begin = try XCTUnwrap(start.range(of: "reorder.begin("))
        XCTAssertLessThan(stop.lowerBound, begin.lowerBound)
        XCTAssertLessThan(clear.lowerBound, begin.lowerBound)
    }


    func testTaskNineCancelsBeforeRecognizerDisableAndRestoresVoiceOverTouchGate() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let gesture = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneGesture.swift"),
            encoding: .utf8
        )
        let carouselCompact = normalized(carousel)
        let cancellation = normalized(
            try slice(
                carousel,
                from: "private func cancelSceneInteraction()",
                to: "private func clearBlankTapCandidate()"
            )
        )
        XCTAssertTrue(cancellation.contains("clearBlankTapCandidate()"))
        XCTAssertTrue(cancellation.contains("model.cancelInteraction()"))
        XCTAssertTrue(
            carouselCompact.contains(
                "scenePhase==.active&&!voiceOverEnabled"
            )
        )
        XCTAssertTrue(
            carouselCompact.contains(
                ".onChange(of:voiceOverEnabled){_,enabledinifenabled{cancelSceneInteraction()}}"
            )
        )
        XCTAssertTrue(
            carouselCompact.contains(
                ".onChange(of:reduceMotion){_,enabledinifenabled{cancelSceneInteraction()}}"
            )
        )

        let prepare = normalized(
            try slice(
                gesture,
                from: "func prepareForDisable()",
                to: "private func beginTapCandidate("
            )
        )
        let output = try XCTUnwrap(prepare.range(of: "output=.cancelled"))
        let cancelled = try XCTUnwrap(prepare.range(of: "state=.cancelled"))
        XCTAssertLessThan(output.lowerBound, cancelled.lowerBound)
        XCTAssertEqual(prepare.components(separatedBy: "state=.cancelled").count - 1, 1)

        let update = normalized(
            try slice(
                gesture,
                from: "func updateUIGestureRecognizer(",
                to: "func handleUIGestureRecognizerAction("
            )
        )
        let prepareCall = try XCTUnwrap(update.range(of: "recognizer.prepareForDisable()"))
        let disable = try XCTUnwrap(update.range(of: "recognizer.isEnabled=isEnabled"))
        XCTAssertLessThan(prepareCall.lowerBound, disable.lowerBound)
    }

    func testExpandedCardDragContinuesSceneAndPreservesOverflowScrolling() throws {
        let carousel = try String(contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"))
        let card = try String(contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"))
        let route = normalized(try slice(carousel, from: "private func route(", to: "private func routeTap("))
        let begin = try XCTUnwrap(route.range(of: "case.dragBegan:"))
        let changed = try XCTUnwrap(route.range(of: "case.dragChanged,.dragEnded:"))
        let start = String(route[begin.upperBound..<changed.lowerBound])
        let collapse = try XCTUnwrap(start.range(of: "collapseExpandedCard()"))
        let forward = try XCTUnwrap(start.range(of: "model.handle(event,"))
        XCTAssertLessThan(collapse.lowerBound, forward.lowerBound, "同一次拖动先收起再接续位移，无需额外点击")
        XCTAssertTrue(normalized(carousel).contains("letcontrolsArePublished=isFront"), "展开时按钮仍须排除场景手势")
        let compactCard = normalized(card)
        XCTAssertTrue(compactCard.contains(".scrollDisabled(!expandedContentCanScroll)"))
        XCTAssertTrue(compactCard.contains("ifexpandedContentCanScroll{Color.clear.dashboardSceneControlRegion()}"), "长卡内部保留滚动；短卡允许拖动场景")
        XCTAssertFalse(carousel.contains("TapGesture().onEnded { collapseExpandedCard() }"), "点按只由场景路由处理，避免同一次点击收起后又展开")
    }

    func testDragThresholdCrossingDeliversInitialMovementAfterBegin() throws {
        let gesture = try String(contentsOf: root.appendingPathComponent("App/Views/DashboardSceneGesture.swift"))
        let start = normalized(try slice(gesture, from: "private func moveTapCandidate(", to: "private func moveSceneDrag("))
        XCTAssertTrue(start.contains("pendingDragChange=.dragChanged(delta:displacement,location:location,timestamp:primaryTouch.timestamp)"),
                      "一次 move 就跨过阈值的快速滑动也必须传递全部初始位移")
        let delivery = normalized(try slice(gesture, from: "func handleUIGestureRecognizerAction(", to: "final class Coordinator"))
        XCTAssertTrue(delivery.contains("whileletevent=recognizer.consumeOutput()"), "先 begin 再 change，在同一次回调中交付")
        let end = normalized(try slice(gesture, from: "private func endPrimary(", to: "private func updateVelocity("))
        let fallback = try XCTUnwrap(end.range(of: "ifdeliverUnreportedDrag(endingAt:location,timestamp:touch.timestamp){return}"))
        let tap = try XCTUnwrap(end.range(of: "output=.tap("))
        XCTAssertLessThan(fallback.lowerBound, tap.lowerBound, "没有 touchesMoved 的快速拖动必须按起终点识别，不能误当点按")
        XCTAssertTrue(end.contains("pendingDragEnd=.dragEnded(velocity:.zero,timestamp:timestamp)"))
    }

    func testTaskNineReducedEffectsAreDeterministicOpaqueAndMarkedWithoutColor() throws {
        let carousel = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardCarouselView.swift"),
            encoding: .utf8
        )
        let theme = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSceneTheme.swift"),
            encoding: .utf8
        )
        let carouselCompact = normalized(carousel)
        let themeCompact = normalized(theme)

        for token in [
            "leteffectiveRefreshGlow=item.refreshGlow&&!reduceMotion",
            "leteffectiveBarShimmer=item.barShimmer&&!reduceMotion",
            "refreshGlow:effectiveRefreshGlow",
            "tintedBars:item.tintedBars",
            "barShimmer:effectiveBarShimmer",
            "blur:reduceMotion?0:CGFloat(pose.blur)",
            ".blur(radius:blur)",
            ".animation(reduceMotion?.linear(duration:0.12):nil){contentincontent.opacity(visualOpacity)}",
            ".animation(expansionAnimation,value:model.expandedID)",
            "letshowsCurrentMarker=differentiateWithoutColor&&isFront",
            "DashboardCurrentCardMarker(theme:theme)",
        ] {
            XCTAssertTrue(carouselCompact.contains(token), "missing reduced-effects contract \(token)")
        }

        XCTAssertTrue(theme.contains("@Environment(\\.accessibilityReduceTransparency)"))
        XCTAssertTrue(themeCompact.contains("shape.fill(Color(.secondarySystemGroupedBackground))"))
        XCTAssertTrue(themeCompact.contains("if!reduceTransparency"))
        XCTAssertTrue(themeCompact.contains("reduceTransparency?theme.primaryForeground.opacity(0.7)"))
        XCTAssertTrue(theme.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(theme.contains(".accessibilityHidden(true)"))
    }


    /// 侧边键菜单：胶囊必须在玻璃效果之前声明 `contentShape(Capsule)`——液态玻璃不参与命中测试，
    /// 否则只有图标 / 文字字形能点到，点在胶囊空白处会穿到遮罩把菜单收起（真机反馈「侧边键菜单点击不生效」，DEVLOG #95）；
    /// `--open-side-key` 只弹一次的守卫在控制器。
    func testSideKeyChipsAreTappableAcrossTheCapsuleAndAutoOpenOnce() throws {
        let view = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSideKeyView.swift"),
            encoding: .utf8
        )
        let shape = try XCTUnwrap(view.range(of: ".contentShape(Capsule(style: .continuous))"), "胶囊须声明命中形状")
        let surface = try XCTUnwrap(view.range(of: ".modifier(SideKeyChipSurface("))
        XCTAssertLessThan(shape.lowerBound, surface.lowerBound, "命中形状要在玻璃效果之前声明")
        XCTAssertFalse(view.contains("didAutoOpen"), "只弹一次的守卫不在视图 @State（换主题重建会归零）")
        let controller = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardSideKeyController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("guard !didOpenForAutomation, machine.menu == nil"), "自动弹菜单由常驻控制器守卫，只弹一次")
        XCTAssertTrue(controller.contains("if effect != .selectionChanged {"), "侧边键诊断记在控制器且跳过轮换选中")
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(dashboard.contains("sideKey: effect"), "诊断只在控制器记一次，视图不重复记")
    }

}

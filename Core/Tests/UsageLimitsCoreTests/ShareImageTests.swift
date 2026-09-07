import CoreGraphics
import XCTest
@testable import UsageLimitsCore

final class ShareImageTests: XCTestCase {
    /// 明细行不得压住上一行：无条指标的标签占 16pt，明细在 20pt 处起画；
    /// 有条指标的明细上提 8pt，仍必须落在进度条下方。历史上两处都叠过。
    func testCaptionRowNeverOverlapsLabelOrBar() {
        XCTAssertGreaterThanOrEqual(
            ShareLayout.labelOnlyHeight - ShareLayout.labelHeight, 3,
            "无条指标的明细与标签之间至少留 3pt"
        )
        XCTAssertGreaterThan(
            ShareLayout.meterHeight - ShareLayout.captionLift,
            ShareLayout.barOffsetY + ShareLayout.barHeight,
            "有条指标的明细必须画在进度条下方"
        )
        XCTAssertGreaterThanOrEqual(
            ShareLayout.captionAdvance(hasBar: false),
            ShareLayout.captionTextHeight,
            "明细占位不得小于其文字高度"
        )
    }

    private func iconFromAppAsset() -> CGImage? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
        return ShareChrome.cgImage(contentsOf: url)
    }

    private func loadLogos() -> [ProviderID: CGImage] {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/Assets.xcassets")
        var logos: [ProviderID: CGImage] = [:]
        for provider in ProviderID.allCases {
            let url = catalog.appendingPathComponent("\(provider.logoAssetName).imageset/logo.png")
            if let img = ShareChrome.cgImage(contentsOf: url) { logos[provider] = img }
        }
        return logos
    }

    func testShareAppIconAssetIsTheAppIconFile() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
        let share = root.appendingPathComponent("SharedUI/Assets.xcassets/ShareAppIcon.imageset/AppIcon.png")
        let appData = try? Data(contentsOf: app)
        let shareData = try? Data(contentsOf: share)
        XCTAssertEqual(appData, shareData, "分享图品牌位必须用主屏 App 图标，不能是另一张图")
        let flow = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Share/ShareCardView.swift")
        let src = try? String(contentsOf: flow, encoding: .utf8)
        XCTAssertTrue(src?.contains("ShareAppIcon") == true)
    }

    func testComposeSingleProviderIncludesDisplayedValuesAndChrome() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let icon = iconFromAppAsset()
        let logos = loadLogos()
        let result = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh, icon: icon, logos: logos
        )
        XCTAssertEqual(result.canvasWidth, 390)
        XCTAssertGreaterThan(result.canvasHeight, ShareImageComposer.topSafeReserve)
        XCTAssertEqual(result.model.title, "Usage Limits")
        XCTAssertTrue(result.model.sections.first?.includesLogo == true)
        XCTAssertTrue(result.model.includesQR)
        XCTAssertTrue(result.model.appStoreURL.contains("apps.apple.com"))
        XCTAssertTrue(result.model.visibleTexts.contains("Usage Limits"))
        XCTAssertFalse(result.model.includesSubtitle)
        XCTAssertTrue(result.model.brandAtBottom)
        XCTAssertTrue(result.model.visibleTexts.contains("Claude"))
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("All models") && $0.contains("61") })
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("Fable") && $0.contains("44") })
    }

    func testComposeAllExpandedIncludesPrepaidAmounts() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let icon = iconFromAppAsset()
        let result = ShareImageComposer.compose(
            snapshots: snaps, expanded: true, language: .zh, icon: icon
        )
        XCTAssertEqual(result.canvasWidth, 390)
        XCTAssertGreaterThan(result.canvasHeight, ShareImageComposer.topSafeReserve)
        XCTAssertTrue(result.model.includesQR)
        XCTAssertEqual(result.model.sections.count, snaps.count)
        XCTAssertTrue(result.model.visibleTexts.contains("DeepSeek"))
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("重置余额") && $0.contains("54.48") })
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("累计消费金额") && $0.contains("95.65") })
        XCTAssertTrue(result.model.visibleTexts.contains("ChatGPT"))
    }

    func testCustomShareSectionDoesNotUsePlaceholderProviderLogo() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 12.5, pinned: true)],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            status: .ok,
            isCustom: true
        )
        let logos = loadLogos()
        XCTAssertNotNil(logos[.claude])
        let result = ShareImageComposer.compose(
            snapshots: [snap],
            titles: ["中转站"],
            expanded: true,
            language: .zh,
            logos: logos
        )
        XCTAssertEqual(result.model.sections.count, 1)
        XCTAssertTrue(result.model.sections[0].isCustom)
        XCTAssertFalse(result.model.sections[0].includesLogo)
        XCTAssertEqual(result.model.sections[0].providerName, "中转站")
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("已用") && $0.contains("12.5") })
    }

    func testCustomShareListsUsedAndBalanceWithoutPercent() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "已用", amount: 168.80205405, pinned: true),
                UsageMetric(id: "balance", label: "余额", amount: 168.8, pinned: true),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            status: .ok,
            isCustom: true
        )
        let collapsed = ShareImageComposer.model(
            snapshots: [snap], expanded: false, language: .zh, hasIcon: false, hasQR: false
        )
        XCTAssertEqual(collapsed.sections[0].meters.map(\.label), ["已用", "余额"])
        XCTAssertEqual(collapsed.sections[0].meters.map(\.valueText), ["168.80", "168.80"])
        XCTAssertTrue(collapsed.sections[0].meters.allSatisfy { $0.usedPercent == nil })
    }

    func testCustomSharePercentAndTimestampFollowSharedPresentationSettings() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reset = now.addingTimeInterval(7_200)
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(
                    id: "ratio", label: "占比", amount: 42, pinned: true,
                    displayValue: "42%", kind: CustomFieldRole.percent.rawValue
                ),
                UsageMetric(
                    id: "expiry", label: "到期", resetsAt: reset,
                    amount: reset.timeIntervalSince1970, pinned: true,
                    displayValue: "1760007200", kind: CustomFieldRole.timestamp.rawValue
                ),
            ],
            fetchedAt: now,
            status: .ok,
            isCustom: true
        )
        let used = ShareImageComposer.model(
            snapshots: [snap], expanded: true, language: .zh, hasIcon: false, hasQR: false,
            displayMode: .used, resetTimeStyle: .countdown, now: now
        )
        let remaining = ShareImageComposer.compose(
            snapshots: [snap], expanded: true, language: .en,
            displayMode: .remaining, resetTimeStyle: .absolute, now: now
        ).model

        XCTAssertEqual(used.sections[0].meters.map(\.valueText), [
            "42%", TimeFormat.reset(reset, now: now, language: .zh, style: .countdown),
        ])
        XCTAssertEqual(remaining.sections[0].meters.map(\.valueText), [
            "58%", TimeFormat.reset(reset, now: now, language: .en, style: .absolute),
        ])
        XCTAssertTrue(used.sections[0].meters.allSatisfy { $0.usedPercent == nil })
    }

    func testCustomShareFailureDoesNotKeepLeftoverMetrics() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 12.5, pinned: true)],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            status: .needsLogin,
            isCustom: true
        )
        let model = ShareImageComposer.model(
            snapshots: [snap], expanded: true, language: .en, hasIcon: false, hasQR: false
        )
        XCTAssertEqual(model.sections[0].meters.map(\.label), [L10n.tr("custom.noNumeric", .en)])
        XCTAssertFalse(model.visibleTexts.contains { $0.contains("12.5") })
    }

    func testShareIncludesTwoAccountsOfTheSameProvider() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let primaryAcc = ProviderAccount(provider: .grok, name: "xAI 主号", isPrimary: true)
        let extraAcc = ProviderAccount(provider: .grok, name: "xAI 小号")
        let primarySnap = SharedStore.demoSnapshots(now: now).first { $0.provider == .grok }!
        var extraSnap = primarySnap
        extraSnap.planName = "SuperGrok Extra"
        let tint = TintResolver.resolve(accountTint: nil, provider: .grok, overrides: [:])
        let items = [
            ShareCardInput(id: ShareCardInput.accountID(primaryAcc.id), snapshot: primarySnap, title: "xAI 主号", tint: tint),
            ShareCardInput(id: ShareCardInput.accountID(extraAcc.id), snapshot: extraSnap, title: "xAI 小号", tint: tint),
        ]
        XCTAssertNotEqual(items[0].id, items[1].id, "同供应商多账号不能用 snapshot.id（服务商 rawValue）当勾选键")

        let result = ShareImageComposer.compose(
            snapshots: items.map(\.snapshot),
            titles: items.map(\.title),
            expanded: true,
            language: .zh
        )
        XCTAssertEqual(result.model.sections.count, 2)
        XCTAssertEqual(result.model.sections.map(\.providerName), ["xAI 主号", "xAI 小号"])
        XCTAssertTrue(result.model.visibleTexts.contains("xAI 主号"))
        XCTAssertTrue(result.model.visibleTexts.contains("xAI 小号"))
        XCTAssertTrue(result.model.visibleTexts.contains("SuperGrok Extra"))
    }

    func testInfoPlistDeclaresWeChatQueryAndPhotoAdd() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: plist)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(obj as? [String: Any])
        let schemes = try XCTUnwrap(dict["LSApplicationQueriesSchemes"] as? [String])
        XCTAssertTrue(schemes.contains("weixin"))
        let usage = try XCTUnwrap(dict["NSPhotoLibraryAddUsageDescription"] as? String)
        XCTAssertFalse(usage.isEmpty)
        let appRoot = plist.deletingLastPathComponent()
        for lang in ["zh", "en", "ja", "fr", "ru"] {
            let strings = try String(
                contentsOf: appRoot.appendingPathComponent("\(lang).lproj/InfoPlist.strings"),
                encoding: .utf8
            )
            XCTAssertTrue(strings.contains("NSPhotoLibraryAddUsageDescription"), lang)
        }
    }

    func testComposeDrawsProgressBarMetersNotTextOnly() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let result = ShareImageComposer.compose(snapshots: [claude], expanded: true, language: .zh)
        XCTAssertTrue(result.model.sections.contains { $0.meters.contains { $0.usedPercent != nil } })
        let weekly = result.model.sections.first?.meters.first { $0.label == "All models" }
        XCTAssertEqual(weekly?.usedPercent, 61)
        XCTAssertEqual(weekly?.valueText, "61%")
    }

    func testHideUnusedOmitsZeroPercentMetric() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let hidden = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(hideUnusedMetrics: true)
        )
        XCTAssertFalse(hidden.model.visibleTexts.contains { $0.contains("Sonnet") })
        XCTAssertFalse(hidden.model.sections.flatMap(\.meters).contains { $0.label == "Sonnet" })
        let shown = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(hideUnusedMetrics: false)
        )
        XCTAssertTrue(shown.model.visibleTexts.contains { $0.contains("Sonnet") })
    }

    func testHideUpdateTimeOmitsStamp() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snaps = SharedStore.demoSnapshots(now: now)
        let claude = snaps.first { $0.provider == .claude }!
        let stamp = L10n.tr("card.updatedAt", .zh, TimeFormat.hourMinute(now))
        let shown = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(hideUpdateTime: false)
        )
        XCTAssertTrue(shown.model.visibleTexts.contains(stamp))
        XCTAssertNotNil(shown.model.sections.first?.updateTime)
        let hidden = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(hideUpdateTime: true)
        )
        XCTAssertFalse(hidden.model.visibleTexts.contains(stamp))
        XCTAssertNil(hidden.model.sections.first?.updateTime)
    }

    func testSameColorOptionRecordedOnResult() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let off = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(sameColorBars: false)
        )
        let on = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(hideUnusedMetrics: true, sameColorBars: true)
        )
        XCTAssertFalse(off.options.sameColorBars)
        XCTAssertTrue(on.options.sameColorBars)
        XCTAssertNotEqual(off.options, on.options)
    }

    func testShareComposeOptionsPersistRoundTrip() {
        let suite = "test.shareopts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        XCTAssertEqual(store.shareComposeOptions, ShareComposeOptions())
        let edited = ShareComposeOptions(
            hideUpdateTime: true, hideUnusedMetrics: false, sameColorBars: true, rainbowGlow: false
        )
        store.shareComposeOptions = edited
        XCTAssertEqual(store.shareComposeOptions, edited)
    }

    func testRainbowGlowDefaultsOnAndCanBeDisabled() throws {
        XCTAssertTrue(ShareComposeOptions().rainbowGlow)
        // 老版本持久化的 JSON 没有 rainbowGlow 键：解码后默认开启。
        let legacy = try JSONDecoder().decode(ShareComposeOptions.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.rainbowGlow)
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let off = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh,
            options: ShareComposeOptions(rainbowGlow: false)
        )
        XCTAssertFalse(off.options.rainbowGlow)
        let on = ShareImageComposer.compose(snapshots: [claude], expanded: true, language: .zh)
        XCTAssertTrue(on.options.rainbowGlow)
        // 光晕只改像素，不改布局：画布尺寸必须逐点相同。
        XCTAssertEqual(off.canvasWidth, on.canvasWidth)
        XCTAssertEqual(off.canvasHeight, on.canvasHeight)
    }

    func testGlobalManageLabelIsExpandWhenChipsVisible() {
        XCTAssertEqual(ShareManageLabel.l10nKey(chipsVisible: true), "share.manage.expand")
        XCTAssertEqual(ShareManageLabel.l10nKey(chipsVisible: false), "share.manage.collapse")
        XCTAssertEqual(L10n.tr(ShareManageLabel.l10nKey(chipsVisible: true), .zh), "分享展开")
        XCTAssertEqual(L10n.tr(ShareManageLabel.l10nKey(chipsVisible: false), .zh), "分享折叠")
    }

    func testSharePreviewTargetsAreEditShareAndPhotos() {
        XCTAssertEqual(ShareTarget.allCases, [.edit, .wechat, .moments, .more, .saveToPhotos])
        // 微信 / 朋友圈用注释藏起，不要 filter；case 与素材仍保留
        XCTAssertEqual(ShareTarget.visibleCases, [.edit, .more, .saveToPhotos])
        XCTAssertFalse(ShareTarget.visibleCases.contains(.wechat))
        XCTAssertFalse(ShareTarget.visibleCases.contains(.moments))
        XCTAssertEqual(ShareTarget.edit.systemImage, "square.and.pencil")
        XCTAssertEqual(ShareTarget.wechat.assetName, "LogoWeChat")
        XCTAssertEqual(ShareTarget.moments.assetName, "LogoMoments")
        XCTAssertNil(ShareTarget.edit.assetName)
        XCTAssertNil(ShareTarget.more.assetName)
        XCTAssertNil(ShareTarget.saveToPhotos.assetName)
        XCTAssertEqual(L10n.tr(ShareTarget.more.l10nKey, .zh), "分享")
        XCTAssertEqual(L10n.tr(ShareTarget.edit.l10nKey, .zh), "编辑")
    }

    func testWeChatLogoKeepsOfficialTwoBubbleAspect() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/Assets.xcassets/LogoWeChat.imageset/logo.png")
        let img = try XCTUnwrap(ShareChrome.cgImage(contentsOf: url))
        XCTAssertGreaterThan(img.width, img.height, "官方微信标是绿+白双气泡，应比正方形更宽")
        let ratio = Double(img.width) / Double(img.height)
        XCTAssertEqual(ratio, 322.0 / 266.0, accuracy: 0.08)
    }

    func testMomentsLogoIsApertureNotPieChart() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/Assets.xcassets/LogoMoments.imageset/logo.png")
        let img = try XCTUnwrap(ShareChrome.cgImage(contentsOf: url))
        let ratio = Double(img.width) / Double(img.height)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.08, "朋友圈光圈标应接近正方形")
        XCTAssertGreaterThan(img.width, 80)
        XCTAssertGreaterThan(img.height, 80)
    }


    func testSharePreviewSheetKeepsTargetsOutsideScroll() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Share/SharePreviewSheet.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("shareButton(.edit)"))
        XCTAssertTrue(src.contains("// shareButton(.wechat)"), "微信入口须注释掉，不能用 filter/opacity 隐藏")
        XCTAssertTrue(src.contains("// shareButton(.moments)"), "朋友圈入口须注释掉，打开即恢复")
        XCTAssertFalse(src.contains("ForEach(ShareTarget.visibleCases)"))
        XCTAssertTrue(src.contains("shareBar"))
        XCTAssertTrue(src.contains("ShareInstancePickerSheet"))
        XCTAssertTrue(src.contains("showInstancePicker"))
        XCTAssertTrue(src.contains("case .edit"))
        XCTAssertTrue(src.contains("share.opt.hideTime"))
        XCTAssertTrue(src.contains("share.opt.hideUnused"))
        XCTAssertTrue(src.contains("share.opt.sameColor"))
        XCTAssertTrue(src.contains("share.opt.glow"))
        XCTAssertTrue(src.contains("ShareManageLabel.l10nKey(chipsVisible:"))
        XCTAssertTrue(src.contains("optionChips"))
        XCTAssertTrue(src.contains("target.assetName"))
        XCTAssertTrue(src.contains("shareTargetGlyph"))
        // 微信 = 分享面板微信扩展（临时文件 URL 防扩展内存超限）；朋友圈 = 存相册 + 指引
        XCTAssertTrue(src.contains("ShareFlow.temporaryImageFile"))
        XCTAssertTrue(src.contains("ShareFlow.prepareForMoments"))
        XCTAssertTrue(src.contains("impactOccurred"), "分享按钮点击须立刻触感反馈，不能等异步完成")
        XCTAssertTrue(src.contains("UIImpactFeedbackGenerator"))
        XCTAssertTrue(src.contains("share.moments.guide"))
        XCTAssertTrue(src.contains("case .more"))
        // 底栏与选项悬浮在 ScrollView 之上（safeAreaInset），不随长图滚动
        let scrollRange = try XCTUnwrap(src.range(of: "ScrollView"))
        let chipsRange = try XCTUnwrap(src.range(of: "optionChips"))
        let barRange = try XCTUnwrap(src.range(of: "shareBar"))
        XCTAssertLessThan(scrollRange.lowerBound, chipsRange.lowerBound)
        XCTAssertLessThan(chipsRange.lowerBound, barRange.lowerBound)
        XCTAssertTrue(src.contains("safeAreaInset(edge: .bottom)"), "底部操作区应悬浮于滚动内容之上")
        // 底部面板用液态玻璃（iOS 26 glassEffect，老系统回退超薄材质）
        XCTAssertTrue(src.contains("glassEffect"), "底部面板应使用液态玻璃")
        XCTAssertTrue(src.contains("ultraThinMaterial"), "iOS 26 以下应有材质回退")
    }

    func testShareSelectionPickedKeepsCatalogOrder() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snaps = SharedStore.demoSnapshots(now: now)
        let grok = snaps.first { $0.provider == .grok }!
        let cursor = snaps.first { $0.provider == .cursor }!
        let tint = TintResolver.resolve(accountTint: nil, provider: .grok, overrides: [:])
        let catalog = [
            ShareCardInput(id: ShareCardInput.accountID(UUID()), snapshot: grok, title: "X1", tint: tint),
            ShareCardInput(id: ShareCardInput.accountID(UUID()), snapshot: cursor, title: "C1", tint: tint),
            ShareCardInput(id: ShareCardInput.accountID(UUID()), snapshot: grok, title: "X2", tint: tint),
        ]
        let picked = ShareCardInput.picked(from: catalog, ids: [catalog[2].id, catalog[0].id])
        XCTAssertEqual(picked.map(\.title), ["X1", "X2"], "多选须保持首页顺序，不能按 Set 乱序")
        XCTAssertFalse(picked.contains { $0.title == "C1" })
    }

    func testShareImageReservesTopSafeAreaForDynamicIsland() {
        XCTAssertEqual(ShareImageComposer.topSafeReserve, 59)
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let grok = snaps.first { $0.provider == .grok }!
        let result = ShareImageComposer.compose(
            snapshots: [grok],
            titles: ["Grok-main"],
            expanded: true,
            language: .zh,
            options: ShareComposeOptions(rainbowGlow: false)
        )
        XCTAssertEqual(result.model.topSafeReserve, 59)
        XCTAssertTrue(result.model.visibleTexts.contains("Grok-main"))
        // 顶部这 59pt 是空白：画布高度必须把它算在白卡之外，首条标题才不会被灵动岛挡住。
        XCTAssertEqual(ShareLayout.canvasHeight(of: result.model), result.canvasHeight)
        XCTAssertGreaterThan(
            result.canvasHeight,
            ShareImageComposer.topSafeReserve + ShareLayout.margin * 2 + 80
        )
    }

    func testShareTargetsCommentOutWeChatInsteadOfRuntimeHide() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Sources/UsageLimitsCore/ShareTargets.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("// .wechat"), "微信须写进注释，不能 allCases.filter")
        XCTAssertTrue(src.contains("// .moments"), "朋友圈须写进注释，不能运行时 filter")
        XCTAssertFalse(src.contains("allCases.filter"), "visibleCases 不得用 filter 隐藏入口")
    }

    /// 顶部 reserved 带里不应有不透明近黑文字。卡片阴影是低 alpha 预乘暗色，不算。

    func testBundledOrGeneratedQRMatchesStableAppStoreURL() {
        XCTAssertEqual(ShareChrome.appStoreURL.host, "apps.apple.com")
        // 按 Apple ID 直达，不走搜索：全局唯一，改名不受影响
        XCTAssertEqual(ShareChrome.appStoreURL.absoluteString, "https://apps.apple.com/app/id6808912101")
        XCTAssertEqual(ShareChrome.appStoreURL.path, "/app/id\(ShareChrome.appStoreID)")
        let qr = ShareChrome.qrImage()
        XCTAssertNotNil(qr)
        XCTAssertGreaterThan(qr?.width ?? 0, 0)
        XCTAssertGreaterThan(qr?.height ?? 0, 0)
    }

    /// 包内静态图必须与常量 URL 同步：曾经出现过 PNG 还指向旧的搜索链接。
    func testBundledQRDecodesToAppStoreURL() throws {
        #if canImport(CoreImage)
        let bundled = try XCTUnwrap(ShareChrome.bundledQRImage())
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: CIImage(cgImage: bundled))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(messages, [ShareChrome.appStoreURL.absoluteString])
        #endif
    }

    // MARK: 套餐徽章（明细开关联动）

    private func claudeDemo(
        planName: String = "Claude Max 5x",
        cycle: BillingCycle? = .monthly
    ) -> ProviderSnapshot {
        var snap = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
            .first { $0.provider == .claude }!
        snap.planName = planName
        snap.billingCycle = cycle
        return snap
    }

    /// 周期与标价只跟「明细」开关走：关着时分享图与旧版逐字一致，只有套餐名。
    func testPlanCycleAndPriceFollowDetailsOption() {
        let snap = claudeDemo()
        let off = ShareImageComposer.compose(
            snapshots: [snap], expanded: true, language: .zh,
            options: ShareComposeOptions(showMetricDetails: false)
        )
        let offSection = off.model.sections[0]
        XCTAssertEqual(offSection.planName, "Claude Max 5x")
        XCTAssertNil(offSection.planCycleTag, "明细关时不带周期")
        XCTAssertNil(offSection.planPrice, "明细关时不带标价")
        XCTAssertFalse(off.model.visibleTexts.contains("$100"))

        let on = ShareImageComposer.compose(
            snapshots: [snap], expanded: true, language: .zh,
            options: ShareComposeOptions(showMetricDetails: true)
        )
        let onSection = on.model.sections[0]
        XCTAssertEqual(onSection.planName, "Claude Max 5x")
        XCTAssertEqual(onSection.planCycleTag, "月")
        XCTAssertEqual(onSection.planPrice, "$100")
        XCTAssertTrue(on.model.visibleTexts.contains("月"))
        XCTAssertTrue(on.model.visibleTexts.contains("$100"))
    }

    /// 年付账号取年标价、周期标签跟着变成「年」；英文走 L10n 的 yr。
    func testPlanBadgesUseYearlyCycleAndPrice() {
        let yearly = claudeDemo(planName: "Claude Pro", cycle: .yearly)
        let zh = ShareImageComposer.compose(
            snapshots: [yearly], expanded: true, language: .zh,
            options: ShareComposeOptions(showMetricDetails: true)
        )
        XCTAssertEqual(zh.model.sections[0].planCycleTag, "年")
        XCTAssertEqual(zh.model.sections[0].planPrice, "$200")
        let en = ShareImageComposer.compose(
            snapshots: [yearly], expanded: true, language: .en,
            options: ShareComposeOptions(showMetricDetails: true)
        )
        XCTAssertEqual(en.model.sections[0].planCycleTag, "yr")
    }

    /// 周期字段缺失但套餐有标价：与首页同口径，按月付兜底。
    func testPlanBadgesFallBackToMonthlyTagWhenCycleMissing() {
        let noCycle = claudeDemo(cycle: nil)
        let result = ShareImageComposer.compose(
            snapshots: [noCycle], expanded: true, language: .zh,
            options: ShareComposeOptions(showMetricDetails: true)
        )
        XCTAssertEqual(result.model.sections[0].planCycleTag, "月")
        XCTAssertEqual(result.model.sections[0].planPrice, "$100")
    }

    /// 标价表里没有的套餐：明细开着也只画套餐名，不能凭空造周期徽章。
    func testPlanBadgesAbsentWithoutListPrice() {
        let free = claudeDemo(planName: "Claude Free", cycle: .monthly)
        let result = ShareImageComposer.compose(
            snapshots: [free], expanded: true, language: .zh,
            options: ShareComposeOptions(showMetricDetails: true)
        )
        XCTAssertEqual(result.model.sections[0].planName, "Claude Free")
        XCTAssertNil(result.model.sections[0].planCycleTag)
        XCTAssertNil(result.model.sections[0].planPrice)
        XCTAssertFalse(result.model.visibleTexts.contains("月"))
    }
}

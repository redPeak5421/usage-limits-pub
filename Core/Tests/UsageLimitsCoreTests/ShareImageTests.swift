import CoreGraphics
import XCTest
@testable import UsageLimitsCore

final class ShareImageTests: XCTestCase {
    func testLabelOnlyDetailRendersBelowLabelWithVisibleGap() throws {
        let snapshot = ProviderSnapshot(
            provider: .minimax,
            metrics: [UsageMetric(id: "spacing.fixture", label: "MMMMgggg",
                                  detail: "MMMMgggg", amount: 158_400)],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000), status: .ok
        )
        let result = ShareImageComposer.compose(
            snapshots: [snapshot], expanded: true, language: .en,
            options: ShareComposeOptions(hideUpdateTime: true, rainbowGlow: false,
                                         hideBrandRow: true, showMetricDetails: true)
        )
        write(result, name: "share-label-detail-spacing.png")
        XCTAssertEqual(result.model.sections[0].meters[0].detailText, "MMMMgggg")
        let image = result.image
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        let scale = image.width / 390
        // 只取首条指标左列的标签和明细，不包含标题、右侧数值及卡片圆角。
        var inkBands: [ClosedRange<Int>] = []
        for y in (129 * scale)..<(163 * scale) {
            let hasInk = ((48 * scale)..<(108 * scale)).contains { x in
                let index = y * image.bytesPerRow + x * image.bitsPerPixel / 8
                return bytes[index] < 190 && bytes[index + 1] < 190 && bytes[index + 2] < 190
            }
            guard hasInk else { continue }
            if let last = inkBands.last, last.upperBound == y - 1 {
                inkBands[inkBands.count - 1] = last.lowerBound...y
            } else {
                inkBands.append(y...y)
            }
        }
        XCTAssertEqual(inkBands.count, 2, "标签与明细必须是两条分离的文字带，不能重叠")
        if inkBands.count == 2 {
            XCTAssertGreaterThanOrEqual(inkBands[1].lowerBound - inkBands[0].upperBound - 1,
                                        3 * scale, "明细与标签至少留出 3pt 可见空白")
        }
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

    private func write(_ result: ShareResult, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SHARE_IMAGE_OUT_DIR"], !dir.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? result.pngData.write(to: url)
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
            .appendingPathComponent("App/Share/ShareFlow.swift")
        let src = try? String(contentsOf: flow, encoding: .utf8)
        XCTAssertTrue(src?.contains("ShareAppIcon") == true)
    }

    func testShareBrandIconDrawnUprightLikeHomeScreen() {
        let marker = makeTopRedBottomBlueIcon()
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let result = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh, icon: marker
        )
        XCTAssertTrue(
            brandIconIsUpright(in: result.image),
            "分享图 App 图标须与主屏同向（上红下蓝标记），不能上下颠倒"
        )
    }

    /// 位图第一行是顶：上半红、下半蓝。画布 y 向下时若未再翻转，顶会变成蓝。
    private func makeTopRedBottomBlueIcon() -> CGImage {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if y < h / 2 {
                    pixels[i] = 220; pixels[i + 1] = 40; pixels[i + 2] = 20; pixels[i + 3] = 255
                } else {
                    pixels[i] = 20; pixels[i + 1] = 60; pixels[i + 2] = 220; pixels[i + 3] = 255
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func brandIconIsUpright(in image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data as Data? else { return false }
        let w = image.width
        let h = image.height
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3, data.count >= w * h * bpp else { return false }
        // 品牌图标在卡片左下：约 56pt × 3x = 168px，x 约 48pt×3。
        let iconW = min(168, w / 4)
        let iconX = min(w - iconW - 1, 144)
        var best = (score: Int.min, y: 0)
        let y0 = h / 2
        let y1 = h - iconW - 8
        guard y1 > y0 else { return false }
        for y in stride(from: y0, through: y1, by: 6) {
            var topRed = 0, topBlue = 0, botRed = 0, botBlue = 0
            for dy in 0..<(iconW / 4) {
                for dx in stride(from: 8, to: iconW - 8, by: 4) {
                    let ti = ((y + dy) * w + iconX + dx) * bpp
                    let bi = ((y + iconW - 1 - dy) * w + iconX + dx) * bpp
                    guard ti + 2 < data.count, bi + 2 < data.count else { continue }
                    if data[ti] > data[ti + 2] { topRed += 1 } else { topBlue += 1 }
                    if data[bi] > data[bi + 2] { botRed += 1 } else { botBlue += 1 }
                }
            }
            let score = (topRed - topBlue) + (botBlue - botRed)
            if score > best.score { best = (score, y) }
        }
        return best.score > 20
    }

    func testComposeSingleProviderIncludesDisplayedValuesAndChrome() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let icon = iconFromAppAsset()
        let logos = loadLogos()
        let result = ShareImageComposer.compose(
            snapshots: [claude], expanded: true, language: .zh, icon: icon, logos: logos
        )
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)
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
        let payload = ShareImageComposer.payload(from: result)
        XCTAssertEqual(payload.pngData, result.pngData)
        XCTAssertEqual(payload.activityItems, [result.pngData])
        XCTAssertFalse(payload.pngData.isEmpty)
        write(result, name: "share-single.png")
    }

    func testComposeAllExpandedIncludesPrepaidAmounts() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let icon = iconFromAppAsset()
        let result = ShareImageComposer.compose(
            snapshots: snaps, expanded: true, language: .zh, icon: icon
        )
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)
        XCTAssertTrue(result.model.includesQR)
        XCTAssertEqual(result.model.sections.count, snaps.count)
        XCTAssertTrue(result.model.visibleTexts.contains("DeepSeek"))
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("重置余额") && $0.contains("54.48") })
        XCTAssertTrue(result.model.visibleTexts.contains { $0.contains("累计消费金额") && $0.contains("95.65") })
        XCTAssertTrue(result.model.visibleTexts.contains("ChatGPT"))
        let payload = ShareImageComposer.payload(from: result)
        XCTAssertTrue(payload.activityItems.contains(result.pngData))
        write(result, name: "share-all.png")
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
        write(result, name: "share-bars.png")
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
        write(on, name: "share-options.png")
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
        // 同尺寸下关闭光晕只影响像素，不影响布局。
        XCTAssertEqual(off.image.width, on.image.width)
        XCTAssertEqual(off.image.height, on.image.height)
        XCTAssertNotEqual(off.pngData, on.pngData)
        write(off, name: "share-noglow.png")
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
        // 3x 画布：顶部 59pt 内不得出现近黑标题像素（标题色约 gray 0.12）。
        XCTAssertTrue(
            topBandLacksDarkText(result.image, points: ShareImageComposer.topSafeReserve),
            "分享图顶部须留空，避免刘海 / 灵动岛挡住首条标题"
        )
        XCTAssertGreaterThanOrEqual(
            result.image.height,
            Int((ShareImageComposer.topSafeReserve + 80) * 3)
        )
        write(result, name: "share-safe-top.png")
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
    private func topBandLacksDarkText(_ image: CGImage, points: CGFloat) -> Bool {
        guard let data = image.dataProvider?.data as Data? else { return false }
        let w = image.width
        let bpp = image.bitsPerPixel / 8
        let bpr = max(image.bytesPerRow, w * bpp)
        let rows = min(Int(points * 3), image.height)
        guard bpp >= 3, data.count >= bpr * max(rows - 1, 0) + w * bpp else { return false }
        var dark = 0
        for y in 0..<rows {
            for x in stride(from: 0, to: w, by: 4) {
                let i = y * bpr + x * bpp
                guard i + 2 < data.count else { continue }
                let alphaOK = bpp < 4 || data[i + 3] > 200
                if alphaOK, data[i] < 50, data[i + 1] < 50, data[i + 2] < 50 { dark += 1 }
            }
        }
        return dark < 8
    }

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
}

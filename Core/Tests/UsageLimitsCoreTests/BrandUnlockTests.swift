import XCTest
@testable import UsageLimitsCore

final class BrandUnlockTests: XCTestCase {
    func testSequenceIsPhraseRepeatedTwice() {
        XCTAssertEqual(BrandUnlockCombo.phrase.count, 9)
        XCTAssertEqual(BrandUnlockCombo.sequence, BrandUnlockCombo.phrase + BrandUnlockCombo.phrase)
        XCTAssertEqual(BrandUnlockCombo.sequence.count, 18)
        XCTAssertEqual(
            BrandUnlockCombo.phrase,
            [.cookie, .cookie, .version, .shield, .shield, .version, .webkit, .webkit, .version]
        )
    }

    func testSinglePhraseDoesNotUnlock() {
        var progress = 0
        for tap in BrandUnlockCombo.phrase {
            progress = BrandUnlockCombo.advance(progress: progress, tap: tap)
        }
        XCTAssertEqual(progress, 9)
        XCTAssertFalse(BrandUnlockCombo.isComplete(progress))
    }

    func testFullSequenceUnlocksAndWrongTapResets() {
        var progress = 0
        for tap in BrandUnlockCombo.sequence {
            progress = BrandUnlockCombo.advance(progress: progress, tap: tap)
        }
        XCTAssertTrue(BrandUnlockCombo.isComplete(progress))

        progress = 0
        progress = BrandUnlockCombo.advance(progress: progress, tap: .cookie)
        progress = BrandUnlockCombo.advance(progress: progress, tap: .cookie)
        XCTAssertEqual(progress, 2)
        progress = BrandUnlockCombo.advance(progress: progress, tap: .cookie)
        XCTAssertEqual(progress, 1, "点错但 Cookie 是开头，应重计为第一次 Cookie")
        progress = BrandUnlockCombo.advance(progress: progress, tap: .version)
        XCTAssertEqual(progress, 0)
    }

    func testPrivacyCopyHasCookieAndWebKitHotspotsInEveryLanguage() {
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            let body = L10n.tr("settings.privacy.body", lang)
            XCTAssertTrue(containsHotspot(.cookie, in: body), "\(lang.rawValue) 正文需能点 Cookie")
            XCTAssertTrue(containsHotspot(.webkit, in: body), "\(lang.rawValue) 正文需能点 WebKit")
        }
    }

    func testUnlockSessionDiesOnRelaunchAndAfterThirtyMinutes() {
        XCTAssertEqual(BrandUnlockSession.visibleDuration, 30 * 60)
        XCTAssertFalse(BrandUnlockSession.isVisible(unlockedAt: nil, now: Date()), "进程重启后无解锁时刻，开关不可见")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(BrandUnlockSession.isVisible(unlockedAt: start, now: start))
        XCTAssertTrue(BrandUnlockSession.isVisible(
            unlockedAt: start, now: start.addingTimeInterval(30 * 60 - 1)
        ))
        XCTAssertFalse(BrandUnlockSession.isVisible(
            unlockedAt: start, now: start.addingTimeInterval(30 * 60)
        ))
        XCTAssertEqual(BrandUnlockSession.remainingVisible(unlockedAt: start, now: start), 30 * 60)
        XCTAssertEqual(
            BrandUnlockSession.remainingVisible(unlockedAt: start, now: start.addingTimeInterval(10 * 60)),
            20 * 60
        )
        XCTAssertEqual(
            BrandUnlockSession.remainingVisible(unlockedAt: start, now: start.addingTimeInterval(40 * 60)),
            0
        )
    }

    func testHideBrandRowDefaultsOffAndRoundTrips() {
        XCTAssertFalse(ShareComposeOptions().hideBrandRow)
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        var opts = store.shareComposeOptions
        opts.hideBrandRow = true
        store.shareComposeOptions = opts
        XCTAssertTrue(store.shareComposeOptions.hideBrandRow)
    }

    func testHidingToggleResetsShareBrandAndNextUnlockStartsOff() {
        let hidden = ShareComposeOptions(
            hideUpdateTime: true, hideUnusedMetrics: false, sameColorBars: true,
            rainbowGlow: false, hideBrandRow: true
        )
        let reset = BrandUnlockSession.shareOptionsAfterHidingToggle(hidden)
        XCTAssertFalse(reset.hideBrandRow, "开关消失后必须恢复二维码/logo")
        XCTAssertTrue(reset.hideUpdateTime)
        XCTAssertFalse(reset.hideUnusedMetrics)
        XCTAssertTrue(reset.sameColorBars)
        XCTAssertFalse(reset.rainbowGlow)
        XCTAssertFalse(BrandUnlockSession.shareOptionsAfterHidingToggle(reset).hideBrandRow)

        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.shareComposeOptions = hidden
        store.shareComposeOptions = BrandUnlockSession.shareOptionsAfterHidingToggle(
            store.shareComposeOptions
        )
        XCTAssertFalse(store.shareComposeOptions.hideBrandRow)
        let shown = ShareImageComposer.model(
            snapshots: SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
                .filter { $0.provider == .claude },
            expanded: true, language: .zh,
            hasIcon: true, hasQR: true,
            options: store.shareComposeOptions
        )
        XCTAssertTrue(shown.includesQR)
        XCTAssertTrue(shown.brandAtBottom)
        XCTAssertTrue(shown.visibleTexts.contains(L10n.tr("share.scanAppStore", .zh)))
    }

    func testHideBrandRowLegacyJSONDefaultsFalse() throws {
        let opts = try JSONDecoder().decode(ShareComposeOptions.self, from: Data("{}".utf8))
        XCTAssertFalse(opts.hideBrandRow)
    }

    func testModelHidesEntireBrandRowWhenOptionOn() {
        let snaps = SharedStore.demoSnapshots(now: Date(timeIntervalSince1970: 1_760_000_000))
        let claude = snaps.first { $0.provider == .claude }!
        let shown = ShareImageComposer.model(
            snapshots: [claude], expanded: true, language: .zh, hasIcon: true, hasQR: true
        )
        let hidden = ShareImageComposer.model(
            snapshots: [claude], expanded: true, language: .zh,
            hasIcon: true, hasQR: true,
            options: ShareComposeOptions(hideBrandRow: true)
        )
        XCTAssertTrue(shown.includesQR)
        XCTAssertTrue(shown.brandAtBottom)
        XCTAssertTrue(shown.visibleTexts.contains(L10n.tr("share.scanAppStore", .zh)))
        XCTAssertFalse(hidden.includesQR)
        XCTAssertFalse(hidden.brandAtBottom)
        XCTAssertFalse(hidden.visibleTexts.contains(L10n.tr("share.scanAppStore", .zh)))
        XCTAssertLessThan(ShareLayout.canvasHeight(of: hidden), ShareLayout.canvasHeight(of: shown))
        XCTAssertEqual(L10n.tr("settings.share.hideBrand", .zh), "隐藏分享二维码")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertNotEqual(L10n.tr("settings.share.hideBrand", lang), "settings.share.hideBrand")
        }
    }

    func testSettingsHidesToggleUntilUnlockedAndSilentTaps() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/SettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("if state.shareBrandUnlocked"), "解锁前完全看不到开关")
        XCTAssertTrue(src.contains("hideBrandRow"))
        XCTAssertTrue(src.contains("BrandUnlockCombo.advance"))
        XCTAssertTrue(src.contains("unlockShareBrand"))
        XCTAssertTrue(src.contains("expireShareBrandUnlockIfNeeded"))
        XCTAssertTrue(src.contains("SilentHotspotText"))
        XCTAssertTrue(src.contains("SilentTapCatcher"))
        XCTAssertTrue(src.contains("lock.shield"))
        XCTAssertTrue(src.contains("UnlockTracker"), "进度不得进 @State Int，避免每点刷新界面")
        XCTAssertFalse(src.contains("impactOccurred"), "组合键点击不得有触感")
        XCTAssertFalse(src.contains("UIImpactFeedbackGenerator"), "组合键点击不得有触感")
        XCTAssertFalse(src.contains("sensoryFeedback"), "组合键点击不得有触感")
        XCTAssertFalse(src.contains("withAnimation"), "组合键点击不得有动画")
        XCTAssertTrue(src.contains("disablesAnimations"))
        XCTAssertTrue(src.contains(".animation(nil, value: state.shareBrandUnlocked)"))
        XCTAssertFalse(src.contains(".onTapGesture"), "SwiftUI onTapGesture 会让 Form 行闪高亮")

        let appDir = url.deletingLastPathComponent().deletingLastPathComponent()
        let appSrc = try String(contentsOf: appDir.appendingPathComponent("AppState.swift"), encoding: .utf8)
        XCTAssertFalse(appSrc.contains("store.shareBrandUnlocked"), "解锁不得落盘，重启后开关必须消失")
        XCTAssertTrue(appSrc.contains("BrandUnlockSession"))
        XCTAssertTrue(appSrc.contains("unlockShareBrand"))
        XCTAssertTrue(appSrc.contains("expireShareBrandUnlockIfNeeded"))
        XCTAssertTrue(appSrc.contains("restoreShareBrandVisibility"), "开关消失须重置分享隐藏状态")
        XCTAssertTrue(appSrc.contains("shareOptionsAfterHidingToggle"))
        XCTAssertTrue(
            appSrc.contains("restoreShareBrandVisibility()"),
            "启动、收回开关、再次解锁都要恢复默认关闭"
        )

        let appMain = try String(
            contentsOf: appDir.appendingPathComponent("UsageLimitsApp.swift"), encoding: .utf8
        )
        XCTAssertTrue(appMain.contains("expireShareBrandUnlockIfNeeded"), "回到前台要用墙上时钟收回超时开关")
    }

    private func containsHotspot(_ tap: BrandUnlockTap, in text: String) -> Bool {
        let ns = text as NSString
        for i in 0..<ns.length {
            if BrandUnlockCombo.hotspot(in: text, utf16Index: i) == tap { return true }
        }
        return false
    }

    private func makeStore() -> (SharedStore, () -> Void) {
        let suite = "test.brandunlock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SharedStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }
}

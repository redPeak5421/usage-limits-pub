import XCTest
@testable import UsageLimitsCore

/// 登录页顶部加载条：宽度只跟 estimatedProgress 走，满格后延迟归零，中途开新导航不能被归零打断。
final class LoginLoadProgressTests: XCTestCase {
    func testStartsHidden() {
        let progress = LoginLoadProgress()
        XCTAssertEqual(progress.phase, .idle)
        XCTAssertEqual(progress.value, 0)
        XCTAssertFalse(progress.isVisible, "没开始加载不画条")
    }

    func testZeroProgressShowsStartingSliver() {
        var progress = LoginLoadProgress()
        XCTAssertFalse(progress.apply(0))
        XCTAssertEqual(progress.phase, .loading)
        XCTAssertTrue(progress.isVisible, "WebKit 起步仍是 0 时也要有反馈")
        XCTAssertEqual(progress.value, LoginLoadProgress.minimumWidth)
    }

    func testTracksIntermediateProgress() {
        var progress = LoginLoadProgress()
        XCTAssertFalse(progress.apply(0.42))
        XCTAssertEqual(progress.value, 0.42)
        XCTAssertEqual(progress.phase, .loading)
    }

    func testFullProgressSchedulesHideOnlyOnce() {
        var progress = LoginLoadProgress()
        progress.apply(0.6)
        XCTAssertTrue(progress.apply(1), "首次满格要安排淡出")
        XCTAssertEqual(progress.phase, .finishing)
        XCTAssertEqual(progress.value, 1)
        XCTAssertTrue(progress.isVisible, "淡出前仍然可见")
        XCTAssertFalse(progress.apply(1), "重复满格不再排第二个淡出计时")
    }

    func testSettleClearsAfterFinish() {
        var progress = LoginLoadProgress()
        progress.apply(1)
        progress.settle()
        XCTAssertEqual(progress.phase, .idle)
        XCTAssertEqual(progress.value, 0)
        XCTAssertFalse(progress.isVisible)
    }

    func testSettleIgnoredWhileLoading() {
        var progress = LoginLoadProgress()
        progress.apply(1)
        progress.apply(0.1)
        progress.settle()
        XCTAssertEqual(progress.phase, .loading, "上一页的淡出计时不得清掉新导航的进度")
        XCTAssertTrue(progress.isVisible)
        XCTAssertEqual(progress.value, 0.1)
    }

    func testClampsOutOfRangeAndNonFinite() {
        var progress = LoginLoadProgress()
        progress.apply(-1)
        XCTAssertEqual(progress.value, LoginLoadProgress.minimumWidth)
        progress.apply(2)
        XCTAssertEqual(progress.value, 1)
        XCTAssertEqual(progress.phase, .finishing)
        progress.apply(.nan)
        XCTAssertEqual(progress.value, LoginLoadProgress.minimumWidth, "非有限值按 0 处理，不把 NaN 画进宽度")
    }

    func testHideDelayIsShortEnoughToNotLinger() {
        XCTAssertGreaterThan(LoginLoadProgress.hideDelay, .zero)
        XCTAssertLessThanOrEqual(LoginLoadProgress.hideDelay, .milliseconds(400))
    }
}

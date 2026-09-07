import XCTest
@testable import UsageLimitsCore

final class WatchConnectivityPolicyTests: XCTestCase {
    func testPushRequiresPairedWatchWithAppInstalled() {
        XCTAssertTrue(
            WatchConnectivityPolicy.canPushApplicationContext(
                sessionSupported: true,
                sessionActivated: true,
                watchPaired: true,
                watchAppInstalled: true
            )
        )
        XCTAssertFalse(
            WatchConnectivityPolicy.canPushApplicationContext(
                sessionSupported: true,
                sessionActivated: true,
                watchPaired: true,
                watchAppInstalled: false
            ),
            "没装手表 App 还推送会刷屏 WatchAppNotInstalled"
        )
        XCTAssertFalse(
            WatchConnectivityPolicy.canPushApplicationContext(
                sessionSupported: true,
                sessionActivated: true,
                watchPaired: false,
                watchAppInstalled: false
            )
        )
        XCTAssertFalse(
            WatchConnectivityPolicy.canPushApplicationContext(
                sessionSupported: true,
                sessionActivated: false,
                watchPaired: true,
                watchAppInstalled: true
            )
        )
    }
}

import XCTest
@testable import UsageLimitsCore

final class DashboardScrollAnchorTests: XCTestCase {
    private let a = DashboardSceneItemID.account(UUID())
    private let b = DashboardSceneItemID.account(UUID())
    private let demo = DashboardSceneItemID.demo(.claude)

    // MARK: - 位置判定

    func testCardBelowViewportTop() {
        XCTAssertEqual(DashboardScrollAnchor.position(minY: 120, maxY: 320), .below)
    }

    func testCardStraddlingViewportTop() {
        XCTAssertEqual(DashboardScrollAnchor.position(minY: -40, maxY: 160), .straddlingTop)
    }

    func testCardExactlyAtViewportTopStraddles() {
        // 顶边正好对齐：仍算当前在读的那张，不能判成已滚过。
        XCTAssertEqual(DashboardScrollAnchor.position(minY: 0, maxY: 200), .straddlingTop)
    }

    func testCardFullyAboveViewportTop() {
        XCTAssertEqual(DashboardScrollAnchor.position(minY: -260, maxY: -60), .above)
    }

    func testCardEndingExactlyAtViewportTopIsAbove() {
        XCTAssertEqual(DashboardScrollAnchor.position(minY: -200, maxY: 0), .above)
    }

    // MARK: - 锚点更新

    func testStraddlingCardBecomesAnchor() {
        XCTAssertEqual(
            DashboardScrollAnchor.updated(anchor: nil, card: a, position: .straddlingTop, isFirstItem: false),
            a
        )
    }

    /// 多列时同一行两张卡都压住顶边，后上报的接管；同一行落点一样。
    func testLaterStraddlingCardInSameRowTakesOver() {
        let first = DashboardScrollAnchor.updated(anchor: nil, card: a, position: .straddlingTop, isFirstItem: false)
        XCTAssertEqual(
            DashboardScrollAnchor.updated(anchor: first, card: b, position: .straddlingTop, isFirstItem: false),
            b
        )
    }

    func testFirstItemBackInViewClearsAnchor() {
        XCTAssertNil(
            DashboardScrollAnchor.updated(anchor: b, card: a, position: .below, isFirstItem: true)
        )
    }

    func testNonFirstItemBelowKeepsAnchor() {
        XCTAssertEqual(
            DashboardScrollAnchor.updated(anchor: a, card: b, position: .below, isFirstItem: false),
            a
        )
    }

    func testCardScrolledAboveKeepsAnchor() {
        XCTAssertEqual(
            DashboardScrollAnchor.updated(anchor: b, card: a, position: .above, isFirstItem: false),
            b
        )
    }

    /// 首张卡滚过顶边不清锚点：只有它重新回到顶边下方才代表列表回到了最顶。
    func testFirstItemScrolledAboveKeepsAnchor() {
        XCTAssertEqual(
            DashboardScrollAnchor.updated(anchor: b, card: a, position: .above, isFirstItem: true),
            b
        )
    }

    func testDemoCardCanBeAnchor() {
        XCTAssertEqual(
            DashboardScrollAnchor.updated(anchor: nil, card: demo, position: .straddlingTop, isFirstItem: false),
            demo
        )
    }
}

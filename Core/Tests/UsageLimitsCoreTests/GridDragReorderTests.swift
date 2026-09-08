import XCTest
@testable import UsageLimitsCore

/// 平铺首页多列拖动排序的判定回归。坐标全部显式给值，模拟 `LazyVGrid` 的实际排布：
/// 两列 = 卡宽 360、列间距 14（x 0 / 374）；三列 = 卡宽 236、列间距 14（x 0 / 250 / 500）；
/// 行高 200、行间距 14（y 0 / 214 / 428）。
final class GridDragReorderTests: XCTestCase {
    // MARK: - 计划中的复现用例

    func testTwoColumnsCanMoveFirstCardAfterItsRowNeighbour() {
        let a = UUID(), b = UUID()
        let cards = [
            GridDragReorder.Card(id: a, x: 0, y: 0, width: 360, height: 200),
            GridDragReorder.Card(id: b, x: 374, y: 0, width: 360, height: 200),
        ]
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: cards, dragging: a
        ), .toEnd)
    }

    func testTwoColumnsCanMoveSecondCardBeforeItsRowNeighbour() {
        let a = UUID(), b = UUID()
        let cards = [
            GridDragReorder.Card(id: a, x: 0, y: 0, width: 360, height: 200),
            GridDragReorder.Card(id: b, x: 374, y: 0, width: 360, height: 200),
        ]
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 20, pointerY: 100, cards: cards, dragging: b
        ), .before(a))
    }

    // MARK: - 2×2 网格

    func testTwoByTwoDropOnRowNeighbourRightHalfInsertsBeforeNextRow() {
        let ids = Self.ids(4)
        let cards = Self.twoColumnGrid(ids)
        // A 拖到 B 的右半区：读序上应插到 B 之后，也就是下一行行首 C 的前面。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: cards, dragging: ids[0]
        ), .before(ids[2]))
    }

    func testTwoByTwoDropInGutterUsesNearestCard() {
        let ids = Self.ids(4)
        let cards = Self.twoColumnGrid(ids)
        // 第二行两卡之间的缝隙、偏 C 一侧：参考卡取 C，落在它右半区 → 插到 D 前面。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 330, pointerY: 314, cards: cards, dragging: ids[0]
        ), .before(ids[3]))
    }

    func testTwoByTwoDropBelowEverythingGoesToEnd() {
        let ids = Self.ids(4)
        let cards = Self.twoColumnGrid(ids)
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 554, pointerY: 500, cards: cards, dragging: ids[0]
        ), .toEnd)
    }

    // MARK: - 单列 regular（iPad mini 竖屏 / 窄分屏）

    func testSingleColumnNeedsToCrossMidlineBeforeMovingDown() {
        let ids = Self.ids(3)
        let cards = Self.singleColumn(ids)
        // B 的纵向中线在 314：只到 300 还不够。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 350, pointerY: 300, cards: cards, dragging: ids[0]
        ), .none)
        // 穿过中线后才后移一格。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 350, pointerY: 330, cards: cards, dragging: ids[0]
        ), .before(ids[2]))
    }

    func testSingleColumnMidlineBandHoldsStill() {
        let ids = Self.ids(3)
        let cards = Self.singleColumn(ids)
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 350, pointerY: 316, cards: cards, dragging: ids[0]
        ), .none)
    }

    /// 同列的两张卡即使上下紧贴（间距为 0），也不能当成同一行去比左右半。
    func testTouchingCardsInSameColumnStayVertical() {
        let a = UUID(), b = UUID()
        let cards = [
            GridDragReorder.Card(id: a, x: 0, y: 0, width: 360, height: 200),
            GridDragReorder.Card(id: b, x: 0, y: 200, width: 360, height: 200),
        ]
        // 指针在 B 的右半、但在 B 的中线之上：按行判会后移，按列判应当不动。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 340, pointerY: 250, cards: cards, dragging: a
        ), .none)
    }

    // MARK: - 三列

    func testThreeColumnsInsertBeforeFirstColumn() {
        let ids = Self.ids(7)
        let cards = Self.threeColumnGrid(ids)
        // E（第二行中列）拖到首行首列 A 的左半区。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 20, pointerY: 100, cards: cards, dragging: ids[4]
        ), .before(ids[0]))
    }

    func testThreeColumnsInsertAfterMiddleColumn() {
        let ids = Self.ids(7)
        let cards = Self.threeColumnGrid(ids)
        // A 拖到 B（中列）右半区 → 插到 C 前面。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 420, pointerY: 100, cards: cards, dragging: ids[0]
        ), .before(ids[2]))
    }

    func testThreeColumnsInsertAfterLastColumnCrossesRow() {
        let ids = Self.ids(7)
        let cards = Self.threeColumnGrid(ids)
        // A 拖到 C（末列）右半区 → 跨到第二行行首 D 的前面。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 700, pointerY: 100, cards: cards, dragging: ids[0]
        ), .before(ids[3]))
    }

    /// 末行只剩一张卡：这一行没有同行邻居，左右半没有意义，退回上下中线判定。
    func testLoneCardInLastRowUsesVerticalMidline() {
        let ids = Self.ids(7)
        let cards = Self.threeColumnGrid(ids)
        let lone = ids[6]
        // 落在它左半但中线之上 → 插到它前面。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 20, pointerY: 500, cards: cards, dragging: ids[0]
        ), .before(lone))
        // 落在它左半但中线之下 → 移到末尾（若按左右半判会误判成插到它前面）。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 20, pointerY: 560, cards: cards, dragging: ids[0]
        ), .toEnd)
        // 贴着中线不动。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 20, pointerY: 528, cards: cards, dragging: ids[0]
        ), .none)
    }

    // MARK: - 展开高度不同 / 滞回带

    func testExpandedNeighbourStillCountsAsSameRow() {
        let a = UUID(), b = UUID()
        // A 展开到 420 高，B 仍是 200 高：纵向区间仍有重叠，属于同一行。
        let cards = [
            GridDragReorder.Card(id: a, x: 0, y: 0, width: 360, height: 420),
            GridDragReorder.Card(id: b, x: 374, y: 0, width: 360, height: 200),
        ]
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: cards, dragging: a
        ), .toEnd)
        // 反向：B 拖到 A 的左半区（y 落在 A 展开后的下半段）。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 60, pointerY: 300, cards: cards, dragging: b
        ), .before(a))
        // B 拖到 A 的右半区：读序上就是原位，不动。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 300, pointerY: 300, cards: cards, dragging: b
        ), .none)
    }

    func testHorizontalMidlineBandHoldsStill() {
        let a = UUID(), b = UUID()
        let cards = [
            GridDragReorder.Card(id: a, x: 0, y: 0, width: 360, height: 200),
            GridDragReorder.Card(id: b, x: 374, y: 0, width: 360, height: 200),
        ]
        // B 的横向中线在 554，滞回带 ±8。
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 554, pointerY: 100, cards: cards, dragging: a
        ), .none)
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 560, pointerY: 100, cards: cards, dragging: a
        ), .none)
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 564, pointerY: 100, cards: cards, dragging: a
        ), .toEnd)
    }

    // MARK: - 退化输入

    func testEmptyCardsReturnNone() {
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 100, pointerY: 100, cards: [], dragging: UUID()
        ), .none)
    }

    func testMissingDraggedCardReturnsNone() {
        let b = UUID()
        let cards = [GridDragReorder.Card(id: b, x: 0, y: 0, width: 360, height: 200)]
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 100, pointerY: 100, cards: cards, dragging: UUID()
        ), .none)
    }

    func testSingleCardReturnsNone() {
        let a = UUID()
        let cards = [GridDragReorder.Card(id: a, x: 0, y: 0, width: 360, height: 200)]
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 900, pointerY: 900, cards: cards, dragging: a
        ), .none)
    }

    // MARK: - 重放稳定性

    func testReplayingSamePointerAfterRelayoutDoesNotKeepSwapping() {
        let ids = Self.ids(2)
        let cards = Self.twoColumnRow(ids)
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: cards, dragging: ids[0]
        ), .toEnd)
        // 应用 .toEnd 后顺序变成 [B, A]，布局跟着换位；同一指针不该再动。
        let relaid = Self.twoColumnRow([ids[1], ids[0]])
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: relaid, dragging: ids[0]
        ), .none)
    }

    func testReplayingSamePointerInGridSettlesAfterOneMove() {
        let ids = Self.ids(4)
        let cards = Self.twoColumnGrid(ids)
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: cards, dragging: ids[0]
        ), .before(ids[2]))
        // 应用后顺序 [B, A, C, D]，A 落到了指针底下：重放同一指针必须 .none，
        // 否则参考卡会退化成斜对角的 D，顺序继续往后滑。
        let relaid = Self.twoColumnGrid([ids[1], ids[0], ids[2], ids[3]])
        XCTAssertEqual(GridDragReorder.decision(
            pointerX: 714, pointerY: 100, cards: relaid, dragging: ids[0]
        ), .none)
    }

    // MARK: - 布局夹具

    private static func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    /// 两列一行。
    private static func twoColumnRow(_ ids: [UUID]) -> [GridDragReorder.Card] {
        ids.enumerated().map { index, id in
            GridDragReorder.Card(id: id, x: Double(index % 2) * 374, y: 0, width: 360, height: 200)
        }
    }

    /// 两列多行。
    private static func twoColumnGrid(_ ids: [UUID]) -> [GridDragReorder.Card] {
        ids.enumerated().map { index, id in
            GridDragReorder.Card(
                id: id,
                x: Double(index % 2) * 374,
                y: Double(index / 2) * 214,
                width: 360,
                height: 200
            )
        }
    }

    /// 三列多行；7 张卡时末行只剩一张。
    private static func threeColumnGrid(_ ids: [UUID]) -> [GridDragReorder.Card] {
        ids.enumerated().map { index, id in
            GridDragReorder.Card(
                id: id,
                x: Double(index % 3) * 250,
                y: Double(index / 3) * 214,
                width: 236,
                height: 200
            )
        }
    }

    /// 单列（regular 宽度也可能只排得下一列）。
    private static func singleColumn(_ ids: [UUID]) -> [GridDragReorder.Card] {
        ids.enumerated().map { index, id in
            GridDragReorder.Card(id: id, x: 0, y: Double(index) * 214, width: 700, height: 200)
        }
    }
}

import Foundation
import XCTest
@testable import UsageLimitsCore

final class DashboardReorderTests: XCTestCase {
    func testSecondFingerMovesPreviewButPrimaryCommitsExactlyOnce() {
        let ids: [DashboardSceneItemID] = [
            .account(UUID()), .account(UUID()), .account(UUID()), .account(UUID())
        ]
        var state = DashboardReorderState()

        state.begin(sourceIndex: 1, domain: 0..<4)
        XCTAssertEqual(state.update(secondFingerDeltaY: 130, pointsPerSlot: 64), 3)
        XCTAssertEqual(state.previewOrder(ids), [ids[0], ids[2], ids[3], ids[1]])

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.sourceIndex, 1)
        XCTAssertEqual(state.targetIndex, 3)

        XCTAssertEqual(state.primaryEnded(), .commit(sourceIndex: 1, targetIndex: 3))
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.sourceIndex)
        XCTAssertNil(state.targetIndex)
        XCTAssertTrue(state.domain.isEmpty)
        XCTAssertEqual(state.primaryEnded(), .none)
    }

    func testCancelRollsBackExactlyOnceAndDomainClampsTarget() {
        var state = DashboardReorderState()
        state.begin(sourceIndex: 2, domain: 0..<3)

        XCTAssertEqual(state.update(secondFingerDeltaY: 1_000, pointsPerSlot: 64), 2)
        XCTAssertEqual(state.cancel(), .rollback)
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.sourceIndex)
        XCTAssertNil(state.targetIndex)
        XCTAssertTrue(state.domain.isEmpty)
        XCTAssertEqual(state.cancel(), .none)
        XCTAssertEqual(state.primaryEnded(), .none)
    }

    func testPreviewUsesPostRemovalInsertionIndexWhenMovingBackward() {
        let ids: [DashboardSceneItemID] = [
            .account(UUID()), .account(UUID()), .account(UUID()), .account(UUID())
        ]
        var state = DashboardReorderState()

        state.begin(sourceIndex: 3, domain: 0..<4)
        XCTAssertEqual(state.update(secondFingerDeltaY: -130, pointsPerSlot: 64), 1)
        XCTAssertEqual(state.previewOrder(ids), [ids[0], ids[3], ids[1], ids[2]])
    }

    func testInvalidOrEmptyDomainDoesNotBeginReorder() {
        let ids: [DashboardSceneItemID] = [.account(UUID())]
        var state = DashboardReorderState()

        state.begin(sourceIndex: 0, domain: 0..<0)
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.update(secondFingerDeltaY: 64, pointsPerSlot: 64))
        XCTAssertEqual(state.previewOrder(ids), ids)
        XCTAssertEqual(state.primaryEnded(), .none)
        XCTAssertEqual(state.cancel(), .none)

        state.begin(sourceIndex: 3, domain: 0..<3)
        XCTAssertFalse(state.isActive)
    }

    func testNonFiniteDeltaAndSlotWidthAreRejectedWithoutChangingActiveState() {
        var state = DashboardReorderState()
        state.begin(sourceIndex: 1, domain: 0..<3)

        XCTAssertNil(state.update(secondFingerDeltaY: .nan, pointsPerSlot: 64))
        XCTAssertNil(state.update(secondFingerDeltaY: .infinity, pointsPerSlot: 64))
        XCTAssertNil(state.update(secondFingerDeltaY: 64, pointsPerSlot: .infinity))
        XCTAssertNil(state.update(secondFingerDeltaY: 64, pointsPerSlot: .nan))
        XCTAssertEqual(state.sourceIndex, 1)
        XCTAssertEqual(state.targetIndex, 1)
        XCTAssertTrue(state.isActive)
    }

    func testNonZeroDemoDomainClampsPreviewWithinDemoItems() {
        let ids: [DashboardSceneItemID] = [
            .account(UUID()),
            .account(UUID()),
            .demo(.claude),
            .demo(.openai),
            .demo(.grok)
        ]
        var state = DashboardReorderState()
        state.begin(sourceIndex: 3, domain: 2..<5)

        XCTAssertEqual(state.update(secondFingerDeltaY: -1_000, pointsPerSlot: 64), 2)
        XCTAssertEqual(state.previewOrder(ids), [ids[0], ids[1], ids[3], ids[2], ids[4]])

        XCTAssertEqual(state.update(secondFingerDeltaY: 1_000, pointsPerSlot: 64), 4)
        XCTAssertEqual(state.previewOrder(ids), [ids[0], ids[1], ids[2], ids[4], ids[3]])
    }

    func testFiniteInputsWhoseQuotientOverflowsAreRejected() {
        let delta = Double.greatestFiniteMagnitude
        let slotWidth = Double.leastNonzeroMagnitude
        XCTAssertTrue(delta.isFinite)
        XCTAssertTrue(slotWidth.isFinite)

        var state = DashboardReorderState()
        state.begin(sourceIndex: 1, domain: 0..<3)

        XCTAssertNil(state.update(secondFingerDeltaY: delta, pointsPerSlot: slotWidth))
        XCTAssertEqual(state.targetIndex, 1)
        XCTAssertTrue(state.isActive)
    }

    func testOutOfRangeFiniteRoundedOffsetsClampWithoutTrapping() {
        var state = DashboardReorderState()
        state.begin(sourceIndex: 1, domain: 0..<3)

        XCTAssertEqual(
            state.update(secondFingerDeltaY: Double.greatestFiniteMagnitude, pointsPerSlot: 1),
            2
        )
        XCTAssertEqual(
            state.update(secondFingerDeltaY: -Double.greatestFiniteMagnitude, pointsPerSlot: 1),
            0
        )
    }

    func testNearIntBoundaryAdditionOverflowClampsWithoutTrapping() {
        var state = DashboardReorderState()
        state.begin(sourceIndex: Int.max - 1, domain: (Int.max - 2)..<Int.max)
        XCTAssertEqual(state.update(secondFingerDeltaY: 2, pointsPerSlot: 1), Int.max - 1)

        state.begin(sourceIndex: Int.min + 1, domain: Int.min..<(Int.min + 3))
        XCTAssertEqual(state.update(secondFingerDeltaY: -2, pointsPerSlot: 1), Int.min)
    }

    func testRealAndDemoIDsExposeSeparateDomains() {
        XCTAssertEqual(DashboardSceneItemID.account(UUID()).domain, .accounts)
        XCTAssertEqual(DashboardSceneItemID.demo(.claude).domain, .demoProviders)
    }

    func testPublicReducerTypesAreSendable() {
        requireSendable(DashboardSceneItemID.self)
        requireSendable(DashboardReorderDomain.self)
        requireSendable(DashboardReorderCompletion.self)
        requireSendable(DashboardReorderState.self)
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}

    func testDragReorderDecisionUsesMidlineHysteresis() {
        let a = UUID(), b = UUID(), c = UUID()
        let cards = [(id: a, midY: 50.0), (id: b, midY: 150.0), (id: c, midY: 250.0)]
        XCTAssertEqual(DragReorder.decision(pointerY: 280, cards: cards, dragging: a), .toEnd)
        XCTAssertEqual(DragReorder.decision(pointerY: 152, cards: cards, dragging: a), .none)
        XCTAssertEqual(DragReorder.decision(pointerY: 180, cards: cards, dragging: a), .before(c))
        XCTAssertEqual(DragReorder.decision(pointerY: 40, cards: cards, dragging: c), .before(a))
        XCTAssertEqual(DragReorder.decision(pointerY: 148, cards: cards, dragging: c), .none)
        XCTAssertEqual(DragReorder.decision(pointerY: 150, cards: cards, dragging: b), .none)
    }
}

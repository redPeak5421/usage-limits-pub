import XCTest
import Foundation
@testable import UsageLimitsCore

final class DashboardSceneMathTests: XCTestCase {
    func testShortestOffsetWrapsAcrossSeam() {
        XCTAssertEqual(
            DashboardSceneMath.shortestOffset(itemIndex: 0, position: 7.8, count: 8),
            0.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(DashboardSceneMath.wrappedIndex(-1, count: 8), 7)
        XCTAssertEqual(DashboardSceneMath.wrappedIndex(8, count: 8), 0)
    }

    func testShortestOffsetPreservesLapsAndBreaksExactTiesTowardLowerOccurrence() {
        XCTAssertEqual(
            DashboardSceneMath.shortestOffset(itemIndex: 0, position: 9.2, count: 4),
            -1.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            DashboardSceneMath.shortestOffset(itemIndex: 0, position: -9.2, count: 4),
            1.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            DashboardSceneMath.shortestOffset(itemIndex: 0, position: 2, count: 4),
            -2,
            accuracy: 0.000_001
        )
    }

    func testEightSectorAxisLockMatchesReference() {
        XCTAssertEqual(DashboardSceneMath.classifyAxis(dx: 0, dy: 20), .vertical)
        XCTAssertEqual(DashboardSceneMath.classifyAxis(dx: 20, dy: 0), .horizontal)
        XCTAssertEqual(DashboardSceneMath.classifyAxis(dx: 20, dy: 20), .spacing(direction: 1))
        XCTAssertEqual(DashboardSceneMath.classifyAxis(dx: -20, dy: 20), .spacing(direction: -1))
        XCTAssertNil(DashboardSceneMath.classifyAxis(dx: 4, dy: 4))
    }

    func testRouletteFrontAndReducedMotion() {
        let front = DashboardSceneMath.roulettePose(offset: 0, reduceMotion: false)
        // translateZ(46) 在 860px 相机下的投影放大：前排卡必须是最大的一张
        XCTAssertEqual(front.scale, 860.0 / (860.0 - 46.0), accuracy: 0.000_001)
        XCTAssertEqual(front.opacity, 1, accuracy: 0.000_001)
        XCTAssertEqual(front.rotationX, 0, accuracy: 0.000_001)

        let standard = DashboardSceneMath.roulettePose(offset: 1, reduceMotion: false)
        let reduced = DashboardSceneMath.roulettePose(offset: 1, reduceMotion: true)
        XCTAssertGreaterThan(abs(standard.rotationX), abs(reduced.rotationX))
        XCTAssertEqual(reduced.blur, 0, accuracy: 0.000_001)
    }

    func testRouletteNonzeroPoseMatchesReference() {
        let standard = DashboardSceneMath.roulettePose(offset: 1, reduceMotion: false)
        XCTAssertEqual(standard.y, 171, accuracy: 0.000_001)
        XCTAssertEqual(standard.z, 9.459_459_459_459_458, accuracy: 0.000_001)
        XCTAssertEqual(standard.rotationX, -30, accuracy: 0.000_001)
        XCTAssertEqual(standard.scale, 0.99 * 860.0 / (860.0 - 9.459_459_459_459_458), accuracy: 0.000_001)
        XCTAssertLessThan(
            standard.scale,
            DashboardSceneMath.roulettePose(offset: 0, reduceMotion: false).scale,
            "neighbors must project smaller than the front card"
        )
        let scaled = DashboardSceneMath.roulettePose(offset: 1, reduceMotion: false, unitScale: 1.13)
        XCTAssertEqual(scaled.y, 171 * 1.13, accuracy: 0.000_001)
        XCTAssertEqual(scaled.scale, standard.scale, accuracy: 0.000_001)
        XCTAssertEqual(DashboardSceneMath.roulettePerspective, 320.0 / 860.0, accuracy: 0.000_001)
        XCTAssertEqual(standard.opacity, 0.952_633_857_296_55, accuracy: 0.000_001)
        XCTAssertEqual(standard.brightness, 0.83, accuracy: 0.000_001)
        XCTAssertEqual(standard.blur, 0.125, accuracy: 0.000_001)

        let reduced = DashboardSceneMath.roulettePose(offset: 1, reduceMotion: true)
        XCTAssertEqual(reduced.y, 150.48, accuracy: 0.000_001)
        XCTAssertEqual(reduced.rotationX, -12, accuracy: 0.000_001)
        XCTAssertEqual(reduced.blur, 0, accuracy: 0.000_001)
    }

    func testHelixFrontFacesViewerAndSpacingPreventsPierce() {
        let pose = DashboardSceneMath.helixPose(
            offset: 0, isFront: true, tiltDegrees: 44, spacing: 96, foregroundLift: 0,
            cardWidth: 320, cardHeight: 202,
            sceneWidth: 390, reduceMotion: false
        )
        XCTAssertEqual(pose.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(pose.rotationX, 0, accuracy: 0.000_001)
        XCTAssertEqual(pose.rotationY, 0, accuracy: 0.000_001)
        XCTAssertEqual(pose.scale, 1, accuracy: 0.000_001)

        let minimum = DashboardSceneMath.minimumHelixSpacing(
            cardWidth: 320, cardHeight: 202, sceneWidth: 390, tiltDegrees: 44
        )
        XCTAssertGreaterThan(minimum, 0)
        XCTAssertFalse(DashboardSceneMath.adjacentHelixCardsIntersect(
            spacing: minimum, cardWidth: 320, cardHeight: 202,
            sceneWidth: 390, tiltDegrees: 44
        ))
        XCTAssertEqual(
            DashboardSceneMath.maximumHelixSpacing(
                minimum: minimum, cardHeight: 202, sceneHeight: 760
            ),
            max(minimum + 28, min(202 * 2.05, 760 / 2.35)),
            accuracy: 0.000_001
        )
    }

    func testHelixNonzeroFrontAndNonFrontPosesMatchReference() {
        let front = DashboardSceneMath.helixPose(
            offset: 0.75, isFront: true, tiltDegrees: 44, spacing: 120, foregroundLift: 0,
            cardWidth: 320, cardHeight: 202,
            sceneWidth: 390, reduceMotion: false
        )
        XCTAssertEqual(
            front.x,
            127.339_507_571_824_92 * 980 / (980 + 119.231_928_484_406_5),
            accuracy: 0.000_001
        )
        XCTAssertEqual(front.y, 90 * 980 / (980 + 119.231_928_484_406_5), accuracy: 0.000_001)
        XCTAssertEqual(front.z, -119.231_928_484_406_5, accuracy: 0.000_001)
        XCTAssertEqual(front.rotationX, 1.864_687_5, accuracy: 0.000_001)
        XCTAssertGreaterThan(front.rotationY, 20, "贴切线：0.75 格已明显侧转（再乘 facing 收敛）")
        XCTAssertEqual(front.rotationZ, 3.480_837_780_527_794_6, accuracy: 0.000_001)
        // 参考稿 perspective 980px：z 深度折进 scale
        XCTAssertEqual(
            front.scale,
            0.728_571_428_571_428_5 * 980 / (980 + 119.231_928_484_406_5),
            accuracy: 0.000_001
        )

        let nonFront = DashboardSceneMath.helixPose(
            offset: 0.75, isFront: false, tiltDegrees: 44, spacing: 120, foregroundLift: 0,
            cardWidth: 320, cardHeight: 202,
            sceneWidth: 390, reduceMotion: false
        )
        XCTAssertEqual(
            nonFront.x,
            127.339_507_571_824_92 * 980 / (980 + 119.231_928_484_406_5),
            accuracy: 0.000_001
        )
        XCTAssertEqual(nonFront.y, 90 * 980 / (980 + 119.231_928_484_406_5), accuracy: 0.000_001)
        XCTAssertEqual(nonFront.z, -119.231_928_484_406_5, accuracy: 0.000_001)
        XCTAssertEqual(nonFront.rotationX, 2.21, accuracy: 0.000_001)
        XCTAssertGreaterThan(nonFront.rotationY, front.rotationY, "非焦点卡不收敛，转得更足")
        XCTAssertEqual(nonFront.rotationZ, 4.125_437_369_514_423, accuracy: 0.000_001)
        XCTAssertEqual(
            nonFront.scale,
            0.678_306_878_306_878_3 * 980 / (980 + 119.231_928_484_406_5),
            accuracy: 0.000_001
        )
    }

    func testStepVelocityMatchesReferenceFrictionCurve() {
        XCTAssertEqual(
            DashboardSceneMath.stepVelocity(
                0.02,
                deltaMilliseconds: 32,
                friction: 0.9
            ),
            0.0162,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            DashboardSceneMath.stepVelocity(
                0.02,
                deltaMilliseconds: 0,
                friction: 0.9
            ),
            0.02,
            accuracy: 0.000_001
        )
    }

    func testVelocitySettlesInsteadOfRunningForever() {
        var velocity = 0.02
        for _ in 0..<240 {
            velocity = DashboardSceneMath.stepVelocity(
                velocity,
                deltaMilliseconds: 16,
                friction: 0.9
            )
        }
        XCTAssertEqual(velocity, 0, accuracy: 0.000_1)
    }

    func testSampledVelocityUsesLatestEightMonotonicPointsAndMilliseconds() {
        let samples = [
            DashboardSceneDragSample(x: -1_000, y: 500, timestamp: 0),
            DashboardSceneDragSample(x: -1_000, y: 500, timestamp: 0.01),
            DashboardSceneDragSample(x: 20, y: -10, timestamp: 0.02),
            DashboardSceneDragSample(x: 30, y: -15, timestamp: 0.03),
            DashboardSceneDragSample(x: 40, y: -20, timestamp: 0.04),
            DashboardSceneDragSample(x: 50, y: -25, timestamp: 0.05),
            DashboardSceneDragSample(x: 60, y: -30, timestamp: 0.06),
            DashboardSceneDragSample(x: 70, y: -35, timestamp: 0.07),
            DashboardSceneDragSample(x: 80, y: -40, timestamp: 0.08),
            DashboardSceneDragSample(x: 90, y: -45, timestamp: 0.09),
        ]

        let velocity = DashboardSceneMath.sampledVelocity(
            samples: samples,
            releaseTimestamp: 0.10
        )

        XCTAssertEqual(velocity.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(velocity.y, -0.5, accuracy: 0.000_001)
    }

    func testSampledVelocityUsesLatestNinetyMilliseconds() {
        let samples = [
            DashboardSceneDragSample(x: -1_000, y: 500, timestamp: 0),
            DashboardSceneDragSample(x: 40, y: -20, timestamp: 0.04),
            DashboardSceneDragSample(x: 100, y: 40, timestamp: 0.10),
        ]

        let velocity = DashboardSceneMath.sampledVelocity(
            samples: samples,
            releaseTimestamp: 0.10
        )

        XCTAssertEqual(velocity.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(velocity.y, 1, accuracy: 0.000_001)
    }

    func testSampledVelocityRequiresTwelveMillisecondsAndFreshRelease() {
        let short = [
            DashboardSceneDragSample(x: 0, y: 0, timestamp: 1),
            DashboardSceneDragSample(x: 11, y: 11, timestamp: 1.011),
        ]
        XCTAssertEqual(
            DashboardSceneMath.sampledVelocity(samples: short, releaseTimestamp: 1.011),
            .zero
        )

        let valid = [
            DashboardSceneDragSample(x: 0, y: 0, timestamp: 1),
            DashboardSceneDragSample(x: 12, y: -6, timestamp: 1.012),
        ]
        let fresh = DashboardSceneMath.sampledVelocity(
            samples: valid,
            releaseTimestamp: 1.151
        )
        XCTAssertEqual(fresh.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(fresh.y, -0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            DashboardSceneMath.sampledVelocity(samples: valid, releaseTimestamp: 1.152),
            .zero
        )
    }

    func testSampledVelocityRejectsInvalidOrNonmonotonicTime() {
        let valid = [
            DashboardSceneDragSample(x: 0, y: 0, timestamp: 1),
            DashboardSceneDragSample(x: 20, y: 10, timestamp: 1.02),
        ]
        XCTAssertEqual(
            DashboardSceneMath.sampledVelocity(samples: valid, releaseTimestamp: 0.99),
            .zero
        )
        XCTAssertEqual(
            DashboardSceneMath.sampledVelocity(samples: valid, releaseTimestamp: .nan),
            .zero
        )

        let nonmonotonic = [
            DashboardSceneDragSample(x: 0, y: 0, timestamp: 1),
            DashboardSceneDragSample(x: 20, y: 10, timestamp: 0.99),
        ]
        XCTAssertEqual(
            DashboardSceneMath.sampledVelocity(samples: nonmonotonic, releaseTimestamp: 1),
            .zero
        )

        let nonfinite = [
            DashboardSceneDragSample(x: 0, y: 0, timestamp: 1),
            DashboardSceneDragSample(x: .infinity, y: 10, timestamp: 1.02),
        ]
        XCTAssertEqual(
            DashboardSceneMath.sampledVelocity(samples: nonfinite, releaseTimestamp: 1.02),
            .zero
        )
    }

    func testReconcileKeepsSurvivingStableSelection() {
        let a = DashboardSceneItemID.account(UUID())
        let b = DashboardSceneItemID.account(UUID())
        let c = DashboardSceneItemID.account(UUID())

        XCTAssertEqual(
            DashboardSceneMath.reconciledSelection(
                current: b,
                old: [a, b, c],
                new: [c, b, a]
            ),
            b
        )
    }

    func testReconcileDeletedSelectionPrefersSuccessorThenPredecessor() {
        let a = DashboardSceneItemID.account(UUID())
        let b = DashboardSceneItemID.account(UUID())
        let c = DashboardSceneItemID.account(UUID())
        let d = DashboardSceneItemID.account(UUID())

        XCTAssertEqual(
            DashboardSceneMath.reconciledSelection(
                current: b,
                old: [a, b, c, d],
                new: [a, c]
            ),
            c
        )
        XCTAssertEqual(
            DashboardSceneMath.reconciledSelection(
                current: c,
                old: [a, b, c, d],
                new: [a, b]
            ),
            b
        )
    }

    func testReconcileFallsBackToFirstAndReturnsNilForEmptyInput() {
        let old = DashboardSceneItemID.account(UUID())
        let first = DashboardSceneItemID.account(UUID())
        let second = DashboardSceneItemID.account(UUID())

        XCTAssertEqual(
            DashboardSceneMath.reconciledSelection(
                current: old,
                old: [old],
                new: [first, second]
            ),
            first
        )
        XCTAssertNil(
            DashboardSceneMath.reconciledSelection(
                current: old,
                old: [old],
                new: []
            )
        )
    }

    func testEffectiveHelixSpacingCompressesWithFlatteningButHonorsCollisionMinimum() {
        XCTAssertEqual(
            DashboardSceneMath.effectiveHelixSpacing(
                spacing: 200,
                minimum: 80,
                tiltDegrees: 0
            ),
            200,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            DashboardSceneMath.effectiveHelixSpacing(
                spacing: 200,
                minimum: 80,
                tiltDegrees: 70
            ),
            110,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            DashboardSceneMath.effectiveHelixSpacing(
                spacing: 96,
                minimum: 80,
                tiltDegrees: 70
            ),
            80,
            accuracy: 0.000_001
        )
    }

    func testProjectedRouletteBoundsRouteExposedNeighborPastFrontEdge() {
        let sceneWidth = 402.0
        let sceneHeight = 693.0
        let cardWidth = 320.0
        let cardHeight = cardWidth * (53.98 / 85.6)
        let front = DashboardSceneMath.projectedCardBounds(
            pose: DashboardSceneMath.roulettePose(offset: 0, reduceMotion: false),
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            sceneWidth: sceneWidth,
            sceneHeight: sceneHeight
        )
        let neighbor = DashboardSceneMath.projectedCardBounds(
            pose: DashboardSceneMath.roulettePose(offset: 1, reduceMotion: false),
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            sceneWidth: sceneWidth,
            sceneHeight: sceneHeight
        )
        // 紧贴前排卡下边缘外侧的一点：前排不得吃掉它，下一张卡透视后的上边缘必须盖住它
        let exposedNeighborPoint = CGPoint(
            x: front.midX - 90,
            y: front.maxY + 0.5
        )

        XCTAssertEqual(front.midX, sceneWidth / 2, accuracy: 0.000_001)
        XCTAssertEqual(front.midY, sceneHeight / 2, accuracy: 0.000_001)
        XCTAssertFalse(
            front.insetBy(dx: 1, dy: 1).contains(exposedNeighborPoint),
            "the front card must not capture a point just beyond its visible edge"
        )
        XCTAssertTrue(
            neighbor.insetBy(dx: 1, dy: 1).contains(exposedNeighborPoint),
            "the transformed neighbor must own its exposed face"
        )
        XCTAssertLessThan(neighbor.height, front.height)
        XCTAssertGreaterThan(neighbor.midY, front.midY)
    }

    func testProjectedCardBoundsRejectInvalidGeometry() {
        let pose = DashboardSceneMath.roulettePose(offset: 0, reduceMotion: false)
        XCTAssertTrue(
            DashboardSceneMath.projectedCardBounds(
                pose: pose,
                cardWidth: .nan,
                cardHeight: 202,
                sceneWidth: 402,
                sceneHeight: 693
            ).isNull
        )
        XCTAssertTrue(
            DashboardSceneMath.projectedCardBounds(
                pose: pose,
                cardWidth: 0,
                cardHeight: 202,
                sceneWidth: 402,
                sceneHeight: 693
            ).isNull
        )
    }

    /// 手指能拖到的倾斜只到线圈段尽头（43.75°）：再往外参考稿会把链条拉平、在竖屏上露出大片空白。
    func testInteractiveHelixTiltStopsAtTheCoilEnd() {
        let range = DashboardSceneMath.helixCoilTiltRange
        XCTAssertEqual(range.upperBound, 43.75, accuracy: 0.001)
        XCTAssertEqual(range.lowerBound, -43.75, accuracy: 0.001)
        XCTAssertTrue(DashboardSceneMath.helixTiltRange.contains(range.upperBound))
        XCTAssertLessThan(range.upperBound, DashboardSceneMath.helixTiltRange.upperBound)
    }

    /// 横向拖动的线圈半径增益：x 摆幅与 z 深度一起放大、再按相机投影；前排 z = 0 不受影响；越界值夹住。
    func testHelixCoilGainWidensTheCoilAndPushesBackCardsAway() {
        func pose(offset: Double, gain: Double) -> DashboardScenePose {
            DashboardSceneMath.helixPose(
                offset: offset, isFront: offset == 0, tiltDegrees: 44, spacing: 120, coilGain: gain, foregroundLift: 0,
                cardWidth: 320, cardHeight: 202, sceneWidth: 390, reduceMotion: false
            )
        }
        let front = pose(offset: 0, gain: 1.1)
        XCTAssertEqual(front.z, 0, accuracy: 0.000_001)
        XCTAssertEqual(front.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(front.scale, 1, accuracy: 0.000_001)

        let near = pose(offset: 1, gain: 1)
        let far = pose(offset: 1, gain: 1.1)
        XCTAssertLessThan(far.z, near.z)
        XCTAssertLessThan(far.scale, near.scale)
        XCTAssertEqual(far.z, near.z * 1.1, accuracy: 0.000_001)
        XCTAssertGreaterThan(abs(far.x), abs(near.x), "半径变大：横向甩得更开（投影后仍更宽）")
        XCTAssertLessThan(abs(far.y), abs(near.y), "拉远的同时纵向也收拢：链条不断开")
        XCTAssertEqual(far.y / near.y, far.scale / near.scale, accuracy: 0.000_001, "纵向与缩放用同一投影")

        let clamped = pose(offset: 1, gain: 99)
        let limit = pose(offset: 1, gain: DashboardSceneMath.helixCoilGainRange.upperBound)
        XCTAssertEqual(clamped.scale, limit.scale, accuracy: 0.000_001)
        XCTAssertEqual(pose(offset: 1, gain: .nan).scale, near.scale, accuracy: 0.000_001)
    }

    /// 拧度（线圈半径增益）范围：上限 1.1475（原 1.35 收 15%）；对称到负值 —— 0 是竖线，过 0 反向拧。
    func testHelixCoilGainRangeIsSymmetricAndCappedBelowOldLimit() {
        let range = DashboardSceneMath.helixCoilGainRange
        XCTAssertEqual(range.upperBound, 1.1475, accuracy: 0.000_001)
        XCTAssertEqual(range.lowerBound, -range.upperBound, accuracy: 0.000_001)
        XCTAssertTrue(range.contains(DashboardSceneMath.helixDefaultCoilGain))
        XCTAssertTrue(range.contains(0))
    }

    /// 负拧度 = 反手性：与同大小正拧度相比 x、绕轴朝向（rotationY / rotationZ）镜像，深度、缩放、虚化、上下倾斜不变。
    func testNegativeCoilGainMirrorsHelixHandedness() {
        for (offset, gain) in [(1.0, 1.0), (2.0, 0.8), (-1.0, DashboardSceneMath.helixCoilGainRange.upperBound), (1.0, 0.3)] {
            let right = coilPose(offset, gain: gain)
            let left = coilPose(offset, gain: -gain)
            XCTAssertGreaterThan(abs(right.x), 1, "offset \(offset) gain \(gain)：正拧度本身要有摆幅")
            XCTAssertEqual(left.x, -right.x, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.rotationY, -right.rotationY, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.rotationZ, -right.rotationZ, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.z, right.z, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.y, right.y, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.scale, right.scale, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.blur, right.blur, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.opacity, right.opacity, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
            XCTAssertEqual(left.rotationX, right.rotationX, accuracy: 0.000_001, "offset \(offset) gain \(gain)")
        }
        let overshoot = coilPose(1, gain: -99)
        let limit = coilPose(1, gain: DashboardSceneMath.helixCoilGainRange.lowerBound)
        XCTAssertEqual(overshoot.x, limit.x, accuracy: 0.000_001, "负向越界同样夹在下限")
    }

    private func coilPose(_ offset: Double, gain: Double) -> DashboardScenePose {
        DashboardSceneMath.helixPose(
            offset: offset, isFront: offset == 0,
            tiltDegrees: DashboardSceneMath.helixCoilTiltRange.upperBound,
            spacing: 120, coilGain: gain,
            cardWidth: 320, cardHeight: 202, sceneWidth: 390, reduceMotion: false
        )
    }

    /// 拧度 0：所有卡片 x = z = 0、不绕轴转、不虚化，只剩纵向螺距 —— 一列正对观者的竖线；焦点卡仍原样。
    func testZeroCoilGainStacksCardsInAVerticalLineFacingTheViewer() {
        for offset in [-2.0, -1, 1, 2, 3] {
            let pose = coilPose(offset, gain: 0)
            XCTAssertEqual(pose.x, 0, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.z, 0, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.rotationX, 0, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.rotationY, 0, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.rotationZ, 0, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.blur, 0, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.opacity, 1, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertEqual(pose.y, offset * 120, accuracy: 0.000_001, "offset \(offset)")
            XCTAssertGreaterThan(pose.scale, 0)
            XCTAssertTrue(pose.scale.isFinite)
        }
        let front = coilPose(0, gain: 0)
        XCTAssertEqual(front.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(front.z, 0, accuracy: 0.000_001)
        // 整列 z 全为 0 时画顺序仍有定义：离焦点近的在上
        XCTAssertGreaterThan(coilPose(1, gain: 0).depthOrder, coilPose(2, gain: 0).depthOrder)
        XCTAssertGreaterThan(coilPose(-1, gain: 0).depthOrder, coilPose(-3, gain: 0).depthOrder)
    }

    /// 拧度从旧下限（0.6）往 0 收时卡片朝向与前景虚化按比例回正；0.6 及以上的朝向和以前完全一样。
    func testCoilGainBelowUntwistThresholdStraightensCardsProportionally() {
        let atOldFloor = coilPose(1, gain: DashboardSceneMath.helixUntwistGain)
        let atDefault = coilPose(1, gain: DashboardSceneMath.helixDefaultCoilGain)
        let atMax = coilPose(1, gain: DashboardSceneMath.helixCoilGainRange.upperBound)
        XCTAssertGreaterThan(abs(atDefault.rotationY), 1)
        XCTAssertEqual(atOldFloor.rotationY, atDefault.rotationY, accuracy: 0.000_001)
        XCTAssertEqual(atMax.rotationY, atDefault.rotationY, accuracy: 0.000_001)
        XCTAssertEqual(atOldFloor.blur, atDefault.blur, accuracy: 0.000_001)

        let half = coilPose(1, gain: DashboardSceneMath.helixUntwistGain * 0.5)
        XCTAssertEqual(half.rotationY, atDefault.rotationY * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(half.rotationX, atDefault.rotationX * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(half.rotationZ, atDefault.rotationZ * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(half.blur, atDefault.blur * 0.5, accuracy: 0.000_001)
        XCTAssertGreaterThan(abs(half.x), 0, "半径还没到 0：仍有横向摆幅")
    }

    /// 默认前景抬升：前后两张邻卡都到观者前方（z > 0、更大、带虚化），再远的仍在后方；焦点卡不动。
    func testHelixForegroundLiftPutsNeighborsInFrontWithBlur() {
        func pose(_ offset: Double, lift: Double = DashboardSceneMath.helixForegroundLift) -> DashboardScenePose {
            DashboardSceneMath.helixPose(
                offset: offset, isFront: offset == 0, tiltDegrees: 40, spacing: 120,
                coilGain: 1, foregroundLift: lift,
                cardWidth: 320, cardHeight: 202, sceneWidth: 390, reduceMotion: false
            )
        }
        let front = pose(0)
        XCTAssertEqual(front.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(front.z, 0, accuracy: 0.000_001)
        XCTAssertEqual(front.blur, 0, accuracy: 0.000_001)

        for offset in [1.0, -1.0] {
            let neighbor = pose(offset)
            XCTAssertGreaterThan(neighbor.z, 0, "邻卡在前景 \(offset)")
            XCTAssertGreaterThan(neighbor.blur, 0)
            XCTAssertLessThan(neighbor.opacity, 1)
            XCTAssertGreaterThan(neighbor.scale, pose(offset, lift: 0).scale)
        }
        XCTAssertEqual(pose(1).z, pose(-1).z, accuracy: 0.000_001, "前后对称")
        XCTAssertLessThan(pose(2).z, 0, "再远的绕到后方")
        XCTAssertEqual(pose(2).blur, 0, accuracy: 0.000_001)
        // 半格处仍在前景、且有限：焦点切换时不会跳变到后方
        XCTAssertGreaterThan(pose(0.5).z, 0)
        XCTAssertTrue(pose(0.5).z.isFinite)
        // 抬升 0 = 参考稿：全部在后方
        XCTAssertLessThan(pose(1, lift: 0).z, 0)
        XCTAssertEqual(pose(1, lift: .nan).z, pose(1, lift: 0).z, accuracy: 0.000_001)
    }

    /// 真实螺旋：卡片朝向轴心，对面的卡片 |rotationY| > 90°（渲染时露出背面、内容镜像）；焦点卡正对观者。
    func testHelixCardsFaceTheAxisSoTheFarSideShowsItsBack() {
        func pose(_ offset: Double) -> DashboardScenePose {
            DashboardSceneMath.helixPose(
                offset: offset, isFront: offset == 0, tiltDegrees: 40, spacing: 120,
                coilGain: 1, foregroundLift: 0,
                cardWidth: 320, cardHeight: 202, sceneWidth: 390, reduceMotion: false
            )
        }
        XCTAssertEqual(pose(0).rotationY, 0, accuracy: 0.000_001)
        XCTAssertEqual(pose(1).rotationY, -pose(-1).rotationY, accuracy: 0.000_001)
        XCTAssertGreaterThan(abs(pose(1).rotationY), 45)
        XCTAssertLessThan(abs(pose(1).rotationY), 90, "邻卡还是正面")
        let farSide = (2...4).map { abs(pose(Double($0)).rotationY) }
        XCTAssertTrue(farSide.contains { $0 > 90 }, "线圈对面必有露背面的卡")
        XCTAssertTrue(farSide.allSatisfy { $0 <= 180 })
        XCTAssertEqual(DashboardSceneMath.normalizedDegrees(270), -90, accuracy: 0.000_001)
        XCTAssertEqual(DashboardSceneMath.normalizedDegrees(-180), 180, accuracy: 0.000_001)
        XCTAssertEqual(DashboardSceneMath.normalizedDegrees(.nan), 0, accuracy: 0.000_001)
    }
}

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

enum DashboardSceneGestureEvent {
    case tap(location: CGPoint, timestamp: TimeInterval)
    case dragBegan(location: CGPoint, timestamp: TimeInterval)
    case dragChanged(delta: CGSize, location: CGPoint, timestamp: TimeInterval)
    /// Velocity is expressed in named `dashboardScene` points per second.
    case dragEnded(velocity: CGSize, timestamp: TimeInterval)
    case reorderBegan(location: CGPoint)
    case reorderChanged(secondFingerDeltaY: CGFloat)
    case reorderEnded
    case cancelled
}

final class DashboardSceneGestureRecognizer: UIGestureRecognizer {
    var minimumPressDuration: TimeInterval = 0.45
    var movementTolerance: CGFloat = 8
    var isExcludedTarget: (CGPoint) -> Bool = { _ in false }
    var isReorderTarget: (CGPoint) -> Bool = { _ in false }
    /// 「延后判定」区域（计量条）：触摸可以从这里开始，短触 / 拖动照常滚动场景，只是不从这里起整卡排序的长按。
    var isDeferredTarget: (CGPoint) -> Bool = { _ in false }
    var sceneLocation: (UITouch) -> CGPoint? = { _ in nil }
    var onExcludedTouchBegan: () -> Void = {}

    private(set) var output: DashboardSceneGestureEvent?
    /// 越过阈值的那次 move 同时包含 begin 与位移，不能等下一次 move 才开始移动。
    private var pendingDragChange: DashboardSceneGestureEvent?
    private var pendingDragEnd: DashboardSceneGestureEvent?

    private enum Mode: Equatable {
        case tapCandidate
        case sceneDrag
        case reorder
    }

    private var mode: Mode = .tapCandidate
    private var primaryTouch: UITouch?
    private var secondaryTouch: UITouch?
    private var holdTimer: Timer?

    private var cachedInitialReorderEligibility = false
    private var initialPrimaryPoint: CGPoint?
    private var initialPrimaryTimestamp: TimeInterval?
    private var lastPrimaryPoint: CGPoint?
    private var lastPrimaryTimestamp: TimeInterval?
    private var lastPrimaryVelocity = CGSize.zero

    private var secondaryStartY: CGFloat?
    private var lastReorderDelta: CGFloat = 0
    private var replacementBaseline: CGFloat = 0
    private var terminalEventEmitted = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        switch mode {
        case .tapCandidate:
            beginTapCandidate(touches)
        case .sceneDrag:
            cancelActiveInteraction()
        case .reorder:
            beginReorderSecondary(touches)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        switch mode {
        case .tapCandidate:
            moveTapCandidate(touches)
        case .sceneDrag:
            moveSceneDrag(touches)
        case .reorder:
            moveReorderSecondary(touches)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let primaryTouch, touches.contains(where: { $0 === primaryTouch }) {
            endPrimary(primaryTouch)
            return
        }

        if let secondaryTouch, touches.contains(where: { $0 === secondaryTouch }) {
            self.secondaryTouch = nil
            secondaryStartY = nil
            replacementBaseline = lastReorderDelta
            output = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let includesPrimary = primaryTouch.map { primary in
            touches.contains(where: { $0 === primary })
        } ?? false
        let includesSecondary = secondaryTouch.map { secondary in
            touches.contains(where: { $0 === secondary })
        } ?? false

        guard includesPrimary || includesSecondary else { return }
        cancelActiveInteraction()
    }

    override func reset() {
        super.reset()
        invalidateHoldTimer()
        mode = .tapCandidate
        primaryTouch = nil
        secondaryTouch = nil
        cachedInitialReorderEligibility = false
        initialPrimaryPoint = nil
        initialPrimaryTimestamp = nil
        lastPrimaryPoint = nil
        lastPrimaryTimestamp = nil
        lastPrimaryVelocity = .zero
        secondaryStartY = nil
        lastReorderDelta = 0
        replacementBaseline = 0
        terminalEventEmitted = false
        output = nil
        pendingDragChange = nil
        pendingDragEnd = nil
    }

    func consumeOutput() -> DashboardSceneGestureEvent? {
        defer {
            output = pendingDragChange
            pendingDragChange = pendingDragEnd
            pendingDragEnd = nil
        }
        return output
    }

    func prepareForDisable() {
        invalidateHoldTimer()
        pendingDragChange = nil
        pendingDragEnd = nil
        guard state == .began || state == .changed, !terminalEventEmitted else {
            output = nil
            return
        }
        terminalEventEmitted = true
        output = .cancelled
        state = .cancelled
    }

    private func beginTapCandidate(_ touches: Set<UITouch>) {
        guard state == .possible, primaryTouch == nil, touches.count == 1,
              let touch = touches.first,
              let location = sceneLocation(touch)
        else {
            failCandidate()
            return
        }
        guard !isExcludedTarget(location) else {
            onExcludedTouchBegan()
            failCandidate()
            return
        }

        primaryTouch = touch
        cachedInitialReorderEligibility = isReorderTarget(location) && !isDeferredTarget(location)
        initialPrimaryPoint = location
        initialPrimaryTimestamp = touch.timestamp
        lastPrimaryPoint = location
        lastPrimaryTimestamp = touch.timestamp
        lastPrimaryVelocity = .zero
        output = nil

        if cachedInitialReorderEligibility {
            scheduleHoldTimer(for: touch)
        }
    }

    private func beginReorderSecondary(_ touches: Set<UITouch>) {
        guard state == .began || state == .changed,
              primaryTouch != nil,
              secondaryTouch == nil,
              touches.count == 1,
              let touch = touches.first,
              let location = sceneLocation(touch)
        else { return }
        guard !isExcludedTarget(location) else {
            onExcludedTouchBegan()
            return
        }

        secondaryTouch = touch
        secondaryStartY = location.y
        replacementBaseline = lastReorderDelta
        output = nil
    }

    private func moveTapCandidate(_ touches: Set<UITouch>) {
        guard state == .possible,
              let primaryTouch,
              touches.contains(where: { $0 === primaryTouch }),
              let initialPrimaryPoint,
              let initialPrimaryTimestamp,
              let location = sceneLocation(primaryTouch)
        else { return }

        let displacement = CGSize(
            width: location.x - initialPrimaryPoint.x,
            height: location.y - initialPrimaryPoint.y
        )
        guard hypot(displacement.width, displacement.height) > movementTolerance else { return }

        invalidateHoldTimer()
        mode = .sceneDrag
        lastPrimaryPoint = location
        lastPrimaryTimestamp = primaryTouch.timestamp
        lastPrimaryVelocity = .zero
        output = .dragBegan(
            location: initialPrimaryPoint,
            timestamp: initialPrimaryTimestamp
        )
        pendingDragChange = .dragChanged(
            delta: displacement,
            location: location,
            timestamp: primaryTouch.timestamp
        )
        state = .began
    }

    private func moveSceneDrag(_ touches: Set<UITouch>) {
        guard state == .began || state == .changed,
              let primaryTouch,
              touches.contains(where: { $0 === primaryTouch }),
              let previousPoint = lastPrimaryPoint,
              let location = sceneLocation(primaryTouch)
        else { return }

        let delta = CGSize(
            width: location.x - previousPoint.x,
            height: location.y - previousPoint.y
        )
        updateVelocity(delta: delta, timestamp: primaryTouch.timestamp)
        lastPrimaryPoint = location
        lastPrimaryTimestamp = primaryTouch.timestamp
        output = .dragChanged(
            delta: delta,
            location: location,
            timestamp: primaryTouch.timestamp
        )
        state = .changed
    }

    private func moveReorderSecondary(_ touches: Set<UITouch>) {
        guard state == .began || state == .changed,
              let secondaryTouch,
              touches.contains(where: { $0 === secondaryTouch }),
              let secondaryStartY,
              let location = sceneLocation(secondaryTouch)
        else { return }

        let delta = replacementBaseline + location.y - secondaryStartY
        lastReorderDelta = delta
        output = .reorderChanged(secondFingerDeltaY: delta)
        state = .changed
    }

    private func endPrimary(_ touch: UITouch) {
        invalidateHoldTimer()

        switch mode {
        case .tapCandidate:
            guard state == .possible, let location = sceneLocation(touch) else {
                failCandidate()
                return
            }
            if deliverUnreportedDrag(endingAt: location, timestamp: touch.timestamp) { return }
            terminalEventEmitted = true
            output = .tap(location: location, timestamp: touch.timestamp)
            state = .recognized
        case .sceneDrag:
            guard state == .began || state == .changed else { return }
            if let previousPoint = lastPrimaryPoint,
               let location = sceneLocation(touch) {
                let delta = CGSize(
                    width: location.x - previousPoint.x,
                    height: location.y - previousPoint.y
                )
                updateVelocity(delta: delta, timestamp: touch.timestamp)
            }
            terminalEventEmitted = true
            output = .dragEnded(velocity: lastPrimaryVelocity, timestamp: touch.timestamp)
            state = .ended
        case .reorder:
            guard state == .began || state == .changed else { return }
            terminalEventEmitted = true
            output = .reorderEnded
            state = .ended
        }
    }

    /// 很快的滑动可能只有 began / ended，没有中间 moved；按起终点补全同一手势，不能误触收起按钮。
    private func deliverUnreportedDrag(endingAt location: CGPoint, timestamp: TimeInterval) -> Bool {
        guard let initialPrimaryPoint, let initialPrimaryTimestamp else { return false }
        let displacement = CGSize(width: location.x - initialPrimaryPoint.x,
                                  height: location.y - initialPrimaryPoint.y)
        guard hypot(displacement.width, displacement.height) > movementTolerance else { return false }
        terminalEventEmitted = true
        output = .dragBegan(location: initialPrimaryPoint, timestamp: initialPrimaryTimestamp)
        pendingDragChange = .dragChanged(delta: displacement, location: location, timestamp: timestamp)
        // 没有中间采样，不猜测惯性速度；只交付真实位移。
        pendingDragEnd = .dragEnded(velocity: .zero, timestamp: timestamp)
        state = .recognized
        return true
    }

    private func updateVelocity(delta: CGSize, timestamp: TimeInterval) {
        guard let lastPrimaryTimestamp else { return }
        let elapsed = timestamp - lastPrimaryTimestamp
        guard elapsed > 0 else { return }
        lastPrimaryVelocity = CGSize(
            width: delta.width / elapsed,
            height: delta.height / elapsed
        )
    }

    private func scheduleHoldTimer(for touch: UITouch) {
        invalidateHoldTimer()
        let timer = Timer(timeInterval: minimumPressDuration, repeats: false) { [weak self, weak expectedPrimary = touch] timer in
            guard let self,
                  let expectedPrimary,
                  self.state == .possible,
                  self.mode == .tapCandidate,
                  self.primaryTouch === expectedPrimary,
                  self.cachedInitialReorderEligibility,
                  let location = self.initialPrimaryPoint
            else {
                self?.holdTimer = nil
                timer.invalidate()
                return
            }

            self.holdTimer = nil
            timer.invalidate()
            self.mode = .reorder
            self.output = .reorderBegan(location: location)
            self.state = .began
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func invalidateHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func failCandidate() {
        invalidateHoldTimer()
        output = nil
        pendingDragChange = nil
        pendingDragEnd = nil
        guard state == .possible else { return }
        state = .failed
    }

    private func cancelActiveInteraction() {
        invalidateHoldTimer()
        pendingDragChange = nil
        pendingDragEnd = nil
        guard state == .began || state == .changed else {
            failCandidate()
            return
        }
        guard !terminalEventEmitted else { return }
        terminalEventEmitted = true
        output = .cancelled
        state = .cancelled
    }
}

struct DashboardSceneGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var minimumPressDuration: TimeInterval = 0.45
    var movementTolerance: CGFloat = 8
    var isExcludedTarget: (CGPoint) -> Bool
    var isReorderTarget: (CGPoint) -> Bool
    var isDeferredTarget: (CGPoint) -> Bool = { _ in false }
    var onEvent: (DashboardSceneGestureEvent) -> Void
    var onExcludedTouchBegan: () -> Void = {}

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(
            converter: converter,
            onEvent: onEvent,
            onExcludedTouchBegan: onExcludedTouchBegan
        )
    }

    func makeUIGestureRecognizer(context: Context) -> DashboardSceneGestureRecognizer {
        let recognizer = DashboardSceneGestureRecognizer(target: nil, action: nil)
        recognizer.cancelsTouchesInView = false
        recognizer.minimumPressDuration = minimumPressDuration
        recognizer.movementTolerance = movementTolerance
        recognizer.isExcludedTarget = isExcludedTarget
        recognizer.isReorderTarget = isReorderTarget
        recognizer.isDeferredTarget = isDeferredTarget
        recognizer.sceneLocation = { [weak coordinator = context.coordinator] touch in
            coordinator?.sceneLocation(of: touch)
        }
        recognizer.onExcludedTouchBegan = { [weak coordinator = context.coordinator] in
            coordinator?.excludedTouchBegan()
        }
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: DashboardSceneGestureRecognizer, context: Context) {
        context.coordinator.converter = context.converter
        context.coordinator.onEvent = onEvent
        recognizer.minimumPressDuration = minimumPressDuration
        context.coordinator.onExcludedTouchBegan = onExcludedTouchBegan
        recognizer.movementTolerance = movementTolerance
        recognizer.isExcludedTarget = isExcludedTarget
        recognizer.isReorderTarget = isReorderTarget
        recognizer.isDeferredTarget = isDeferredTarget
        recognizer.sceneLocation = { [weak coordinator = context.coordinator] touch in
            coordinator?.sceneLocation(of: touch)
        }
        recognizer.onExcludedTouchBegan = { [weak coordinator = context.coordinator] in
            coordinator?.excludedTouchBegan()
        }

        if recognizer.isEnabled != isEnabled {
            if !isEnabled {
                recognizer.prepareForDisable()
            }
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: DashboardSceneGestureRecognizer, context: Context) {
        while let event = recognizer.consumeOutput() {
            context.coordinator.deliver(event)
        }
    }

    final class Coordinator {
        var converter: CoordinateSpaceConverter
        var onEvent: (DashboardSceneGestureEvent) -> Void

        var onExcludedTouchBegan: () -> Void
        init(
            converter: CoordinateSpaceConverter,
            onEvent: @escaping (DashboardSceneGestureEvent) -> Void,
            onExcludedTouchBegan: @escaping () -> Void
        ) {
            self.converter = converter
            self.onEvent = onEvent
            self.onExcludedTouchBegan = onExcludedTouchBegan
        }

        func sceneLocation(of touch: UITouch) -> CGPoint {
            converter.convert(globalPoint: touch.location(in: nil), to: .named("dashboardScene"))
        }

        func excludedTouchBegan() {
            onExcludedTouchBegan()
        }

        func deliver(_ event: DashboardSceneGestureEvent) {
            switch event {
            case let .tap(location, timestamp):
                onEvent(.tap(location: location, timestamp: timestamp))
            case let .dragBegan(location, timestamp):
                onEvent(.dragBegan(location: location, timestamp: timestamp))
            case let .dragChanged(delta, location, timestamp):
                onEvent(.dragChanged(
                    delta: delta,
                    location: location,
                    timestamp: timestamp
                ))
            case let .dragEnded(fallbackVelocity, timestamp):
                let convertedVelocity = converter.velocity(in: .named("dashboardScene"))
                    .map { CGSize(width: $0.x, height: $0.y) }
                    ?? fallbackVelocity
                onEvent(.dragEnded(velocity: convertedVelocity, timestamp: timestamp))
            case .reorderBegan, .reorderChanged, .reorderEnded, .cancelled:
                onEvent(event)
            }
        }
    }
}

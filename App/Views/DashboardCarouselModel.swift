import UsageLimitsCore
import SwiftUI
import UIKit

struct DashboardReorderCommit: Equatable {
    let orderedIDs: [DashboardSceneItemID]
    let domain: DashboardReorderDomain
}

@MainActor
final class DashboardCarouselModel: ObservableObject {
    @Published private(set) var orderedIDs: [DashboardSceneItemID] = []
    @Published private(set) var position: Double = 0
    @Published private(set) var tiltDegrees: Double = DashboardSceneMath.helixCoilTiltRange.upperBound
    @Published private(set) var spacing: Double = 96
    @Published private(set) var effectiveSpacing: Double = 96
    /// 螺旋线圈半径增益（横向拖动）：1 = 参考稿原始半径，越大卡片沿越大的圆弧甩开、后方越远越小。
    @Published private(set) var coilGain: Double = DashboardSceneMath.helixDefaultCoilGain
    @Published private(set) var expandedID: DashboardSceneItemID?
    @Published private(set) var reorderPreview: [DashboardSceneItemID]?
    @Published private(set) var isInteracting = false


    /// 定时缓动时钟：目标动画共用（elapsed / duration → easeInOutCubic），到点即 `isFinished`，
    /// 结束那一帧的进度恰为 1，终值不必再单独写一次。
    private struct Tween {
        let durationMilliseconds: Double
        var elapsedMilliseconds = 0.0

        var isFinished: Bool { elapsedMilliseconds >= durationMilliseconds }

        mutating func advance(by deltaMilliseconds: Double) -> Double {
            elapsedMilliseconds = min(durationMilliseconds, elapsedMilliseconds + deltaMilliseconds)
            let unit = elapsedMilliseconds / durationMilliseconds
            return unit < 0.5 ? 4 * unit * unit * unit : 1 - pow(-2 * unit + 2, 3) / 2
        }
    }

    private struct FocusAnimation {
        let id: DashboardSceneItemID
        let from: Double
        let to: Double
        var tween = Tween(durationMilliseconds: 420)
    }

    /// 双击空白「还原为竖直」的过渡：拧度从当前值缓动到 0、螺距缓动回默认值（用户裁定：要有动画，不能瞬间还原）。
    private struct HelixResetAnimation {
        let fromGain: Double
        let fromSpacing: Double
        let toSpacing: Double
        var tween = Tween(durationMilliseconds: 480)
    }

    private struct HelixGeometryKey: Equatable {
        let cardWidth: Double
        let cardHeight: Double
        let sceneWidth: Double
        let sceneHeight: Double
        let tiltDegrees: Double
    }

    private let frameDriver = DashboardDisplayLinkDriver()
    private var lastFrameTimestamp: CFTimeInterval?

    private var positionVelocity = 0.0
    private var tiltVelocity = 0.0
    private var spacingVelocity = 0.0
    private var coilVelocity = 0.0
    private var focusAnimation: FocusAnimation?
    private var helixResetAnimation: HelixResetAnimation?
    private var pendingExpansionID: DashboardSceneItemID?

    private var dragLayout: DashboardSceneLayout?
    private var dragOrigin: CGPoint?
    private var dragAxis: DashboardSceneAxis?
    private var samples: [DashboardSceneDragSample] = []

    private var reorder = DashboardReorderState()
    private var reorderBaselineIDs: [DashboardSceneItemID]?
    private var reorderDomain: DashboardReorderDomain?

    private var collapsedCardSize: CGSize = .zero
    private var collapsedSceneSize: CGSize = .zero
    private var cachedGeometryKey: HelixGeometryKey?
    private var cachedMinimumSpacing = 0.0
    private var cachedMaximumSpacing = 0.0
    private var hasAppliedDefaultSpacing = false
    private var hasAppliedLaunchCoilGain = false

    var selectedID: DashboardSceneItemID? {
        guard let first = orderedIDs.first else { return nil }
        let roundedPosition = position.isFinite ? position.rounded() : 0
        let count = Double(orderedIDs.count)
        var remainder = roundedPosition.truncatingRemainder(dividingBy: count)
        if remainder < 0 {
            remainder += count
        }
        guard let index = Int(exactly: remainder), orderedIDs.indices.contains(index) else {
            return first
        }
        return orderedIDs[index]
    }

    func reconcile(ids: [DashboardSceneItemID], preferredID: DashboardSceneItemID? = nil) {
        guard Set(ids).count == ids.count else {
            cancelInteraction()
            return
        }
        let priorSelection = selectedID
        guard ids != orderedIDs else { return }
        cancelInteraction()
        let fallback = DashboardSceneMath.reconciledSelection(
            current: priorSelection,
            old: orderedIDs,
            new: ids
        )
        let resolved: DashboardSceneItemID?
        if let priorSelection, ids.contains(priorSelection) {
            resolved = priorSelection
        } else if let preferredID, ids.contains(preferredID) {
            resolved = preferredID
        } else {
            resolved = fallback
        }

        orderedIDs = ids
        reorderPreview = nil

        guard let resolved, let index = ids.firstIndex(of: resolved) else {
            position = 0
            expandedID = nil
            pendingExpansionID = nil
            return
        }

        addPosition(
            DashboardSceneMath.shortestOffset(
                itemIndex: index,
                position: position,
                count: ids.count
            )
        )
        if expandedID.map({ !ids.contains($0) }) == true {
            expandedID = nil
        }
        if pendingExpansionID.map({ !ids.contains($0) }) == true {
            pendingExpansionID = nil
        }
    }

    func focus(id: DashboardSceneItemID, reduceMotion: Bool) {
        guard expandedID == nil else { return }
        installFocus(id: id, expandAfterFocus: false, reduceMotion: reduceMotion)
    }

    func toggleExpansion(for id: DashboardSceneItemID, canExpand: Bool, reduceMotion: Bool) {
        if expandedID == id {
            expandedID = nil
            return
        }
        guard expandedID == nil, canExpand else { return }
        installFocus(id: id, expandAfterFocus: true, reduceMotion: reduceMotion)
    }

    func collapseAndFocus(_ id: DashboardSceneItemID, reduceMotion: Bool) {
        expandedID = nil
        cancelReorder()
        stopMotion(clearTargets: true)
        installFocus(id: id, expandAfterFocus: false, reduceMotion: reduceMotion)
    }

    func handle(
        _ event: DashboardSceneGestureEvent,
        layout: DashboardSceneLayout,
        sceneSize _: CGSize,
        reduceMotion: Bool
    ) {
        guard expandedID == nil else { return }

        switch event {
        case let .dragBegan(location, _):
            beginDrag(location: location, layout: layout)
        case let .dragChanged(delta, location, timestamp):
            changeDrag(delta: delta, location: location, timestamp: timestamp)
        case let .dragEnded(_, timestamp):
            endDrag(timestamp: timestamp, reduceMotion: reduceMotion)
        case .tap, .reorderBegan, .reorderChanged, .reorderEnded, .cancelled:
            break
        }
    }

    func updateGeometry(cardSize: CGSize, sceneSize: CGSize) {
        guard cardSize.width.isFinite, cardSize.height.isFinite,
              sceneSize.width.isFinite, sceneSize.height.isFinite,
              cardSize.width > 0, cardSize.height > 0,
              sceneSize.width > 0, sceneSize.height > 0
        else { return }

        collapsedCardSize = cardSize
        collapsedSceneSize = sceneSize
        refreshHelixGeometryCache()
        clampBaseSpacingToCachedBounds()
    }

    /// 横向拖 260pt = 线圈半径增益 ±1。
    private static let pointsPerCoilGain = 260.0

    /// 螺旋还原为竖直（双击空白 / 无障碍动作）：拧度归 0 成一列竖线，螺距回默认值（倾斜固定不动）。
    /// 用户裁定：双击不是回到默认拧度，而是竖直；且要缓动过去（`helixResetAnimation`），减弱动态时才瞬间到位。
    func resetHelix(reduceMotion: Bool) {
        guard expandedID == nil else { return }
        spacingVelocity = 0
        coilVelocity = 0
        tiltVelocity = 0
        helixResetAnimation = nil
        let targetSpacing = clampedBaseSpacing(defaultSpacing)
        if reduceMotion {
            setCoilGain(0)
            setSpacing(targetSpacing)
            restartFrameDriverIfNeeded()
            return
        }
        helixResetAnimation = HelixResetAnimation(fromGain: coilGain, fromSpacing: spacing, toSpacing: targetSpacing)
        restartFrameDriver()
    }

    /// 第一次拿到卡片尺寸时把螺距设成按卡高等比的默认值。
    func applyDefaultSpacingIfNeeded() {
        guard !hasAppliedDefaultSpacing, collapsedCardSize.height > 0 else { return }
        hasAppliedDefaultSpacing = true
        setSpacing(defaultSpacing)
    }

    private var defaultSpacing: Double {
        DashboardSceneMath.helixDefaultSpacing(cardHeight: Double(collapsedCardSize.height))
    }

    /// `--helix-coil-gain` 启动参数：首次出现时以指定拧度启动（模拟器截图验证用），越界值夹在范围内。
    func applyLaunchCoilGainIfNeeded(_ value: Double?) {
        guard let value, !hasAppliedLaunchCoilGain else { return }
        hasAppliedLaunchCoilGain = true
        setCoilGain(value)
    }

    private func setCoilGain(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(
            DashboardSceneMath.helixCoilGainRange.upperBound,
            max(DashboardSceneMath.helixCoilGainRange.lowerBound, value)
        )
        if coilGain != clamped {
            coilGain = clamped
        }
    }

    func beginReorder(id: DashboardSceneItemID) {
        guard expandedID == nil,
              !reorder.isActive,
              Set(orderedIDs).count == orderedIDs.count,
              let sourceIndex = orderedIDs.firstIndex(of: id)
        else { return }

        let domain = id.domain
        let matchingIndices = orderedIDs.indices.filter { orderedIDs[$0].domain == domain }
        guard matchingIndices.count >= 2,
              let first = matchingIndices.first, let last = matchingIndices.last,
              matchingIndices.count == last - first + 1
        else { return }

        stopMotion(clearTargets: true)
        clearDrag()
        isInteracting = false

        let domainRange = first..<(last + 1)
        reorder.begin(sourceIndex: sourceIndex, domain: domainRange)
        guard reorder.isActive else { return }

        addPosition(
            DashboardSceneMath.shortestOffset(
                itemIndex: sourceIndex,
                position: position,
                count: orderedIDs.count
            )
        )
        reorderBaselineIDs = orderedIDs
        reorderDomain = domain
        reorderPreview = orderedIDs
        isInteracting = true
    }

    func updateReorder(secondFingerDeltaY: CGFloat) {
        guard expandedID == nil, reorder.isActive,
              reorderBaselineIDs == orderedIDs
        else { return }
        _ = reorder.update(
            secondFingerDeltaY: Double(secondFingerDeltaY),
            pointsPerSlot: 64
        )
        reorderPreview = reorder.previewOrder(orderedIDs)
    }

    func finishReorder() -> DashboardReorderCommit? {
        guard reorder.isActive else { return nil }

        let preview = reorderPreview
        let baseline = reorderBaselineIDs
        let domain = reorderDomain
        let completion = reorder.primaryEnded()
        reorderPreview = nil
        reorderBaselineIDs = nil
        reorderDomain = nil
        isInteracting = false

        guard case .commit = completion,
              let preview, let baseline, let domain,
              baseline == orderedIDs,
              preview.count == orderedIDs.count,
              Set(preview).count == preview.count,
              Set(preview) == Set(orderedIDs)
        else { return nil }

        let baselineDomainIDs = orderedIDs.filter { $0.domain == domain }
        let committedDomainIDs = preview.filter { $0.domain == domain }
        guard committedDomainIDs.count == baselineDomainIDs.count,
              Set(committedDomainIDs) == Set(baselineDomainIDs),
              preview.filter({ $0.domain != domain }) == orderedIDs.filter({ $0.domain != domain })
        else { return nil }

        let stableSelection = selectedID
        orderedIDs = preview
        if let stableSelection, let index = orderedIDs.firstIndex(of: stableSelection) {
            addPosition(
                DashboardSceneMath.shortestOffset(
                    itemIndex: index,
                    position: position,
                    count: orderedIDs.count
                )
            )
        }
        return DashboardReorderCommit(orderedIDs: committedDomainIDs, domain: domain)
    }

    func accessibilityAdjustSelection(by direction: Int) {
        guard direction == (-1) || direction == 1,
              !orderedIDs.isEmpty,
              let selectedID,
              let selectedIndex = orderedIDs.firstIndex(of: selectedID)
        else { return }
        let targetIndex = DashboardSceneMath.wrappedIndex(
            selectedIndex + direction,
            count: orderedIDs.count
        )
        collapseAndFocus(orderedIDs[targetIndex], reduceMotion: true)
    }

    func canAccessibilityMoveSelected(by direction: Int) -> Bool {
        guard expandedID == nil,
              !reorder.isActive,
              Set(orderedIDs).count == orderedIDs.count,
              direction == (-1) || direction == 1,
              let selectedID,
              let sourceIndex = orderedIDs.firstIndex(of: selectedID)
        else { return false }

        let matchingIndices = orderedIDs.indices.filter {
            orderedIDs[$0].domain == selectedID.domain
        }
        guard let first = matchingIndices.first, let last = matchingIndices.last,
              matchingIndices.count >= 2,
              matchingIndices.count == last - first + 1
        else { return false }
        let targetIndex = sourceIndex + direction
        return matchingIndices.contains(targetIndex)
    }

    func accessibilityMoveSelected(by direction: Int) -> DashboardReorderCommit? {
        guard canAccessibilityMoveSelected(by: direction), let selectedID else { return nil }
        beginReorder(id: selectedID)
        updateReorder(secondFingerDeltaY: CGFloat(direction) * 64)
        return finishReorder()
    }

    func cancelInteraction() {
        cancelReorder()
        stopMotion(clearTargets: true)
        clearDrag()
        if orderedIDs.isEmpty {
            setPosition(0)
        } else {
            setPosition(position.rounded())
        }
        isInteracting = false
    }


    private var hasTargetAnimation: Bool {
        focusAnimation != nil || helixResetAnimation != nil
    }

    private var hasActiveMotion: Bool {
        if hasTargetAnimation {
            return true
        }
        if abs(positionVelocity) >= 0.0008 || abs(tiltVelocity) >= 0.0008
            || abs(spacingVelocity) >= 0.004 || abs(coilVelocity) >= 0.00004 {
            return true
        }
        guard !orderedIDs.isEmpty else { return false }
        return abs(position.rounded() - position) >= 0.002
    }

    private func installFocus(
        id: DashboardSceneItemID,
        expandAfterFocus: Bool,
        reduceMotion: Bool
    ) {
        guard let index = orderedIDs.firstIndex(of: id) else { return }

        cancelReorder()
        stopMotion(clearTargets: true)
        clearDrag()
        isInteracting = false
        let offset = DashboardSceneMath.shortestOffset(
            itemIndex: index,
            position: position,
            count: orderedIDs.count
        )
        let target = positionAdding(offset)
        pendingExpansionID = expandAfterFocus ? id : nil

        if reduceMotion || abs(target - position) < 0.002 {
            setPosition(target)
            focusAnimation = nil
            completePendingExpansion(at: id)
            return
        }

        focusAnimation = FocusAnimation(
            id: id,
            from: position,
            to: target)
        restartFrameDriver()
    }

    private func completePendingExpansion(at id: DashboardSceneItemID) {
        guard pendingExpansionID == id, selectedID == id else {
            pendingExpansionID = nil
            return
        }
        pendingExpansionID = nil
        expandedID = id
    }

    private func beginDrag(location: CGPoint, layout: DashboardSceneLayout) {
        guard orderedIDs.count > 1 else {
            cancelInteraction()
            return
        }
        cancelReorder()
        stopMotion(clearTargets: true)
        clearDrag()
        dragLayout = layout
        dragOrigin = location
        dragAxis = layout == .roulette ? .vertical : nil
        isInteracting = true
    }

    private func changeDrag(delta: CGSize, location: CGPoint, timestamp: TimeInterval) {
        guard isInteracting, let dragLayout, dragOrigin != nil else { return }
        defer {
            recordSample(location: location, timestamp: timestamp)
        }
        guard delta.width.isFinite, delta.height.isFinite,
              location.x.isFinite, location.y.isFinite
        else { return }

        switch dragLayout {
        case .roulette:
            if orderedIDs.count > 1 {
                addPosition(-Double(delta.height) / 132)
            }
        case .helix:
            if dragAxis == nil, let dragOrigin {
                let dx = Double(location.x - dragOrigin.x)
                let dy = Double(location.y - dragOrigin.y)
                // 斜向不再单独当「调螺距」手势（在屏幕角落一拖就把卡片拉稀，用户当 bug 报）：归到占优的那条轴
                if case .spacing = DashboardSceneMath.classifyAxis(dx: dx, dy: dy) {
                    dragAxis = abs(dy) >= abs(dx) ? .vertical : .horizontal
                } else {
                    dragAxis = DashboardSceneMath.classifyAxis(dx: dx, dy: dy)
                }
            }
            guard let dragAxis else { return }
            switch dragAxis {
            case .vertical:
                if orderedIDs.count > 1 {
                    addPosition(-Double(delta.height) / 64)
                }
            case .horizontal:
                // 横向 = 拉大 / 缩小线圈半径（后方卡片沿更大的圆弧远去）；倾斜固定在线圈段尽头
                setCoilGain(coilGain + Double(delta.width) / Self.pointsPerCoilGain)
            case .spacing:
                break
            }
        }
    }

    private func recordSample(location: CGPoint, timestamp: TimeInterval) {
        guard location.x.isFinite, location.y.isFinite, timestamp.isFinite else { return }
        samples.append(
            DashboardSceneDragSample(
                x: Double(location.x),
                y: Double(location.y),
                timestamp: timestamp
            )
        )
        if samples.count > 8 {
            samples.removeFirst(samples.count - 8)
        }
    }

    private func endDrag(timestamp: TimeInterval, reduceMotion: Bool) {
        guard isInteracting, let layout = dragLayout else { return }
        let axis = dragAxis
        let releaseVelocity = sampledReleaseVelocity(at: timestamp)
        clearDrag()
        isInteracting = false

        guard !reduceMotion else {
            positionVelocity = 0
            tiltVelocity = 0
            spacingVelocity = 0
            coilVelocity = 0
            setPosition(orderedIDs.isEmpty ? 0 : position.rounded())
            frameDriver.stop()
            lastFrameTimestamp = nil
            return
        }

        switch layout {
        case .roulette:
            positionVelocity = orderedIDs.count > 1 ? -releaseVelocity.height / 132 : 0
        case .helix:
            switch axis {
            case .vertical:
                positionVelocity = orderedIDs.count > 1 ? -releaseVelocity.height / 64 : 0
            case .horizontal:
                coilVelocity = releaseVelocity.width / Self.pointsPerCoilGain
            case .spacing, nil:
                break
            }
        }
        restartFrameDriverIfNeeded()
    }

    private func sampledReleaseVelocity(at timestamp: TimeInterval) -> (width: Double, height: Double) {
        let velocity = DashboardSceneMath.sampledVelocity(
            samples: samples,
            releaseTimestamp: timestamp
        )
        return (velocity.x, velocity.y)
    }

    private func clearDrag() {
        dragLayout = nil
        dragOrigin = nil
        dragAxis = nil
        samples.removeAll(keepingCapacity: true)
    }

    private func cancelReorder() {
        if reorder.isActive {
            _ = reorder.cancel()
        }
        reorderPreview = nil
        reorderBaselineIDs = nil
        reorderDomain = nil
        isInteracting = dragLayout != nil
    }

    private func stopMotion(clearTargets: Bool) {
        frameDriver.stop()
        lastFrameTimestamp = nil
        positionVelocity = 0
        tiltVelocity = 0
        spacingVelocity = 0
        coilVelocity = 0
        if clearTargets {
            focusAnimation = nil
            helixResetAnimation = nil
            pendingExpansionID = nil
        }
    }

    private func restartFrameDriverIfNeeded() {
        guard hasActiveMotion else {
            frameDriver.stop()
            lastFrameTimestamp = nil
            return
        }
        restartFrameDriver()
    }

    private func restartFrameDriver() {
        frameDriver.stop()
        lastFrameTimestamp = nil
        frameDriver.start { [weak self] timestamp in
            self?.step(timestamp: timestamp) ?? false
        }
    }

    private func step(timestamp: CFTimeInterval) -> Bool {
        guard timestamp.isFinite else { return hasActiveMotion }
        guard let previous = lastFrameTimestamp else {
            lastFrameTimestamp = timestamp
            return hasActiveMotion
        }
        lastFrameTimestamp = timestamp
        let animationDeltaMilliseconds = max(0, (timestamp - previous) * 1000)
        let deltaMilliseconds = min(32, animationDeltaMilliseconds)
        guard animationDeltaMilliseconds > 0 else { return hasActiveMotion }

        let hadTargetAnimation = hasTargetAnimation
        stepFocus(deltaMilliseconds: animationDeltaMilliseconds)
        stepHelixReset(deltaMilliseconds: animationDeltaMilliseconds)
        if !hadTargetAnimation {
            stepVelocity(deltaMilliseconds: deltaMilliseconds)
            snapPosition(deltaMilliseconds: deltaMilliseconds)
        }

        let keepRunning = hasActiveMotion
        if !keepRunning {
            lastFrameTimestamp = nil
        }
        return keepRunning
    }

    private func stepFocus(deltaMilliseconds: Double) {
        guard var animation = focusAnimation else { return }
        guard orderedIDs.contains(animation.id) else {
            focusAnimation = nil
            pendingExpansionID = nil
            return
        }
        let eased = animation.tween.advance(by: deltaMilliseconds)
        setPosition(DashboardSceneMath.lerp(animation.from, animation.to, eased))
        if animation.tween.isFinished {
            focusAnimation = nil
            completePendingExpansion(at: animation.id)
        } else {
            focusAnimation = animation
        }
    }

    /// 「还原为竖直」逐帧：拧度与螺距走同一条缓动曲线。
    private func stepHelixReset(deltaMilliseconds: Double) {
        guard var animation = helixResetAnimation else { return }
        let eased = animation.tween.advance(by: deltaMilliseconds)
        setCoilGain(DashboardSceneMath.lerp(animation.fromGain, 0, eased))
        setSpacing(DashboardSceneMath.lerp(animation.fromSpacing, animation.toSpacing, eased))
        helixResetAnimation = animation.tween.isFinished ? nil : animation
    }

    private func stepVelocity(deltaMilliseconds: Double) {
        if abs(positionVelocity) >= 0.0008 {
            addPosition(positionVelocity * deltaMilliseconds)
            positionVelocity = DashboardSceneMath.stepVelocity(
                positionVelocity,
                deltaMilliseconds: deltaMilliseconds,
                friction: 0.9
            )
        }
        if abs(positionVelocity) < 0.0008 {
            positionVelocity = 0
        }

        if abs(tiltVelocity) >= 0.0008 {
            let priorTilt = tiltDegrees
            setTilt(tiltDegrees + tiltVelocity * deltaMilliseconds)
            tiltVelocity = DashboardSceneMath.stepVelocity(
                tiltVelocity,
                deltaMilliseconds: deltaMilliseconds,
                friction: 0.88
            )
            if tiltDegrees == priorTilt {
                tiltVelocity = 0
            }
        }
        if abs(tiltVelocity) < 0.0008 {
            tiltVelocity = 0
        }

        if abs(spacingVelocity) >= 0.004 {
            let priorSpacing = spacing
            setSpacing(spacing + spacingVelocity * deltaMilliseconds)
            spacingVelocity = DashboardSceneMath.stepVelocity(
                spacingVelocity,
                deltaMilliseconds: deltaMilliseconds,
                friction: 0.9
            )
            if spacing == priorSpacing {
                spacingVelocity = 0
            }
        }
        if abs(spacingVelocity) < 0.004 {
            spacingVelocity = 0
        }

        if abs(coilVelocity) >= 0.00004 {
            let priorGain = coilGain
            setCoilGain(coilGain + coilVelocity * deltaMilliseconds)
            coilVelocity = DashboardSceneMath.stepVelocity(
                coilVelocity,
                deltaMilliseconds: deltaMilliseconds,
                friction: 0.9
            )
            if coilGain == priorGain {
                coilVelocity = 0
            }
        }
        if abs(coilVelocity) < 0.00004 {
            coilVelocity = 0
        }
    }

    private func snapPosition(deltaMilliseconds: Double) {
        guard positionVelocity == 0, !orderedIDs.isEmpty else {
            if orderedIDs.isEmpty { setPosition(0) }
            return
        }
        let diff = position.rounded() - position
        if abs(diff) < 0.002 {
            setPosition(position.rounded())
            return
        }
        let ease = min(1, max(0.12, 1 - pow(0.86, deltaMilliseconds / 16)))
        addPosition(diff * ease)
    }

    private func setTilt(_ value: Double) {
        guard value.isFinite else { return }
        tiltDegrees = min(
            DashboardSceneMath.helixCoilTiltRange.upperBound,
            max(DashboardSceneMath.helixCoilTiltRange.lowerBound, value)
        )
        refreshHelixGeometryCache()
    }

    private func setSpacing(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = clampedBaseSpacing(value)
        if spacing != clamped {
            spacing = clamped
        }
        refreshEffectiveSpacing()
    }

    private func clampBaseSpacingToCachedBounds() {
        let clamped = clampedBaseSpacing(spacing)
        if spacing != clamped {
            spacing = clamped
        }
        refreshEffectiveSpacing()
    }

    private func clampedBaseSpacing(_ value: Double) -> Double {
        guard cachedMaximumSpacing > 0 else { return max(0, value) }
        return min(cachedMaximumSpacing, max(cachedMinimumSpacing, value))
    }

    private func refreshHelixGeometryCache() {
        let key = HelixGeometryKey(
            cardWidth: Double(collapsedCardSize.width),
            cardHeight: Double(collapsedCardSize.height),
            sceneWidth: Double(collapsedSceneSize.width),
            sceneHeight: Double(collapsedSceneSize.height),
            tiltDegrees: tiltDegrees
        )
        guard key.cardWidth > 0, key.cardHeight > 0,
              key.sceneWidth > 0, key.sceneHeight > 0
        else {
            refreshEffectiveSpacing()
            return
        }
        guard key != cachedGeometryKey else {
            refreshEffectiveSpacing()
            return
        }

        cachedGeometryKey = key
        cachedMinimumSpacing = DashboardSceneMath.minimumHelixSpacing(
            cardWidth: key.cardWidth,
            cardHeight: key.cardHeight,
            sceneWidth: key.sceneWidth,
            tiltDegrees: key.tiltDegrees
        ) * DashboardSceneMath.helixCollisionRelaxation
        cachedMaximumSpacing = DashboardSceneMath.maximumHelixSpacing(
            minimum: cachedMinimumSpacing,
            cardHeight: key.cardHeight,
            sceneHeight: key.sceneHeight
        )
        refreshEffectiveSpacing()
    }

    private func refreshEffectiveSpacing() {
        effectiveSpacing = DashboardSceneMath.effectiveHelixSpacing(
            spacing: spacing,
            minimum: cachedMinimumSpacing,
            tiltDegrees: tiltDegrees
        )
    }

    private func setPosition(_ value: Double) {
        position = value.isFinite ? value : 0
    }

    private func addPosition(_ delta: Double) {
        setPosition(positionAdding(delta))
    }

    private func positionAdding(_ delta: Double) -> Double {
        let base = position.isFinite ? position : 0
        guard delta.isFinite else { return base }
        let candidate = base + delta
        return candidate.isFinite ? candidate : base
    }

}

@MainActor
final class DashboardDisplayLinkDriver {
    @MainActor
    private final class Target: NSObject {
        let callback: @MainActor (CFTimeInterval) -> Void

        init(callback: @escaping @MainActor (CFTimeInterval) -> Void) {
            self.callback = callback
        }

        @objc func fire(_ link: CADisplayLink) {
            callback(link.timestamp)
        }
    }

    private var displayLink: CADisplayLink?
    private var target: Target?
    private var tick: (@MainActor (CFTimeInterval) -> Bool)?

    deinit {
        displayLink?.invalidate()
    }

    func start(tick: @escaping @MainActor (CFTimeInterval) -> Bool) {
        guard displayLink == nil else { return }
        self.tick = tick
        let target = Target { [weak self] time in
            guard let self else { return }
            if self.tick?(time) != true {
                self.stop()
            }
        }
        self.target = target
        let link = CADisplayLink(target: target, selector: #selector(Target.fire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        target = nil
        tick = nil
    }
}

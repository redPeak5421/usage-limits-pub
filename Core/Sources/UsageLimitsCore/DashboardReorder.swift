import Foundation

public enum DashboardSceneItemID: Hashable, Sendable {
    case account(UUID)
    case demo(ProviderID)

    public var domain: DashboardReorderDomain {
        switch self {
        case .account:
            return .accounts
        case .demo:
            return .demoProviders
        }
    }
}

public enum DashboardReorderDomain: Equatable, Sendable {
    case accounts
    case demoProviders
}

public enum DashboardReorderCompletion: Equatable, Sendable {
    case none
    case commit(sourceIndex: Int, targetIndex: Int)
    case rollback
}

public struct DashboardReorderState: Equatable, Sendable {
    public private(set) var sourceIndex: Int?
    public private(set) var targetIndex: Int?
    public private(set) var domain: Range<Int> = 0..<0

    public init() {}

    public var isActive: Bool {
        sourceIndex != nil
    }

    public mutating func begin(sourceIndex: Int, domain: Range<Int>) {
        guard domain.contains(sourceIndex) else { return }
        self.sourceIndex = sourceIndex
        targetIndex = sourceIndex
        self.domain = domain
    }

    @discardableResult
    public mutating func update(secondFingerDeltaY: Double, pointsPerSlot: Double) -> Int? {
        guard
            let sourceIndex,
            secondFingerDeltaY.isFinite,
            pointsPerSlot.isFinite,
            pointsPerSlot > 0,
            !domain.isEmpty
        else {
            return nil
        }

        let slotOffset = (secondFingerDeltaY / pointsPerSlot).rounded()
        guard slotOffset.isFinite else { return nil }

        let lowerTarget = domain.lowerBound
        let upperTarget = domain.upperBound - 1
        let proposed: Int
        if let offset = Int(exactly: slotOffset) {
            let (sum, overflowed) = sourceIndex.addingReportingOverflow(offset)
            proposed = overflowed ? (offset < 0 ? lowerTarget : upperTarget) : sum
        } else {
            proposed = slotOffset < 0 ? lowerTarget : upperTarget
        }

        targetIndex = min(max(proposed, lowerTarget), upperTarget)
        return targetIndex
    }

    public mutating func primaryEnded() -> DashboardReorderCompletion {
        guard let sourceIndex, let targetIndex else { return .none }
        clear()
        return .commit(sourceIndex: sourceIndex, targetIndex: targetIndex)
    }

    public mutating func cancel() -> DashboardReorderCompletion {
        guard isActive else { return .none }
        clear()
        return .rollback
    }

    public func previewOrder(_ items: [DashboardSceneItemID]) -> [DashboardSceneItemID] {
        guard
            let sourceIndex,
            let targetIndex,
            items.indices.contains(sourceIndex),
            items.indices.contains(targetIndex),
            sourceIndex != targetIndex
        else {
            return items
        }

        var preview = items
        let item = preview.remove(at: sourceIndex)
        preview.insert(item, at: targetIndex)
        return preview
    }

    private mutating func clear() {
        sourceIndex = nil
        targetIndex = nil
        domain = 0..<0
    }
}

/// 平铺首页的容器级拖动：按指针 Y 与各卡中线决定插到谁前面，带滞回避免中线抖动。
public enum DragReorder {
    public enum Decision: Equatable {
        case none
        case before(UUID)
        case toEnd
    }

    /// `cards` = 当前可见卡（含被拖卡）按 midY 升序；`band` = 中线两侧滞回带（pt）。
    public static func decision(
        pointerY: Double,
        cards: [(id: UUID, midY: Double)],
        dragging: UUID,
        band: Double = 6
    ) -> Decision {
        guard let current = cards.firstIndex(where: { $0.id == dragging }) else { return .none }
        let others = cards.filter { $0.id != dragging }
        if others.isEmpty { return .none }
        let desired = others.firstIndex { pointerY < $0.midY } ?? others.count
        if desired == current { return .none }
        if desired > current {
            guard pointerY > others[desired - 1].midY + band else { return .none }
            return desired == others.count ? .toEnd : .before(others[desired].id)
        }
        guard pointerY < others[desired].midY - band else { return .none }
        return .before(others[desired].id)
    }
}

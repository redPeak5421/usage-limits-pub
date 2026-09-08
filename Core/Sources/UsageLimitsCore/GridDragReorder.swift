import Foundation

/// 平铺首页多列布局的容器级拖动判定：只吃数值几何，不依赖 SwiftUI / UIKit，
/// 返回值与单列的 `DragReorder.Decision` 同一套契约（插到 target 之前 / 移至末尾）。
public enum GridDragReorder {
    /// 一张已测量的卡片。坐标空间与指针一致（平铺首页用 `dashboardList` 命名空间）。
    public struct Card: Equatable, Sendable {
        public let id: UUID
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(id: UUID, x: Double, y: Double, width: Double, height: Double) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var minX: Double { min(x, x + width) }
        var maxX: Double { max(x, x + width) }
        var minY: Double { min(y, y + height) }
        var maxY: Double { max(y, y + height) }
        var midX: Double { minX + (maxX - minX) / 2 }
        var midY: Double { minY + (maxY - minY) / 2 }

        func contains(pointerX: Double, pointerY: Double) -> Bool {
            pointerX >= minX && pointerX < maxX && pointerY >= minY && pointerY < maxY
        }

        func squaredDistance(pointerX: Double, pointerY: Double) -> Double {
            let dx = midX - pointerX
            let dy = midY - pointerY
            return dx * dx + dy * dy
        }
    }

    /// `cards` 已按账号显示顺序排序，只含已测量的账号，且包含被拖卡。
    ///
    /// 先取指针落在哪张卡（都没落中就取中心最近的一张），再看指针在这张卡的
    /// 上方 / 下方 / 左半 / 右半，决定插到它前面还是后面。`horizontalBand` 是横向中线两侧的
    /// 滞回带，指针停在中线附近时不换位，避免来回抖。
    ///
    /// regular 宽度不等于多列：iPad mini 竖屏、Stage Manager 600–765pt 的窗口都只排得下一列。
    /// 那时参考卡这一行只有它自己，左右半没有意义——往下拖到下一张卡的左半边会被判成
    /// 「插到它前面」，卡片纹丝不动。所以先看参考卡在同一行有没有邻居：没有就退回单列口径
    /// （指针 y 与参考卡 midY 比大小，`verticalBand` 是中线滞回带，与 `DragReorder.decision`
    /// 的 6pt 一致），有才用左右半。
    ///
    /// 同行判断必须把**被拖卡也算进几何**：两列各一张卡时，参考卡唯一的同行邻居就是被拖卡，
    /// 把它排除掉会误判成单列，于是左卡拖到右卡右半区一直返回 `.none`（卡片拖不动）。
    /// 排除被拖卡只用于生成目标插入顺序。
        public static func decision(
        pointerX: Double,
        pointerY: Double,
        cards: [Card],
        dragging: UUID,
        horizontalBand: Double = 8,
        verticalBand: Double = 6
    ) -> DragReorder.Decision {
        guard let currentIndex = cards.firstIndex(where: { $0.id == dragging }) else { return .none }
        let others = cards.filter { $0.id != dragging }
        guard !others.isEmpty else { return .none }
        // 上一次判定已经把被拖卡挪到指针底下时，重放同一指针不该再动：否则参考卡会退化成
        // 斜对角的邻居，顺序继续往后滑一格。
        if cards[currentIndex].contains(pointerX: pointerX, pointerY: pointerY) { return .none }
        let reference = others.first { $0.contains(pointerX: pointerX, pointerY: pointerY) }
            ?? others.min {
                $0.squaredDistance(pointerX: pointerX, pointerY: pointerY)
                    < $1.squaredDistance(pointerX: pointerX, pointerY: pointerY)
            }
        guard let reference,
              let referenceIndex = others.firstIndex(where: { $0.id == reference.id })
        else { return .none }

        // 同行邻居 = 与参考卡纵向区间正重叠、且横向落在另一列的卡（含被拖卡）。
        // 一张都没有说明这一行只排得下参考卡自己。卡间的纵向间距不算重叠；
        // 同列的卡横向完全重叠，不算同行。
        let hasRowNeighbour = cards.contains { candidate in
            candidate.id != reference.id
                && Self.overlaps(candidate.minY, candidate.maxY, reference.minY, reference.maxY)
                && Self.isDifferentColumn(candidate, reference)
        }

        let insertsBefore: Bool
        if pointerY < reference.minY {
            insertsBefore = true
        } else if pointerY > reference.maxY {
            insertsBefore = false
        } else if !hasRowNeighbour {
            if abs(pointerY - reference.midY) < verticalBand { return .none }
            insertsBefore = pointerY < reference.midY
        } else if abs(pointerX - reference.midX) < horizontalBand {
            return .none
        } else {
            insertsBefore = pointerX < reference.midX
        }

        let desired = insertsBefore ? referenceIndex : referenceIndex + 1
        guard desired != currentIndex else { return .none }
        return desired >= others.count ? .toEnd : .before(others[desired].id)
    }

    /// 两段区间有正长度的重叠（只挨着不算）。
    private static func overlaps(_ lowerA: Double, _ upperA: Double, _ lowerB: Double, _ upperB: Double) -> Bool {
        min(upperA, upperB) - max(lowerA, lowerB) > 0
    }

    /// 横向重叠不到较窄一张的一半就算不同列。网格各列本就互不相交，留这点余量是为了
    /// 容忍布局取整；同列的卡横向完全重叠，稳稳判成同列。
    private static func isDifferentColumn(_ lhs: Card, _ rhs: Card) -> Bool {
        let overlapX = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        let narrower = min(lhs.maxX - lhs.minX, rhs.maxX - rhs.minX)
        return overlapX < narrower / 2
    }
}

import CoreGraphics
import Foundation

/// 分享预览的滚动锚点：记住视口中心那张卡，以及它顶边离视口顶边多远。
public struct SharePreviewAnchor: Equatable, Sendable {
    /// 锚点卡片在旧模型里的下标；改选择集后按 `key` 找不回时用它兜底。
    public let index: Int
    /// 卡片标题。同一批卡重排后按名字认人，比下标可靠。
    public let key: String
    /// 卡片顶边相对视口顶边的距离（画布 pt）。负值表示顶边已经滚出屏幕上方。
    public let topInViewport: CGFloat

    public init(index: Int, key: String, topInViewport: CGFloat) {
        self.index = index
        self.key = key
        self.topInViewport = topInViewport
    }
}

/// 切「明细」这类开关会整体改写画布高度。若始终以画布顶边为原点，
/// 实例一多，正在看的那张卡就会被上方卡片的伸缩推出屏幕。
/// 这里把视口中心那张卡定为原点，重排后让它回到同一屏幕位置，上下各自伸缩。
///
/// 全部按画布坐标（pt，未经预览缩放）计算，调用方自己按缩放比换算。
public enum SharePreviewScroll {

    /// 视口垂直中心落在哪张卡上。没有卡片时返回 nil。
    public static func anchor(
        in model: ShareCardModel,
        offset: CGFloat,
        viewportHeight: CGFloat
    ) -> SharePreviewAnchor? {
        let tops = ShareLayout.sectionTops(of: model)
        guard !tops.isEmpty else { return nil }
        let center = offset + viewportHeight / 2
        // 中心还在首卡上方（顶部留白里）时也认首卡，避免没有锚点可用。
        var index = 0
        for (i, top) in tops.enumerated() where top <= center { index = i }
        return SharePreviewAnchor(
            index: index,
            key: model.sections[index].providerName,
            topInViewport: tops[index] - offset
        )
    }

    /// 让锚点卡片回到同一屏幕位置所需的新滚动偏移；越界就夹到可滚范围内。
    ///
    /// `slack` 是画布上下各自的额外留白（画布 pt）。预览在画布外还包了一圈内边距，
    /// 顶到底时视口顶边其实在画布顶边之上，不把这段算进可滚范围，
    /// 停在最顶上时来回换算会凭空多滚出一个留白的距离。
    public static func restoredOffset(
        for anchor: SharePreviewAnchor?,
        in model: ShareCardModel,
        viewportHeight: CGFloat,
        slack: CGFloat = 0
    ) -> CGFloat {
        let tops = ShareLayout.sectionTops(of: model)
        guard let anchor, !tops.isEmpty else { return -slack }
        let index = model.sections.firstIndex { $0.providerName == anchor.key }
            ?? min(max(anchor.index, 0), tops.count - 1)
        let maxOffset = max(ShareLayout.canvasHeight(of: model) - viewportHeight + slack, -slack)
        return min(max(tops[index] - anchor.topInViewport, -slack), maxOffset)
    }
}

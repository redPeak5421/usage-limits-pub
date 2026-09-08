import Foundation

/// 平铺首页在多列 / 单列容器之间切换时的阅读位置锚点。
///
/// `LazyVGrid` 与 `LazyVStack` 是两个不同的容器，窗口宽度跨过 regular / compact 时整段内容
/// 被销毁重建，`ScrollView` 的偏移量归零——2026-09-08 在 iPad Air 11 M4 实测：两列滚到中部再
/// 缩窄窗口，首页直接弹回第一张卡。偏移量本身不能沿用（两列的 y 和单列的 y 不是一回事），
/// 所以记的是「当前压在视口顶边的那张卡」，切完容器再滚回这张卡。
public enum DashboardScrollAnchor {
    /// 一张卡相对视口顶边的位置。坐标以视口左上角为原点，往下为正。
    public enum CardPosition: Equatable, Sendable {
        /// 整张卡都在顶边下方：还没滚到它。
        case below
        /// 压在顶边上：这就是当前正在读的那张。
        case straddlingTop
        /// 整张卡都滚过顶边了。
        case above
    }

    public static func position(minY: Double, maxY: Double) -> CardPosition {
        if minY > 0 { return .below }
        if maxY > 0 { return .straddlingTop }
        return .above
    }

    /// 某张卡上报新位置后，锚点应该变成什么。
    ///
    /// - 压在顶边的卡就是锚点。多列时同一行会有两张卡同时压住顶边，谁后上报都行：同一行滚回去
    ///   的落点一样。
    /// - 列表滚到最顶时没有任何卡压住顶边，此时首张卡会上报 `.below`：把锚点清空，恢复时就让
    ///   系统保持在顶部，横幅和空态提示不会被顶出视口。
    /// - 其余情况保持原样，避免滚动过程中反复写状态。
    public static func updated(
        anchor: DashboardSceneItemID?,
        card: DashboardSceneItemID,
        position: CardPosition,
        isFirstItem: Bool
    ) -> DashboardSceneItemID? {
        switch position {
        case .straddlingTop:
            return card
        case .below where isFirstItem:
            return nil
        case .below, .above:
            return anchor
        }
    }
}

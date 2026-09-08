import SwiftUI

/// 设置类页面在 regular 宽度（iPad 全屏 / 横屏 / 2:1 分屏、Max 机型横屏）下的可读栏宽。
///
/// Form / List 默认铺满容器，iPad 上一行会横跨整块屏：标题在最左、开关甩到最右，眼睛要扫过 1000pt。
/// 这里把内容收进一条固定宽度的中间栏并居中，两侧铺同色底，观感与系统「设置」一致。
///
/// `content` 只能出现在**唯一一条结构路径**上，宽度靠环境值改数、不靠 if / else 换分支：
/// `@ViewBuilder` 的分支会生成 `_ConditionalContent`，窗口宽度跨过 regular / compact 时整棵子树
/// 被销毁重建，`List` 的滚动位置、`@FocusState`、子视图 `@State` 全部回到初始值。
/// 2026-09-08 在 iPad Air 11 M4（窗口化 App）实测：分支写法下把服务商列表滚到中部再缩窄窗口，
/// 列表直接弹回顶部。只有背景可以条件化——它不含 `content`，重建不丢状态。
struct ReadableWidthModifier: ViewModifier {
    /// 一行文字 / 一条设置项的舒适上限；再宽两端控件就会脱节。
    static let defaultMaxWidth: CGFloat = 700

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let maxWidth: CGFloat
    /// 收窄后两侧露出的底色。父级已经自带底色（或本身就在 ScrollView 里）时传 nil，避免盖住原背景。
    let background: Color?

    private var isRegular: Bool { horizontalSizeClass == .regular }

    func body(content: Content) -> some View {
        content
            // compact 下放开到 .infinity：与收窄前一样铺满容器，只是多了两个不改尺寸的布局节点。
            .frame(maxWidth: isRegular ? maxWidth : .infinity)
            .frame(maxWidth: .infinity)
            .background(alignment: .center) {
                if isRegular, let background {
                    background.ignoresSafeArea()
                }
            }
    }
}

extension View {
    /// regular 宽度下把内容收进可读栏宽并居中；compact 宽度铺满容器，与收窄前一致。
    func readableWidth(
        maxWidth: CGFloat = ReadableWidthModifier.defaultMaxWidth,
        background: Color? = Color(.systemGroupedBackground)
    ) -> some View {
        modifier(ReadableWidthModifier(maxWidth: maxWidth, background: background))
    }
}

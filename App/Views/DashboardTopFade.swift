import SwiftUI

/// 首页顶栏的渐进磨砂：最顶部边缘（状态栏区域）保持不透明，往下过渡成半透明磨砂，
/// 到导航栏底边完全透明。三种首页主题共用；系统顶栏底色隐藏，由它接管。
struct DashboardTopFade: View {
    /// 顶边的不透明底色（平铺用系统分组背景色，场景用主题页面底色）。
    let solid: Color
    /// 状态栏 + 导航栏的总高度（取自内容的顶部安全区）。
    let totalHeight: CGFloat

    static let navigationBarHeight: CGFloat = 44

    var body: some View {
        // 状态栏区域全不透明；导航栏区域从磨砂过渡到透明
        let opaqueHeight = max(0, totalHeight - Self.navigationBarHeight)
        let opaqueStop = totalHeight > 0 ? opaqueHeight / totalHeight : 0
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: opaqueStop),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            solid
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: opaqueStop),
                            .init(color: .clear, location: min(1, opaqueStop + 0.45)),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .frame(height: totalHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// 隐藏系统顶栏底色，用渐进磨砂盖住状态栏 + 导航栏区域（挂在首页内容上）。
    func dashboardTopFade(solid: Color) -> some View {
        modifier(DashboardTopFadeModifier(solid: solid))
    }

    /// iOS 26 的滚动边缘效果与自绘渐进磨砂会叠两层，平铺列表上关掉系统那层。
    func dashboardHidesSystemScrollEdgeEffect() -> some View {
        modifier(DashboardHideScrollEdgeEffect())
    }
}

private struct DashboardTopFadeModifier: ViewModifier {
    let solid: Color

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .overlay(alignment: .top) {
                    DashboardTopFade(solid: solid, totalHeight: proxy.safeAreaInsets.top)
                        .frame(maxWidth: .infinity)
                        .ignoresSafeArea(edges: .top)
                }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct DashboardHideScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

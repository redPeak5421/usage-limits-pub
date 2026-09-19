import SwiftUI

struct EmptyStateGlowBackdrop: View {
    /// 光的唯一色相；外晕与内核同色，只差浓度。
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    /// 由中心到边缘的相对浓度：(1 − t²)²，两端斜率为零，边缘平滑落到全透明，看不出轮廓。
    private static let falloff: [(location: CGFloat, weight: Double)] = [
        (0.0, 1.0),
        (0.2, 0.922),
        (0.4, 0.706),
        (0.6, 0.410),
        (0.8, 0.130),
        (1.0, 0.0),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // 外晕：比按钮组更宽更高，铺满两颗胶囊并向外渐隐；横向拉长，纵向收着，不大片盖住标题与页脚。
                glow(peak: colorScheme == .dark ? 0.30 : 0.22)
                    .frame(width: size.width * 1.5, height: size.height * 1.7)
                // 内核：同色相、更小更浓，压在无色玻璃的次按钮背后，给它透出的颜色一点纵深。
                glow(peak: colorScheme == .dark ? 0.14 : 0.10)
                    .frame(width: size.width * 0.95, height: size.height * 0.75)
            }
            // 中心略低于按钮组正中：着色的主按钮自己有颜色，光主要给下面那颗无色玻璃折射。
            .position(x: size.width / 2, y: size.height * 0.58)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 一层椭圆渐变：中心 `peak`，按 `falloff` 渐隐到同色相的全透明（不插值到 `.clear`，免得边缘发灰）。
    private func glow(peak: Double) -> some View {
        EllipticalGradient(
            stops: Self.falloff.map { Gradient.Stop(color: tint.opacity(peak * $0.weight), location: $0.location) },
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
    }
}

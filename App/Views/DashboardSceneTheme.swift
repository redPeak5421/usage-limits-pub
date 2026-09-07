import SwiftUI
import UsageLimitsCore

enum DashboardSceneTheme: Equatable {
    case atelierVault
    case nightReel

    /// 场景配色只看深浅色：浅色用 Atelier Vault 色板，深色用 Night Reel 色板；布局另由 `DashboardSceneLayout` 决定。
    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .nightReel : .atelierVault
    }

    var pageBackground: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#F2F1EE")
        case .nightReel: Color(brandTintHex: "#070709")
        }
    }

    var pageDepth: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#E7E5E0")
        case .nightReel: Color(brandTintHex: "#101014")
        }
    }

    var primaryForeground: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#2C2A26")
        case .nightReel: Color(brandTintHex: "#F3F4F6")
        }
    }

    var secondaryForeground: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#6A6660")
        case .nightReel: Color(brandTintHex: "#9AA0A8")
        }
    }

    var metalAccent: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#8A6D45")
        case .nightReel: Color(brandTintHex: "#F3F4F6")
        }
    }

    var surfaceBase: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#E7E5E0")
        case .nightReel: Color(brandTintHex: "#101014")
        }
    }

    var surfaceHighlight: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#F2F1EE")
        case .nightReel: Color(brandTintHex: "#F3F4F6")
        }
    }

    var surfaceShadow: Color {
        switch self {
        case .atelierVault: Color(brandTintHex: "#2C2A26")
        case .nightReel: Color(brandTintHex: "#070709")
        }
    }

    var isDark: Bool {
        self == .nightReel
    }
}

/// 首页场景布局：轮盘（card-roulette）/ 螺旋（glass-helix）。平铺没有场景，返回 nil。
/// 两种布局在浅色 / 深色下都可用，配色由 `DashboardSceneTheme` 按外观设置给。
enum DashboardSceneLayout: Equatable {
    case roulette
    case helix

    init?(preference: DashboardTheme) {
        switch preference {
        case .flat: return nil
        case .roulette: self = .roulette
        case .helix: self = .helix
        }
    }
}

struct DashboardSceneBackground: View {
    let theme: DashboardSceneTheme

    var body: some View {
        ZStack {
            theme.pageBackground

            LinearGradient(
                colors: [
                    theme.pageDepth.opacity(theme.isDark ? 0.96 : 0.82),
                    theme.pageBackground.opacity(0.92),
                    theme.pageDepth.opacity(theme.isDark ? 0.72 : 0.5),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    theme.surfaceHighlight.opacity(theme.isDark ? 0.08 : 0.45),
                    theme.pageBackground.opacity(0),
                ],
                center: .topLeading,
                startRadius: 8,
                endRadius: 520
            )

            RadialGradient(
                colors: [
                    theme.metalAccent.opacity(theme.isDark ? 0.04 : 0.1),
                    theme.pageBackground.opacity(0),
                ],
                center: .bottomTrailing,
                startRadius: 12,
                endRadius: 440
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 场景装饰。轮盘没有任何装饰（右侧黄铜指针已删：它不可点、还会压住展开的卡片）；
/// 螺旋只保留紧凑光晕（两条边缘导轨已删：在真机上像一圈线框），并且始终画在卡片之下。
struct DashboardSceneChrome: View {
    let theme: DashboardSceneTheme
    let layout: DashboardSceneLayout
    let tint: BrandTint?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if layout == .helix {
            let haloColor = tint.map { Color(brandTintHex: $0.startHex) } ?? theme.metalAccent
            GeometryReader { proxy in
                ZStack {
                    if !reduceTransparency {
                        RadialGradient(
                            colors: [
                                haloColor.opacity(0.14),
                                theme.pageBackground.opacity(0),
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: min(proxy.size.width, proxy.size.height) * 0.32
                        )
                        .frame(
                            width: min(proxy.size.width * 0.72, 280),
                            height: min(proxy.size.height * 0.38, 210)
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// 卡片底面：保持 App 原有的系统默认卡面（浅色白、深色黑），不取主题 case 的色板；
/// 品牌色只由卡片内容（标签、按钮、用量条）承载。
struct DashboardCardSurface: View {
    let theme: DashboardSceneTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        ZStack {
            // 参考主题的层间投影（0 16px 36px rgba(0,0,0,.42)）：让每一层都从下一层上抬起来。
            shape.fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: theme.surfaceShadow.opacity(
                        reduceTransparency ? 0 : (theme.isDark ? 0.6 : 0.34)
                    ),
                    radius: theme.isDark ? 18 : 16,
                    y: theme.isDark ? 10 : 10
                )

            // Reduce Transparency：两种外观都改用更实的描边分离卡片，不靠阴影。
            shape.strokeBorder(
                reduceTransparency
                    ? theme.primaryForeground.opacity(0.7)
                    : (theme.isDark
                        ? theme.surfaceHighlight.opacity(0.14)
                        : theme.surfaceShadow.opacity(0.1)),
                lineWidth: reduceTransparency ? 2 : 1
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 邻卡变暗：参考主题用 `filter: brightness(0.32 + fade * 0.68)`；在白 / 黑卡面上直接减亮度会发灰，
/// 改为按同一曲线覆盖一层墨色，得到暖调的"退到阴影里"，而不是脏灰。`amount = 1 - brightness`。
struct DashboardCardDim: View {
    let theme: DashboardSceneTheme
    let amount: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.surfaceShadow.opacity(min(max(amount, 0), 1) * 0.85))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

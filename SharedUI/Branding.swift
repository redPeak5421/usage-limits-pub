import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UsageLimitsCore

// iPhone App、小组件、手表 App 三端共同编译的品牌与环境基础件。

/// 显示语言注入：各端根视图写入，所有视图经 @Environment 读取。
/// 默认值兜底读本进程可见的存储（小组件进程无根注入时也能拿到正确语言）。
private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = SharedStore.shared.appLanguage
}

/// 百分比展示口径注入（已用 / 剩余）：与语言同一套路，各端根视图写入。
private struct UsageDisplayModeKey: EnvironmentKey {
    static let defaultValue: UsageDisplayMode = SharedStore.shared.usageDisplayMode
}

/// 重置时间展示口径注入（倒计时 / 具体时刻）。
private struct ResetTimeStyleKey: EnvironmentKey {
    static let defaultValue: ResetTimeStyle = SharedStore.shared.resetTimeStyle
}

public extension EnvironmentValues {
    var resetTimeStyle: ResetTimeStyle {
        get { self[ResetTimeStyleKey.self] }
        set { self[ResetTimeStyleKey.self] = newValue }
    }

    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }

    var usageDisplayMode: UsageDisplayMode {
        get { self[UsageDisplayModeKey.self] }
        set { self[UsageDisplayModeKey.self] = newValue }
    }
}

public extension Color {
    /// `#RRGGBB` → Color；非法回落中灰。
    init(brandTintHex hex: String) {
        let rgb = BrandTint.rgb(fromHex: hex) ?? .init(red: 128, green: 128, blue: 128)
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}

public extension BrandTint {
    var startColor: Color { Color(brandTintHex: startHex) }
    var endColor: Color { Color(brandTintHex: endHex ?? startHex) }

    /// 标签胶囊底：渐变=实底左→右（按胶囊完整宽度）；纯色=15% 淡底。
    var badgeFill: LinearGradient {
        if isGradient {
            return LinearGradient(
                colors: [startColor, endColor], startPoint: .leading, endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [startColor.opacity(0.15), startColor.opacity(0.15)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// 渐变实底配白字（MiniMax 官网样式）；纯色淡底配同色字。
    var badgeForeground: Color { isGradient ? .white : startColor }

    /// 按钮着色、图表线等单色场景的代表色。
    var representativeColor: Color { startColor }

    var barFill: LinearGradient {
        LinearGradient(colors: [startColor, endColor], startPoint: .leading, endPoint: .trailing)
    }

    /// 色点/色卡：纯色实底；渐变对角过渡（不做 15% 淡化，忠实显示当前色）。
    var swatchFill: LinearGradient {
        LinearGradient(
            colors: [startColor, endColor],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// 各服务商纯图形商标（无文字）。单色标在深浅色下跟随前景色。
/// 自定义模板图标：有图用落盘字节，否则链环占位。
struct CustomTemplateLogo: View {
    let data: Data?
    var size: CGFloat = 16
    var fallbackTint: Color = .secondary

    var body: some View {
        Group {
            if let data, let image = Self.platformImage(data) {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(fallbackTint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #else
        return nil
        #endif
    }
}

struct CatalogMark: View {
    let assetName: String
    var size: CGFloat = 16

    var body: some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ProviderLogo: View {
    let provider: ProviderID
    var size: CGFloat = 16

    var body: some View {
        CatalogMark(assetName: provider.logoAssetName, size: size)
    }
}

func usageLevelColor(_ percent: Double?) -> Color {
    switch UsagePresentation.riskLevel(for: percent) {
    case .unknown: return .secondary
    case .low: return .green
    case .medium: return .orange
    case .high: return .red
    }
}

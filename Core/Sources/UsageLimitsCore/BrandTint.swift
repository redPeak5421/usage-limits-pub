import CoreGraphics
import Foundation

/// 品牌主题色：纯色或双色线性渐变。hex 存储，App / 小组件 / 手表 / 分享图统一取色。
///
/// 渐变的方向约定：标签胶囊与用量条都按**元素完整长度**从左到右均匀过渡；
/// 用量条的已用部分相当于「揭开」渐变前段（颜色位置固定，进度增长时平滑延伸），
/// 不按已用长度压缩——否则低进度会把首尾两色挤进一小截，色差爆炸。
public struct BrandTint: Codable, Equatable, Sendable {
    /// 起始色 `#RRGGBB`。
    public var startHex: String
    /// 结束色；nil 即纯色。
    public var endHex: String?

    public init(startHex: String, endHex: String? = nil) {
        self.startHex = startHex
        self.endHex = endHex
    }

    public var isGradient: Bool {
        guard let endHex else { return false }
        return !endHex.isEmpty && endHex.caseInsensitiveCompare(startHex) != .orderedSame
    }

    // MARK: hex ↔ RGB

    /// 0–255 整数分量。
    public struct RGB: Equatable, Sendable {
        public var red: Int
        public var green: Int
        public var blue: Int

        public init(red: Int, green: Int, blue: Int) {
            self.red = min(max(red, 0), 255)
            self.green = min(max(green, 0), 255)
            self.blue = min(max(blue, 0), 255)
        }
    }

    /// 解析 `#RRGGBB` / `RRGGBB`（大小写均可）；长度或字符非法返回 nil。
    public static func rgb(fromHex hex: String) -> RGB? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: text).scanHexInt64(&value) else { return nil }
        return RGB(
            red: Int((value >> 16) & 0xFF),
            green: Int((value >> 8) & 0xFF),
            blue: Int(value & 0xFF)
        )
    }

    public static func hexString(_ rgb: RGB) -> String {
        String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    /// 规范化：合法则统一成大写 `#RRGGBB`，非法返回 nil。
    public static func normalized(hex: String) -> String? {
        rgb(fromHex: hex).map(hexString)
    }

    // MARK: CGColor（分享图 CoreGraphics 渲染用）

    public var startCGColor: CGColor { Self.cgColor(hex: startHex) }
    public var endCGColor: CGColor { Self.cgColor(hex: endHex ?? startHex) }

    static func cgColor(hex: String) -> CGColor {
        let rgb = rgb(fromHex: hex) ?? RGB(red: 128, green: 128, blue: 128)
        return CGColor(
            srgbRed: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }
}

public extension ProviderID {
    /// 内置品牌主题色（与各家 2026 现行商标对齐；MiniMax 为官网渐变粉→珊瑚）。
    /// Grok 官方是黑白极简、无彩色，用石板灰作深色模式可见的代理色。
    var builtinTint: BrandTint {
        switch self {
        case .claude: return BrandTint(startHex: "#D97757")
        case .openai: return BrandTint(startHex: "#10A37F")
        case .grok: return BrandTint(startHex: "#616B80")
        case .cursor: return BrandTint(startHex: "#F54E00")
        case .deepseek: return BrandTint(startHex: "#4D6BFE")
        case .zhipu: return BrandTint(startHex: "#6C63FF")
        case .kimi: return BrandTint(startHex: "#007CFF")
        case .minimax: return BrandTint(startHex: "#E21680", endHex: "#FF633A")
        case .jimeng: return BrandTint(startHex: "#7C3AED")
        // OpenCode 商标是黑白方括号，取图标内格的中性灰作代理色。
        case .opencode: return BrandTint(startHex: "#5A5858")
        // 2026-08 新增：按各家官网主色；纯黑白商标（Notion / Ollama / Augment）用深灰代理色。
        case .longcat: return BrandTint(startHex: "#FFC300")
        case .mimo: return BrandTint(startHex: "#FF6900")
        case .qoder: return BrandTint(startHex: "#5B5CE6")
        case .perplexity: return BrandTint(startHex: "#20808D")
        case .augment: return BrandTint(startHex: "#3C3C3C")
        case .abacus: return BrandTint(startHex: "#2E6FF2")
        case .t3chat: return BrandTint(startHex: "#D23F8F")
        case .notion: return BrandTint(startHex: "#37352F")
        case .ollama: return BrandTint(startHex: "#4A4A4A")
        case .stepfun: return BrandTint(startHex: "#0052D9")
        case .copilot: return BrandTint(startHex: "#24292F")
        case .gemini: return BrandTint(startHex: "#3184F9")
        case .antigravity: return BrandTint(startHex: "#3184F9")
        case .kiro: return BrandTint(startHex: "#9046FF")
        // 国际站与国内站同一品牌；不做渐变，避免两张卡视觉完全相同难以区分。
        case .minimaxGlobal: return BrandTint(startHex: "#E21680")
        }
    }
}

/// 三层回落：账号自定义 → 供应商默认覆盖 → 内置品牌色。纯函数，可单测。
public enum TintResolver {
    /// 自定义账号默认色（与 Grok 代理灰同值，但禁止走 `.grok` 解析器）。
    public static let customDefault = BrandTint(startHex: "#616B80")

    public static func resolve(
        accountTint: BrandTint?,
        provider: ProviderID,
        overrides: [String: BrandTint]
    ) -> BrandTint {
        accountTint ?? overrides[provider.rawValue] ?? provider.builtinTint
    }

    /// 自定义账号：账号 tint → 模板默认色 → 内置灰。不吃 `ProviderID`。
    public static func resolve(accountTint: BrandTint?, templateTint: BrandTint? = nil) -> BrandTint {
        accountTint ?? templateTint ?? customDefault
    }

    /// 表端主号环没有账号对象：把主号账号色叠进供应商覆盖表。附加账号仍走自己的 `account.tint`。
    public static func watchProviderOverrides(
        providerOverrides: [String: BrandTint],
        accounts: [ProviderAccount]
    ) -> [String: BrandTint] {
        var map = providerOverrides
        for account in accounts where account.isPrimary {
            if let tint = account.tint, let provider = account.provider {
                map[provider.rawValue] = tint
            }
        }
        return map
    }
}

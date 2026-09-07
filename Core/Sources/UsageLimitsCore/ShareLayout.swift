import CoreGraphics
import Foundation

/// 分享画布的几何常量与高度算式。
///
/// 预览、导出共用同一棵 SwiftUI 视图树，这里是那棵树的尺寸依据；
/// 放在 Core 是为了让画布高度、行距这类会回归的数字能被单测直接盯住。
/// 配色与光晕在 App 侧以扩展补齐（需要 SwiftUI）。
public enum ShareLayout {

    public static let canvasWidth: CGFloat = 390
    public static let margin: CGFloat = 16
    public static let padding: CGFloat = 16
    public static let shellCorner: CGFloat = 24
    public static let cardCorner: CGFloat = 16
    public static let cardInset: CGFloat = 16
    public static let sectionGap: CGFloat = 10

    public static let headerHeight: CGFloat = 22
    public static let logoSize: CGFloat = 18
    public static let badgeHeight: CGFloat = 16
    public static let badgeFontSize: CGFloat = 11
    public static let badgePadding: CGFloat = 6
    public static let badgeSpacing: CGFloat = 6
    /// 胶囊高 16pt，另留 4pt 才不会贴住首条指标。
    public static let planRowHeight: CGFloat = badgeHeight + 4

    public static let labelHeight: CGFloat = 16
    public static let meterHeight: CGFloat = 36
    public static let labelOnlyHeight: CGFloat = 20
    public static let barHeight: CGFloat = 6
    public static let barOffsetY: CGFloat = 18
    public static let captionTextHeight: CGFloat = 12
    public static let captionLift: CGFloat = 8
    public static let updateHeight: CGFloat = 14
    /// 卡片底部余量：`cardH` 的 26 计到标题行、绘制起点却是 +38，差额落在末尾。
    public static func cardBottomSlack(hasUpdate: Bool) -> CGFloat { hasUpdate ? 6 : 4 }

    public static let brandHeight: CGFloat = 108
    public static let brandTopGap: CGFloat = 12
    public static let brandIcon: CGFloat = 56
    public static let brandQR: CGFloat = 72
    public static let scanGap: CGFloat = 10
    public static let scanHeight: CGFloat = 18


    public static func captionAdvance(hasBar: Bool) -> CGFloat { hasBar ? 14 : 22 }

    public static func metersHeight(_ meters: [ShareMeter]) -> CGFloat {
        if meters.isEmpty { return meterHeight }
        return meters.reduce(0) { total, meter in
            let hasBar = meter.usedPercent != nil
            return total + (hasBar ? meterHeight : labelOnlyHeight)
                + (meter.hasCaption ? captionAdvance(hasBar: hasBar) : 0)
        }
    }

    public static func cardHeight(_ section: ShareCardModel.Section) -> CGFloat {
        26 + (section.planBadges.isEmpty ? 0 : planRowHeight)
            + metersHeight(section.meters) + 16
            + (section.updateTime != nil ? 16 : 0)
    }

    /// 画布总高。导出图的像素高 = 它 × `ShareCanvasRenderer.scale`。
    public static func canvasHeight(of model: ShareCardModel) -> CGFloat {
        let body = model.sections.reduce(0) { $0 + cardHeight($1) }
            + CGFloat(max(model.sections.count - 1, 0)) * sectionGap
        let brand = model.brandAtBottom ? brandTopGap + brandHeight + scanGap + scanHeight : 0
        let shell = padding + body + brand + padding
        return model.topSafeReserve + margin + shell + margin
    }
}

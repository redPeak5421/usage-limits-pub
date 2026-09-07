import CoreGraphics
import Foundation
@testable import UsageLimitsCore

/// 分享图的绘制已经搬到 App 侧的 SwiftUI 视图（预览与导出同一棵树），
/// Core 只负责结构化内容与几何。这里保留老 `compose` 的调用形状，
/// 让原有断言继续盯着「画什么」和「多高」，不必逐条改写。
struct ComposedShare {
    let model: ShareCardModel

    var options: ShareComposeOptions { model.options }
    /// 画布高度（pt）。老断言里比较 `image.height` 的，改比这个。
    var canvasHeight: CGFloat { ShareLayout.canvasHeight(of: model) }
    var canvasWidth: CGFloat { ShareLayout.canvasWidth }
}

extension ShareImageComposer {
    static func compose(
        snapshots: [ProviderSnapshot],
        titles: [String] = [],
        tints: [BrandTint?] = [],
        expanded: Bool,
        language: AppLanguage,
        icon: CGImage? = nil,
        qr: CGImage? = nil,
        options: ShareComposeOptions = ShareComposeOptions(),
        logos: [ProviderID: CGImage] = [:],
        customMark: CGImage? = nil,
        customMarks: [CGImage?] = [],
        displayMode: UsageDisplayMode = .used,
        resetTimeStyle: ResetTimeStyle = .countdown,
        now: Date = Date()
    ) -> ComposedShare {
        let showBrand = !options.hideBrandRow
        return ComposedShare(model: model(
            snapshots: snapshots,
            expanded: expanded,
            language: language,
            // 老入口按「有没有拿到位图」决定，测试里不传就当作有，行为与 App 一致。
            hasIcon: showBrand,
            hasQR: showBrand,
            options: options,
            logoProviders: logos.isEmpty ? Set(ProviderID.allCases) : Set(logos.keys),
            titles: titles,
            tints: tints,
            displayMode: displayMode,
            resetTimeStyle: resetTimeStyle,
            now: now
        ))
    }
}

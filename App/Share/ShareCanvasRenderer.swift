import SwiftUI
import UIKit
import UsageLimitsCore

/// 把 `ShareCardView` 渲成分享用的 PNG。
///
/// 预览与导出走同一棵视图树：预览里看到的就是分享出去的那张图，不存在两套布局漂移。
/// 只在真正要分享 / 保存那一刻调用一次，平时切选项不产生任何位图。
@MainActor
enum ShareCanvasRenderer {
    /// 分享图按 3 倍图导出，与老渲染器的画布倍率一致。
    static let scale: CGFloat = 3

    static func render(
        model: ShareCardModel,
        assets: ShareCardAssets,
        lang: AppLanguage
    ) -> Data? {
        let renderer = ImageRenderer(content: ShareCardView(model: model, assets: assets, lang: lang))
        renderer.scale = scale
        // 分享图始终是浅色画布，不跟随系统外观。
        renderer.isOpaque = true
        // 全局分享十几张卡时画布高达一万三千像素，`uiImage` 会因内部纹理上限直接返回 nil；
        // 改成自己开位图上下文再让 SwiftUI 往里画，尺寸只受内存限制。
        var rendered: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let pixelWidth = Int((size.width * scale).rounded())
            let pixelHeight = Int((size.height * scale).rounded())
            guard pixelWidth > 0, pixelHeight > 0,
                  let context = CGContext(
                      data: nil,
                      width: pixelWidth,
                      height: pixelHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.scaleBy(x: scale, y: scale)
            draw(context)
            rendered = context.makeImage()
        }
        return rendered.flatMap { UIImage(cgImage: $0).pngData() }
    }
}

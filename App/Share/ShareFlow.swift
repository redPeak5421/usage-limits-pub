import Photos
import SwiftUI
import UIKit
import UsageLimitsCore

/// 一次分享请求：首页目录 + 当前勾选。预览改选项或改多选后可重新合成。
struct ShareRequest: Identifiable {
    let id = UUID()
    /// 首页全部可见实例，供「编辑」多选。
    let catalog: [ShareCardInput]
    /// 当前勾选的实例 id（账号 UUID 或演示橱窗 id）。
    let selectedIDs: Set<String>
    let expanded: Bool
    let isGlobal: Bool
    /// 打开预览时的初始内容；位图留到分享 / 保存那一刻才渲。
    let model: ShareCardModel
}

/// 保存到相册 + 直接唤起微信 + 系统分享（「分享」）。
enum ShareFlow {
    /// 分享画布的结构化内容。预览只要它，切选项不生成任何位图。
    static func model(
        snapshots: [ProviderSnapshot],
        titles: [String] = [],
        tints: [BrandTint?] = [],
        expanded: Bool,
        language: AppLanguage,
        options: ShareComposeOptions = SharedStore.shared.shareComposeOptions,
        displayMode: UsageDisplayMode = SharedStore.shared.usageDisplayMode,
        resetTimeStyle: ResetTimeStyle = SharedStore.shared.resetTimeStyle
    ) -> ShareCardModel {
        ShareImageComposer.model(
            snapshots: snapshots,
            expanded: expanded,
            language: language,
            hasIcon: !options.hideBrandRow,
            hasQR: !options.hideBrandRow,
            options: options,
            logoProviders: Set(ProviderID.allCases),
            titles: titles,
            tints: tints,
            displayMode: displayMode,
            resetTimeStyle: resetTimeStyle
        )
    }

    /// 真正要分享 / 保存时才合成一次 PNG，渲染的正是预览那棵视图树。
    @MainActor
    static func compose(
        snapshots: [ProviderSnapshot],
        titles: [String] = [],
        tints: [BrandTint?] = [],
        expanded: Bool,
        language: AppLanguage,
        options: ShareComposeOptions = SharedStore.shared.shareComposeOptions,
        customLogos: [Data?] = [],
        displayMode: UsageDisplayMode = SharedStore.shared.usageDisplayMode,
        resetTimeStyle: ResetTimeStyle = SharedStore.shared.resetTimeStyle
    ) -> Data? {
        let card = model(
            snapshots: snapshots, titles: titles, tints: tints, expanded: expanded,
            language: language, options: options,
            displayMode: displayMode, resetTimeStyle: resetTimeStyle
        )
        return ShareCanvasRenderer.render(
            model: card,
            assets: ShareCardAssets.make(customLogoData: customLogos),
            lang: language
        )
    }

    static var isWeChatInstalled: Bool {
        UIApplication.shared.canOpenURL(ShareChrome.weixinURL)
    }

    /// 微信功能深链（weixin://dl/*）已全部废弃，无 OpenSDK 时：
    /// - 发送给朋友：走系统分享面板的微信扩展。扩展内存配额远低于前台 App，
    ///   传临时文件 URL（而非 UIImage/Data）最稳，微信拿到即进选人页。
    /// - 朋友圈：扩展不支持发布朋友圈，只能存相册后引导用户手动选图。
    static func temporaryImageFile(_ pngData: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-limits-share-\(UUID().uuidString.prefix(8)).png")
        do {
            try pngData.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 朋友圈准备工作：存相册（发布时从相册选）+ 复制到剪贴板（聊天里也可直接粘贴）。
    @MainActor
    static func prepareForMoments(_ pngData: Data) async throws {
        if let image = UIImage(data: pngData) {
            UIPasteboard.general.image = image
        }
        try await saveToPhotos(pngData)
    }

    /// 打开微信首页（深链废弃后能到达的最深入口）。
    @MainActor
    static func openWeChat() {
        UIApplication.shared.open(ShareChrome.weixinURL)
    }

    @MainActor
    static func saveToPhotos(_ pngData: Data) async throws {
        guard let image = UIImage(data: pngData) else {
            throw ShareError.invalidImage
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ShareError.photoDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    enum ShareError: Error {
        case invalidImage
        case photoDenied
    }
}

/// 系统分享面板：「分享」入口用，载荷是合成图。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

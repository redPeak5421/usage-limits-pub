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
///
/// iPhone 上 `UIActivityViewController` 是半屏卡片，iPad 上是 popover：没有
/// `popoverPresentationController.sourceView` / `sourceRect` 就会在呈现瞬间抛
/// NSInternalInconsistencyException 崩掉。所以这里不把它当成 SwiftUI 的 sheet 内容，
/// 而是挂一个空的宿主控制器，由宿主自己 present 并把锚点设成自身正中、无箭头。
struct ActivityShareSheet: UIViewControllerRepresentable {
    /// nil / 空数组 = 不呈现；赋值即请求呈现一次。
    let items: [Any]?
    /// 面板关掉（完成或取消）后回调，调用方据此把 items 清回 nil。
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> ActivityAnchorController {
        let controller = ActivityAnchorController()
        controller.onFinish = onFinish
        controller.request(items: items)
        return controller
    }

    func updateUIViewController(_ uiViewController: ActivityAnchorController, context: Context) {
        uiViewController.onFinish = onFinish
        uiViewController.request(items: items)
    }
}

/// 分享面板的宿主：只负责给 iPad popover 一个合法锚点，自身不画任何东西。
final class ActivityAnchorController: UIViewController {
    var onFinish: () -> Void = {}
    private var pending: [Any]?
    /// 「面板已经在我这儿」的缓存标记。真身是 `presentedViewController`，这个标记只防重复呈现，
    /// 随时可能与真身脱节（见 `syncShowingWithPresentation`），所以每个入口都先校正再判断。
    private var showing = false
    /// 每次新请求配一次重试机会：guard 拦下（祖先正在 present、还没进窗口）时下一轮 runloop 再试一次。
    /// 不做无限重试，避免呈现条件长期不满足时空转主队列。
    private var retryArmed = false

    func request(items: [Any]?) {
        syncShowingWithPresentation()
        guard let items, !items.isEmpty else {
            pending = nil
            retryArmed = false
            return
        }
        pending = items
        retryArmed = true
        presentIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 首次 update 时视图可能还没进窗口，进窗口后补一次。
        presentIfPossible()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 自己离屏时面板必然不在了；标记留在 true 会把本页的分享锁死。
        syncShowingWithPresentation()
    }

    /// UIKit 会静默拒绝 present（祖先正在 present、正在转场），这种情况不会走
    /// `completionWithItemsHandler`，`showing` 就永远停在 true，本页此后再也分享不出去。
    /// 拿真身校正：没有被呈现的控制器就说明面板不在，标记复位。
    private func syncShowingWithPresentation() {
        if showing, presentedViewController == nil { showing = false }
    }

    private func scheduleRetry() {
        guard retryArmed, pending != nil else { return }
        retryArmed = false
        DispatchQueue.main.async { [weak self] in self?.presentIfPossible() }
    }

    private func presentIfPossible() {
        syncShowingWithPresentation()
        guard !showing, presentedViewController == nil, view.window != nil,
              let items = pending else {
            scheduleRetry()
            return
        }
        showing = true
        pending = nil
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            // 宿主铺在预览滚动区背后，bounds 非空；退化成零尺寸时退回上层视图，绝不留 nil。
            let host: UIView = view
            let anchor: UIView = host.bounds.isEmpty ? (host.superview ?? host) : host
            popover.sourceView = anchor
            popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.showing = false
            self?.onFinish()
        }
        present(activity, animated: true) { [weak self] in
            // 呈现被拒时真身仍是 nil；就地复位，别把标记留成 true。
            self?.syncShowingWithPresentation()
        }
    }
}

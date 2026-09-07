import MessageUI
import UIKit
import UsageLimitsCore

/// 反馈邮件：由 UIKit 从最上层控制器直接 present `MFMailComposeViewController`，附件在 present 之前挂好。
/// 不走 SwiftUI `.sheet` + `UIViewControllerRepresentable`——那样 MFMailComposeViewController 会被当成子控制器
/// 嵌进 SwiftUI 的承载控制器，远程撰写界面起来后挂的附件会丢（真机 0.2.501 / 0.2.513 两次反馈邮件没有日志附件，DEVLOG #94）。
@MainActor
enum FeedbackMailComposer {
    /// 撰写器展示期间要强持有代理（MFMailComposeViewController 只弱引用它）。
    private static var activeDelegate: Delegate?

    /// 弹出系统邮件撰写器，主题 / 正文按 App 语言本地化；`diagnostics` 非 nil 就作为附件。
    /// `log` 记一行诊断（附件字节数），下次真机反馈能对上证据。
    /// - Returns: 能否 present（设备没配邮件账号、或没有可承载的控制器时 false，调用方按「邮件不可用」提示）。
    static func present(
        language: AppLanguage,
        diagnostics: Data?,
        log: (String) -> Void,
        onFinished: @escaping (_ failed: Bool) -> Void
    ) -> Bool {
        guard MFMailComposeViewController.canSendMail(),
              let presenter = UIApplication.usagelimitsTopViewController
        else { return false }
        let controller = MFMailComposeViewController()
        controller.setToRecipients([FeedbackMailDraft.recipient])
        controller.setSubject(FeedbackMailDraft.subject(for: language))
        controller.setMessageBody(FeedbackMailDraft.body(for: language), isHTML: false)
        if let diagnostics {
            // 必须在 present 之前挂：present 之后再加，撰写界面不会显示
            controller.addAttachmentData(
                diagnostics,
                mimeType: FeedbackMailDraft.attachmentMIMEType,
                fileName: FeedbackMailDraft.attachmentFileName
            )
            log("feedback: attached \(FeedbackMailDraft.attachmentFileName) \(diagnostics.count) bytes")
        }
        let delegate = Delegate { failed in
            activeDelegate = nil
            onFinished(failed)
        }
        controller.mailComposeDelegate = delegate
        activeDelegate = delegate
        presenter.present(controller, animated: true)
        return true
    }

    @MainActor
    private final class Delegate: NSObject, @MainActor MFMailComposeViewControllerDelegate {
        private let onFinished: (Bool) -> Void

        init(onFinished: @escaping (Bool) -> Void) {
            self.onFinished = onFinished
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            let failed = result == .failed || error != nil
            controller.dismiss(animated: true) {
                self.onFinished(failed)
            }
        }
    }
}

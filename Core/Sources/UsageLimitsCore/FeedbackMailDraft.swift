import Foundation

public enum FeedbackMailDraft {
    public static let recipient = "canonforge5421@gmail.com"
    public static let attachmentMIMEType = "text/plain"
    public static let attachmentFileName = "usage-limits-diagnostics.txt"

    /// 主题 / 正文按 App 语言取本地化文案（用户裁定）。
    public static func subject(for language: AppLanguage) -> String {
        L10n.tr("feedback.mail.subject", language)
    }

    public static func body(for language: AppLanguage) -> String {
        L10n.tr("feedback.mail.body", language)
    }

    public static func diagnosticAttachment(from lines: [String]) -> Data {
        let text = lines.isEmpty
            ? "No diagnostic logs recorded.\n"
            : lines.joined(separator: "\n")
        return Data(text.utf8)
    }
}

import Foundation

/// 登录页探测到已有会话时的确认/拒绝决策。与 WKWebView I/O 分离，便于单测喂「探针 ok + 身份」。
public enum LoginConfirm {
    public enum ProbeAction: Equatable, Sendable {
        case wait
        case prompt(accountLabel: String)
    }

    public enum Choice: Equatable, Sendable {
        case accept
        case decline
    }

    public struct Outcome: Equatable, Sendable {
        public var markDetected: Bool
        public var dismissAsSuccess: Bool
        public var suppressFurtherAutoAccept: Bool

        public static func applying(_ choice: Choice) -> Outcome {
            switch choice {
            case .accept:
                return Outcome(markDetected: true, dismissAsSuccess: true, suppressFurtherAutoAccept: false)
            case .decline:
                return Outcome(markDetected: false, dismissAsSuccess: false, suppressFurtherAutoAccept: true)
            }
        }
    }

    /// 站点身份优先；探针没拿到邮箱/用户名时回退到配置的显示名。
    public static func accountLabel(siteIdentity: String?, displayName: String) -> String {
        let trimmed = siteIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? displayName : trimmed
    }

    /// 探针 ok 只弹出确认，不得直接当作登录完成。
    /// `autoPromptSuppressed` 在用户点「否」之后为 true，避免同一会话立刻再被接受。
    public static func action(
        probeOK: Bool,
        alreadyDetected: Bool,
        confirmationVisible: Bool,
        autoPromptSuppressed: Bool,
        siteIdentity: String?,
        displayName: String
    ) -> ProbeAction {
        if alreadyDetected || confirmationVisible || !probeOK { return .wait }
        if autoPromptSuppressed { return .wait }
        return .prompt(accountLabel: accountLabel(siteIdentity: siteIdentity, displayName: displayName))
    }

    /// 点「否」之后：只要当前会话仍是已登录，就继续抑制自动接受；
    /// 探针变为未登录（用户已退出/换号过程中）才解除抑制。
    public static func stillSuppressAutoPrompt(probeOK: Bool, currentlySuppressed: Bool) -> Bool {
        currentlySuppressed && probeOK
    }
}

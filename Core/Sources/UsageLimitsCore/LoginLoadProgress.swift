import Foundation

/// 登录页顶部加载条的状态：把 WKWebView 的 `estimatedProgress` 变成「画多宽 + 显不显示」。
/// 官方站首屏慢时用户原本只看到空白页，这条给出页面确实在加载的反馈。
/// 纯值类型，不依赖 WebKit，可单测；只描述加载进度，与登录态探测互不相干。
public struct LoginLoadProgress: Equatable, Sendable {
    /// 加载条阶段。`finishing` = 已满格，等淡出计时到点。
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case finishing
    }

    /// 起步宽度：WebKit 刚开始导航时 `estimatedProgress` 仍可能是 0，画 0 宽看着像没反应。
    public static let minimumWidth = 0.05
    /// 满格到归零之间的停留时间：登录流程多跳转，立刻消失会一路闪烁。
    public static let hideDelay = Duration.milliseconds(250)

    public private(set) var phase: Phase = .idle
    public private(set) var value: Double = 0

    public init() {}

    public var isVisible: Bool { phase != .idle }

    /// 吃一次 `estimatedProgress`。返回 true 表示这次刚满格，调用方应在 `hideDelay` 之后调 `settle()`。
    @discardableResult
    public mutating func apply(_ raw: Double) -> Bool {
        let clamped = min(max(raw.isFinite ? raw : 0, 0), 1)
        guard clamped < 1 else {
            let wasFinishing = phase == .finishing
            phase = .finishing
            value = 1
            return !wasFinishing
        }
        phase = .loading
        value = max(clamped, Self.minimumWidth)
        return false
    }

    /// 淡出计时到点。期间若又开始新导航（已回到 `loading`）就不归零。
    public mutating func settle() {
        guard phase == .finishing else { return }
        phase = .idle
        value = 0
    }
}

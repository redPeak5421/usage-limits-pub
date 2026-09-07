import Combine
import SwiftUI

public struct CardDecorations: Equatable, Sendable {
    public var refreshGlow: Bool
    public var tintedBars: Bool
    public var barShimmer: Bool

    public static let empty = CardDecorations()

    public init(refreshGlow: Bool = false, tintedBars: Bool = false, barShimmer: Bool = false) {
        self.refreshGlow = refreshGlow
        self.tintedBars = tintedBars
        self.barShimmer = barShimmer
    }
}

public struct UsageBarDecorator {
    public let fill: (Color) -> AnyView
    public init(fill: @escaping (Color) -> AnyView) { self.fill = fill }
}

private struct UsageBarDecoratorKey: EnvironmentKey {
    static let defaultValue: UsageBarDecorator? = nil
}

public extension EnvironmentValues {
    /// 由卡片按 Edition 写入；指标行与自定义卡只认这一个不透明钩子。
    var usageBarDecorator: UsageBarDecorator? {
        get { self[UsageBarDecoratorKey.self] }
        set { self[UsageBarDecoratorKey.self] = newValue }
    }
}

@MainActor
open class Edition: ObservableObject {
    @Published public var pendingRoute: String?

    public init() {}

    open var showsCardEffects: Bool { false }
    open func settingsEntry() -> AnyView? { nil }
    open func appearanceSection() -> AnyView? { nil }
    open func widgetPreviewHeader() -> AnyView? { nil }
    open func cardDecorations() -> CardDecorations { .empty }
    open func refreshGlowOverlay(cornerRadius: CGFloat) -> AnyView? { nil }
    open func usageBarDecorator(tint: BrandTint?, tinted: Bool, shimmer: Bool) -> UsageBarDecorator? { nil }
    open func widgetPreviewRim(cornerRadius: CGFloat) -> AnyView? { nil }
    open func route(_ id: String) -> AnyView? { nil }
    open func handleLaunch(_ args: [String]) {}
    open func onForeground() async {}
}

@MainActor
public final class BaseEdition: Edition {}

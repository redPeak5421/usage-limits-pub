import Foundation

/// 启动参数（模拟器自动化验证用）：`--flag` 与 `--flag <值>` 只在这里解析一次，App / Watch 共用。
public struct LaunchArguments: Sendable {
    private let arguments: [String]

    public init(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.arguments = arguments
    }

    public func contains(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    /// `--flag <值>` 里的值；没有该 flag、或它是最后一个参数时为 nil。
    public func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

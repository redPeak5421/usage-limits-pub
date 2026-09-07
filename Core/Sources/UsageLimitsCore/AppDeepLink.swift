import Foundation

/// App 深链。小组件点进来要定位到它展示的那张卡：
/// - `usagelimits://open/account/<uuid>`：附加账号 / 自定义账号；
/// - `usagelimits://open/<provider>`：内置服务商主账号；
/// - `usagelimits://open`：总览，只打开 App。
/// 旧 `aiusage://` 链接继续兼容，包括系统已缓存的小组件链接。
public enum AppDeepLink: Equatable {
    case home
    case account(UUID)
    case provider(ProviderID)

    public static func accountURL(_ accountID: UUID) -> URL {
        URL(string: "usagelimits://open/account/\(accountID.uuidString)")!
    }

    public static func parse(_ url: URL) -> AppDeepLink? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "usagelimits" || scheme == "aiusage" else { return nil }
        let host = (url.host ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "open", parts.count >= 2, parts[0].lowercased() == "account",
           let id = UUID(uuidString: parts[1]) {
            return .account(id)
        }
        if host == "open", let first = parts.first, let provider = ProviderID(rawValue: first.lowercased()) {
            return .provider(provider)
        }
        if host == "open" || host.isEmpty {
            return .home
        }
        return nil
    }

    /// 首页要定位的场景项：账号链接就是那张账号卡；服务商链接定位该服务商主账号卡（没有主账号退到任一账号卡），
    /// 一个账号都没有时只有演示态才有卡可去（`.demo`）。总览不定位。
    public func revealTarget(accounts: [ProviderAccount], demoMode: Bool) -> DashboardSceneItemID? {
        switch self {
        case .home:
            return nil
        case .account(let id):
            return .account(id)
        case .provider(let provider):
            let account = accounts.first { $0.provider == provider && $0.isPrimary }
                ?? accounts.first { $0.provider == provider }
            if let account { return .account(account.id) }
            return demoMode ? .demo(provider) : nil
        }
    }
}

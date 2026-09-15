import Foundation
import WatchConnectivity
import UsageLimitsCore

/// iPhone 端手表同步：状态变化时把快照 / 启用状态 / 顺序 / 语言整体推送到手表
///（applicationContext 自带去重与后台送达），并接收手表端的服务商开关操作。
/// 载荷只含用量数字与偏好，绝不包含任何凭据。
///
/// `@unchecked Sendable`：可变状态只有两个回调闭包，均在主线程注入一次；
/// WCSession 委托回调里对 self 的使用全部派发回主队列执行。
final class WatchSync: NSObject, @unchecked Sendable {
    static let shared = WatchSync()

    /// 手表端拨动开关时回调（主线程调用；AppState 注入）。
    var onSetEnabled: ((ProviderID, Bool) -> Void)?
    /// 手表端拖动排序时回调（主线程调用；AppState 注入）。
    var onSetOrder: (([ProviderID]) -> Void)?
    /// 手表端按账号拨动开关（主线程调用；AppState 注入）。
    var onSetAccountEnabled: ((UUID, Bool) -> Void)?
    /// 手表端按账号拖动排序（主线程调用；AppState 注入）。
    var onSetAccountOrder: (([UUID]) -> Void)?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 推送当前完整状态。未配对或未安装手表 App 时必须跳过：
    /// `updateApplicationContext` 会在系统层打 `WCErrorCodeWatchAppNotInstalled`，`try?` 消不掉。
    func pushState() {
        let session = WCSession.default
        guard WatchConnectivityPolicy.canPushApplicationContext(
            sessionSupported: WCSession.isSupported(),
            sessionActivated: session.activationState == .activated,
            watchPaired: session.isPaired,
            watchAppInstalled: session.isWatchAppInstalled
        ) else { return }
        let store = SharedStore.shared
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var context: [String: Any] = [
            "enabled": Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
                ($0.rawValue, ProviderAvailability.isAvailable($0) && store.isEnabled($0))
            }),
            "order": store.providerOrder.map(\.rawValue),
            "language": store.appLanguage.rawValue,
            "usageDisplay": store.usageDisplayMode.rawValue,
            "resetTime": store.resetTimeStyle.rawValue,
            "demo": store.demoMode,
        ]
        if let data = try? encoder.encode(store.allSnapshots()) {
            context["snapshots"] = data
        }
        let customItems = WatchCustomPayload.items(
            accounts: store.accounts,
            templates: store.customTemplates,
            snapshot: { store.accountSnapshot(for: $0) },
            demoMode: store.demoMode
        )
        let packed = WatchCustomPayload.encode(customItems, encoder: encoder)
        if packed.droppedOldest > 0 {
            store.appendDiagnostic("watch: 自定义载荷超限，丢弃最旧 \(packed.droppedOldest) 个")
        }
        context["customItems"] = packed.data
        let extraItems = WatchExtraPayload.items(
            accounts: store.accounts,
            snapshot: { store.accountSnapshot(for: $0) },
            demoMode: store.demoMode,
            tintOverrides: store.providerTintOverrides,
            language: store.appLanguage
        )
        let extraPacked = WatchExtraPayload.encode(extraItems, encoder: encoder)
        if extraPacked.droppedOldest > 0 {
            store.appendDiagnostic("watch: 附加账号载荷超限，丢弃最旧 \(extraPacked.droppedOldest) 个")
        }
        context["extraItems"] = extraPacked.data
        // 设置页按账号列开关：同一服务商的多个账号平级，停用的也列出来
        let toggles = WatchAccountToggles.items(
            accounts: store.accounts,
            demoMode: store.demoMode,
            displayName: { store.displayName(for: $0) }
        )
        if let togglesData = WatchAccountToggles.encode(toggles, encoder: encoder) {
            context["accountToggles"] = togglesData
        } else {
            store.appendDiagnostic("watch: 账号开关载荷编码失败，表端退回按服务商列")
        }
        let watchTints = TintResolver.watchProviderOverrides(
            providerOverrides: store.providerTintOverrides,
            accounts: store.accounts
        )
        if let tintData = try? encoder.encode(watchTints) {
            context["tintOverrides"] = tintData
        }
        try? session.updateApplicationContext(context)
    }

    private func handleToggle(_ payload: [String: Any]) {
        if let raw = payload["setEnabled"] as? String,
           let provider = ProviderID(rawValue: raw),
           let value = payload["value"] as? Bool {
            DispatchQueue.main.async { self.onSetEnabled?(provider, value) }
        }
        // 每条命令独立判断，一条格式不对不影响同一载荷里的其它命令
        if let rawOrder = payload["setOrder"] as? [String] {
            let order = rawOrder.compactMap(ProviderID.init(rawValue:))
            if !order.isEmpty {
                DispatchQueue.main.async { self.onSetOrder?(order) }
            }
        }
        if let raw = payload["setAccountEnabled"] as? String,
           let id = UUID(uuidString: raw),
           let value = payload["accountValue"] as? Bool {
            DispatchQueue.main.async { self.onSetAccountEnabled?(id, value) }
        }
        if let rawIDs = payload["setAccountOrder"] as? [String] {
            let ids = rawIDs.compactMap(UUID.init(uuidString:))
            if !ids.isEmpty {
                DispatchQueue.main.async { self.onSetAccountOrder?(ids) }
            }
        }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        DispatchQueue.main.async { self.pushState() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// 用户后来装上/卸掉手表 App 时补推或停推。
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.pushState() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleToggle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleToggle(userInfo)
    }
}

import Foundation
import Combine
import WatchConnectivity
import UsageLimitsCore

/// 手表端状态：iPhone 经 WatchConnectivity 推送快照 / 启用状态 / 顺序 / 语言
///（applicationContext，自动去重、后台送达），本地落盘缓存保证离线可看；
/// 手表端拨动开关先改本地再回传 iPhone，两端保持一致。载荷只含用量数字，无任何凭据。
///
/// `@unchecked Sendable`：@Published 状态只在主线程写（初始化 +
/// WCSession 委托回调里统一 `DispatchQueue.main.async` 派发后修改）。
final class WatchStore: NSObject, ObservableObject, @unchecked Sendable {
    @Published var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published var customItems: [WatchCustomItem] = []
    @Published var extraItems: [WatchExtraItem] = []
    @Published var enabled: Set<ProviderID> = Set(ProviderID.allCases)
    @Published var order: [ProviderID] = ProviderID.allCases
    @Published var language: AppLanguage = .system
    @Published var usageDisplayMode: UsageDisplayMode = .used
    @Published var resetTimeStyle: ResetTimeStyle = .countdown
    @Published var demoMode = false
    @Published var tintOverrides: [String: BrandTint] = [:]

    /// 手表自身的本地缓存（standard defaults；手表与 iPhone 不共享 App Group）。
    private let cache = SharedStore(defaults: .standard)
    private let decoder: JSONDecoder
    /// --demo 启动参数强制演示模式（模拟器截图验证用），不被 iPhone 推送覆盖。
    private let demoForcedByArgs: Bool

    override init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        demoForcedByArgs = ProcessInfo.processInfo.arguments.contains("--demo")
        super.init()
        demoMode = demoForcedByArgs || cache.demoMode
        order = cache.providerOrder
        enabled = Set(order.filter { cache.isEnabled($0) })
        language = cache.appLanguage
        usageDisplayMode = cache.usageDisplayMode
        resetTimeStyle = cache.resetTimeStyle
        snapshots = Dictionary(uniqueKeysWithValues: cache.allSnapshots().map { ($0.provider, $0) })
        if let data = UserDefaults.standard.data(forKey: "watch.customItems") {
            customItems = WatchCustomPayload.decode(data, decoder: decoder)
        }
        if let data = UserDefaults.standard.data(forKey: "watch.extraItems") {
            extraItems = WatchExtraPayload.decode(data, decoder: decoder)
        }
        if let data = UserDefaults.standard.data(forKey: "watch.tintOverrides"),
           let map = try? decoder.decode([String: BrandTint].self, from: data) {
            tintOverrides = map
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// 圆环页展示的服务商（按全局顺序，只含启用的，与 iPhone 首页一致）。
    var activeProviders: [ProviderID] {
        order.filter { ProviderAvailability.isAvailable($0) && enabled.contains($0) }
    }

    func snapshot(for provider: ProviderID) -> ProviderSnapshot? {
        demoMode
            ? SharedStore.demoSnapshots(now: Date()).first { $0.provider == provider }
            : snapshots[provider]
    }

    /// 设置页开关：本地即时生效并缓存，同时回传 iPhone。
    func setEnabled(_ on: Bool, for provider: ProviderID) {
        if on {
            enabled.insert(provider)
        } else {
            enabled.remove(provider)
        }
        cache.setEnabled(on, for: provider)
        sendToPhone(["setEnabled": provider.rawValue, "value": on])
    }

    /// 设置页长按拖动排序：改的是与 iPhone 共用的同一份全局顺序，回传后两端联动。
    func moveOrder(fromOffsets: IndexSet, toOffset: Int) {
        var visible = order.filter(ProviderAvailability.isAvailable)
        visible.move(fromOffsets: fromOffsets, toOffset: toOffset)
        var iterator = visible.makeIterator()
        let next = order.map { ProviderAvailability.isAvailable($0) ? iterator.next()! : $0 }
        order = next
        cache.providerOrder = next
        sendToPhone(["setOrder": next.map(\.rawValue)])
    }

    private func sendToPhone(_ message: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                // 发送失败改走后台队列，iPhone 下次唤醒时送达
                session.transferUserInfo(message)
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    /// 应用 iPhone 推来的完整状态并落盘。
    private func apply(_ context: [String: Any]) {
        if let data = context["snapshots"] as? Data,
           let snaps = try? decoder.decode([ProviderSnapshot].self, from: data) {
            snapshots = Dictionary(uniqueKeysWithValues: snaps.map { ($0.provider, $0) })
            for snap in snaps { cache.save(snap) }
        }
        if let enabledMap = context["enabled"] as? [String: Bool] {
            for (raw, value) in enabledMap {
                if let provider = ProviderID(rawValue: raw) {
                    cache.setEnabled(value, for: provider)
                }
            }
            enabled = Set(ProviderID.allCases.filter { enabledMap[$0.rawValue] ?? true })
        }
        if let rawOrder = context["order"] as? [String] {
            var next = rawOrder.compactMap(ProviderID.init(rawValue:))
            for p in ProviderID.allCases where !next.contains(p) { next.append(p) }
            order = next
            cache.providerOrder = next
        }
        if let raw = context["language"] as? String, let lang = AppLanguage(rawValue: raw) {
            language = lang
            cache.appLanguage = lang
        }
        if let raw = context["usageDisplay"] as? String, let mode = UsageDisplayMode(rawValue: raw) {
            usageDisplayMode = mode
            cache.usageDisplayMode = mode
        }
        if let raw = context["resetTime"] as? String, let style = ResetTimeStyle(rawValue: raw) {
            resetTimeStyle = style
            cache.resetTimeStyle = style
        }
        if let demo = context["demo"] as? Bool, !demoForcedByArgs {
            demoMode = demo
            cache.demoMode = demo
        }
        if let data = context["customItems"] as? Data {
            customItems = demoMode ? [] : WatchCustomPayload.decode(data, decoder: decoder)
            UserDefaults.standard.set(data, forKey: "watch.customItems")
        }
        if let data = context["extraItems"] as? Data {
            extraItems = demoMode ? [] : WatchExtraPayload.decode(data, decoder: decoder)
            UserDefaults.standard.set(data, forKey: "watch.extraItems")
        }
        if let data = context["tintOverrides"] as? Data,
           let map = try? decoder.decode([String: BrandTint].self, from: data) {
            tintOverrides = map
            UserDefaults.standard.set(data, forKey: "watch.tintOverrides")
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // 激活后补上最近一次推送（离线期间 iPhone 更新过也能追平）
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        DispatchQueue.main.async { self.apply(context) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }
}

import Foundation
import UserNotifications
import UsageLimitsCore

/// 本地通知投递与预排。App 无服务器，所有提醒都是本机通知：
/// - 刷新时检测出的事件（阈值/额度回满）即时投递；
/// - 时间提前已知的提醒（套餐到期前 N 天、到点重置）预先排定，
///   App 不在前台也能按时弹出；iPhone 锁屏时系统会自动转发到已配对 Apple Watch。
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private let store = SharedStore.shared

    private override init() {
        super.init()
    }

    /// App 启动时调用：接管前台展示（不设 delegate 时 App 在前台收到通知不会显示，
    /// 而阈值检测恰恰主要发生在前台刷新时）。
    func activate() {
        center.delegate = self
    }

    /// 首次开启任一提醒时申请权限（系统只弹一次，之后调用无副作用）。
    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            SharedStore.shared.appendDiagnostic("通知权限申请结果：\(granted ? "已允许" : "被拒绝")")
        }
    }

    /// 即时投递决策器输出的事件。去重键只在投递确认成功后登记——
    /// 权限未授权或投递失败时不烧键，事件在下个周期仍有机会补发。
    func deliver(_ events: [NotificationEvent], language: AppLanguage) async {
        guard !events.isEmpty else { return }
        let auth = await center.notificationSettings().authorizationStatus
        guard auth == .authorized || auth == .provisional || auth == .ephemeral else {
            store.appendDiagnostic("提醒未投递：通知权限未授权（\(events.count) 条）")
            return
        }
        let settings = store.notificationSettings
        for event in events {
            let cfg = settings.resolved(for: event.provider)
            let content = UNMutableNotificationContent()
            let isCustom = event.dedupeKey.hasPrefix("prepaid.custom.")
                || event.accountID.flatMap { id in store.accounts.first { $0.id == id }?.isCustom } == true
            let metricLabel = event.localizedMetricLabel(language: language, isCustomAccount: isCustom)
            switch event.kind {
            case .threshold:
                guard let currentPercent = UsagePresentation.roundedUsedPercent(event.usedPercent),
                      let thresholdPercent = UsagePresentation.roundedUsedPercent(cfg.thresholdPercent)
                else {
                    store.appendDiagnostic("提醒未投递：百分比非法（\(event.dedupeKey)）")
                    continue
                }
                let name = event.accountTitle ?? event.provider.localizedVendor(language)
                content.title = L10n.tr("notify.threshold.title", language, name)
                content.body = L10n.tr(
                    "notify.threshold.body", language,
                    metricLabel, currentPercent, thresholdPercent
                )
            case .reset:
                content.title = L10n.tr(
                    "notify.reset.title", language, event.accountTitle ?? event.provider.localizedVendor(language)
                )
                content.body = L10n.tr("notify.reset.body.detected", language, metricLabel)
            case .prepaidAmount:
                let snap: ProviderSnapshot?
                if let accountID = event.accountID {
                    snap = store.accountSnapshot(for: accountID)
                } else {
                    snap = store.displaySnapshot(for: event.provider) ?? store.snapshot(for: event.provider)
                }
                let currency = PrepaidCurrency.code(from: snap)
                let current = MoneyFormat.string(event.amount ?? 0, currency: currency)
                let line = MoneyFormat.string(cfg.prepaidAmount, currency: currency)
                let titleName = event.accountTitle ?? event.provider.localizedVendor(language)
                content.title = L10n.tr("notify.prepaid.title", language, titleName)
                content.body = L10n.tr(
                    "notify.prepaid.body", language,
                    metricLabel, current, line
                )
            }
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(
                    identifier: "event.\(event.dedupeKey)", content: content, trigger: nil
                ))
                store.markNotified(event.dedupeKey)
                store.appendDiagnostic("已发提醒：\(event.dedupeKey)")
            } catch {
                store.appendDiagnostic("提醒投递失败：\(event.dedupeKey)（\(error.localizedDescription)）")
            }
        }
    }

    /// 整体重排可预知时间的提醒（先清后排，保证关掉开关即撤销）。
    /// 每次快照落盘或提醒设置变化后调用。
    func rescheduleCalendarReminders(language: AppLanguage) {
        let settings = store.notificationSettings
        // 必须清掉全部 pending：附加账号删除后 ID 已不在 accounts，按现列表撤会漏。
        center.removeAllPendingNotificationRequests()
        guard settings.needsCalendarReminders else { return }

        let now = Date()
        func schedulePair(snap: ProviderSnapshot, account: ProviderAccount?) {
            let cfg = settings.resolved(for: snap.provider)
            let name = account.map { store.displayName(for: $0) } ?? snap.provider.localizedVendor(language)
            let accountID = account?.isPrimary == false ? account?.id : nil
            let extraIDs = accountID.map { NotificationDecider.extraCalendarIDs(accountID: $0) }
            let expiryID = extraIDs?[0] ?? "expiry.\(snap.provider.rawValue)"
            let resetID = extraIDs?[1] ?? "resetAt.\(snap.provider.rawValue)"
            if cfg.expiryEnabled, let expires = snap.planExpiresAt,
               // 按日历天回推（跨夏令时不漂移），而非固定 86400 秒
               let fireAt = Calendar.current.date(
                   byAdding: .day, value: -cfg.expiryDaysBefore, to: expires
               ), fireAt > now {
                let content = UNMutableNotificationContent()
                content.title = L10n.tr("notify.expiry.title", language, name)
                content.body = L10n.tr(
                    "notify.expiry.body", language,
                    snap.planName.map { L10n.tr($0, language) } ?? name, cfg.expiryDaysBefore
                )
                content.sound = .default
                schedule(id: expiryID, content: content, at: fireAt)
            }
            if cfg.resetEnabled,
               let metric = snap.longestWindowMetric,
               let resets = metric.resetsAt, resets > now {
                let content = UNMutableNotificationContent()
                content.title = L10n.tr("notify.reset.title", language, name)
                content.body = L10n.tr(
                    "notify.reset.body.scheduled", language,
                    L10n.metricLabel(
                        provider: snap.provider,
                        id: metric.id,
                        fallback: metric.label,
                        language: language
                    )
                )
                content.sound = .default
                schedule(id: resetID, content: content, at: resets)
                // 预登记同一次重置的检测去重键：到点通知与刷新检测只发一条
                store.markNotified(NotificationDecider.resetDedupeKey(
                    provider: snap.provider, metricID: metric.id, resetsAt: resets, accountID: accountID
                ))
            }
        }
        for snap in store.allSnapshots() where store.isEnabled(snap.provider) && snap.status.isOK {
            schedulePair(snap: snap, account: store.primaryAccount(of: snap.provider))
        }
        for account in store.accounts where !account.isCustom && !account.isPrimary && account.isEnabled {
            guard let provider = account.provider, store.isEnabled(provider) else { continue }
            guard let snap = store.accountSnapshot(for: account.id), snap.status.isOK else { continue }
            schedulePair(snap: snap, account: account)
        }
    }

    private func schedule(id: String, content: UNNotificationContent, at date: Date) {
        // 目标是绝对时刻：用时间间隔触发器（日历触发器按「墙上时钟」匹配，
        // 排定后换时区/夏令时会漂移甚至落入不存在的时刻）
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow), repeats: false
        )
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// App 在前台时收到通知也以横幅+通知中心展示。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

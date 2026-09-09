import Foundation
import BackgroundTasks
import WidgetKit
import UsageLimitsCore

/// 后台刷新（尽力而为）：系统给机会时在后台跑一轮探针，检测阈值/额度回满。
/// WKWebView 在后台执行成功率不确定（2026-08-16 设计决策：接受尽力而为），
/// 结果进诊断日志观察；后台探针失败绝不覆盖已有的正常快照。
@MainActor
enum BackgroundRefresh {
    nonisolated static let taskID = "com.canonforge.usagelimits.refresh"
    /// 整轮探针的时间预算：BGAppRefreshTask 通常只给约 30 秒，留出收尾余量。
    nonisolated static let sweepBudget: TimeInterval = 20

    /// 必须在 App 启动完成前调用（UsageLimitsApp.init）。
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    /// 进后台时提交下一轮请求；系统按用量习惯决定实际执行时机。
    nonisolated static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private nonisolated static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let completion = Completion()
        let work = Task { @MainActor in
            let store = SharedStore.shared
            let settings = store.notificationSettings
            // 后台探针只为提醒服务：演示模式或「需要刷快照的提醒」全关时直接完成。
            // 预充值金额告警也靠新旧快照对比，必须算进闸门；到期提醒走日历预排。
            guard !store.demoMode, settings.needsBackgroundProbe else {
                completion.finish(task, success: true)
                return
            }
            let deadline = Date().addingTimeInterval(sweepBudget)
            var allOK = true
            let includeCustom = settings.prepaidScope == .unified && settings.prepaidAmountEnabled
            let primaryItems = store.enabledProviders.compactMap { provider -> (id: ProviderID, fetchedAt: Date)? in
                guard ProviderAvailability.isAvailable(provider) else { return nil }
                guard let old = store.snapshot(for: provider), old.status.isOK else { return nil }
                return (provider, old.fetchedAt)
            }
            let extraItems = store.accounts.compactMap { account -> (id: UUID, fetchedAt: Date)? in
                guard ProviderAvailability.isAvailable(account) else { return nil }
                guard !account.isCustom, !account.isPrimary, account.isEnabled else { return nil }
                guard let provider = account.provider, store.isEnabled(provider) else { return nil }
                guard let old = store.accountSnapshot(for: account.id), old.status.isOK else { return nil }
                return (account.id, old.fetchedAt)
            }
            let customItems = includeCustom
                ? store.accounts.compactMap { account -> (id: UUID, fetchedAt: Date)? in
                    guard account.isCustom, account.isEnabled else { return nil }
                    guard let old = store.accountSnapshot(for: account.id), old.status.isOK else { return nil }
                    return (account.id, old.fetchedAt)
                }
                : []
            // 最旧的先刷；同样陈旧时附加内置优先，避免 20s 预算被主号吃完。
            for target in RefreshSweep.order(
                primaries: primaryItems, extras: extraItems, customs: customItems
            ) {
                if Task.isCancelled || Date() >= deadline {
                    allOK = false
                    break
                }
                let ok: Bool
                switch target {
                case .primary(let provider):
                    ok = await refreshPrimary(provider, store: store, settings: settings)
                case .extra(let accountID):
                    ok = await refreshExtra(accountID, store: store, settings: settings)
                case .custom(let accountID):
                    ok = await refreshCustom(accountID, store: store, settings: settings)
                }
                if !ok { allOK = false }
            }
            NotificationManager.shared.rescheduleCalendarReminders(language: store.appLanguage)
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.pushState()
            store.appendDiagnostic("后台刷新完成 success=\(allOK)")
            completion.finish(task, success: allOK)
        }
        task.expirationHandler = {
            work.cancel()
            // 过期时必须上报完成，否则系统强杀 App 并降低后续调度配额
            Task { @MainActor in completion.finish(task, success: false) }
        }
    }

    private static func refreshPrimary(
        _ provider: ProviderID,
        store: SharedStore,
        settings: NotificationSettings
    ) async -> Bool {
        guard let old = store.snapshot(for: provider), old.status.isOK else { return true }
        let startAccount = store.accounts.first(where: { $0.provider == provider && $0.isPrimary && $0.isEnabled })
        let startFingerprint = startAccount?.identityFingerprint
        let startFetchedAt = old.fetchedAt
        let results = await WebViewFetcher.shared.runProbes(for: provider)
        if Task.isCancelled { return false }
        guard store.isEnabled(provider) else { return false }
        guard let live = store.accounts.first(where: { $0.provider == provider && $0.isPrimary && $0.isEnabled }) else { return false }
        guard store.snapshot(for: provider)?.fetchedAt == startFetchedAt else { return false }
        guard live.identityFingerprint == startFingerprint else { return false }
        var snap = AppState.parse(provider: provider, results: results, now: Date())
        snap = RefreshPolicy.preservingBreakdowns(old: old, new: snap)
        var accounts = store.accounts
        let identity = AccountIdentity.apply(
            accounts: &accounts, provider: provider, accountID: nil,
            results: results, snap: &snap
        )
        if identity == .bound { store.accounts = accounts }
        // 后台 WebView 环境不可靠：非 ok / 身份冲突不落盘，防止把已登录状态刷成未登录
        guard identity != .mismatch, snap.status.isOK else { return false }
        guard RefreshPolicy.shouldCommit(old: old, new: snap, results: results) else { return false }
        guard store.save(snap) else { return false }
        guard let committed = store.snapshot(for: provider) else { return false }
        let events = NotificationDecider.events(
            old: old, new: committed, settings: settings,
            alreadyNotified: store.notifiedKeys()
        )
        await NotificationManager.shared.deliver(events, language: store.appLanguage)
        return true
    }

    private static func refreshExtra(
        _ accountID: UUID,
        store: SharedStore,
        settings: NotificationSettings
    ) async -> Bool {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else { return true }
        guard !account.isCustom, !account.isPrimary, account.isEnabled else { return true }
        guard let provider = account.provider, store.isEnabled(provider) else { return true }
        guard let old = store.accountSnapshot(for: account.id), old.status.isOK else { return true }
        let startFingerprint = account.identityFingerprint
        let startFetchedAt = old.fetchedAt
        let results = await WebViewFetcher.shared.runProbes(for: provider, accountID: account.id)
        if Task.isCancelled { return false }
        guard let live = store.accounts.first(where: { $0.id == accountID }),
              live.isCustom == false, live.isPrimary == false, live.isEnabled,
              let liveProvider = live.provider, store.isEnabled(liveProvider)
        else { return false }
        guard store.accountSnapshot(for: accountID)?.fetchedAt == startFetchedAt else { return false }
        guard live.identityFingerprint == startFingerprint else { return false }
        var snap = AppState.parse(provider: liveProvider, results: results, now: Date())
        snap = RefreshPolicy.preservingBreakdowns(old: old, new: snap)
        var accounts = store.accounts
        let identity = AccountIdentity.apply(
            accounts: &accounts, provider: provider, accountID: account.id,
            results: results, snap: &snap
        )
        if identity == .bound { store.accounts = accounts }
        guard identity != .mismatch, snap.status.isOK else { return false }
        guard RefreshPolicy.shouldCommit(old: old, new: snap, results: results) else { return false }
        guard store.saveAccountSnapshot(snap, accountID: account.id) else { return false }
        guard let committed = store.accountSnapshot(for: account.id) else { return false }
        let events = NotificationDecider.events(
            old: old, new: committed, settings: settings,
            alreadyNotified: store.notifiedKeys(),
            accountID: account.id,
            accountTitle: store.displayName(for: account)
        )
        await NotificationManager.shared.deliver(events, language: store.appLanguage)
        return true
    }

    private static func refreshCustom(
        _ accountID: UUID,
        store: SharedStore,
        settings: NotificationSettings
    ) async -> Bool {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else { return true }
        guard account.isCustom, account.isEnabled else { return true }
        guard let old = store.accountSnapshot(for: account.id), old.status.isOK else { return true }
        guard let templateID = account.templateID,
              let template = store.customTemplate(id: templateID) else { return true }
        let startToken = store.accountToken(for: account.id)
        let startFetchedAt = old.fetchedAt
        let startTemplate = template
        let client = CustomUsageClient(session: CustomUsageClient.makeSession())
        let outcome = await CustomUsageRefresh.perform(
            template: template,
            token: startToken,
            old: old,
            client: client
        )
        if Task.isCancelled { return false }
        guard let live = store.accounts.first(where: { $0.id == accountID }),
              live.isCustom, live.isEnabled
        else { return false }
        guard store.accountSnapshot(for: accountID)?.fetchedAt == startFetchedAt else { return false }
        guard store.accountToken(for: accountID) == startToken else { return false }
        guard store.customTemplate(id: templateID) == startTemplate else { return false }
        store.appendDiagnostic(outcome.diagnostic)
        if outcome.didCommit {
            guard store.saveAccountSnapshot(outcome.snapshot, accountID: account.id) else { return false }
            guard let committed = store.accountSnapshot(for: account.id) else { return false }
            let events = NotificationDecider.customPrepaidEvents(
                old: old,
                new: committed,
                accountID: account.id,
                accountTitle: store.displayName(for: account),
                settings: settings
            )
            await NotificationManager.shared.deliver(events, language: store.appLanguage)
            return true
        }
        return false
    }

    /// setTaskCompleted 只允许调用一次：正常完成与过期收尾之间做一次性闸门。
    @MainActor
    private final class Completion {
        private var done = false
        nonisolated init() {}
        func finish(_ task: BGAppRefreshTask, success: Bool) {
            guard !done else { return }
            done = true
            task.setTaskCompleted(success: success)
        }
    }
}

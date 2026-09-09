import XCTest
@testable import UsageLimitsCore

final class NotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeStore() -> (SharedStore, () -> Void) {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let cleanup = { defaults.removePersistentDomain(forName: suite) }
        return (SharedStore(defaults: defaults), cleanup)
    }

    private func snap(
        _ provider: ProviderID = .claude,
        metrics: [UsageMetric],
        status: SnapshotStatus = .ok,
        planExpiresAt: Date? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider, planName: "P", metrics: metrics,
            fetchedAt: now, status: status, planExpiresAt: planExpiresAt
        )
    }

    private func metric(_ id: String, _ percent: Double?, resetsIn: TimeInterval? = nil) -> UsageMetric {
        UsageMetric(id: id, label: id, usedPercent: percent,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    // MARK: - 设置持久化

    func testSettingsDefaultsAndRoundTrip() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let defaults = store.notificationSettings
        XCTAssertFalse(defaults.thresholdEnabled)
        XCTAssertFalse(defaults.expiryEnabled)
        XCTAssertFalse(defaults.resetEnabled)
        XCTAssertFalse(defaults.prepaidAmountEnabled)
        XCTAssertFalse(defaults.anyEnabled)
        XCTAssertEqual(defaults.thresholdPercent, 80)
        XCTAssertEqual(defaults.expiryDaysBefore, 3)
        XCTAssertEqual(defaults.prepaidAmount, 10)
        XCTAssertEqual(defaults.thresholdScope, .unified)
        XCTAssertEqual(defaults.prepaidScope, .unified)
        XCTAssertTrue(defaults.providerConfigs.isEmpty)
        XCTAssertFalse(defaults.needsBackgroundProbe)

        var edited = defaults
        edited.thresholdEnabled = true
        edited.thresholdPercent = 90
        edited.expiryDaysBefore = 7
        edited.prepaidAmountEnabled = true
        edited.prepaidAmount = 20
        store.notificationSettings = edited
        XCTAssertEqual(store.notificationSettings, edited)
        XCTAssertTrue(store.notificationSettings.anyEnabled)
        XCTAssertTrue(store.notificationSettings.needsBackgroundProbe)
    }

    func testNeedsBackgroundProbeIncludesPrepaidNotExpiry() {
        var s = NotificationSettings()
        XCTAssertFalse(s.needsBackgroundProbe)
        s.expiryEnabled = true
        XCTAssertFalse(s.needsBackgroundProbe, "到期提醒走日历预排，不该单独打开后台探针")
        s.expiryEnabled = false
        s.prepaidAmountEnabled = true
        XCTAssertTrue(s.needsBackgroundProbe)
        s.prepaidAmountEnabled = false
        s.thresholdEnabled = true
        XCTAssertTrue(s.needsBackgroundProbe)
        s.thresholdEnabled = false
        s.resetEnabled = true
        XCTAssertTrue(s.needsBackgroundProbe)
    }

    func testNotificationSettingsViewHasScopeAndCurrency() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/NotificationSettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("AlertScope.unified"))
        XCTAssertTrue(src.contains("AlertScope.perProvider"))
        XCTAssertTrue(src.contains("providerPicker"))
        XCTAssertTrue(src.contains("PrepaidCurrency.code"))
        XCTAssertTrue(src.contains("notify.providerPicker"))
        XCTAssertTrue(src.contains("Menu"))
        XCTAssertTrue(src.contains("provider.localizedName(lang)"))
        XCTAssertTrue(src.contains("selectedProvider.localizedName(lang)"))
        XCTAssertFalse(src.contains("provider.vendorName"))
        XCTAssertTrue(src.contains("ProviderLogo(provider: provider"))
        XCTAssertTrue(src.contains("ProviderLogo(provider: selectedProvider"))
        XCTAssertFalse(src.contains(".pickerStyle(.menu)"))
        XCTAssertTrue(src.contains("notify.threshold.header"), "额度阈值应有标题")
        XCTAssertTrue(src.contains("notify.expiry.header"), "套餐到期应有标题")
        XCTAssertTrue(src.contains("notify.reset.header"), "额度重置应有标题")
        XCTAssertTrue(src.contains("notify.prepaid.header"), "预充值金额应有标题")
        XCTAssertTrue(src.contains("header:"), "标题须在控件上方，不能只靠 footer")
    }

    func testReminderItemHeaderKeysResolveInAllLanguages() {
        let expectedZH = [
            "notify.threshold.header": "额度阈值",
            "notify.expiry.header": "套餐到期",
            "notify.reset.header": "额度重置",
            "notify.prepaid.header": "预充值金额",
        ]
        for (key, zh) in expectedZH {
            XCTAssertEqual(L10n.tr(key, .zh), zh)
            for lang in AppLanguage.concrete {
                let value = L10n.tr(key, lang)
                XCTAssertFalse(value.isEmpty, "\(key) \(lang) 缺文案")
                XCTAssertNotEqual(value, key, "\(key) \(lang) 未翻译")
            }
        }
    }

    func testBackgroundRefreshGateUsesShippedNeedsBackgroundProbe() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/BackgroundRefresh.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("needsBackgroundProbe"))
        XCTAssertFalse(src.contains("settings.thresholdEnabled || settings.resetEnabled"))
    }

    func testSettingsDecodeWithoutPrepaidFields() throws {
        // 老版本落盘没有预充值字段，必须能解码并保持默认关闭
        let json = """
        {"thresholdEnabled":true,"thresholdPercent":85,"expiryEnabled":false,"expiryDaysBefore":3,"resetEnabled":true}
        """
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.thresholdEnabled)
        XCTAssertEqual(settings.thresholdPercent, 85)
        XCTAssertTrue(settings.resetEnabled)
        XCTAssertFalse(settings.prepaidAmountEnabled)
        XCTAssertEqual(settings.prepaidAmount, 10)
        XCTAssertEqual(settings.thresholdScope, .unified)
        XCTAssertEqual(settings.prepaidScope, .unified)
        XCTAssertTrue(settings.providerConfigs.isEmpty)
    }

    func testResolvedUsesPerProviderOverride() {
        var s = NotificationSettings()
        s.thresholdEnabled = true
        s.thresholdPercent = 80
        s.thresholdScope = .perProvider
        s.upsert(.claude, ProviderAlertConfig(thresholdEnabled: true, thresholdPercent: 90))
        s.upsert(.grok, ProviderAlertConfig(thresholdEnabled: false, thresholdPercent: 50))
        XCTAssertEqual(s.resolved(for: .claude).thresholdPercent, 90)
        XCTAssertTrue(s.resolved(for: .claude).thresholdEnabled)
        XCTAssertFalse(s.resolved(for: .grok).thresholdEnabled)
        // 未单独配置的服务商：按供应商模式下默认关
        XCTAssertFalse(s.resolved(for: .openai).thresholdEnabled)
        XCTAssertTrue(s.anyEnabled)
        XCTAssertTrue(s.needsBackgroundProbe)
    }

    func testPerProviderThresholdOnlyFiresForThatVendor() {
        var s = NotificationSettings()
        s.thresholdScope = .perProvider
        s.upsert(.claude, ProviderAlertConfig(thresholdEnabled: true, thresholdPercent: 80))
        s.upsert(.grok, ProviderAlertConfig(thresholdEnabled: true, thresholdPercent: 95))
        let old = snap(.claude, metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
        let new = snap(.claude, metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        XCTAssertEqual(
            NotificationDecider.events(old: old, new: new, settings: s, alreadyNotified: []).count, 1
        )
        let grokOld = snap(.grok, metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
        let grokNew = snap(.grok, metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        XCTAssertTrue(NotificationDecider.events(
            old: grokOld, new: grokNew, settings: s, alreadyNotified: []
        ).isEmpty)
    }

    func testPrepaidCurrencyHiddenUntilFetched() {
        XCTAssertNil(PrepaidCurrency.code(from: nil))
        let noAPI = snap(.claude, metrics: [metric("weekly", 10)])
        XCTAssertNil(PrepaidCurrency.code(from: noAPI))
        let deepseek = ProviderSnapshot(
            provider: .deepseek,
            metrics: [UsageMetric(id: "balance", label: "重置余额", amount: 12, currency: "CNY")],
            fetchedAt: now, status: .ok, currency: "CNY"
        )
        XCTAssertEqual(PrepaidCurrency.code(from: deepseek), "CNY")
        let needsLogin = ProviderSnapshot(
            provider: .deepseek, metrics: [], fetchedAt: now, status: .needsLogin, currency: "CNY"
        )
        XCTAssertNil(PrepaidCurrency.code(from: needsLogin))
    }

    func testNotifiedKeysDedupeAndCap() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertFalse(store.notifiedKeys().contains("a"))
        store.markNotified("a")
        XCTAssertTrue(store.notifiedKeys().contains("a"))
        XCTAssertTrue(store.notifiedKeys().contains("a"))
        for i in 0..<220 { store.markNotified("k\(i)") }
        XCTAssertLessThanOrEqual(store.notifiedKeys().count, 200)
        XCTAssertTrue(store.notifiedKeys().contains("k219"))
        XCTAssertFalse(store.notifiedKeys().contains("a"))
    }

    // MARK: - 阈值提醒

    private var thresholdOn: NotificationSettings {
        var s = NotificationSettings()
        s.thresholdEnabled = true
        s.thresholdPercent = 80
        return s
    }

    func testThresholdCrossingFires() {
        let old = snap(metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
        let new = snap(metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        let events = NotificationDecider.events(old: old, new: new, settings: thresholdOn, alreadyNotified: [])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .threshold)
        XCTAssertEqual(events[0].provider, .claude)
        XCTAssertEqual(events[0].metricID, "weekly")
        XCTAssertEqual(events[0].usedPercent, 85)
    }

    func testThresholdNoRepeatWithinCycle() {
        let old = snap(metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        let new = snap(metrics: [metric("weekly", 90, resetsIn: 3 * 86400)])
        // 旧值已在阈值之上：不是穿越，不再提醒
        XCTAssertTrue(NotificationDecider.events(old: old, new: new, settings: thresholdOn, alreadyNotified: []).isEmpty)
        // 即便判作穿越（旧缺失），去重键在场也不提醒
        let crossed = NotificationDecider.events(old: nil, new: new, settings: thresholdOn, alreadyNotified: [])
        XCTAssertEqual(crossed.count, 1)
        let again = NotificationDecider.events(
            old: nil, new: new, settings: thresholdOn,
            alreadyNotified: [crossed[0].dedupeKey]
        )
        XCTAssertTrue(again.isEmpty)
    }

    func testThresholdRearmsAfterWindowReset() {
        let old = snap(metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
        let new = snap(metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        let first = NotificationDecider.events(old: old, new: new, settings: thresholdOn, alreadyNotified: [])
        // 下个周期：resetsAt 变化 → 去重键不同，可以再次提醒
        let nextOld = snap(metrics: [metric("weekly", 60, resetsIn: 10 * 86400)])
        let nextNew = snap(metrics: [metric("weekly", 88, resetsIn: 10 * 86400)])
        let second = NotificationDecider.events(
            old: nextOld, new: nextNew, settings: thresholdOn,
            alreadyNotified: [first[0].dedupeKey]
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(second[0].dedupeKey, first[0].dedupeKey)
    }

    func testThresholdDisabledOrBelowNoEvents() {
        let old = snap(metrics: [metric("weekly", 70)])
        let new = snap(metrics: [metric("weekly", 85)])
        var off = thresholdOn
        off.thresholdEnabled = false
        XCTAssertTrue(NotificationDecider.events(old: old, new: new, settings: off, alreadyNotified: []).isEmpty)
        let below = snap(metrics: [metric("weekly", 75)])
        XCTAssertTrue(NotificationDecider.events(old: old, new: below, settings: thresholdOn, alreadyNotified: []).isEmpty)
    }

    func testThresholdMissingOldMetricIsNotACrossing() {
        // 有旧快照但缺该指标（解析瞬时缺失/接口漂移）：视为未知，不算穿越
        let old = snap(metrics: [metric("other", 10, resetsIn: 3 * 86400)])
        let new = snap(metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        XCTAssertTrue(NotificationDecider.events(old: old, new: new, settings: thresholdOn, alreadyNotified: []).isEmpty)
    }

    func testThresholdOldNeedsLoginSuppressesEvents() {
        // 旧快照是 needsLogin（重新登录成功的那一轮）：不把全部高用量指标当新穿越
        let old = snap(metrics: [], status: .needsLogin)
        let new = snap(metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        XCTAssertTrue(NotificationDecider.events(old: old, new: new, settings: thresholdOn, alreadyNotified: []).isEmpty)
    }

    func testThresholdAndResetIgnoreNonOKNewSnapshot() {
        let old = snap(metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
        let leftover = [metric("weekly", 85, resetsIn: 3 * 86400)]
        for status in [SnapshotStatus.needsLogin, .error("x")] {
            let new = snap(metrics: leftover, status: status)
            XCTAssertTrue(
                NotificationDecider.events(old: old, new: new, settings: thresholdOn, alreadyNotified: []).isEmpty,
                "threshold \(status)"
            )
        }
        let resetOld = snap(metrics: [metric("weekly", 61, resetsIn: 3 * 86400)])
        for status in [SnapshotStatus.needsLogin, .error("x")] {
            let new = snap(metrics: [metric("weekly", 0, resetsIn: 10 * 86400)], status: status)
            XCTAssertTrue(
                NotificationDecider.events(old: resetOld, new: new, settings: resetOn, alreadyNotified: []).isEmpty,
                "reset new \(status)"
            )
        }
        let resetFromLogin = snap(metrics: [metric("weekly", 61, resetsIn: 3 * 86400)], status: .needsLogin)
        let resetNew = snap(metrics: [metric("weekly", 0, resetsIn: 10 * 86400)])
        XCTAssertTrue(
            NotificationDecider.events(old: resetFromLogin, new: resetNew, settings: resetOn, alreadyNotified: []).isEmpty,
            "reset old needsLogin"
        )
    }

    func testInvalidPercentagesNeverTriggerThresholdOrResetEvents() {
        let invalid = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 101]
        for value in invalid {
            let oldBelow = snap(metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
            let invalidNew = snap(metrics: [metric("weekly", value, resetsIn: 3 * 86400)])
            XCTAssertTrue(
                NotificationDecider.events(
                    old: oldBelow, new: invalidNew,
                    settings: thresholdOn, alreadyNotified: []
                ).isEmpty,
                "invalid threshold value \(value)"
            )

            let invalidOld = snap(metrics: [metric("weekly", value, resetsIn: 3 * 86400)])
            let resetNew = snap(metrics: [metric("weekly", 0, resetsIn: 10 * 86400)])
            XCTAssertTrue(
                NotificationDecider.events(
                    old: invalidOld, new: resetNew,
                    settings: resetOn, alreadyNotified: []
                ).isEmpty,
                "invalid old reset value \(value)"
            )
            XCTAssertTrue(
                NotificationDecider.events(
                    old: snap(metrics: [metric("weekly", 61, resetsIn: 3 * 86400)]),
                    new: invalidNew,
                    settings: resetOn, alreadyNotified: []
                ).isEmpty,
                "invalid new reset value \(value)"
            )
        }
    }

    func testNotificationManagerUsesSafePercentFormatter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/NotificationManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("UsagePresentation.roundedUsedPercent"))
        XCTAssertTrue(source.contains("localizedMetricLabel"), "自定义预充值不得走官方 metricKey")
        XCTAssertFalse(source.contains("Int((event.usedPercent"))
        XCTAssertFalse(source.contains("event.usedPercent ?? 0"))
    }

    func testStampAbsorbsRelativeResetDrift() {
        // 部分解析器的 resetsAt 是 now+剩余秒数推算的相对值，每轮刷新漂移几秒：
        // 同一小时桶内去重键必须一致，避免重复提醒
        let old = snap(metrics: [metric("weekly", 70, resetsIn: 3 * 86400)])
        let a = snap(metrics: [metric("weekly", 85, resetsIn: 3 * 86400)])
        let b = snap(metrics: [metric("weekly", 86, resetsIn: 3 * 86400 + 90)])
        let ea = NotificationDecider.events(old: old, new: a, settings: thresholdOn, alreadyNotified: [])
        let eb = NotificationDecider.events(old: old, new: b, settings: thresholdOn, alreadyNotified: [])
        XCTAssertEqual(ea[0].dedupeKey, eb[0].dedupeKey)
    }

    // MARK: - 重置提醒（刷新时检测）

    private var resetOn: NotificationSettings {
        var s = NotificationSettings()
        s.resetEnabled = true
        return s
    }

    func testResetDetectionFiresOnLongestWindowOnly() {
        // session（5h 窗口）与 weekly 同时归零：只对最长窗口（weekly）提醒
        let old = snap(metrics: [
            metric("session", 80, resetsIn: 2 * 3600),
            metric("weekly", 61, resetsIn: 3 * 86400),
        ])
        let new = snap(metrics: [
            metric("session", 0, resetsIn: 2 * 3600),
            metric("weekly", 0, resetsIn: 10 * 86400),
        ])
        let events = NotificationDecider.events(old: old, new: new, settings: resetOn, alreadyNotified: [])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .reset)
        XCTAssertEqual(events[0].metricID, "weekly")
    }

    func testResetNotFiredWhenStillUsedOrNoOldUsage() {
        let old = snap(metrics: [metric("weekly", 61, resetsIn: 3 * 86400)])
        // 只是下降没归零：不提醒
        let partial = snap(metrics: [metric("weekly", 40, resetsIn: 3 * 86400)])
        XCTAssertTrue(NotificationDecider.events(old: old, new: partial, settings: resetOn, alreadyNotified: []).isEmpty)
        // 旧值本来就是 0：不提醒
        let oldZero = snap(metrics: [metric("weekly", 0, resetsIn: 3 * 86400)])
        let newZero = snap(metrics: [metric("weekly", 0, resetsIn: 10 * 86400)])
        XCTAssertTrue(NotificationDecider.events(old: oldZero, new: newZero, settings: resetOn, alreadyNotified: []).isEmpty)
        // 无旧快照：无从比较，不提醒
        XCTAssertTrue(NotificationDecider.events(old: nil, new: partial, settings: resetOn, alreadyNotified: []).isEmpty)
    }

    func testResetDedupe() {
        let old = snap(metrics: [metric("weekly", 61, resetsIn: 3 * 86400)])
        let new = snap(metrics: [metric("weekly", 0, resetsIn: 10 * 86400)])
        let first = NotificationDecider.events(old: old, new: new, settings: resetOn, alreadyNotified: [])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(NotificationDecider.events(
            old: old, new: new, settings: resetOn,
            alreadyNotified: [first[0].dedupeKey]
        ).isEmpty)
    }

    func testResetDedupeKeyHelperMatchesEventKey() {
        // App 层预排「到点重置」通知时用该 helper 预登记检测键：两者必须一致，
        // 否则同一次重置会收到到点+检测两条提醒
        let resets = now.addingTimeInterval(3 * 86400)
        let old = snap(metrics: [UsageMetric(id: "weekly", label: "weekly", usedPercent: 61, resetsAt: resets)])
        let new = snap(metrics: [metric("weekly", 0, resetsIn: 10 * 86400)])
        let events = NotificationDecider.events(old: old, new: new, settings: resetOn, alreadyNotified: [])
        XCTAssertEqual(
            events[0].dedupeKey,
            NotificationDecider.resetDedupeKey(provider: .claude, metricID: "weekly", resetsAt: resets)
        )
    }

    // MARK: - planExpiresAt

    func testSnapshotDecodesWithoutPlanExpiresAt() throws {
        // 老版本落盘的快照没有 planExpiresAt 字段，必须能解码
        let json = """
        {"provider":"claude","metrics":[],"fetchedAt":"2026-08-16T00:00:00Z","status":{"ok":{}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(ProviderSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.planExpiresAt)
    }

    // MARK: - 预充值金额告警（DeepSeek）

    private var prepaidOn: NotificationSettings {
        var s = NotificationSettings()
        s.prepaidAmountEnabled = true
        s.prepaidAmount = 10
        return s
    }

    private func prepaidSnap(_ amount: Double, provider: ProviderID = .deepseek) -> ProviderSnapshot {
        snap(provider, metrics: [
            UsageMetric(id: "balance", label: "重置余额", amount: amount, currency: "CNY"),
            UsageMetric(id: "total_spent", label: "累计消费金额", amount: 1, currency: "CNY"),
        ])
    }

    func testPrepaidCrossingFiresOnce() {
        let old = prepaidSnap(54.48)
        let new = prepaidSnap(8.2)
        let events = NotificationDecider.events(old: old, new: new, settings: prepaidOn, alreadyNotified: [])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .prepaidAmount)
        XCTAssertEqual(events[0].provider, .deepseek)
        XCTAssertEqual(events[0].metricID, "balance")
        XCTAssertEqual(events[0].amount, 8.2)
        XCTAssertEqual(
            events[0].dedupeKey,
            NotificationDecider.prepaidDedupeKey(
                provider: .deepseek, threshold: 10, fetchedAt: new.fetchedAt
            )
        )
    }

    func testPrepaidAlreadyBelowDoesNotRefire() {
        let old = prepaidSnap(8)
        let newer = prepaidSnap(5)
        XCTAssertTrue(NotificationDecider.events(
            old: old, new: newer, settings: prepaidOn, alreadyNotified: []
        ).isEmpty)
    }

    func testPrepaidDisabledOrNonDeepSeekNoEvent() {
        let old = prepaidSnap(54)
        let new = prepaidSnap(8)
        var off = prepaidOn
        off.prepaidAmountEnabled = false
        XCTAssertTrue(NotificationDecider.events(old: old, new: new, settings: off, alreadyNotified: []).isEmpty)

        // 没有 balance 指标：不告警
        let noBalOld = snap(.claude, metrics: [metric("weekly", 54)])
        let noBalNew = snap(.claude, metrics: [metric("weekly", 8)])
        XCTAssertTrue(NotificationDecider.events(
            old: noBalOld, new: noBalNew, settings: prepaidOn, alreadyNotified: []
        ).isEmpty)
        // 已有 balance（未来其他家适配后）应按穿越发
        let claudeOld = snap(.claude, metrics: [UsageMetric(id: "balance", label: "重置余额", amount: 54)])
        let claudeNew = snap(.claude, metrics: [UsageMetric(id: "balance", label: "重置余额", amount: 8)])
        XCTAssertEqual(NotificationDecider.events(
            old: claudeOld, new: claudeNew, settings: prepaidOn, alreadyNotified: []
        ).count, 1)
    }

    func testPerProviderPrepaidUsesThatVendorsAmount() {
        var s = NotificationSettings()
        s.prepaidScope = .perProvider
        s.upsert(.deepseek, ProviderAlertConfig(prepaidAmountEnabled: true, prepaidAmount: 20))
        s.upsert(.claude, ProviderAlertConfig(prepaidAmountEnabled: true, prepaidAmount: 5))
        // DeepSeek 54→15 穿过 20，应发
        XCTAssertEqual(NotificationDecider.events(
            old: prepaidSnap(54), new: prepaidSnap(15),
            settings: s, alreadyNotified: []
        ).count, 1)
        // Claude 54→15 阈值是 5，15 仍在线上，不发
        XCTAssertTrue(NotificationDecider.events(
            old: prepaidSnap(54, provider: .claude),
            new: prepaidSnap(15, provider: .claude),
            settings: s, alreadyNotified: []
        ).isEmpty)
        XCTAssertTrue(s.needsBackgroundProbe)
    }

    func testPrepaidRearmsAfterTopUp() {
        let first = NotificationDecider.events(
            old: prepaidSnap(50), new: prepaidSnap(8),
            settings: prepaidOn, alreadyNotified: []
        )
        XCTAssertEqual(first.count, 1)
        // 充值回到同一金额再跌破同一点：穿越判定必须再发，不能被 previousAmount 键永久压住
        let second = NotificationDecider.events(
            old: prepaidSnap(50), new: prepaidSnap(8),
            settings: prepaidOn, alreadyNotified: [first[0].dedupeKey]
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].kind, .prepaidAmount)
        XCTAssertEqual(second[0].amount, 8)
    }

    func testOpenAIParserPopulatesPlanExpiresAt() {
        let expires = now.addingTimeInterval(20 * 86400)
        let iso = ISO8601DateFormatter().string(from: expires)
        let body = """
        {"accounts":{"default":{"entitlement":{"subscription_plan":"chatgptplusplan",
        "has_active_subscription":true,"expires_at":"\(iso)"}}}}
        """
        let session = """
        {"user":{"email":"a@b.com"},"accessToken":"tok","expires":"2099-01-01T00:00:00.000Z"}
        """
        let snap = OpenAIParser.parse(
            results: [
                "session": ProbeResult(status: 200, body: session),
                "accounts_check": ProbeResult(status: 200, body: body),
            ],
            now: now
        )
        XCTAssertEqual(snap.planName, "ChatGPT Plus")
        XCTAssertNotNil(snap.planExpiresAt)
        XCTAssertEqual(snap.planExpiresAt!.timeIntervalSince(expires), 0, accuracy: 1)
    }

    func testCustomPrepaidCrossingUsesAccountUUIDAndSkipsEvents() {
        let accountID = UUID()
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 50, pinned: true)],
            fetchedAt: now,
            status: .ok,
            isCustom: true
        )
        let new = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 8, pinned: true)],
            fetchedAt: now.addingTimeInterval(60),
            status: .ok,
            isCustom: true
        )
        XCTAssertTrue(
            NotificationDecider.events(old: old, new: new, settings: prepaidOn, alreadyNotified: []).isEmpty,
            "自定义快照不得走占位 provider 的 events"
        )
        let events = NotificationDecider.customPrepaidEvents(
            old: old, new: new, accountID: accountID, accountTitle: "中转A", settings: prepaidOn
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].accountID, accountID)
        XCTAssertEqual(events[0].accountTitle, "中转A")
        XCTAssertTrue(events[0].dedupeKey.contains(accountID.uuidString))
        XCTAssertEqual(events[0].amount, 8)
        XCTAssertNotEqual(events[0].accountTitle, ProviderID.claude.vendorName)
    }

    func testCustomPrepaidSkipsPerProviderScope() {
        var settings = prepaidOn
        settings.prepaidScope = .perProvider
        let accountID = UUID()
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 50, pinned: true)],
            fetchedAt: now, status: .ok, isCustom: true
        )
        let new = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 8, pinned: true)],
            fetchedAt: now, status: .ok, isCustom: true
        )
        XCTAssertTrue(NotificationDecider.customPrepaidEvents(
            old: old, new: new, accountID: accountID, accountTitle: "中转A", settings: settings
        ).isEmpty)
    }

    func testCustomPrepaidRecognizesBalanceLabelWithPathID() {
        let accountID = UUID()
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "remaining", label: "余额", amount: 50, pinned: true)],
            fetchedAt: now, status: .ok, isCustom: true
        )
        let new = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "remaining", label: "余额", amount: 8, pinned: true)],
            fetchedAt: now.addingTimeInterval(60), status: .ok, isCustom: true
        )
        let events = NotificationDecider.customPrepaidEvents(
            old: old, new: new, accountID: accountID, accountTitle: "中转A", settings: prepaidOn
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].amount, 8)
    }

    func testCustomPrepaidNoBalanceDoesNotFire() {
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 50, pinned: true)],
            fetchedAt: now, status: .ok, isCustom: true
        )
        let new = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 8, pinned: true)],
            fetchedAt: now, status: .ok, isCustom: true
        )
        XCTAssertTrue(NotificationDecider.customPrepaidEvents(
            old: old, new: new, accountID: UUID(), accountTitle: "中转A", settings: prepaidOn
        ).isEmpty)
    }

    func testCustomPrepaidPrefersCurrencyRemainingAndKeepsLabel() {
        let accountID = UUID()
        func crof(_ credits: Double, requests: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                provider: .claude,
                metrics: [
                    UsageMetric(id: "credits", label: "积分", amount: credits, currency: "USD", pinned: true, kind: "remaining"),
                    UsageMetric(id: "usable_requests", label: "剩余请求", amount: requests, pinned: true, kind: "remaining"),
                ],
                fetchedAt: now, status: .ok, isCustom: true
            )
        }
        let events = NotificationDecider.customPrepaidEvents(
            old: crof(50, requests: 250), new: crof(8, requests: 10),
            accountID: accountID, accountTitle: "Crof", settings: prepaidOn
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].amount, 8)
        XCTAssertEqual(events[0].metricID, "credits")
        XCTAssertEqual(events[0].metricLabel, "积分")
        XCTAssertNotEqual(events[0].metricLabel, "balance")
    }

    func testCustomPrepaidRecognizesPrepaidCreditsPathLabel() {
        let accountID = UUID()
        func snap(_ amount: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                provider: .claude,
                metrics: [
                    UsageMetric(
                        id: "prepaid_credits", label: "prepaid_credits",
                        amount: amount, pinned: true, kind: "remaining"
                    )
                ],
                fetchedAt: now, status: .ok, isCustom: true
            )
        }
        let events = NotificationDecider.customPrepaidEvents(
            old: snap(50), new: snap(8),
            accountID: accountID, accountTitle: "中转A", settings: prepaidOn
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].amount, 8)
        XCTAssertEqual(events[0].metricID, "prepaid_credits")
        XCTAssertEqual(events[0].metricLabel, "prepaid_credits")
        XCTAssertEqual(
            events[0].localizedMetricLabel(language: .en, isCustomAccount: true),
            L10n.tr("prepaid_credits", .en)
        )
        XCTAssertNotEqual(
            events[0].localizedMetricLabel(language: .en, isCustomAccount: true),
            L10n.metricLabel(
                provider: .claude, id: "prepaid_credits",
                fallback: "prepaid_credits", language: .en
            ),
            "自定义 prepaid_credits 不得映射成 Claude Usage credits"
        )
    }

    func testCustomPrepaidIgnoresRequestRemainingWithoutCurrency() {
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "usable_requests", label: "剩余请求", amount: 50, pinned: true, kind: "remaining")],
            fetchedAt: now, status: .ok, isCustom: true
        )
        let new = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "usable_requests", label: "剩余请求", amount: 8, pinned: true, kind: "remaining")],
            fetchedAt: now.addingTimeInterval(60), status: .ok, isCustom: true
        )
        XCTAssertTrue(NotificationDecider.customPrepaidEvents(
            old: old, new: new, accountID: UUID(), accountTitle: "Crof", settings: prepaidOn
        ).isEmpty)
    }

}

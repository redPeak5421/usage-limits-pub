import XCTest
@testable import UsageLimitsCore

final class StoreTests: XCTestCase {
    private func makeStore() -> (SharedStore, () -> Void) {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let cleanup = { defaults.removePersistentDomain(forName: suite) }
        return (SharedStore(defaults: defaults), cleanup)
    }

    func testSnapshotRoundTrip() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let snap = SharedStore.demoSnapshots(now: Date()).first!
        store.save(snap)
        let loaded = store.snapshot(for: .claude)
        XCTAssertEqual(loaded?.provider, .claude)
        XCTAssertEqual(loaded?.planName, snap.planName)
        XCTAssertEqual(loaded?.metrics.count, snap.metrics.count)
        XCTAssertEqual(loaded?.status, .ok)
        XCTAssertEqual(loaded?.billingCycle, snap.billingCycle)
    }

    func testInvalidSnapshotDoesNotOverwriteValidProviderOrAccountCacheAndRecordsDiagnostic() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let accountID = UUID()
        store.accounts = [ProviderAccount(id: accountID, provider: .claude, name: "Extra")]
        let valid = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "weekly", label: "周额度", usedPercent: 25, amount: 10)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ok,
            timeBreakdowns: [UsageBreakdown(
                id: "time", label: "今天", cost: 1, requests: 2, tokens: 3,
                series: [UsagePoint(at: Date(timeIntervalSince1970: 1_700_000_000), value: 4)]
            )],
            creditHistory: [CreditLedgerEntry(
                id: "credit", title: "充值", amount: 5, historyType: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        )
        XCTAssertTrue(store.save(valid))
        XCTAssertTrue(store.saveAccountSnapshot(valid, accountID: accountID))

        var invalidMetric = valid
        invalidMetric.metrics[0].usedPercent = .nan
        var invalidBreakdown = valid
        invalidBreakdown.timeBreakdowns?[0].series[0].value = .infinity
        var invalidHistory = valid
        invalidHistory.creditHistory?[0].amount = .infinity
        var invalidDate = valid
        invalidDate.planExpiresAt = Date(timeIntervalSince1970: .infinity)

        for invalid in [invalidMetric, invalidBreakdown, invalidHistory, invalidDate] {
            XCTAssertFalse(store.save(invalid))
            XCTAssertFalse(store.saveAccountSnapshot(invalid, accountID: accountID))
        }

        XCTAssertEqual(store.snapshot(for: .claude), valid)
        XCTAssertEqual(store.accountSnapshot(for: accountID), valid)
        XCTAssertEqual(store.diagnostics().filter { $0.contains("refused invalid snapshot") }.count, 8)
    }

    func testLegacyInvalidAndUnreadableCachesAreRejectedAndDiagnosedOnRead() throws {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let invalidPercent = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "weekly", label: "周额度", usedPercent: 101)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ok
        )
        let accountID = UUID()
        let invalidDate = ProviderSnapshot(
            provider: .zhipu,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ok,
            planExpiresAt: Date(timeIntervalSince1970: -315_619_200)
        )
        defaults.set(try encoder.encode(invalidPercent), forKey: "snapshot.claude")
        defaults.set(try encoder.encode(invalidDate), forKey: "snapshot.account.\(accountID.uuidString)")
        defaults.set(Data("{".utf8), forKey: "snapshot.openai")

        XCTAssertNil(store.snapshot(for: .claude))
        XCTAssertNil(store.accountSnapshot(for: accountID))
        XCTAssertNil(store.snapshot(for: .openai))
        let diagnostics = store.diagnostics()
        XCTAssertEqual(diagnostics.filter { $0.contains("refused invalid cached snapshot") }.count, 2)
        XCTAssertEqual(diagnostics.filter { $0.contains("refused unreadable cached snapshot") }.count, 1)
    }

    func testMetricOrderingKeepsUnknownAtEndAndIgnoresStale() {
        func m(_ id: String) -> UsageMetric { UsageMetric(id: id, label: id, usedPercent: 1) }
        let metrics = [m("five_hour"), m("seven_day"), m("opus"), m("sonnet")]
        // 用户把周额度放最前、opus 其次；sonnet 没列入排最后；gone 已不存在被忽略
        let ordered = MetricOrdering.apply(metrics, order: ["seven_day", "gone", "opus"])
        XCTAssertEqual(ordered.map(\.id), ["seven_day", "opus", "five_hour", "sonnet"])
        XCTAssertEqual(MetricOrdering.apply(metrics, order: []).map(\.id), metrics.map(\.id))
    }

    func testMetricOrderAppliesWhenReadingSnapshots() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let snap = SharedStore.demoSnapshots(now: Date()).first { $0.provider == .claude }!
        XCTAssertGreaterThan(snap.metrics.count, 1)
        store.save(snap)
        let reversed = snap.metrics.map(\.id).reversed()
        store.setMetricOrder(Array(reversed), for: SharedStore.metricOrderKey(provider: .claude))
        XCTAssertEqual(store.snapshot(for: .claude)?.metrics.map(\.id), Array(reversed))
        // 附加账号走账号键
        let id = UUID()
        store.accounts = [ProviderAccount(id: id, provider: .claude, name: "Extra")]
        store.saveAccountSnapshot(snap, accountID: id)
        store.setMetricOrder(Array(reversed), for: SharedStore.metricOrderKey(accountID: id))
        XCTAssertEqual(store.accountSnapshot(for: id)?.metrics.map(\.id), Array(reversed))
        // 清除后回到解析器顺序
        store.setMetricOrder([], for: SharedStore.metricOrderKey(provider: .claude))
        XCTAssertEqual(store.snapshot(for: .claude)?.metrics.map(\.id), snap.metrics.map(\.id))
    }

    func testCardRefreshRainbowGlowDefaultsOffAndRoundTrips() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertFalse(store.cardRefreshRainbowGlow)
        store.cardRefreshRainbowGlow = true
        XCTAssertTrue(store.cardRefreshRainbowGlow)
        store.cardRefreshRainbowGlow = false
        XCTAssertFalse(store.cardRefreshRainbowGlow)
    }

    func testCardTintedBarsAndShimmerDefaultOffAndRoundTrip() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertFalse(store.cardTintedBars)
        XCTAssertFalse(store.cardBarShimmer)
        store.cardTintedBars = true
        store.cardBarShimmer = true
        XCTAssertTrue(store.cardTintedBars)
        XCTAssertTrue(store.cardBarShimmer)
        // 三个开关的文案随 Pro 走（ProL10n 注册），公开表里不再有
        for key in ["settings.cardRefreshGlow", "settings.cardTintedBars", "settings.cardBarShimmer"] {
            XCTAssertEqual(L10n.tr(key, .en), key, "\(key) 不应留在公开表")
        }
    }

    func testAppThemeRoundTripDefaultsToSystem() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertEqual(store.appTheme, .system)
        store.appTheme = .dark
        XCTAssertEqual(store.appTheme, .dark)
    }

    func testDashboardThemeRoundTripDefaultsToFlat() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertEqual(store.dashboardTheme, .flat)
        store.dashboardTheme = .helix
        XCTAssertEqual(store.dashboardTheme, .helix)
        XCTAssertEqual(DashboardTheme.allCases, [.flat, .roulette, .helix])
        XCTAssertEqual(L10n.tr(DashboardTheme.flat.titleKey, .zh), "平铺")
        XCTAssertEqual(L10n.tr(DashboardTheme.roulette.titleKey, .zh), "轮盘")
        XCTAssertEqual(L10n.tr(DashboardTheme.helix.titleKey, .zh), "螺旋")
        for key in ["settings.dashboardTheme", "settings.dashboardTheme.footer"] + DashboardTheme.allCases.map(\.titleKey) {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
    }

    /// 折叠态计量条数：平铺 1、轮盘 / 螺旋 2；没有有用量的指标时仍兜底第一条。
    func testCollapsedMetricsLimitFollowsLayout() {
        let snaps = SharedStore.demoSnapshots(now: Date())
        let claude = snaps.first { $0.provider == .claude }!
        XCTAssertGreaterThanOrEqual(claude.activeMetrics.count, 2)
        XCTAssertEqual(claude.collapsedMetrics(limit: 1).map(\.id), [claude.collapsedMetric!.id])
        XCTAssertEqual(claude.collapsedMetrics(limit: 2).map(\.id), Array(claude.activeMetrics.prefix(2)).map(\.id))
        XCTAssertEqual(claude.collapsedMetrics(limit: 0).count, 1, "下限 1 条")
        var idle = claude
        idle.metrics = claude.metrics.map { metric in
            var copy = metric
            copy.pinned = nil
            copy.usedPercent = 0
            copy.remaining = nil
            copy.total = nil
            copy.amount = nil
            return copy
        }
        XCTAssertTrue(idle.activeMetrics.isEmpty)
        XCTAssertEqual(idle.collapsedMetrics(limit: 2).map(\.id), [idle.metrics[0].id])
    }

    func testSaveAccountSnapshotRefusesUnknownAccount() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let ghost = UUID()
        let snap = SharedStore.demoSnapshots(now: Date())[0]
        XCTAssertFalse(store.saveAccountSnapshot(snap, accountID: ghost))
        XCTAssertNil(store.accountSnapshot(for: ghost))
        XCTAssertTrue(store.diagnostics().contains { $0.contains("unknown account") })
    }

    func testRemoveSnapshot() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.save(SharedStore.demoSnapshots(now: Date())[0])
        store.removeSnapshot(for: .claude)
        XCTAssertNil(store.snapshot(for: .claude))
    }

    func testProviderOrderPersistsAndAppendsNewProviders() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertEqual(store.providerOrder, ProviderID.allCases)
        store.providerOrder = [.grok, .claude, .cursor, .openai]
        XCTAssertEqual(
            store.providerOrder,
            [.grok, .claude, .cursor, .openai] + ProviderID.allCases.filter {
                ![ProviderID.grok, .claude, .cursor, .openai].contains($0)
            }
        )
        // 存量顺序缺项时（如未来新增服务商），自动追加到末尾
        store.providerOrder = [.cursor, .openai]
        let after = [.cursor, .openai] + ProviderID.allCases.filter { $0 != .cursor && $0 != .openai }
        XCTAssertEqual(store.providerOrder, after)
        // 启用列表跟随全局顺序
        store.setEnabled(false, for: .openai)
        XCTAssertEqual(store.enabledProviders, after.filter { $0 != .openai })
    }

    func testDemoSnapshotsCoverAllProviders() {
        let snaps = SharedStore.demoSnapshots(now: Date())
        XCTAssertEqual(Set(snaps.map(\.provider)), Set(ProviderID.allCases))
        XCTAssertTrue(snaps.allSatisfy { !$0.metrics.isEmpty && $0.status == .ok })
    }

    func testDemoModeSwitchesDisplaySnapshots() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertTrue(store.displaySnapshots().isEmpty)
        store.demoMode = true
        XCTAssertEqual(store.displaySnapshots().count, ProviderID.allCases.count)
        XCTAssertNotNil(store.displaySnapshot(for: .grok))
        store.demoMode = false
        XCTAssertTrue(store.displaySnapshots().isEmpty)
    }

    func testProviderEnabledDefaultsToTrueAndPersists() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertTrue(store.isEnabled(.claude))
        XCTAssertEqual(store.enabledProviders, ProviderID.allCases)
        store.setEnabled(false, for: .openai)
        XCTAssertFalse(store.isEnabled(.openai))
        XCTAssertEqual(store.enabledProviders, ProviderID.allCases.filter { $0 != .openai })
        store.setEnabled(true, for: .openai)
        XCTAssertTrue(store.isEnabled(.openai))
    }

    func testDisabledProviderHiddenFromDisplaySnapshots() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        for snap in SharedStore.demoSnapshots(now: Date()) {
            store.save(snap)
        }
        store.setEnabled(false, for: .grok)
        // 真实缓存路径
        XCTAssertEqual(Set(store.displaySnapshots().map(\.provider)), Set(ProviderID.allCases).subtracting([.grok]))
        XCTAssertNil(store.displaySnapshot(for: .grok))
        XCTAssertNotNil(store.displaySnapshot(for: .claude))
        // 演示模式路径同样过滤
        store.demoMode = true
        XCTAssertEqual(Set(store.displaySnapshots().map(\.provider)), Set(ProviderID.allCases).subtracting([.grok]))
        XCTAssertNil(store.displaySnapshot(for: .grok))
        // 底层快照仍在（开关不动数据）
        XCTAssertNotNil(store.snapshot(for: .grok))
    }

    /// 诊断日志先进内存缓冲、合并落盘：追加不立刻写 UserDefaults；读取/flush 时才写，顺序不变；清空连缓冲一起清。
    func testDiagnosticsAreBufferedAndFlushedInOrder() {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        store.appendDiagnostic("a")
        store.appendDiagnostic("b")
        XCTAssertNil(defaults.stringArray(forKey: "diagnostics"), "追加不得同步整体落盘")
        store.flushDiagnostics()
        XCTAssertEqual(defaults.stringArray(forKey: "diagnostics")?.count, 2)
        store.appendDiagnostic("c")
        let lines = store.diagnostics()
        XCTAssertEqual(lines.count, 3, "读取前先 flush 缓冲")
        XCTAssertTrue(lines[0].hasSuffix("] a") && lines[1].hasSuffix("] b") && lines[2].hasSuffix("] c"))
        store.appendDiagnostic("d")
        store.clearDiagnostics()
        XCTAssertTrue(store.diagnostics().isEmpty, "清空要连缓冲一起清")
    }

    func testDiagnosticsRingBufferCapsAt500() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        for i in 0..<530 {
            store.appendDiagnostic("行 \(i)")
        }
        let lines = store.diagnostics()
        XCTAssertEqual(lines.count, 500)
        XCTAssertTrue(lines.last!.contains("行 529"))
        XCTAssertTrue(lines.first!.contains("行 30"))
        store.clearDiagnostics()
        XCTAssertTrue(store.diagnostics().isEmpty)
    }

    func testAutoRefreshMinutesRoundTripViaSharedStore() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        XCTAssertEqual(AutoRefreshInterval.minutes, 0...60)
        for n in [0, 1, 7, 15, 60] {
            store.autoRefreshInterval = AutoRefreshInterval.seconds(minutes: n)
            XCTAssertEqual(store.autoRefreshInterval, Double(n) * 60, "\(n) 分钟应落盘为 \(n * 60) 秒")
            XCTAssertEqual(AutoRefreshInterval.minutes(seconds: store.autoRefreshInterval), n)
        }
        store.autoRefreshInterval = AutoRefreshInterval.seconds(minutes: 0)
        XCTAssertEqual(store.autoRefreshInterval, 0)
    }

    func testAutoRefreshHelpersSafelyClampNonFinitePersistedValues() {
        XCTAssertEqual(AutoRefreshInterval.clamped(.nan), 0)
        XCTAssertEqual(AutoRefreshInterval.clamped(.infinity), Double(AutoRefreshInterval.maxSeconds))
        XCTAssertEqual(AutoRefreshInterval.clamped(-.infinity), 0)
        XCTAssertEqual(AutoRefreshInterval.choice(fromStored: .nan), AutoRefreshChoice(amount: 0, unit: .minutes))
        XCTAssertEqual(AutoRefreshInterval.choice(fromStored: .infinity), AutoRefreshChoice(amount: 60, unit: .minutes))
        XCTAssertEqual(AutoRefreshInterval.minutes(seconds: .nan), 0)
    }

    func testAutoRefreshSharedStoreClampsRawGetterAndSetterValues() throws {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        let cases: [(Double, Double)] = [
            (.nan, 0), (.infinity, 3600), (-.infinity, 0), (1e308, 3600),
        ]
        for (raw, expected) in cases {
            defaults.set(raw, forKey: "autoRefreshInterval")
            XCTAssertEqual(store.autoRefreshInterval, expected)
            store.autoRefreshInterval = raw
            XCTAssertEqual(defaults.double(forKey: "autoRefreshInterval"), expected)
        }
    }

    func testSafeDurationAndSliderIndexRejectHostileDoublesWithoutChangingNormalRounding() {
        XCTAssertEqual(SafeDuration.nanoseconds(seconds: 0), 0)
        XCTAssertEqual(SafeDuration.nanoseconds(seconds: 0.25), 250_000_000)
        XCTAssertEqual(SafeDuration.nanoseconds(seconds: 1.23456789), 1_234_567_890)
        for invalid in [-1.0, .nan, .infinity, -.infinity, 1e308] {
            XCTAssertNil(SafeDuration.nanoseconds(seconds: invalid))
        }

        XCTAssertEqual(AutoRefreshInterval.sliderStep(at: .nan), 0)
        XCTAssertEqual(AutoRefreshInterval.sliderStep(at: -.infinity), 0)
        XCTAssertEqual(AutoRefreshInterval.sliderStep(at: .infinity), 3600)
        XCTAssertEqual(AutoRefreshInterval.sliderStep(at: 1e308), 3600)
        XCTAssertEqual(AutoRefreshInterval.sliderStep(at: 2.6), 60)
    }

    func testAppUsesSafeSliderSleepEpochAndUIIntegerBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8)
        let fetcher = try String(contentsOf: root.appendingPathComponent("App/Networking/WebViewFetcher.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8)
        let notifications = try String(contentsOf: root.appendingPathComponent("App/Views/NotificationSettingsView.swift"), encoding: .utf8)
        let color = try String(contentsOf: root.appendingPathComponent("App/Views/ColorEditorSheet.swift"), encoding: .utf8)

        XCTAssertTrue(appState.contains("SafeDuration.nanoseconds"))
        XCTAssertFalse(appState.contains("UInt64(remaining *"))
        XCTAssertFalse(appState.contains("UInt64(interval *"))
        XCTAssertTrue(fetcher.contains("SafeDuration.nanoseconds"))
        XCTAssertTrue(fetcher.contains("IntegerFormat.truncating"))
        XCTAssertFalse(fetcher.contains("UInt64(seconds *"))
        XCTAssertFalse(fetcher.contains("Int(Date().timeIntervalSince1970)"))
        XCTAssertTrue(settings.contains("AutoRefreshInterval.sliderStep(at:"))
        XCTAssertFalse(settings.contains("sliderSteps[Int("))
        XCTAssertTrue(notifications.contains("UsagePresentation.roundedUsedPercent"))
        XCTAssertFalse(notifications.contains("Int(thresholdDraft)"))
        XCTAssertTrue(color.contains("IntegerFormat.rounded"))
        XCTAssertFalse(color.contains("Int(round("))
    }

    func testSliderStepsIncludeTenAndThirtySeconds() {
        XCTAssertTrue(AutoRefreshInterval.sliderSteps.contains(10))
        XCTAssertTrue(AutoRefreshInterval.sliderSteps.contains(30))
        XCTAssertTrue(AutoRefreshInterval.sliderSteps.contains(0))
        XCTAssertTrue(AutoRefreshInterval.sliderSteps.contains(60))
        XCTAssertEqual(AutoRefreshInterval.unit(forStored: 10), .seconds)
        XCTAssertEqual(AutoRefreshInterval.unit(forStored: 30), .seconds)
        XCTAssertEqual(AutoRefreshInterval.unit(forStored: 0), .minutes)
        XCTAssertEqual(AutoRefreshInterval.unit(forStored: 60), .minutes)
        XCTAssertEqual(AutoRefreshInterval.displayNumber(10), 10)
        XCTAssertEqual(AutoRefreshInterval.displayNumber(30), 30)
        XCTAssertEqual(AutoRefreshInterval.displayNumber(600), 10)
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.autoRefreshInterval = 10
        XCTAssertEqual(store.autoRefreshInterval, 10)
        store.autoRefreshInterval = 30
        XCTAssertEqual(store.autoRefreshInterval, 30)
        XCTAssertEqual(AutoRefreshInterval.applyingTypedAmount("10", currentUnit: .seconds).storedSeconds, 10)
        XCTAssertEqual(AutoRefreshInterval.applyingTypedAmount("30", currentUnit: .seconds).storedSeconds, 30)
        XCTAssertEqual(AutoRefreshInterval.applyingTypedAmount("10", currentUnit: .minutes).storedSeconds, 600)
    }

    func testTypedNinetyMinutesBecomesNinetySecondsNotOnePointFive() {
        let typed = AutoRefreshInterval.applyingTypedAmount("90", currentUnit: .minutes)
        XCTAssertEqual(typed.amount, 90, "不得改用户正在输入的数字")
        XCTAssertEqual(typed.unit, .seconds, "超过 60 的分钟应改单位为秒")
        XCTAssertEqual(typed.storedSeconds, 90)
        XCTAssertEqual(AutoRefreshInterval.displayNumber(90), 90)
        XCTAssertEqual(AutoRefreshInterval.unit(forStored: 90), .seconds)

        let keepSeconds = AutoRefreshInterval.applyingTypedAmount("90", currentUnit: .seconds)
        XCTAssertEqual(keepSeconds.amount, 90)
        XCTAssertEqual(keepSeconds.unit, .seconds)

        let sixtyMin = AutoRefreshInterval.applyingTypedAmount("60", currentUnit: .minutes)
        XCTAssertEqual(sixtyMin.amount, 60)
        XCTAssertEqual(sixtyMin.unit, .minutes)
        XCTAssertEqual(sixtyMin.storedSeconds, 3600)

        let tooBig = AutoRefreshInterval.applyingTypedAmount("4000", currentUnit: .minutes)
        XCTAssertLessThanOrEqual(tooBig.storedSeconds, 3600)

        let switchRejected = AutoRefreshInterval.applyingUnitSwitch(amount: 90, to: .minutes)
        XCTAssertEqual(switchRejected.amount, 90)
        XCTAssertEqual(switchRejected.unit, .seconds)

        let switchOK = AutoRefreshInterval.applyingUnitSwitch(amount: 30, to: .minutes)
        XCTAssertEqual(switchOK.amount, 30)
        XCTAssertEqual(switchOK.unit, .minutes)
        XCTAssertEqual(switchOK.storedSeconds, 1800)

        XCTAssertEqual(AutoRefreshInterval.applyingTypedAmount("1.5", currentUnit: .minutes).amount, 1,
                       "禁止小数，点号后的数字丢弃")
        XCTAssertEqual(AutoRefreshInterval.applyingTypedAmount("1.5", currentUnit: .minutes).unit, .minutes)
    }

    func testSettingsViewSliderAndMinuteField() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/SettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("Slider("), "自动刷新应保留滑动条")
        XCTAssertFalse(src.contains(".pickerStyle(.wheel)"), "分钟数不再用滚轮")
        XCTAssertTrue(src.contains("TextField"), "分钟数位置应支持手动输入")
        XCTAssertTrue(src.contains("settings.autoRefresh.unit"), "单位固定在输入框后面")
        XCTAssertTrue(src.contains("settings.autoRefresh.unitSeconds"), "不足一分钟时应显示秒")
        XCTAssertTrue(src.contains("AutoRefreshInterval.applyingTypedAmount"), "输入须保持原数字、必要时改单位")
        XCTAssertTrue(src.contains("AutoRefreshInterval.applyingUnitSwitch"), "秒与分钟可切换且互斥")
        XCTAssertTrue(src.contains("AutoRefreshInterval.sliderSteps"), "滑块档位含 10s/30s 与分钟档")
        XCTAssertTrue(src.contains("AutoRefreshUnit.seconds") || src.contains(".seconds"), "单位可切换到秒")
        XCTAssertTrue(src.contains("AutoRefreshUnit.minutes") || src.contains(".minutes"), "单位可切换到分钟")
        XCTAssertFalse(src.contains("minuteSteps"), "档位应走秒数组，以便包含 10s/30s")
        XCTAssertTrue(src.contains("Capsule()"), "数值框圆角应与胶囊分段一致")
        XCTAssertTrue(src.contains("EqualWidthUnitPicker"), "秒与分钟占位宽度须相同")
        XCTAssertTrue(src.contains("AutoRefreshFieldChrome.height"), "数值框与单位分段高度一致")
        XCTAssertTrue(src.contains("AutoRefreshFieldChrome.font"), "数值框与单位分段字重/字号一致")
        XCTAssertTrue(src.contains("frame(maxWidth: .infinity, maxHeight: .infinity)"), "秒/分钟两档等宽且同高")
        // 编辑器可被抽成独立 struct、缩进会变，只认语义不认空白
        let collapsed = src.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(
            collapsed.contains("applyingTypedAmount(cleaned, currentUnit: unit), persist: true"),
            "改时间应直接写入，不必点完成"
        )
        XCTAssertEqual(L10n.tr("settings.autoRefresh.unit", .zh), "分钟")
        XCTAssertEqual(L10n.tr("settings.autoRefresh.unitSeconds", .zh), "秒")
        XCTAssertTrue(L10n.tr("settings.autoRefresh.footer", .zh).contains("60 分钟"))
        XCTAssertTrue(L10n.tr("settings.autoRefresh.footer", .zh).contains("打开"))
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertNotEqual(L10n.tr("settings.autoRefresh.unitSeconds", lang), "settings.autoRefresh.unitSeconds")
        }
    }

    func testSettingsRegroupSourceContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8
        )
        XCTAssertTrue(settings.contains("AppearanceSettingsView()"), "外观为二级页")
        XCTAssertTrue(settings.contains("edition.settingsEntry()"), "扩展入口走 Edition 扩展点")
        XCTAssertTrue(settings.contains("autoRefreshExpanded"), "自动刷新就地折叠")
        XCTAssertTrue(settings.contains("AutoRefreshEditor"), "编辑器抽成独立视图但留在本文件")
        XCTAssertTrue(settings.contains("settings.refreshGroup"))
        XCTAssertTrue(settings.contains("settings.advanced"))
        for moved in ["settings.language", "settings.usageDisplay", "settings.resetTime", "AppIconView()"] {
            XCTAssertFalse(settings.contains(moved), "\(moved) 应移到外观页")
        }

        let appearance = try String(
            contentsOf: root.appendingPathComponent("App/Views/AppearanceSettingsView.swift"), encoding: .utf8
        )
        for key in ["settings.language", "settings.theme", "settings.dashboardTheme", "settings.usageDisplay",
                    "settings.resetTime"] {
            XCTAssertTrue(appearance.contains(key), "外观页应包含 \(key)")
        }
        XCTAssertTrue(appearance.contains("edition.appearanceSection()"), "卡片效果开关节走 Edition 扩展点")

        for key in ["settings.appearance", "settings.refreshGroup", "settings.advanced"] {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
    }

    func testDashboardAccessibilityCopyMatchesExactFiveLanguageMatrix() {
        let expected: [String: [AppLanguage: String]] = [
            "dashboard.action.expand": [
                .zh: "展开当前账号", .en: "Expand account", .ja: "アカウントを展開",
                .fr: "Développer le compte", .ru: "Развернуть аккаунт",
            ],
            "dashboard.action.collapse": [
                .zh: "收起当前账号", .en: "Collapse account", .ja: "アカウントを閉じる",
                .fr: "Réduire le compte", .ru: "Свернуть аккаунт",
            ],
            "dashboard.action.moveEarlier": [
                .zh: "向前移动", .en: "Move earlier", .ja: "前へ移動",
                .fr: "Déplacer avant", .ru: "Переместить раньше",
            ],
            "dashboard.action.moveLater": [
                .zh: "向后移动", .en: "Move later", .ja: "後ろへ移動",
                .fr: "Déplacer après", .ru: "Переместить позже",
            ],
            "dashboard.action.refreshAll": [
                .zh: "刷新全部账号", .en: "Refresh all accounts", .ja: "すべて更新",
                .fr: "Tout actualiser", .ru: "Обновить все аккаунты",
            ],
            "dashboard.action.resetHelix": [
                .zh: "螺旋竖直", .en: "Straighten helix", .ja: "らせんを垂直に",
                .fr: "Redresser l’hélice", .ru: "Выпрямить спираль",
            ],
            "dashboard.position": [
                .zh: "%d / %d", .en: "%d of %d", .ja: "%d / %d",
                .fr: "%d sur %d", .ru: "%d из %d",
            ],
            "dashboard.status.available": [
                .zh: "可用", .en: "Available", .ja: "利用可能",
                .fr: "Disponible", .ru: "Доступно",
            ],
        ]
        XCTAssertEqual(expected.count, 8)


        for (key, translations) in expected {
            XCTAssertEqual(translations.count, 5, "\(key) must define exactly five concrete languages")
            for language in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                XCTAssertEqual(L10n.tr(key, language), translations[language], "\(key) \(language)")
            }
        }

        let formatted: [AppLanguage: String] = [
            .zh: "3 / 11", .en: "3 of 11", .ja: "3 / 11",
            .fr: "3 sur 11", .ru: "3 из 11",
        ]
        for language in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertEqual(
                L10n.tr("dashboard.position", language, 3, 11),
                formatted[language],
                "dashboard.position must preserve current/total argument order for \(language)"
            )
        }
    }

    func testCardRefreshGlowReadsEditionOverlay() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"), encoding: .utf8)
        XCTAssertTrue(card.contains("refreshGlowOverlay(cornerRadius:"), "卡片刷新装饰走 Edition 叠层")
        XCTAssertFalse(card.contains("GlowRim("), "SwiftUI 装饰实现不在本仓库")
    }
}

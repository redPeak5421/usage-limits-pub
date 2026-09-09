import XCTest
@testable import UsageLimitsCore

/// 展示口径（按已用 / 按剩余）只影响展示层：条 / 环的百分比与数值文本，快照与阈值不受影响。
final class UsagePresentationTests: XCTestCase {
    func testBarPercentFlipsOnlyInRemainingMode() {
        XCTAssertEqual(UsagePresentation.barPercent(used: 42, mode: .used), 42)
        XCTAssertEqual(UsagePresentation.barPercent(used: 42, mode: .remaining), 58)
        // 越界钳制后再翻转
        XCTAssertEqual(UsagePresentation.barPercent(used: 130, mode: .used), 100)
        XCTAssertEqual(UsagePresentation.barPercent(used: 130, mode: .remaining), 0)
        XCTAssertEqual(UsagePresentation.barPercent(used: -5, mode: .remaining), 100)
    }

    func testPercentTextRoundsShownValue() {
        XCTAssertEqual(UsagePresentation.percentText(used: 42.4, mode: .used), "42%")
        XCTAssertEqual(UsagePresentation.percentText(used: 42.4, mode: .remaining), "58%")
        XCTAssertEqual(UsagePresentation.percentText(used: 0, mode: .remaining), "100%")
    }

    func testNonFinitePercentIsSafeAndOutOfRangeStillClamps() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(UsagePresentation.barPercent(used: invalid, mode: .used), 0)
            XCTAssertEqual(UsagePresentation.barPercent(used: invalid, mode: .remaining), 0)
            XCTAssertEqual(UsagePresentation.percentText(used: invalid, mode: .used), "—")
            XCTAssertEqual(UsagePresentation.percentText(used: invalid, mode: .remaining), "—")
        }
        XCTAssertEqual(UsagePresentation.barPercent(used: -1, mode: .used), 0)
        XCTAssertEqual(UsagePresentation.barPercent(used: 101, mode: .used), 100)
    }

    func testValidUsedPercentAndRiskLevelRejectInvalidDomain() {
        let invalid = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 101]
        for value in invalid {
            XCTAssertNil(UsagePresentation.validUsedPercent(value))
            XCTAssertNil(UsagePresentation.roundedUsedPercent(value))
            XCTAssertEqual(UsagePresentation.riskLevel(for: value), .unknown)
        }
        XCTAssertEqual(UsagePresentation.validUsedPercent(0), 0)
        XCTAssertEqual(UsagePresentation.validUsedPercent(100), 100)
        XCTAssertEqual(UsagePresentation.roundedUsedPercent(42.6), 43)
        XCTAssertEqual(UsagePresentation.riskLevel(for: 0), .low)
        XCTAssertEqual(UsagePresentation.riskLevel(for: 60), .medium)
        XCTAssertEqual(UsagePresentation.riskLevel(for: 85), .high)
    }

    func testMetricOrderSheetUsesSafeSharedPercentPresenter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/MetricOrderSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("UsagePresentation.percentText"))
        XCTAssertTrue(source.contains("@Environment(\\.usageDisplayMode)"))
        XCTAssertFalse(source.contains("Int(percent"), "排序预览不得自行把未知百分比转 Int")
    }

    func testProviderCardUsesSafeIntegerFormatterForRemoteCountsAndCredits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("IntegerFormat.string"))
        XCTAssertTrue(source.contains("IntegerFormat.signedString"))
        XCTAssertFalse(source.contains("Int(key.requests"))
        XCTAssertFalse(source.contains("Int(value.rounded())"))
        XCTAssertFalse(source.contains("Int(entry.signedAmount.rounded())"))
    }

    func testProductionRiskColorsUseValidatedRiskLevel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let branding = try String(
            contentsOf: root.appendingPathComponent("SharedUI/Branding.swift"), encoding: .utf8
        )
        let share = try String(
            contentsOf: root.appendingPathComponent("App/Share/ShareCardView.swift"), encoding: .utf8
        )
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(branding.contains("UsagePresentation.riskLevel"))
        XCTAssertTrue(share.contains("UsagePresentation.riskLevel"))
        XCTAssertTrue(card.contains("usageLevelColor(metric.usedPercent)"))
    }

    func testMetricValueAlwaysUsesFinitePercentBeforeCountOrPercentDisplayValue() {
        let count = UsageMetric(
            id: "requests", label: "Requests", usedPercent: 25,
            remaining: 75, total: 100, displayValue: "75/100 left"
        )
        let minimax = UsageMetric(
            id: "five_hour", label: "5h", usedPercent: 12,
            displayValue: "12%/100%"
        )

        XCTAssertEqual(UsagePresentation.valueText(for: count, language: .en, mode: .used), "25%")
        XCTAssertEqual(UsagePresentation.valueText(for: count, language: .en, mode: .remaining), "75%")
        XCTAssertEqual(UsagePresentation.valueText(for: minimax, language: .zh, mode: .used), "12%")
        XCTAssertEqual(UsagePresentation.valueText(for: minimax, language: .zh, mode: .remaining), "88%")
    }

    func testMetricValueKeepsNonPercentSemanticsAcrossModes() {
        let count = UsageMetric(id: "requests", label: "Requests", remaining: 7, total: 10)
        let unlimited = UsageMetric(id: "credits", label: "Credits", detail: "无限制", displayValue: "∞")
        let uncapped = UsageMetric(id: "pool", label: "Pool", detail: "无上限")
        let billing = UsageMetric(id: "rate", label: "Rate", displayValue: "高峰 1x")
        let amount = UsageMetric(id: "balance", label: "Balance", amount: 12.5, currency: "USD")

        for mode in UsageDisplayMode.allCases {
            XCTAssertEqual(UsagePresentation.valueText(for: count, language: .en, mode: mode), "7/10 left")
            XCTAssertEqual(UsagePresentation.valueText(for: unlimited, language: .zh, mode: mode), "∞")
            XCTAssertEqual(UsagePresentation.valueText(for: uncapped, language: .en, mode: mode), "∞")
            XCTAssertEqual(UsagePresentation.valueText(for: billing, language: .zh, mode: mode), "高峰 1x")
            XCTAssertEqual(UsagePresentation.valueText(for: amount, language: .en, mode: mode), "$12.50")
        }
    }

    func testMetricValueIgnoresNonFinitePercentAndCountWithoutTrapping() {
        let fallback = UsageMetric(
            id: "bad", label: "Bad", usedPercent: .infinity,
            remaining: .nan, total: .infinity, displayValue: "fallback"
        )
        XCTAssertEqual(UsagePresentation.valueText(for: fallback, language: .en, mode: .remaining), "fallback")
        XCTAssertEqual(
            UsagePresentation.valueText(
                for: UsageMetric(id: "bad", label: "Bad", remaining: .infinity, total: 10),
                language: .en, mode: .used
            ),
            "—"
        )
    }

    func testUsageDisplayKeysExistInAllLanguages() {
        for key in ["settings.usageDisplay", "settings.usageDisplay.used", "settings.usageDisplay.remaining", "settings.usageDisplay.footer"] {
            for lang in AppLanguage.concrete {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
    }

    func testStoreRoundTripDefaultsToUsed() {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        XCTAssertEqual(store.usageDisplayMode, .used)
        store.usageDisplayMode = .remaining
        XCTAssertEqual(store.usageDisplayMode, .remaining)
        defaults.set("garbage", forKey: "usageDisplayMode")
        XCTAssertEqual(store.usageDisplayMode, .used)
    }

    func testShareModelUsesRemainingTextButKeepsUsedPercentForColor() {
        let now = Date()
        let snap = ProviderSnapshot(
            provider: .claude, planName: "Claude Pro",
            metrics: [UsageMetric(id: "five_hour", label: "Current session", usedPercent: 30, resetsAt: now.addingTimeInterval(3600))],
            fetchedAt: now, status: .ok
        )
        let used = ShareImageComposer.model(snapshots: [snap], expanded: true, language: .zh, hasIcon: false, hasQR: false)
        let left = ShareImageComposer.model(snapshots: [snap], expanded: true, language: .zh, hasIcon: false, hasQR: false, displayMode: .remaining)
        XCTAssertEqual(used.sections.first?.meters.first?.valueText, "30%")
        XCTAssertEqual(left.sections.first?.meters.first?.valueText, "70%")
        XCTAssertEqual(left.sections.first?.meters.first?.usedPercent, 30)
        XCTAssertEqual(left.displayMode, .remaining)
        XCTAssertEqual(used.displayMode, .used)
    }

    func testShareModelUsesSameMetricPresenterForCountAndPercentPair() {
        let now = Date()
        let snap = ProviderSnapshot(
            provider: .minimax,
            metrics: [
                UsageMetric(
                    id: "count", label: "Count", usedPercent: 25,
                    remaining: 75, total: 100
                ),
                UsageMetric(
                    id: "pair", label: "Pair", usedPercent: 12,
                    displayValue: "12%/100%"
                ),
            ],
            fetchedAt: now, status: .ok
        )
        let used = ShareImageComposer.model(
            snapshots: [snap], expanded: true, language: .en,
            hasIcon: false, hasQR: false, options: .init(hideUnusedMetrics: false)
        )
        let remaining = ShareImageComposer.model(
            snapshots: [snap], expanded: true, language: .en,
            hasIcon: false, hasQR: false, options: .init(hideUnusedMetrics: false),
            displayMode: .remaining
        )
        XCTAssertEqual(used.sections[0].meters.map(\.valueText), ["25%", "12%"])
        XCTAssertEqual(remaining.sections[0].meters.map(\.valueText), ["75%", "88%"])
    }
}

final class ResetTimeStyleTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testAbsoluteStyleBucketsTodayTomorrowAndLater() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = date(2026, 8, 28, 10, 0, cal: cal)
        XCTAssertEqual(TimeFormat.reset(date(2026, 8, 28, 14, 30, cal: cal), now: now, language: .zh, style: .absolute, calendar: cal), "14:30")
        XCTAssertEqual(TimeFormat.reset(date(2026, 8, 29, 9, 5, cal: cal), now: now, language: .zh, style: .absolute, calendar: cal), "明天 09:05")
        XCTAssertEqual(TimeFormat.reset(date(2026, 8, 29, 9, 5, cal: cal), now: now, language: .en, style: .absolute, calendar: cal), "tomorrow 09:05")
        XCTAssertEqual(TimeFormat.reset(date(2026, 9, 3, 0, 0, cal: cal), now: now, language: .zh, style: .absolute, calendar: cal), "09-03 00:00")
        // 已过期与倒计时口径一致
        XCTAssertEqual(TimeFormat.reset(now.addingTimeInterval(-1), now: now, language: .zh, style: .absolute, calendar: cal), L10n.tr("time.reset", .zh))
    }

    func testCountdownStyleMatchesRelative() {
        let now = Date()
        let later = now.addingTimeInterval(3 * 3600 + 12 * 60)
        XCTAssertEqual(TimeFormat.reset(later, now: now, language: .zh, style: .countdown), TimeFormat.relative(later, now: now, language: .zh))
    }

    func testNonFiniteDateUsesSafePlaceholderInEveryResetStyle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for invalid in [
            Date(timeIntervalSinceReferenceDate: .infinity),
            Date(timeIntervalSinceReferenceDate: -.infinity),
        ] {
            XCTAssertEqual(TimeFormat.relative(invalid, now: now, language: .en), "—")
            XCTAssertEqual(TimeFormat.reset(invalid, now: now, language: .en, style: .countdown), "—")
            XCTAssertEqual(TimeFormat.reset(invalid, now: now, language: .en, style: .absolute), "—")
        }
    }

    func testExtremeFiniteDatesUseSafePlaceholderWithoutIntegerOverflow() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        for invalid in [
            Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude),
            Date(timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude),
        ] {
            XCTAssertEqual(TimeFormat.relative(invalid, now: now, language: .en), "—")
            XCTAssertEqual(TimeFormat.reset(invalid, now: now, language: .en, style: .countdown), "—")
            XCTAssertEqual(TimeFormat.reset(invalid, now: now, language: .en, style: .absolute), "—")
            XCTAssertEqual(TimeFormat.hourMinute(invalid), "—")
            XCTAssertEqual(TimeFormat.monthDayHourMinute(invalid), "—")
            XCTAssertEqual(TimeFormat.refreshStamp(invalid, now: now), "—")
        }
    }

    func testStoreRoundTripDefaultsToCountdown() {
        let suite = "test.usagelimits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: defaults)
        XCTAssertEqual(store.resetTimeStyle, .countdown)
        store.resetTimeStyle = .absolute
        XCTAssertEqual(store.resetTimeStyle, .absolute)
    }

    func testSettingsKeysExistInAllLanguages() {
        for key in ["settings.resetTime", "settings.resetTime.countdown", "settings.resetTime.absolute", "settings.resetTime.footer", "time.tomorrowAt", "diagnostics.empty", "diagnostics.copy", "preview.small22"] {
            for lang in AppLanguage.concrete {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
    }

    func testIllegalResetTimeStyleFallsBackToCountdown() {
        let suite = "test.usagelimits.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for raw in ["nope", "used", ""] {
            defaults.set(raw, forKey: "resetTimeStyle")
            let store = SharedStore(defaults: defaults)
            XCTAssertEqual(store.resetTimeStyle, .countdown, raw)
        }
        defaults.set("absolute", forKey: "resetTimeStyle")
        XCTAssertEqual(SharedStore(defaults: defaults).resetTimeStyle, .absolute)
    }

    func testNewWidgetAndPresetKeysExistInAllLanguages() {
        for key in ["widget.highestUsage", "widget.chooseAccount", "widget.accountType", "widget.overviewTitle", "widget.singleDescription", "widget.overviewDescription", "widget.providerType", "widget.gallery.single", "widget.gallery.singleDetail", "widget.gallery.medium", "widget.gallery.mediumDetail", "widget.gallery.large", "widget.gallery.largeDetail", "widget.metricType", "widget.quotaParam", "widget.homeSlot", "widget.followHome", "widget.emptySlot", "providers.preset.experimental", "providers.reorder", "providers.reorderDone", "card.reorderMetrics", "metricOrder.title", "time.compactMin", "custom.wizard.presetHint"] {
            for lang in AppLanguage.concrete {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
    }

    func testOverviewAndSingleWidgetTitlesAreLocalized() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("widget.overviewTitle"))
        XCTAssertTrue(source.contains("widget.chooseAccount"))
        XCTAssertTrue(source.contains("widget.accountType"))
        XCTAssertTrue(source.contains("widget.providerType"))
        XCTAssertTrue(source.contains("widget.gallery.single"))
        XCTAssertTrue(source.contains("widget.gallery.medium"))
        XCTAssertFalse(source.contains("widget.gallery.overview"), "2×4 总览已下线（DEVLOG #99）")
        XCTAssertEqual(L10n.tr("widget.gallery.overview", .zh), "widget.gallery.overview", "下线小组件的文案不留在表里")
        XCTAssertEqual(L10n.tr("widget.gallery.overviewDetail", .zh), "widget.gallery.overviewDetail")
        XCTAssertTrue(source.contains("widget.gallery.large"))
        XCTAssertTrue(source.contains("widget.gallery.largeDetail"))
        XCTAssertFalse(source.contains("选择要显示的账号"))
        XCTAssertFalse(source.contains("@Parameter(title: \"账号\""))
        XCTAssertFalse(source.contains("TypeDisplayRepresentation(name: \"服务商\")"))
        XCTAssertFalse(source.contains(".configurationDisplayName(\"单账号用量\")"))
        XCTAssertFalse(source.contains(".configurationDisplayName(\"单账号多级用量\")"))
        XCTAssertFalse(source.contains(".configurationDisplayName(\"用量总览\")"))
        XCTAssertFalse(source.contains("Summary(\"显示"))
    }

    func testWatchRingsFollowUsagePresentation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Watch/WatchViews.swift"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("UsagePresentation.barPercent"), "表端圆环须跟展示口径，按剩余时缩短")
        XCTAssertTrue(source.contains("UsagePresentation.valueText"), "表端选中环数值须跟展示口径")
        XCTAssertFalse(
            source.contains("percent: metric.usedPercent ?? 0"),
            "表端不得把 raw usedPercent 直接画进 SingleRing"
        )
    }

    func testMediumQuotaBarUsesResolvedTint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("SharedUI/WidgetViews.swift"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("row.tint ?? (row.isCustom ? TintResolver.customDefault : row.provider.builtinTint)"),
                      "2×4/4×4 官方条须用解析色，不得写死 brandColor")
        XCTAssertFalse(source.contains("row.provider.brandColor"), "官方 QuotaBar 不得绕过账号/供应商覆盖色")
    }

    func testResetLabelsUseTimelineViewOnAppWatchAndWidget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in ["App/Views/ProviderCardView.swift", "Watch/WatchViews.swift", "SharedUI/WidgetViews.swift", "App/Views/CustomUsageCardBody.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertTrue(source.contains("TimelineView(.periodic"), rel)
        }
    }

}

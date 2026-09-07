import XCTest
@testable import UsageLimitsCore

final class CustomUsageDisplayTests: XCTestCase {
    private func snap(_ metrics: [UsageMetric]) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .claude,
            metrics: metrics,
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
    }

    func testFormatTrimsLongDecimalsAndKeepsIntegers() {
        XCTAssertEqual(CustomUsageDisplay.formatAmount(168.80205405), "168.80")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(12.5), "12.50")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(100), "100")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(0), "0")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(1000), "1000")
        XCTAssertEqual(
            CustomUsageDisplay.format(UsageMetric(id: "used", label: "已用", amount: 12.5, displayValue: "12")),
            "12"
        )
    }

    func testUsedShareOnlyWhenBothNonNegativeAndSumPositive() {
        XCTAssertEqual(CustomUsageDisplay.usedSharePercent(used: 168.8, balance: 168.8) ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(CustomUsageDisplay.usedSharePercent(used: 1, balance: 3) ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(CustomUsageDisplay.usedSharePercent(used: 0, balance: 10) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(CustomUsageDisplay.usedSharePercent(used: 10, balance: 0) ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(CustomUsageDisplay.usedSharePercent(used: 0, balance: 0))
        XCTAssertNil(CustomUsageDisplay.usedSharePercent(used: 5, balance: nil))
        XCTAssertNil(CustomUsageDisplay.usedSharePercent(used: nil, balance: 5))
        XCTAssertNil(CustomUsageDisplay.usedSharePercent(used: -1, balance: 10))
    }

    func testPresentationTwoTilesAndDoesNotInventPercentOnMetrics() {
        let used = UsageMetric(id: "used", label: "已用", amount: 168.80205405, pinned: true)
        let balance = UsageMetric(id: "balance", label: "余额", amount: 168.8, pinned: true)
        let shown = CustomUsageDisplay.presentation(from: snap([used, balance]))
        XCTAssertEqual(shown.tiles.map(\.id), ["used", "balance"])
        XCTAssertEqual(shown.tiles.map(\.valueText), ["168.80", "168.80"])
        XCTAssertEqual(shown.usedSharePercent ?? -1, 50, accuracy: 0.05)
        XCTAssertEqual(shown.collapsedSummary, "已用 168.80 · 余额 168.80")
        XCTAssertNil(used.usedPercent)
        XCTAssertNil(balance.usedPercent)
    }

    func testPresentationSingleTileHasNoShareBar() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "used", label: "已用", amount: 12, pinned: true)
        ]))
        XCTAssertEqual(shown.tiles.count, 1)
        XCTAssertNil(shown.usedSharePercent)
        XCTAssertEqual(shown.collapsedSummary, "已用 12")
    }

    func testPresentationListsArbitrarySelectedFieldsWithoutGuessingShare() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "balance", label: "余额", amount: 168.80205405, pinned: true),
            UsageMetric(id: "remaining", label: "剩余额度", amount: 168.80205405, pinned: true),
        ]))
        XCTAssertEqual(shown.tiles.map(\.id), ["balance", "remaining"])
        XCTAssertEqual(shown.tiles.map(\.label), ["余额", "剩余额度"])
        XCTAssertNil(shown.usedSharePercent, "两条余额不得猜已用占比")
        XCTAssertEqual(shown.collapsedSummary, "余额 168.80 · 剩余额度 168.80")
    }

    func testPresentationIgnoresUsedBalanceIdsWhenLabelsAreBothRemainders() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "used", label: "余额", amount: 168.8, pinned: true),
            UsageMetric(id: "balance", label: "剩余额度", amount: 80, pinned: true),
        ]))
        XCTAssertNil(shown.usedSharePercent, "id 叫 used/balance 但展示名都不是已用+余额时不得画条")
    }

    func testPresentationShareUsesDisplayNamesNotIds() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "field_a", label: "本月已用", amount: 20, pinned: true),
            UsageMetric(id: "field_b", label: "账户余额", amount: 80, pinned: true),
        ]))
        XCTAssertEqual(shown.usedSharePercent ?? -1, 20, accuracy: 0.05)
    }

    func testPresentationShareUsesEnglishLabelsWithoutRoles() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "field_a", label: "Used", amount: 25, pinned: true),
            UsageMetric(id: "field_b", label: "Balance", amount: 75, pinned: true),
        ]))
        XCTAssertEqual(shown.usedSharePercent ?? -1, 25, accuracy: 0.05)
        XCTAssertEqual(shown.gauge?.source, .usedShare)
    }

    func testPresentationShareUsesRolesWithoutChineseLabels() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "used", label: "Used", amount: 30, pinned: true, kind: CustomFieldRole.used.rawValue),
            UsageMetric(id: "left", label: "Balance", amount: 70, pinned: true, kind: CustomFieldRole.remaining.rawValue),
        ]))
        XCTAssertEqual(shown.usedSharePercent ?? -1, 30, accuracy: 0.05)
        XCTAssertEqual(shown.gauge?.source, .usedShare)
    }

    func testDerivedGaugeFollowsDisplayModeWhileTilesAndRiskStayUsedBased() {
        let metrics = [
            UsageMetric(id: "used", label: "已用", amount: 20, pinned: true, kind: "used"),
            UsageMetric(id: "limit", label: "总额", amount: 100, pinned: true, kind: "limit"),
            UsageMetric(id: "balance", label: "余额", amount: 80, currency: "USD", pinned: true, kind: "remaining"),
        ]
        let used = CustomUsageDisplay.presentation(from: snap(metrics), mode: .used)
        let remaining = CustomUsageDisplay.presentation(from: snap(metrics), mode: .remaining)

        XCTAssertEqual(used.gauge?.displayedPercent, 20)
        XCTAssertEqual(remaining.gauge?.displayedPercent, 80)
        XCTAssertEqual(used.gauge?.riskPercent, 20)
        XCTAssertEqual(remaining.gauge?.riskPercent, 20)
        XCTAssertEqual(used.tiles, remaining.tiles, "金额 tile 不应被用量显示口径改写")
        XCTAssertEqual(remaining.tiles.first(where: { $0.id == "balance" })?.valueText, "$80.00")
    }

    func testPercentRoleUsesOneModeAwareValueForHeroAndGaugeWithoutInventingUsedPercent() {
        let metric = UsageMetric(
            id: "ratio", label: "占比", amount: 42, pinned: true,
            displayValue: "42%", kind: CustomFieldRole.percent.rawValue
        )
        let used = CustomUsageDisplay.presentation(from: snap([metric]), mode: .used)
        let remaining = CustomUsageDisplay.presentation(from: snap([metric]), mode: .remaining)

        XCTAssertEqual(used.hero?.valueText, "42%")
        XCTAssertEqual(used.gauge?.displayedPercent, 42)
        XCTAssertEqual(remaining.hero?.valueText, "58%")
        XCTAssertEqual(remaining.gauge?.displayedPercent, 58)
        XCTAssertEqual(remaining.gauge?.riskPercent, 42, "风险色仍按原始已用口径")
        XCTAssertNil(metric.usedPercent, "自定义百分比只影响展示，不得进入提醒语义")
    }

    func testTimestampRoleUsesSharedResetPresenterInsteadOfEpochAmount() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reset = now.addingTimeInterval(7_200)
        let metric = UsageMetric(
            id: "expiry", label: "到期", resetsAt: reset,
            amount: reset.timeIntervalSince1970, pinned: true,
            displayValue: "1760007200", kind: CustomFieldRole.timestamp.rawValue
        )

        XCTAssertEqual(
            CustomUsageDisplay.valueText(
                for: metric, mode: .used, language: .zh, resetStyle: .countdown, now: now
            ),
            TimeFormat.reset(reset, now: now, language: .zh, style: .countdown)
        )
        XCTAssertEqual(
            CustomUsageDisplay.valueText(
                for: metric, mode: .remaining, language: .en, resetStyle: .absolute, now: now
            ),
            TimeFormat.reset(reset, now: now, language: .en, style: .absolute)
        )
        XCTAssertFalse(
            CustomUsageDisplay.presentation(
                from: snap([metric]), language: .zh, resetStyle: .countdown, now: now
            ).collapsedSummary.contains("1760007200")
        )
    }

    func testInvalidCustomGaugeInputsNeverProduceGaugeOrPretendZero() {
        let invalid = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1]
        for value in invalid {
            XCTAssertNil(CustomUsageDisplay.gauge(tiles: [
                .init(id: "p", label: "占比", valueText: "bad", amount: value, role: .percent),
            ], share: nil), "invalid percent \(value)")
            XCTAssertNil(CustomUsageDisplay.gauge(tiles: [
                .init(id: "u", label: "已用", valueText: "bad", amount: value, role: .used),
                .init(id: "l", label: "总额", valueText: "100", amount: 100, role: .limit),
            ], share: nil), "invalid used \(value)")
            XCTAssertNil(CustomUsageDisplay.gauge(tiles: [
                .init(id: "r", label: "余额", valueText: "bad", amount: value, role: .remaining),
                .init(id: "l", label: "总额", valueText: "100", amount: 100, role: .limit),
            ], share: nil), "invalid remaining \(value)")
            XCTAssertNil(CustomUsageDisplay.gauge(tiles: [
                .init(id: "u", label: "已用", valueText: "1", amount: 1, role: .used),
                .init(id: "l", label: "总额", valueText: "bad", amount: value, role: .limit),
            ], share: nil), "invalid limit \(value)")
            XCTAssertNil(CustomUsageDisplay.usedSharePercent(used: value, balance: 1))
            XCTAssertNil(CustomUsageDisplay.usedSharePercent(used: 1, balance: value))
        }
        XCTAssertEqual(CustomUsageDisplay.formatAmount(.infinity, currency: "USD"), "—")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(.nan, currency: "CNY"), "—")
    }

    func testProductionSurfacesUseSharedCustomValuePresenter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try [
            "App/Views/CustomUsageCardBody.swift",
            "SharedUI/WidgetViews.swift",
            "Watch/WatchViews.swift",
            "Core/Sources/UsageLimitsCore/ShareImage.swift",
        ].map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }

        XCTAssertTrue(sources[0].contains("CustomUsageDisplay.presentation"))
        XCTAssertTrue(sources[0].contains("resetStyle: resetStyle"))
        XCTAssertTrue(sources[0].contains("collapsedTile") || sources[0].contains("collapsedHero"), "折叠自定义须走展开顺序第一位")
        XCTAssertTrue(sources[1].contains("selectedMeters"), "2×2 自定义按勾选/展开顺序取条")
        XCTAssertTrue(sources[1].contains("CustomUsageDisplay.valueText"))
        XCTAssertFalse(sources[1].contains("? CustomUsageDisplay.format(metric)"))
        XCTAssertTrue(sources[1].contains("customTileValue"), "2×2 自定义时间戳须走 TimelineView")
        XCTAssertTrue(sources[1].contains("ConcentricUsageRings"), "2×2 自定义两条也走同心环")
        XCTAssertTrue(
            sources[1].contains("row.riskPercent ?? row.metric.usedPercent"),
            "2×2 环须吃已用百分比；displayedPercent 已按口径反转过"
        )
        XCTAssertFalse(
            sources[1].contains("percent: gauge.displayedPercent"),
            "2×2 不得把已反转的 displayedPercent 再喂给圆环"
        )
        XCTAssertTrue(sources[1].contains("overviewRows"), "2×4 自定义须带首页 gauge 百分比")
        XCTAssertTrue(sources[1].contains("liveValueText"), "2×4 自定义时间戳须走 TimelineView")
        XCTAssertTrue(
            sources[1].contains("CustomUsageDisplay.fieldRole(metric) == .timestamp"),
            "自定义时间戳行不得再追加同一 reset 文案"
        )
        XCTAssertTrue(sources[0].contains("shownStamp") || sources[0].contains("timestamps.first"),
                      "折叠态须露出第一条时间戳，不能只藏在 moreFields")
        XCTAssertTrue(sources[2].contains("CustomUsageDisplay.valueText"))
        XCTAssertTrue(sources[2].contains("TimelineView(.periodic"), "自定义时间戳页须跟内置圆环一样走 TimelineView")
        XCTAssertTrue(sources[3].contains("CustomUsageDisplay.valueText"))
        XCTAssertTrue(sources[0].contains("if resetStyle == .countdown"), "absolute 模式不得重复第二行绝对时间")
        XCTAssertTrue(sources[0].contains("custom.noNumeric"), "首页自定义空态不得用官方无额度口侄")
        XCTAssertTrue(sources[1].contains("custom.noNumeric"), "2×2/2×4 自定义空态不得用官方无额度口侄")
        XCTAssertTrue(sources[1].contains("themeTint"), "自定义 2×2 环须走主题色")
        XCTAssertTrue(sources[1].contains("smallMeterValue") || sources[1].contains("ringBoard"), "有环时名称用量横向画在顶/底行")
        XCTAssertTrue(sources[1].contains("row.isCustom"), "2×4 自定义行须直接用字段展示名")
        XCTAssertTrue(sources[1].contains("L10n.tr(metric.label, lang)"), "2×4 自定义行名须再查 L10n")
        XCTAssertTrue(sources[2].contains("L10n.tr(metric.label, lang)"), "表端自定义行名须再查 L10n")
        XCTAssertTrue(sources[3].contains("L10n.tr(metric.label, language)"), "分享自定义行名须再查 L10n")
        XCTAssertTrue(sources[2].contains("visibleMetrics"), "表端失败须忽略 leftover 数字")
        XCTAssertTrue(sources[2].contains("custom.noNumeric"), "表端自定义空态不得用官方无额度口侄")
        XCTAssertTrue(sources[3].contains("if let used = meter.usedPercent"), "分享 usedPercent==nil 不得画空条")
        XCTAssertTrue(sources.allSatisfy { !$0.contains("gauge.percent") }, "Gauge API 须明确区分展示百分比和风险百分比")

        let shareFlow = try String(
            contentsOf: root.appendingPathComponent("App/Share/ShareFlow.swift"), encoding: .utf8
        )
        XCTAssertTrue(shareFlow.contains("resetTimeStyle: ResetTimeStyle"))
        XCTAssertTrue(shareFlow.contains("resetTimeStyle: resetTimeStyle"))
    }

    func testGaugePairsSameUnitRemainingAndLimitIgnoringMixedCurrency() {
        let crof = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
            UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
            UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
        ]))
        XCTAssertEqual(crof.gauge?.source, .remainingOverLimit)
        XCTAssertEqual(crof.gauge?.displayedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(crof.gauge?.riskPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(crof.gauge?.caption, "剩余请求 250 / 请求上限 1000")
        XCTAssertNil(
            CustomUsageDisplay.presentation(from: snap([
                UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
                UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
            ])).gauge,
            "美元积分不得和请求上限画成 98.75%"
        )
        XCTAssertNil(
            CustomUsageDisplay.presentation(from: snap([
                UsageMetric(id: "credits", label: "积分", amount: 12.5, pinned: true, kind: "remaining"),
                UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
            ])).gauge,
            "无币种积分也不得和请求上限配对"
        )
    }

    func testShareAndUsedLimitRequireSameUnit() {
        XCTAssertNil(
            CustomUsageDisplay.presentation(from: snap([
                UsageMetric(id: "used", label: "已用", amount: 20, currency: "USD", pinned: true, kind: "used"),
                UsageMetric(id: "left", label: "次数", amount: 80, pinned: true, kind: "remaining"),
            ])).gauge,
            "美元已用不得和次数余额配对"
        )
        let usedLimit = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "usdUsed", label: "已用额度", amount: 80, currency: "USD", pinned: true, kind: "used"),
            UsageMetric(id: "reqCap", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
            UsageMetric(id: "usdCap", label: "额度上限", amount: 100, currency: "USD", pinned: true, kind: "limit"),
        ]))
        XCTAssertEqual(usedLimit.gauge?.source, .usedOverLimit)
        XCTAssertEqual(usedLimit.gauge?.displayedPercent ?? -1, 80, accuracy: 0.001)
    }

    func testMetaLinePrefersHostWhenTitleMatchesTemplate() {
        XCTAssertEqual(
            CustomUsageDisplay.metaLine(
                templateName: "DragonCode", host: "dragoncode.codes", cardTitle: "DragonCode"
            ),
            "dragoncode.codes"
        )
        XCTAssertEqual(
            CustomUsageDisplay.metaLine(
                templateName: "DragonCode", host: "dragoncode.codes", cardTitle: "我的号"
            ),
            "DragonCode"
        )
    }

    func testTimestampWithoutDateShowsKeptValue() {
        let metric = UsageMetric(
            id: "expiry", label: "到期", amount: 1, pinned: true,
            displayValue: "kept", kind: CustomFieldRole.timestamp.rawValue
        )
        XCTAssertEqual(CustomUsageDisplay.valueText(for: metric), "kept")
        XCTAssertEqual(
            CustomUsageDisplay.presentation(from: snap([metric])).timestamps.first?.valueText,
            "kept"
        )
    }

    func testCrofHeroAlignsWithRequestGaugeNotUSDCredits() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
            UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
            UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
        ]))
        XCTAssertEqual(shown.hero?.id, "usable_requests", "Crof 大号须跟请求进度条同单位")
        XCTAssertEqual(shown.gauge?.source, .remainingOverLimit)
        XCTAssertEqual(shown.gauge?.displayedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(shown.hero?.label, "剩余请求")
    }

    func testFallbackRemainingLabelWithoutRoleStillBuildsGauge() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "left", label: "剩余请求", amount: 250, pinned: true),
            UsageMetric(id: "cap", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
        ]))
        XCTAssertEqual(shown.gauge?.source, .remainingOverLimit)
        XCTAssertEqual(shown.gauge?.displayedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(shown.hero?.id, "left")
    }

    func testPrepaidHeroPrefersCurrencyRemainingOverRequestLeft() {
        let prepaid = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "used", label: "已用", amount: 20, currency: "USD", pinned: true, kind: "used"),
            UsageMetric(id: "cash_balance", label: "cash_balance", amount: 80, currency: "USD", pinned: true, kind: "remaining"),
            UsageMetric(id: "voucher", label: "voucher", amount: 20, currency: "USD", pinned: true, kind: "remaining"),
        ]))
        XCTAssertEqual(prepaid.hero?.label, "cash_balance", "多余额保留路径名")
        XCTAssertEqual(prepaid.gauge?.source, .usedShare)

        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
            UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
            UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
        ]))
        XCTAssertEqual(shown.hero?.id, "usable_requests", "有同单位请求条时 hero 跟条，不改画美元余额")
        XCTAssertEqual(shown.hero?.label, "剩余请求")
    }

    func testRoleFallbackDoesNotPullLimitIntoUsed() {
        XCTAssertEqual(
            CustomUsageDisplay.effectiveRole(
                UsageMetric(id: "cap", label: "已用上限", amount: 100, pinned: true, kind: "limit")
            ),
            .limit,
            "有角色只认角色，不得因标签含「已用」改成 used"
        )
        XCTAssertEqual(
            CustomUsageDisplay.effectiveRole(
                UsageMetric(id: "u", label: "已用额度", amount: 20, pinned: true)
            ),
            .used
        )
    }

    func testRemainingSubstringFallbackPairsShareAndHero() {
        let shown = CustomUsageDisplay.presentation(from: snap([
            UsageMetric(id: "u", label: "已用", amount: 20, pinned: true),
            UsageMetric(id: "r", label: "可用积分", amount: 80, pinned: true),
        ]))
        XCTAssertEqual(shown.gauge?.source, .usedShare)
        XCTAssertEqual(shown.hero?.id, "r")
        XCTAssertEqual(shown.usedSharePercent ?? -1, 20, accuracy: 0.001)
    }

    func testPrepaidCreditsPathLabelEntersPrepaidScope() {
        XCTAssertTrue(CustomUsageDisplay.matchesPrepaidLabel("prepaid_credits"))
        XCTAssertTrue(CustomUsageDisplay.matchesPrepaidLabel("cash_balance"))
        XCTAssertTrue(CustomUsageDisplay.matchesPrepaidLabel("Credits"))
        XCTAssertTrue(CustomUsageDisplay.matchesPrepaidLabel("unused_credits"))
        XCTAssertFalse(CustomUsageDisplay.matchesPrepaidLabel("credits_used"))
        XCTAssertFalse(CustomUsageDisplay.matchesPrepaidLabel("剩余请求"))
        XCTAssertTrue(CustomUsageDisplay.matchesPrepaidLabel("余额"))
    }

    func testPersistedChineseCustomLabelsLocalizeOnEnglishSurfaces() {
        let snap = snap([
            UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
            UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
            UsageMetric(id: "credits", label: "可用余额", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
            UsageMetric(id: "left", label: "剩余请求", amount: 40, pinned: true),
        ])
        let en = CustomUsageDisplay.presentation(from: snap, language: .en)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: en.tiles.map { ($0.id, $0.label) }),
            [
                "requests_plan": "Request limit",
                "usable_requests": "Requests left",
                "credits": "Available balance",
                "left": "Requests left",
            ]
        )
        XCTAssertEqual(
            en.tiles.first { $0.id == "left" }?.role,
            .remaining,
            "无 kind 的中文源文案须在本地化前先认 remaining"
        )
        XCTAssertEqual(L10n.tr("请求上限", .ja), "リクエスト上限")
        XCTAssertEqual(L10n.tr("剩余请求", .fr), "Requêtes restantes")
    }
    func testRemainingPercentDoesNotPairAsAmountAgainstLimit() throws {
        let template = try XCTUnwrap(CustomUsageTemplate(
            name: "T", requestURL: "https://api.example.com/v1/usage",
            fields: [
                CustomUsageField(path: "remaining_percent", displayName: "剩余占比", role: .remaining),
                CustomUsageField(path: "usage_limit", displayName: "上限", role: .limit),
            ]
        ))
        let snap = CustomUsageParser.parse(
            status: 200,
            body: #"{"remaining_percent":80,"usage_limit":1000}"#,
            template: template
        )
        XCTAssertEqual(snap.status, .ok)
        let remaining = try XCTUnwrap(snap.metrics.first { $0.id == "remaining_percent" })
        XCTAssertEqual(remaining.amount, 80)
        XCTAssertEqual(remaining.displayValue, "80%")
        XCTAssertNil(remaining.usedPercent, "自定义不得写 usedPercent")
        let used = CustomUsageDisplay.presentation(from: snap, mode: .used)
        XCTAssertEqual(used.gauge?.displayedPercent ?? -1, 20, accuracy: 0.001, "80% 剩余不得和 1000 上限算成 92% 已用")
        XCTAssertEqual(used.tiles.first { $0.id == "remaining_percent" }?.valueText, "20%")
        let leftover = CustomUsageDisplay.presentation(from: snap, mode: .remaining)
        XCTAssertEqual(leftover.gauge?.displayedPercent ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(leftover.tiles.first { $0.id == "remaining_percent" }?.valueText, "80%")
    }


    func testCollapsedTileFollowsMetricOrderNotSemanticHero() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
                UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
                UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        let shown = CustomUsageDisplay.presentation(from: snap)
        XCTAssertEqual(shown.hero?.id, "usable_requests")
        XCTAssertEqual(CustomUsageDisplay.collapsedTile(from: snap, shown: shown)?.id, "credits")
        let reordered = ProviderSnapshot(
            provider: .claude,
            metrics: MetricOrdering.apply(snap.metrics, order: ["usable_requests", "credits", "requests_plan"]),
            fetchedAt: snap.fetchedAt, status: .ok, isCustom: true
        )
        let shown2 = CustomUsageDisplay.presentation(from: reordered)
        XCTAssertEqual(CustomUsageDisplay.collapsedTile(from: reordered, shown: shown2)?.id, "usable_requests")
    }

}

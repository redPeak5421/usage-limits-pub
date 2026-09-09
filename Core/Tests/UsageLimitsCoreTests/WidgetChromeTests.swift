import XCTest
@testable import UsageLimitsCore

final class WidgetChromeTests: XCTestCase {
    func testUsageTitleLargerThanLegacyCaption() {
        // 原先 2×2 底部标题是 .caption2（约 11pt）或 9pt
        XCTAssertGreaterThan(WidgetChrome.usageTitlePointSize, 11)
    }

    func testQuotaBarThickerThanLegacyScaledProgress() {
        // 原先 ProgressView + scaleEffect(y: 0.8) ≈ 3.2pt
        XCTAssertGreaterThan(WidgetChrome.quotaBarHeight, 3.2)
        XCTAssertGreaterThan(WidgetChrome.quotaBarHeight, 4)
    }

    func testMediumNameAndLogoLargerWithoutShrinkingBar() {
        XCTAssertGreaterThan(WidgetChrome.providerLogoSize, 11)
        XCTAssertGreaterThan(WidgetChrome.providerNamePointSize, 12)
        XCTAssertGreaterThan(WidgetChrome.nameColumnWidth, 72)
        XCTAssertEqual(WidgetChrome.quotaBarHeight, 6)
        XCTAssertEqual(WidgetChrome.providerNameLineLimit, 2)
    }

    func testOverviewMeterCapsFollowAccountCountAndFamily() {
        XCTAssertEqual(WidgetChrome.overviewAccountLimit(isLarge: false), 1)
        XCTAssertEqual(WidgetChrome.overviewAccountLimit(isLarge: true), 4)
        XCTAssertEqual(WidgetChrome.overviewMetersPerAccount(accountCount: 1, isLarge: false), 4)
        XCTAssertEqual(WidgetChrome.overviewMetersPerAccount(accountCount: 3, isLarge: false), 4)
        XCTAssertEqual(WidgetChrome.overviewMetersPerAccount(accountCount: 1, isLarge: true), 8)
        XCTAssertEqual(WidgetChrome.overviewMetersPerAccount(accountCount: 2, isLarge: true), 4)
        XCTAssertEqual(WidgetChrome.overviewMetersPerAccount(accountCount: 3, isLarge: true), 3)
        XCTAssertEqual(WidgetChrome.overviewMetersPerAccount(accountCount: 4, isLarge: true), 2)
        let snap = ProviderSnapshot(
            provider: .openai,
            metrics: [
                UsageMetric(id: "a", label: "A", usedPercent: 10),
                UsageMetric(id: "b", label: "B", usedPercent: 20),
                UsageMetric(id: "c", label: "C", usedPercent: 30),
                UsageMetric(id: "d", label: "D", usedPercent: 40),
                UsageMetric(id: "e", label: "E", usedPercent: 50),
            ],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(
            WidgetAccountItems.overviewMeters(
                from: snap,
                cap: WidgetChrome.overviewMetersPerAccount(accountCount: 3, isLarge: true)
            ).map(\.id),
            ["a", "b", "c"],
            "3 家时每家取首页顺序前 3 条"
        )
    }

    func testOverviewPicksInstancesNotWholeProvider() {
        let x1 = ProviderAccount(provider: .grok, name: "X1", isPrimary: true)
        let x2 = ProviderAccount(provider: .grok, name: "X2")
        let c1 = ProviderAccount(provider: .cursor, name: "C1", isPrimary: true)
        let onlyX1 = WidgetAccountItems.overview(
            pickedIDs: [x1.id.uuidString],
            accounts: [x1, c1, x2],
            providerOrder: [.grok, .cursor],
            preview: false,
            isProviderEnabled: { $0 == .grok || $0 == .cursor }
        )
        XCTAssertEqual(onlyX1.map(\.title), ["X1"], "勾选一个 Grok 实例不得带出该供应商其余账号")
        XCTAssertNil(onlyX1[0].extraAccountID, "主账号走服务商快照键")

        let interleaved = WidgetAccountItems.overview(
            pickedIDs: [x2.id.uuidString, c1.id.uuidString, x1.id.uuidString],
            accounts: [x1, c1, x2],
            providerOrder: [.grok, .cursor],
            preview: false,
            isProviderEnabled: { _ in true }
        )
        XCTAssertEqual(interleaved.map(\.title), ["X2", "C1", "X1"], "顺序跟编辑页勾选顺序")

        let allVisible = WidgetAccountItems.overview(
            pickedIDs: [],
            accounts: [x1, c1, x2],
            providerOrder: [.grok, .cursor],
            preview: false,
            isProviderEnabled: { _ in true }
        )
        XCTAssertEqual(allVisible.map(\.title), ["X1", "C1", "X2"], "空勾选 = 全部可见实例")

        var disabled = x2
        disabled.isEnabled = false
        let hidden = WidgetAccountItems.overview(
            pickedIDs: [x1.id.uuidString, disabled.id.uuidString],
            accounts: [x1, disabled],
            providerOrder: [.grok],
            preview: false,
            isProviderEnabled: { $0 == .grok }
        )
        XCTAssertEqual(hidden.map(\.title), ["X1"])
    }

    func testOverviewFallsBackToProviderRowsWhenNoAccounts() {
        let rows = WidgetAccountItems.overview(
            pickedIDs: ["provider.claude", "provider.grok"],
            accounts: [],
            providerOrder: [.grok, .claude, .cursor],
            preview: true,
            isProviderEnabled: { _ in true }
        )
        XCTAssertEqual(rows.map(\.provider), [.claude, .grok])
        XCTAssertEqual(rows.map(\.id), ["provider.claude", "provider.grok"])
    }

    func testShippedWidgetViewsUseChromeConstantsAndBrandTint() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/WidgetViews.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("WidgetChrome.usageTitlePointSize"))
        XCTAssertTrue(src.contains("WidgetChrome.quotaBarHeight"))
        XCTAssertTrue(src.contains("WidgetChrome.providerLogoSize"))
        XCTAssertTrue(src.contains("WidgetChrome.providerNamePointSize"))
        XCTAssertTrue(src.contains("WidgetChrome.providerNameLineLimit"), "过长别名按常量换行，不得缩字号")
        let nameLabel = src.components(separatedBy: "private func nameLabel").dropFirst().first?
            .components(separatedBy: "private func valueText").first ?? ""
        XCTAssertTrue(nameLabel.contains("weight: .bold"), "换行后字重须与短名相同")
        // 2×4 名称列不缩字；只有 4×4 总览的 8 字以内短名允许单行缩字（用户 2026-08-30 指示）。
        XCTAssertTrue(
            nameLabel.contains("minimumScaleFactor(largeOverview && shortName ? 0.6 : 1)"),
            "缩字只能在 4×4 短名分支，其它情况因子必须为 1"
        )
        XCTAssertTrue(nameLabel.contains("WidgetChrome.largeOverviewNamePointSize"), "4×4 名称字号走常量")
        XCTAssertTrue(src.contains("row.provider.builtinTint"), "官方条用解析色回落 builtinTint，不得写死 brandColor")
        XCTAssertFalse(src.contains("row.provider.brandColor"))
        XCTAssertTrue(src.contains("block.title") || src.contains("row.title"), "总览行标题用账号名，同一服务商两行都能显示")
        XCTAssertTrue(src.contains("item.id"), "行 id 必须带账号实例，避免两个 Grok 撞车")
        XCTAssertTrue(src.contains("selectedMeters") || src.contains("selectedMetricIDs"), "2×2 按编辑勾选取计量")
        XCTAssertTrue(src.contains("ConcentricUsageRings"), "2×2 两条计量画同心环")
        XCTAssertTrue(src.contains("ringCallouts"), "2×2 折线标注")
        XCTAssertTrue(src.contains("outerR"), "外圈折线按外圈半径挂点")
        XCTAssertTrue(src.contains("innerR"), "内圈折线按内圈半径挂点")
        XCTAssertTrue(src.contains("ringBoard"), "顶/底各一行，圆环占满中间")
        XCTAssertTrue(src.contains("HStack(spacing: 3)"), "计量名和用量横向排列，避免折行叠环")
        XCTAssertTrue(src.contains("themeTint"), "2×2 环用主题色，不用用量档绿橙红")
        XCTAssertTrue(src.contains("maxMetersPerSmall") || src.contains("WidgetChrome.maxMetersPerSmall"))
        XCTAssertFalse(src.contains("smallInnerRingLineWidth"), "内外环须同一线宽")
        XCTAssertFalse(src.contains("outerW : innerW"), "不得再按内外圈换线宽")
        XCTAssertFalse(src.contains("scaleEffect(y: 0.8)"))
        XCTAssertFalse(src.contains(".tint(usageLevelColor(metric.usedPercent))"))
    }

    func testOverviewWidgetIsEditableAndPreviewScrollsNames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8)
        XCTAssertTrue(widget.contains("struct SingleProviderConfigIntent"), "桌面旧实例仍绑定这个 Intent 名")
        XCTAssertTrue(widget.contains("struct OverviewConfigIntent"), "桌面旧实例仍绑定这个 Intent 名")
        XCTAssertFalse(widget.contains("struct OverviewMediumConfigIntent"))
        XCTAssertFalse(widget.contains("struct OverviewLargeConfigIntent"))
        XCTAssertFalse(widget.contains("typealias DefaultValue"), "EntityQuery.DefaultValue 必须是单个 Entity，数组会让所有编辑页无法载入")
        XCTAssertTrue(widget.contains("var accounts: [AccountChoiceEntity]"), "总览长按必须勾选账号实例")
        XCTAssertFalse(widget.contains("var providers: [ProviderChoice]"), "总览不得再按供应商多选")
        XCTAssertFalse(widget.contains("OverviewProviderFilter"), "供应商级过滤已废弃")
        XCTAssertFalse(
            widget.contains("@Parameter(title: \"服务商\""),
            "单账号/总览编辑页都不得再露出服务商参数"
        )
        XCTAssertTrue(widget.contains("AccountChoiceEntity"), "单账号小组件应能选具体账号实例")
        XCTAssertTrue(widget.contains("MetricChoiceEntity"), "编辑页须能勾选计量条")
        XCTAssertTrue(widget.contains("var quotas: [MetricChoiceEntity]"), "2×2/单账号 2×4 共用计量勾选")
        XCTAssertFalse(
            widget.contains("var metrics: [MetricChoiceEntity]"),
            "参数名已改成 quotas：旧版本存在配置里的「额度」占位文案系统从不刷新，只能随旧参数名一起丢掉（DEVLOG #103）"
        )
        XCTAssertFalse(widget.contains("configuration.metrics"), "时间线读新参数名")
        XCTAssertTrue(
            widget.contains("title: \"widget.quotaParam\",\n        default: MetricChoiceDefaults.slots"),
            "额度参数标题须写明「留空则跟随首页」：改名迁移后的旧小组件列表是空的"
        )
        let xcstrings = try String(
            contentsOf: root.appendingPathComponent("Widget/Localizable.xcstrings"), encoding: .utf8
        )
        XCTAssertTrue(xcstrings.contains("\"widget.quotaParam\""), "参数标题走小组件 xcstrings")
        XCTAssertFalse(widget.contains("var metrics: [OverviewMetricChoiceEntity]"), "总览不再选手动额度")
        XCTAssertFalse(widget.contains("struct OverviewMetricChoiceEntity"), "总览额度实体已删除")
        XCTAssertTrue(widget.contains("\\.$quotas"), "单账号计量条须进 parameterSummary")
        XCTAssertTrue(widget.contains("IntentCollectionSize(min: 0, max: 2)"), "2×2 额度可删到 0，最多 2")
        XCTAssertTrue(widget.contains("IntentCollectionSize(min: 0, max: 4)"), "单账号 2×4 额度可删，最多 4")
        XCTAssertFalse(widget.contains("IntentCollectionSize(min: 0, max: 6)"), "总览不再露出额度集合")
        XCTAssertFalse(widget.contains("IntentCollectionSize(min: 0, max: 8)"))
        XCTAssertFalse(widget.contains("IntentCollectionSize(min: 1, max: 1)"), "2×4 总览已下线（DEVLOG #99），总览只剩 4×4")
        XCTAssertFalse(widget.contains("struct OverviewWidget"), "2×4 总览已下线（DEVLOG #99）")
        XCTAssertFalse(widget.contains("OverviewMediumTimeline"), "2×4 总览时间线随小组件一起删")
        XCTAssertFalse(widget.contains("kind: \"OverviewWidget\""), "2×4 总览 kind 不再注册")
        XCTAssertFalse(widget.contains(".systemMedium: IntentCollectionSize(min: 1"), "总览 Intent 不再声明中号尺寸")
        XCTAssertTrue(widget.contains("IntentCollectionSize(min: 1, max: 4)"), "总览 4×4 账号 1–4")
        XCTAssertFalse(widget.contains("IntentCollectionSize(min: 1, max: 3)"), "2×4 总览不再允许多实例")
        XCTAssertTrue(widget.contains("WidgetEditorPrefill.editorItems"), "编辑页按槽位 id 解析，删除才对得上")
        XCTAssertTrue(widget.contains("query: OverviewAccountChoiceQuery()"), "总览账号 query 丢掉最高用量自动")
        XCTAssertTrue(widget.contains("struct OverviewLargeWidget"), "4×4 须独立小组件，才能单独写描述")
        XCTAssertTrue(widget.contains("widget.gallery.largeDetail"), "4×4 描述不得复用 2×4 文案")
        XCTAssertTrue(widget.contains("displayedOnly"), "单账号预填不得带上未显示的计量")
        XCTAssertFalse(widget.contains("displayedScopedEntities"), "总览不再建额度目录")
        XCTAssertFalse(widget.contains("default: []"), "空 default 会挡住 size 预填，编辑页只剩添加")
        XCTAssertTrue(widget.contains("AccountChoiceQuery.displayed"), "账号建议名单=主页已显示实例")
        XCTAssertTrue(widget.contains("default: OverviewDefaults.accounts"), "总览账号用 Parameter default 预填，不用 DefaultValue 数组")
        XCTAssertFalse(widget.contains("default: OverviewDefaults.metrics"), "总览不再预填额度参数")
        XCTAssertTrue(widget.contains("default: MetricChoiceDefaults.slots"), "单账号额度用 Parameter default 预填 4 个占位槽，显示名按账号现算（DEVLOG #104）")
        XCTAssertTrue(widget.contains("WidgetEditorPrefill.slotID"), "预填行 id 与账号无关（占位槽），换账号后仍成立")
        XCTAssertFalse(widget.contains("MetricChoiceDefaults.metrics"), "不再预填四个「首页额度 N」占位槽（DEVLOG #102）")
        XCTAssertTrue(widget.contains("overviewAccountLimit"), "总览实例数按尺寸封顶")
        XCTAssertFalse(widget.contains("placeholderGroups"), "预填不得再插入组头行")
        XCTAssertFalse(widget.contains("typealias Result = IntentItemCollection"), "Result 改成分组会让已选行只显示类型名「额度」")
        XCTAssertFalse(widget.contains("IntentItemSection"), "已选列表不支持分节，禁止再当 Result")
        XCTAssertFalse(widget.contains("resolvedDisplay"), "占位槽不得拿首页第一个实例的额度名充数（DEVLOG #100）")
        XCTAssertFalse(widget.contains("resolvedMetricTitle"), "displayRepresentation 不知道账号，不得猜实例")
        XCTAssertFalse(widget.contains("typealias DefaultValue"), "不得改 DefaultValue 数组")
        XCTAssertTrue(widget.contains("pickedIDs: accountIDs"), "总览按编辑页实例顺序取账号")
        XCTAssertTrue(widget.contains("maxMeters: WidgetChrome.maxMetersPerSingleAccount"), "单账号 2×4 仍最多 4 条")
        XCTAssertTrue(widget.contains("Summary(\"Show \\(\\.$account)\")"))
        XCTAssertTrue(widget.contains("Summary(\"Show \\(\\.$accounts)\")"))
        let catalog = try String(
            contentsOf: root.appendingPathComponent("Widget/Localizable.xcstrings"), encoding: .utf8
        )
        XCTAssertTrue(catalog.contains("Show \\\\(.account)"), "配置摘要 Show 须进 xcstrings")
        XCTAssertTrue(catalog.contains("Show \\\\(.accounts)"), "总览配置摘要 Show 须进 xcstrings")
        XCTAssertTrue(catalog.contains("显示 \\\\(.account)"), "配置摘要须有中文")
        XCTAssertTrue(catalog.contains("Afficher \\\\(.account)"), "配置摘要须有法文")
        XCTAssertTrue(catalog.contains("widget.gallery.largeDetail"), "4×4 画廊描述须独立")
        XCTAssertFalse(catalog.contains("widget.gallery.overview"), "2×4 总览画廊文案随小组件一起删")
        XCTAssertFalse(catalog.contains("2×4 看周总量"), "4×4 描述不得再写 2×4")
        XCTAssertFalse(catalog.contains("Medium shows weekly"), "4×4 描述不得再写 2×4/medium")
        XCTAssertTrue(widget.contains("pickedIDs:"), "总览须按实例 id 过滤")
        let preview = try String(contentsOf: root.appendingPathComponent("App/Views/WidgetPreviewView.swift"), encoding: .utf8)
        XCTAssertTrue(preview.contains("AccountChipScroller"))
        XCTAssertTrue(preview.contains("CrownTick.play"))
        XCTAssertTrue(preview.contains("allowsMultiple"))
        XCTAssertTrue(preview.contains("pickedIDs"), "预览 4×4 仍按实例勾选")
        XCTAssertFalse(preview.contains("overviewSelection = Set(ids)"), "未选取不得默认全选")
        XCTAssertFalse(preview.contains("preview.overview24"), "2×4 预览不再另开总览块")
        XCTAssertTrue(preview.contains("preview.single24"), "2×4 只留一块预览")
        let views = try String(contentsOf: root.appendingPathComponent("SharedUI/WidgetViews.swift"), encoding: .utf8)
        XCTAssertTrue(views.contains("pickedIDs: item.selectedMetricIDs"), "总览每家计量跟该实例勾选，未勾选回落主页顺序")
        XCTAssertTrue(views.contains("selectedMetricIDs: [String] = []"), "未编辑实例 selectedMetricIDs 为空")
        XCTAssertTrue(preview.contains("fixedSize(horizontal: true"))
        XCTAssertTrue(preview.contains("homeScreenWidgetInset"), "左右边距应对齐主屏小组件")
        XCTAssertTrue(preview.contains("= 16"), "主屏小组件边距约 16pt，预览不得再额外缩窄")
        XCTAssertFalse(preview.contains("0.86"), "不得把 2×4 / 4×4 再缩小一截")
        XCTAssertTrue(preview.contains("scaleEffect"), "按主屏可用宽度等比适配")
        XCTAssertFalse(
            preview.contains(".frame(maxWidth: .infinity)\n                        .background(widgetBackground)"),
            "小组件卡片背景不得横向撑满屏幕"
        )
    }

    func testOfficialPercentFollowsRemainingModeEvenWithDisplayValue() {
        let metric = UsageMetric(
            id: "five_hour", label: "5h", usedPercent: 80, displayValue: "0%/100%"
        )
        XCTAssertEqual(UsagePresentation.valueText(for: metric, language: .en, mode: .remaining), "20%")
        XCTAssertEqual(UsagePresentation.barPercent(used: 80, mode: .remaining), 20)
        XCTAssertEqual(UsagePresentation.valueText(for: metric, language: .en, mode: .used), "80%")
    }

    func testOverviewFallbackTitleUsesLocalizedName() {
        let rows = WidgetAccountItems.overview(
            pickedIDs: [],
            accounts: [],
            providerOrder: [.zhipu, .jimeng, .minimaxGlobal],
            preview: true,
            isProviderEnabled: { _ in true },
            language: .en
        )
        XCTAssertEqual(rows.map(\.title), [
            ProviderID.zhipu.localizedName(.en),
            ProviderID.jimeng.localizedName(.en),
        ])
        XCTAssertNotEqual(rows.map(\.title), rows.map { $0.provider.displayName })
    }

    func testOverflowReservesLastSlotForMoreHint() {
        let exact = WidgetRowSelection.overflow(rowCount: 3, cap: 3)
        XCTAssertEqual(exact.visible, 3)
        XCTAssertEqual(exact.hidden, 0)
        let medium = WidgetRowSelection.overflow(rowCount: 5, cap: 3)
        XCTAssertEqual(medium.visible, 2)
        XCTAssertEqual(medium.hidden, 3)
        let large = WidgetRowSelection.overflow(rowCount: 14, cap: 11)
        XCTAssertEqual(large.visible, 10)
        XCTAssertEqual(large.hidden, 4)
        XCTAssertEqual(L10n.tr("widget.more", .zh, 3), "还有 3 项，打开 App 查看")
        XCTAssertEqual(L10n.tr("widget.more", .en, 3), "3 more — open the app")
        XCTAssertEqual(L10n.tr("common.ok", .zh), "确定")
        XCTAssertEqual(L10n.tr("common.ok", .en), "OK")
    }

    func testShareSurfacesUseLocalizedProviderNameNotChineseDisplayName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let share = try String(
            contentsOf: root.appendingPathComponent("Core/Sources/UsageLimitsCore/ShareImage.swift"), encoding: .utf8
        )
        XCTAssertTrue(share.contains("return snap.provider.localizedName(language)"))
        XCTAssertFalse(
            share.contains("return snap.provider.displayName"),
            "分享图空标题回退不得写死中文 displayName"
        )
        let preview = try String(
            contentsOf: root.appendingPathComponent("App/Share/SharePreviewSheet.swift"), encoding: .utf8
        )
        XCTAssertTrue(preview.contains("item.snapshot.provider.localizedName(lang)"))
        XCTAssertTrue(preview.contains("!item.snapshot.isCustom"), "自定义卡不得用占位 Claude 做副标题")
        XCTAssertFalse(preview.contains("item.snapshot.provider.displayName"))
        XCTAssertTrue(preview.contains("L10n.tr(\"common.ok\""), "分享 toast 确定须走 L10n")
        XCTAssertFalse(preview.contains("Button(\"OK\""), "分享 toast 不得写死英文 OK")
        XCTAssertTrue(preview.contains("item.customLogoData"), "分享选择器自定义卡须能用 customLogoData")
        let shareRender = try String(
            contentsOf: root.appendingPathComponent("App/Share/ShareCardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(shareRender.contains("if let used = meter.usedPercent"), "usedPercent==nil 不得画 0% 空条")
    }

    func testShippedMediumRowsFollowUsagePresentation() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/WidgetViews.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("UsagePresentation.valueText"), "2×4/4×4 官方数值须跟展示口径")
        XCTAssertTrue(src.contains("UsagePresentation.barPercent"), "2×4/4×4 进度条须跟展示口径")
        XCTAssertFalse(src.contains("Int($0.rounded())"), "官方行不得再用 raw usedPercent 拼百分比")
        XCTAssertTrue(src.contains("WidgetRowSelection.overflow"), "超量须走 overflow 留末行")
        XCTAssertTrue(src.contains("widget.more"), "2×4/4×4 超量须提示还有 N 项")
        XCTAssertTrue(src.contains("accountBlocks"), "2×4/4×4 按账号成组，名称垂直居中")
        XCTAssertTrue(src.contains("alignment: .center"), "供应商须落在计量条高度中间")
        XCTAssertTrue(src.contains("GroupBrace"), "多条计量须有花括号框定范围")
        XCTAssertTrue(src.contains("scopedItems.count > 1"), "单账号 2×4 不画花括号")
        XCTAssertTrue(src.contains("overviewMetersPerAccount"), "总览每家条数按实例数查表")
        XCTAssertTrue(src.contains("isLargeOverview"), "4×4 预览须显式走大号总览表")
        XCTAssertTrue(src.contains("displayText(lang)"), "2×2/2×4 错误态须走 displayText，不得一律未登录")
        XCTAssertTrue(src.contains("L10n.metricLabel"), "官方指标名须走 L10n.metricLabel")
    }


    func testParserErrorAndDeepSeekLabelsLocalize() {
        XCTAssertEqual(L10n.tr("未获取到任何响应", .en), "No response received")
        XCTAssertEqual(L10n.tr("未获取到任何响应", .zh), "未获取到任何响应")
        XCTAssertEqual(
            L10n.metricLabel(provider: .deepseek, id: "balance", fallback: "重置余额", language: .en),
            "Prepaid balance"
        )
        XCTAssertEqual(
            SnapshotStatus.error("未获取到任何响应").displayText(.en),
            "No response received"
        )
        XCTAssertEqual(
            SnapshotStatus.error("HTTP 503").displayText(.en),
            "HTTP 503"
        )
        XCTAssertEqual(L10n.tr("本月限额", .en), "Monthly limit")
        XCTAssertEqual(L10n.tr("剩余积分", .en), "Remaining credits")
        XCTAssertEqual(L10n.tr("游客额度", .en), "Guest quota")
        XCTAssertEqual(L10n.tr("月", .en), "mo")
        XCTAssertEqual(L10n.tr("Credits", .zh), "积分")
        XCTAssertEqual(
            L10n.metricLabel(provider: .jimeng, id: "remaining", fallback: "剩余积分", language: .en),
            "Remaining credits"
        )

        XCTAssertEqual(L10n.tr("今天", .en), "Today")
        XCTAssertEqual(L10n.tr("昨天", .en), "Yesterday")
        XCTAssertEqual(L10n.tr("上月", .en), "Last month")
        XCTAssertEqual(
            L10n.metricLabel(provider: .jimeng, id: "subscription", fallback: "订阅积分", language: .en),
            "Subscription credits"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .jimeng, id: "recharge", fallback: "充值积分", language: .en),
            "Purchased credits"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .jimeng, id: "gift", fallback: "赠送积分", language: .en),
            "Bonus credits"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .t3chat, id: "four_hour", fallback: "Base（4 小时）", language: .en),
            "Base (4 hours)"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .t3chat, id: "overage", fallback: "Overage", language: .zh),
            "超额"
        )
        XCTAssertEqual(L10n.tr("app.title", .zh), "Usage Limits")
        XCTAssertEqual(L10n.trDetail("Base - max", .zh), "Base - max")
        XCTAssertEqual(
            L10n.metricLabel(provider: .kimi, id: "seven_day", fallback: "本周用量", language: .en),
            "Weekly usage"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .longcat, id: "fuel_packages", fallback: "加油包", language: .en),
            "Fuel pack"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .zhipu, id: "mcp_monthly", fallback: "MCP 每月额度", language: .en),
            "MCP monthly quota"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .grok, id: "auto", fallback: "自动", language: .en),
            "Auto"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .zhipu, id: "five_hour", fallback: "每 5 小时", language: .en),
            "Every 5 hours"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .zhipu, id: "credit_day", fallback: "每天（积分）", language: .en),
            "Daily (credits)"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .zhipu, id: "seven_day", fallback: "每周", language: .en),
            "Weekly"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .zhipu, id: "window_180", fallback: "每 3 小时", language: .ja),
            "3時間ごと"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .zhipu, id: "unknown", fallback: "限额", language: .en),
            "Limit"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "additional.1", fallback: "附加 1 5 小时窗口", language: .en),
            "Extra 1 5-hour window"
        )
        XCTAssertEqual(L10n.trDetail("状态 degraded", .en), "Status degraded")
        XCTAssertEqual(L10n.tr("高峰 1x", .en), "Peak 1x")
        XCTAssertEqual(L10n.tr("低谷 0.5x", .en), "Off-peak 0.5x")
        let peak = UsageMetric(id: "rate_period", label: "计费时段", displayValue: "高峰 1x")
        XCTAssertEqual(UsagePresentation.valueText(for: peak, language: .en, mode: .used), "Peak 1x")
        XCTAssertEqual(
            L10n.metricLabel(provider: .grok, id: "weekly", fallback: "本月限额", language: .en),
            "Monthly limit"
        )
    }

    func testShareAndCalendarUseMetricLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let share = try String(
            contentsOf: root.appendingPathComponent("Core/Sources/UsageLimitsCore/ShareImage.swift"), encoding: .utf8
        )
        let notify = try String(
            contentsOf: root.appendingPathComponent("App/NotificationManager.swift"), encoding: .utf8
        )
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(share.contains("L10n.metricLabel"), "官方分享卡指标名须走 L10n.metricLabel")
        XCTAssertTrue(notify.contains("notify.reset.body.scheduled"), "日历重置须有排期文案")
        XCTAssertTrue(notify.contains("localizedMetricLabel"), "自定义预充值不得走官方 metricKey")
        XCTAssertTrue(
            notify.contains("L10n.metricLabel") || notify.contains("localizedMetricLabel"),
            "事件投递与日历重置都须走 metricLabel"
        )
        XCTAssertTrue(card.contains("L10n.metricLabel"), "首页官方行须走 L10n.metricLabel")
        XCTAssertTrue(card.contains("L10n.tr(text, lang)"), "套餐/周期徽章须走 L10n")
        XCTAssertTrue(card.contains("L10n.tr(\"deepseek.tokens\", lang)"), "DeepSeek key 行 tok 须走 L10n")
        XCTAssertFalse(card.contains("+ \" tok\""), "DeepSeek key 行不得写死英文 tok")
        XCTAssertFalse(card.contains("[Showing" + " lines"), "首页卡不得再被 Read 页脚截断")
        XCTAssertTrue(share.contains("L10n.tr(metric.label, language)"), "自定义分享行名须再查 L10n")

        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(dashboard.contains("L10n.tr(\"app.title\", lang)"), "首页标题须走 app.title")
        XCTAssertFalse(dashboard.contains("navigationTitle(\"Usage Limits\")"))
        XCTAssertTrue(dashboard.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertTrue(dashboard.contains("state.isRefreshingAll"), "全局刷新按钮须展示真实在飞状态")
        XCTAssertTrue(dashboard.contains("ProgressView()"), "全局刷新中须显示进度")
        XCTAssertTrue(dashboard.contains(".disabled(state.isRefreshingAll)"), "全局刷新在飞时须禁用重入")
        XCTAssertFalse(dashboard.contains(".refreshable"), "下拉刷新只在 DashboardFlatView 的平铺列表里，首页容器本身不挂")
        XCTAssertTrue(share.contains("L10n.tr(period.label, language)"), "预充值时段名须走 L10n")
    }

    func testInterpolatedParserErrorsAndMissingMetricLabelsLocalize() {
        XCTAssertEqual(
            SnapshotStatus.error("余额数据异常：temporary").displayText(.en),
            "Balance data is invalid: temporary"
        )
        XCTAssertEqual(
            SnapshotStatus.error("智谱接口失败 code 1001").displayText(.en),
            "Zhipu request failed code 1001"
        )
        XCTAssertEqual(
            SnapshotStatus.error("DeepSeek code 50001: internal error").displayText(.zh),
            "DeepSeek 错误码 50001: internal error"
        )
        XCTAssertEqual(
            SnapshotStatus.error("LongCat code 404").displayText(.zh),
            "LongCat 错误码 404"
        )
        XCTAssertEqual(
            SnapshotStatus.error("LongCat code 404").displayText(.en),
            "LongCat code 404"
        )
        XCTAssertEqual(
            SnapshotStatus.error("响应状态码异常").displayText(.en),
            "Unexpected response status"
        )
        XCTAssertEqual(L10n.tr("本月", .en), "This month")
        XCTAssertEqual(L10n.tr("5h 限额", .en), "5h limit")
        XCTAssertEqual(L10n.tr("On-demand", .zh), "按需")
        XCTAssertEqual(L10n.tr("购买额度", .en), "Purchased quota")
        XCTAssertEqual(
            L10n.metricLabel(provider: .minimax, id: "model_foo_weekly", fallback: "video-gen（周）", language: .en),
            "video-gen (week)"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .minimax, id: "text_weekly", fallback: "文本生成（周）", language: .en),
            "Text generation (week)"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "primary_window", fallback: "Codex 5 小时窗口", language: .en),
            "Codex 5-hour window"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "secondary_window", fallback: "Codex 周窗口", language: .en),
            "Codex Weekly window"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "code_review", fallback: "Codex 代码审查 5 小时窗口", language: .en),
            "Codex code review 5-hour window"
        )
        XCTAssertEqual(
            L10n.metricLabel(
                provider: .openai,
                id: "additional.spark",
                fallback: "GPT-5.3-Codex-Spark 周窗口",
                language: .en
            ),
            "GPT-5.3-Codex-Spark Weekly window"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "nday", fallback: "Codex 3 天窗口", language: .en),
            "Codex 3-day window"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "nhour", fallback: "Codex 3 小时窗口", language: .en),
            "Codex 3-hour window"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "frac", fallback: "Codex 2.5 小时窗口", language: .ja),
            "Codex 2.5時間ウィンドウ"
        )
        XCTAssertEqual(L10n.tr("未知时长", .en), "Unknown duration")
        XCTAssertEqual(L10n.tr("无限制", .en), "Unlimited")
        XCTAssertEqual(
            SnapshotStatus.ok.emptyUsageCaption(language: .en, okKey: "jimeng.creditsUnavailable"),
            "Credits not available yet"
        )
        XCTAssertEqual(
            SnapshotStatus.error("未获取到任何响应").emptyUsageCaption(language: .en),
            "No response received"
        )
        XCTAssertEqual(
            SnapshotStatus.needsLogin.emptyUsageCaption(language: .en, okKey: "widget.noNumeric"),
            "Not signed in"
        )
        XCTAssertEqual(L10n.tr("custom.noNumeric", .en), "Signed in, but no numbers to show")
        XCTAssertEqual(L10n.tr("custom.noNumeric", .zh), "已登录，但没有可显示的数字")
        XCTAssertEqual(SnapshotStatus.error("HTTP 503").displayText(.en), "HTTP 503")
        XCTAssertEqual(L10n.tr("证书不受信任", .en), "Untrusted certificate")
        XCTAssertEqual(L10n.tr("明文被拦", .en), "Cleartext blocked")
        XCTAssertEqual(L10n.tr("超时", .en), "Timed out")
        XCTAssertEqual(L10n.tr("无网络", .en), "No network")
        XCTAssertEqual(L10n.trDetail("无上限", .en), "Unlimited")
        XCTAssertEqual(L10n.trDetail("已使用", .en), "Used")
        XCTAssertEqual(L10n.trDetail("已用 1.2 / 3.4 points", .en), "Used 1.2 / 3.4 points")
        XCTAssertEqual(L10n.trDetail("12 积分", .en), "12 credits")
        XCTAssertEqual(
            L10n.metricLabel(provider: .minimax, id: "credits", fallback: "积分余额", language: .en),
            "Credit balance"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .mimo, id: "monthly", fallback: "月度额度", language: .en),
            "Monthly quota"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .perplexity, id: "promotional", fallback: "赠送额度", language: .en),
            "Bonus quota"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .perplexity, id: "balance", fallback: "余额", language: .en),
            "Balance"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .openai, id: "credits", fallback: "Codex credits", language: .zh),
            "Codex 积分"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .cursor, id: "team_pooled", fallback: "Team pooled", language: .zh),
            "团队共享"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .cursor, id: "grok_bot", fallback: "Grok Bot", language: .zh),
            "Grok 机器人"
        )
        XCTAssertEqual(L10n.tr("Grok Bot", .ja), "Grokボット")
        XCTAssertEqual(L10n.tr("请求上限", .en), "Request limit")
        XCTAssertEqual(L10n.tr("剩余请求", .en), "Requests left")
        XCTAssertEqual(L10n.tr("Weekly usage", .zh), "每周用量")
        XCTAssertEqual(L10n.tr("Session usage", .ja), "セッション使用量")
        XCTAssertEqual(
            L10n.metricLabel(provider: .notion, id: "rolling", fallback: "Rolling（6 小时）", language: .en),
            "Rolling (6 hours)"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .notion, id: "rolling", fallback: "Rolling（2 周）", language: .en),
            "Rolling (2 weeks)"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .notion, id: "rolling", fallback: "Rolling（1 天）", language: .ja),
            "ローリング（1日）"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .notion, id: "billing_period", fallback: "Billing Period", language: .zh),
            "账期"
        )
        XCTAssertEqual(L10n.trDetail("已用 9 / 8（超额）", .en), "Used 9 / 8 (overage)")
        XCTAssertEqual(L10n.tr("系统繁忙", .en), "System busy")
        XCTAssertEqual(L10n.tr("控制台接口无响应", .en), "Console API did not respond")
        XCTAssertEqual(
            SnapshotStatus.error("Notion AI 额度数据异常").displayText(.en),
            "Notion AI quota data is invalid"
        )
        XCTAssertEqual(
            SnapshotStatus.error("T3 Chat 遇到 Vercel 风控挑战").displayText(.en),
            "T3 Chat hit a Vercel challenge"
        )
        XCTAssertEqual(L10n.trDetail("按月重置", .en), "Resets monthly")
        XCTAssertEqual(L10n.trDetail("2 小时短期限流", .en), "2 hours short rate limit")
        XCTAssertEqual(
            L10n.metricLabel(provider: .grok, id: "weekly.0", fallback: "第三方", language: .en),
            "Third party"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .grok, id: "weekly.8", fallback: "分类 8", language: .en),
            "Category 8"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .minimax, id: "model_speech", fallback: "语音合成", language: .en),
            "Speech synthesis"
        )
        XCTAssertEqual(L10n.tr("游客额度", .en), "Guest quota")
        XCTAssertEqual(L10n.trError("StepFun 用量数据异常", .en), "StepFun usage data is invalid")
        XCTAssertEqual(
            L10n.trDetail("已用 1.0K / 4.0K credits · 最近到期 2026-10-01", .en),
            "Used 1.0K / 4.0K credits · Expires 2026-10-01"
        )
        XCTAssertEqual(
            L10n.trDetail("付费 $30.00 · 赠送 $20.00", .en),
            "Paid $30.00 · Bonus $20.00"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .kimi, id: "window_300", fallback: "窗口 5 小时", language: .en),
            "5-hour window"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .kimi, id: "window_15", fallback: "窗口 15 分钟", language: .ja),
            "15分ウィンドウ"
        )
        XCTAssertEqual(L10n.tr("配额", .en), "Quota")
        XCTAssertEqual(L10n.tr("赠送", .fr), "Bonus")
    }

    func testParserStaticErrorStringsLocalize() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent("Core/Sources/UsageLimitsCore")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("Parser.swift") }
        XCTAssertFalse(files.isEmpty)
        var missing: [String] = []
        let pattern = try NSRegularExpression(pattern: #"\.error\("([^"\\]+)"\)"#)
        for file in files {
            let src = try String(contentsOf: file, encoding: .utf8)
            let ns = src as NSString
            for match in pattern.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: match.range(at: 1))
                if L10n.tr(key, .en) == key {
                    missing.append("\(file.lastPathComponent): \(key)")
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "parser .error strings missing L10n: \(missing.joined(separator: ", "))")
    }

    func testWidgetAndWatchEmptyCaptionsUseStatus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("SharedUI/WidgetViews.swift"), encoding: .utf8
        )
        let watch = try String(
            contentsOf: root.appendingPathComponent("Watch/WatchViews.swift"), encoding: .utf8
        )
        XCTAssertTrue(widget.contains("jimeng.creditsUnavailable"), "2×2/2×4 即梦空额度不得交空白")
        XCTAssertTrue(widget.contains("emptyUsageCaption"), "2×2 空态须走 emptyUsageCaption")
        XCTAssertTrue(widget.contains("custom.noNumeric"), "自定义空态须走自定义口侄")
        XCTAssertTrue(watch.contains("item.status"), "表端自定义空态须看下发 status")
        XCTAssertTrue(watch.contains("visibleMetrics"), "表端失败须忽略 leftover 数字")
        XCTAssertTrue(watch.contains("emptyUsageCaption"), "表端空态须走 emptyUsageCaption")
        XCTAssertTrue(watch.contains("custom.noNumeric"), "表端自定义空态须走自定义口侄")
        XCTAssertTrue(watch.contains("MoneyFormat.string"), "官方仅金额时表端须画钱而不是 card.noNumeric")
        XCTAssertTrue(widget.contains("AppDeepLink.accountURL"), "总览行须能深链到账号实例")
        let editor = try String(
            contentsOf: root.appendingPathComponent("App/Views/ColorEditorSheet.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            editor.contains("L10n.tr(BillingCycle.monthly.tag, lang)"),
            "主题色预览周期标签须走表"
        )
        let home = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            home.contains("isCustom ? \"custom.noNumeric\" : \"card.notLoggedIn\""),
            "首页自定义未抓取不得写官方未登录"
        )
        XCTAssertTrue(home.contains("struct MetricReorderMenu"), "计量条长按须走独立菜单，不得挂整卡")
        XCTAssertTrue(home.contains("onReorderMetrics: onReorderMetrics"), "官方行须能打开计量顺序编辑")
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProvidersSettingsView.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            settings.contains("account.isCustom ? \"custom.noNumeric\" : \"card.notLoggedIn\""),
            "设置页自定义未就绪不得写官方未登录"
        )
    }
    func testOverviewRowsCapTwoFollowExpandedOrder() {
        let snap = ProviderSnapshot(
            provider: .openai,
            metrics: [
                UsageMetric(id: "codex", label: "Codex", usedPercent: 15),
                UsageMetric(id: "primary", label: "5h", usedPercent: 40),
                UsageMetric(id: "secondary", label: "7d", usedPercent: 80),
            ],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(WidgetChrome.maxMetersPerAccount, 2)
        XCTAssertEqual(
            WidgetAccountItems.overviewMeters(from: snap).map(\.id),
            ["codex", "primary"]
        )
        XCTAssertEqual(
            WidgetAccountItems.overviewMeters(from: snap).map(\.id),
            ["codex", "primary"],
            "总览不再改走 weeklySummary，和展开顺序前两条一致"
        )
    }

    func testCollapsedMetricUsesFirstActiveInOrder() {
        let now = Date()
        let snap = ProviderSnapshot(
            provider: .zhipu,
            metrics: [
                UsageMetric(id: "mcp_monthly", label: "MCP 每月额度", usedPercent: 40,
                            resetsAt: now.addingTimeInterval(20 * 86400)),
                UsageMetric(id: "five_hour", label: "每 5 小时", usedPercent: 12,
                            resetsAt: now.addingTimeInterval(3 * 3600)),
            ],
            fetchedAt: now,
            status: .ok
        )
        XCTAssertEqual(snap.collapsedMetric?.id, "mcp_monthly")
        let reordered = ProviderSnapshot(
            provider: .zhipu,
            metrics: MetricOrdering.apply(snap.metrics, order: ["five_hour", "mcp_monthly"]),
            fetchedAt: now,
            status: .ok
        )
        XCTAssertEqual(reordered.collapsedMetric?.id, "five_hour")
    }

    func testSelectedMetersHonorPickedOrderAndCaps() {
        let snap = ProviderSnapshot(
            provider: .openai,
            metrics: [
                UsageMetric(id: "codex", label: "Codex", usedPercent: 15),
                UsageMetric(id: "primary", label: "5h", usedPercent: 40),
                UsageMetric(id: "secondary", label: "7d", usedPercent: 80),
                UsageMetric(id: "plus", label: "Plus", usedPercent: 20),
            ],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(WidgetChrome.maxMetersPerSmall, 2)
        XCTAssertEqual(WidgetChrome.maxMetersPerSingleAccount, 4)
        XCTAssertEqual(
            WidgetAccountItems.selectedMeters(from: snap, cap: WidgetChrome.maxMetersPerSmall).map(\.metric.id),
            ["codex", "primary"]
        )
        XCTAssertEqual(
            WidgetAccountItems.selectedMeters(
                from: snap, pickedIDs: ["secondary", "codex", "plus"], cap: WidgetChrome.maxMetersPerSmall
            ).map(\.metric.id),
            ["secondary", "codex"]
        )
        XCTAssertEqual(
            WidgetAccountItems.overviewMeters(
                from: snap, pickedIDs: ["plus", "secondary", "codex", "primary"], cap: 4
            ).map(\.id),
            ["plus", "secondary", "codex", "primary"]
        )
        XCTAssertEqual(
            WidgetAccountItems.selectedMeters(
                from: snap, pickedIDs: ["missing", "ghost"], cap: 2
            ).map(\.metric.id),
            ["codex", "primary"],
            "未知勾选须回落展开顺序"
        )
        // 编辑页「+」列表含未上屏的额度（用量为 0 默认隐藏），用户点名要就得显示（DEVLOG #102）
        let withIdle = ProviderSnapshot(
            provider: .claude,
            metrics: snap.metrics + [UsageMetric(id: "sonnet", label: "Sonnet", usedPercent: 0)],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertFalse(withIdle.activeMetrics.contains { $0.id == "sonnet" }, "0 用量默认不上首页")
        XCTAssertEqual(
            WidgetAccountItems.selectedMeters(
                from: withIdle, pickedIDs: ["codex", "primary", "secondary", "sonnet"], cap: 4
            ).map(\.metric.id),
            ["codex", "primary", "secondary", "sonnet"],
            "跟随首页 + 手动加的未上屏额度要一起显示"
        )
    }

    func testOverviewRefreshStampOverlaysNameColumn() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/WidgetViews.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("overlay(alignment: .bottomLeading)"), "刷新时间叠在左侧 logo 列底部，不占计量条高度")
        XCTAssertTrue(src.contains("block.id == visible.last"), "只画在最后一家名称列下")
        XCTAssertTrue(src.contains("groupView(block, stamp:"), "名称列接收 stamp")
        XCTAssertFalse(src.contains("RefreshStamp(date: latestFetchedAt, now: now)"), "不得做成整卡居中页脚")
        XCTAssertFalse(src.contains("VStack(alignment: .leading, spacing: 1)"), "不得和名称叠成一列把名字顶歪")
    }

    func testEditorPrefillSlotsMapHomeOrderIncludingEdits() {
        let home = ["seven_day", "five_hour", "seven_day_opus"]
        let catalog = home + ["extra_usage"]
        let slots = (0..<4).map { WidgetEditorPrefill.slotID($0) }
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: slots, homeIDs: home, catalogIDs: catalog),
            home + ["extra_usage"],
            "有默认带默认，有改序带改序；第 4 槽用目录补齐（DEVLOG #104）"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: [], homeIDs: home, catalogIDs: catalog),
            home,
            "空配置回落首页可见额度"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(
                identifiers: ["five_hour", "extra_usage"],
                homeIDs: home,
                catalogIDs: catalog
            ),
            ["five_hour", "extra_usage"],
            "用户增删后保留勾选"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: ["stale"], homeIDs: home, catalogIDs: catalog),
            home,
            "换账号后旧 id 对不上就回落新账号首页额度"
        )
    }

    /// 系统编辑页里换账号后，已选额度行不会重新查 query；`@Parameter(default:)` 与 `displayRepresentation`
    /// 都拿不到当前账号，只能按槽位命名，绝不能拿「首页第一个实例」的额度名充数（DEVLOG #100：选 Claude 却列出 Grok 的额度）。
    func testEditorPlaceholderSlotsNeverBorrowAnotherInstanceTitles() throws {
        XCTAssertEqual(WidgetEditorPrefill.slotTitle(index: 0, language: .zh), "首页额度 1")
        XCTAssertEqual(WidgetEditorPrefill.slotTitle(index: 3, language: .en), "Home quota 4")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertNotEqual(WidgetEditorPrefill.slotTitle(index: 1, language: lang), "widget.homeSlot", "\(lang) 缺占位槽文案")
            XCTAssertTrue(WidgetEditorPrefill.slotTitle(index: 1, language: lang).contains("2"), "占位槽标题须带序号")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8
        )
        let entity = widget.components(separatedBy: "struct MetricChoiceEntity").dropFirst().first?
            .components(separatedBy: "enum WidgetMetricCatalog").first ?? ""
        XCTAssertFalse(entity.isEmpty)
        XCTAssertTrue(entity.contains("WidgetEditorPrefill.slotTitle"), "旧配置里的占位槽仍按槽位命名")
        XCTAssertFalse(entity.contains("\"额度\""), "显示名不得写死中文")
        XCTAssertFalse(entity.contains("WidgetMetricCatalog"), "displayRepresentation 不得再查目录猜账号")
        XCTAssertFalse(entity.contains("store.accounts"), "displayRepresentation 不得读账号表")
        let defaults = widget.components(separatedBy: "enum MetricChoiceDefaults").dropFirst().first?
            .components(separatedBy: "enum OverviewDefaults").first ?? ""
        XCTAssertFalse(defaults.isEmpty)
        XCTAssertFalse(defaults.contains("entities(for: nil"), "default 不得按 nil 账号（首页第一个实例）预填额度名")
        XCTAssertFalse(defaults.contains("store.accounts"), "default 不得自己翻账号表猜实例")
        XCTAssertFalse(defaults.contains("\"额度\""), "占位标题不得写死中文")
        let catalog = widget.components(separatedBy: "static func snapshot(for account: AccountChoiceEntity?").dropFirst().first?
            .components(separatedBy: "static func metricPairs").first ?? ""
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertTrue(
            catalog.contains("HighestUsageChoice.id") && catalog.contains("highestUsageEntry"),
            "「最高用量（自动）」的编辑页目录须解析成时间线同一个实例，不得退到首页第一个账号"
        )
    }

    func testEditorItemsPreserveSlotIDsSoDeleteWorks() {
        let home = ["seven_day", "five_hour", "seven_day_opus"]
        let catalog = home + ["extra_usage"]
        let slots = (0..<4).map { WidgetEditorPrefill.slotID($0) }
        let prefilled = WidgetEditorPrefill.editorItems(
            identifiers: slots, homeIDs: home, catalogIDs: catalog
        )
        XCTAssertEqual(prefilled.map(\.id), slots, "占位槽保留 slot id，第 4 槽用目录补齐")
        XCTAssertEqual(prefilled.map(\.catalogID), home + ["extra_usage"], "标题映射首页顺序，含改序")

        let afterDelete = WidgetEditorPrefill.editorItems(
            identifiers: Array(slots.prefix(2)), homeIDs: home, catalogIDs: catalog
        )
        XCTAssertEqual(afterDelete.map(\.id), Array(slots.prefix(2)), "删一条只剩剩下的槽")
        XCTAssertEqual(afterDelete.map(\.catalogID), Array(home.prefix(2)))

        XCTAssertTrue(
            WidgetEditorPrefill.editorItems(identifiers: [], homeIDs: home, catalogIDs: catalog).isEmpty,
            "编辑页删光不回填，系统才能画出减号并接受空列表"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.editorItems(
                identifiers: ["five_hour", "extra_usage"], homeIDs: home, catalogIDs: catalog
            ).map(\.id),
            ["five_hour", "extra_usage"],
            "用户增删后保留勾选 id"
        )
        XCTAssertTrue(
            WidgetEditorPrefill.editorItems(identifiers: ["stale"], homeIDs: home, catalogIDs: catalog).isEmpty,
            "编辑页对不上的旧 id 不能再填回首页，否则删不掉"
        )
    }

    /// 换账号后系统把额度参数重置回 `@Parameter(default:)`，默认值拿不到账号，四个「首页额度 N」占位行在用户眼里
    /// 就是与实例不匹配的统配名（真机反馈）。默认改成与账号无关的单行「跟随首页额度」，时间线把它展开成所选账号的
    /// 首页可见额度；要指定额度就删掉它、用「+」从当前账号目录里挑（DEVLOG #102）。
    func testFollowHomeRowExpandsToSelectedAccountHomeMetrics() throws {
        let home = ["seven_day", "five_hour", "seven_day_opus"]
        let catalog = home + ["extra_usage"]
        let follow = WidgetEditorPrefill.followHomeID
        XCTAssertTrue(WidgetEditorPrefill.isFollowHomeID(follow))
        XCTAssertNil(WidgetEditorPrefill.slotIndex(follow), "跟随行不是槽位")
        XCTAssertFalse(WidgetEditorPrefill.isHeaderID(follow), "跟随行不是被过滤的表头")
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: [follow], homeIDs: home, catalogIDs: catalog),
            home, "跟随行 = 所选账号首页可见额度"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: [follow, "extra_usage"], homeIDs: home, catalogIDs: catalog),
            home + ["extra_usage"], "跟随行 + 手动加的额度：首页在前，追加去重"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: ["five_hour", follow], homeIDs: home, catalogIDs: catalog),
            ["five_hour", "seven_day", "seven_day_opus"], "按出现顺序展开并去重"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: [follow], homeIDs: [], catalogIDs: catalog),
            [], "账号首页没有额度就空着，视图自己回落"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.editorItems(
                identifiers: [follow, "five_hour", "stale"], homeIDs: home, catalogIDs: catalog
            ).map(\.id),
            [follow, "five_hour"], "编辑页保留跟随行自身 id，系统才能按 id 删除；旧 id 不回填"
        )
        XCTAssertEqual(WidgetEditorPrefill.followHomeTitle(language: .zh), "跟随首页额度")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertNotEqual(WidgetEditorPrefill.followHomeTitle(language: lang), "widget.followHome", "\(lang) 缺跟随行文案")
        }
        let widget = try widgetSource()
        let defaults = widget.components(separatedBy: "enum MetricChoiceDefaults").dropFirst().first?
            .components(separatedBy: "enum OverviewDefaults").first ?? ""
        XCTAssertFalse(defaults.isEmpty)
        XCTAssertTrue(defaults.contains("WidgetEditorPrefill.slotID"), "默认 4 个占位槽（DEVLOG #104）")
        let entity = widget.components(separatedBy: "struct MetricChoiceEntity").dropFirst().first?
            .components(separatedBy: "enum WidgetMetricCatalog").first ?? ""
        XCTAssertTrue(entity.contains("WidgetEditorPrefill.followHomeTitle"), "跟随行显示名走 L10n")
        let query = widget.components(separatedBy: "struct MetricChoiceQuery").dropFirst().first?
            .components(separatedBy: "struct OverviewAccountChoiceQuery").first ?? ""
        XCTAssertTrue(query.contains("isFollowHomeID"), "entities(for:) 回传跟随行时标题留空，不得拿目录名充数")
    }

    /// 真机 0.4.548 编辑页点「账号」显示「无可用选项」：清诊断日志时把 `AccountChoiceQuery` 的单行
    /// `suggestedEntities()` / `defaultResult()` 一起删了，`EntityQuery` 的默认实现返回空数组（DEVLOG #101）。
    /// 每个查询都必须显式给出建议列表。
    func testEveryWidgetEntityQueryProvidesSuggestions() throws {
        let widget = try widgetSource()
        let queries = widget.components(separatedBy: "\nstruct ").dropFirst()
            .filter { $0.split(separator: "\n").first?.contains("EntityQuery") == true }
        XCTAssertGreaterThanOrEqual(queries.count, 3, "账号 / 额度 / 总览账号三个查询")
        for block in queries {
            let name = block.split(separator: ":").first.map(String.init) ?? "?"
            let body = block.components(separatedBy: "\n}\n").first ?? block
            XCTAssertTrue(body.contains("func suggestedEntities()"), "\(name) 缺 suggestedEntities()，选择器会是「无可用选项」")
            XCTAssertTrue(body.contains("func entities(for identifiers:"), "\(name) 缺 entities(for:)")
            XCTAssertTrue(body.contains("func entities(matching string:"), "\(name) 缺搜索")
        }
        let account = widget.components(separatedBy: "struct AccountChoiceQuery").dropFirst().first?
            .components(separatedBy: "\n}\n").first ?? ""
        XCTAssertTrue(
            account.contains("func suggestedEntities() async throws -> [AccountChoiceEntity] { Self.displayed() }"),
            "账号选择器列首页可见实例"
        )
        XCTAssertTrue(
            account.contains("func defaultResult() async -> AccountChoiceEntity? { Self.all().first }"),
            "新加小组件默认账号「最高用量（自动）」"
        )
    }

    private func widgetSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8)
    }

    /// 换账号时系统只渲染 `@Parameter(default:)` 的实体（`entities(for:)` / `defaultResult()` 的返回都不上屏），
    /// 但顺序是：先算静态默认值 → 用新账号调 `entities(for:)` → 再调默认实体的 `displayRepresentation`。
    /// 所以静态默认值给 4 个占位槽，`entities(for:)` 把账号记进 `EditorDependencyCache`，
    /// `displayRepresentation` 按这个账号把第 N 槽显示成它的第 N 条额度名（DEVLOG #104）。
    func testEditorPrefillShowsSelectedAccountMetricNames() throws {
        let home = ["seven_day", "five_hour", "seven_day_opus"]
        let catalog = home + ["extra_usage", "more"]
        XCTAssertEqual(
            WidgetEditorPrefill.prefillIDs(homeIDs: home, catalogIDs: catalog),
            ["seven_day", "five_hour", "seven_day_opus", "extra_usage"],
            "首页在前，目录补齐到 4 条"
        )
        XCTAssertEqual(WidgetEditorPrefill.prefillIDs(homeIDs: [], catalogIDs: ["a"]), ["a"], "首页没有可见项就用目录")
        let slots = (0..<4).map { WidgetEditorPrefill.slotID($0) }
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: slots, homeIDs: home, catalogIDs: catalog),
            ["seven_day", "five_hour", "seven_day_opus", "extra_usage"],
            "时间线按同一份预填列表映射槽位，小组件与编辑页名字一致"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.editorItems(identifiers: slots, homeIDs: home, catalogIDs: catalog).map(\.catalogID),
            ["seven_day", "five_hour", "seven_day_opus", "extra_usage"]
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: slots, homeIDs: ["only"], catalogIDs: ["only"]),
            ["only"], "额度不够 4 条时多余的槽位丢掉"
        )
        // 槽位带账号：预填时按账号定条数；标着别的账号 = 缓存被别的小组件抢先改掉，按本账号全部预填重来
        let mine = WidgetEditorPrefill.slotID(0, owner: "A")
        XCTAssertEqual(mine, "home.slot.0@A")
        XCTAssertEqual(WidgetEditorPrefill.slotIndex(mine), 0)
        XCTAssertEqual(WidgetEditorPrefill.slotOwner(mine), "A")
        XCTAssertNil(WidgetEditorPrefill.slotOwner("home.slot.2"))
        XCTAssertNil(WidgetEditorPrefill.slotIndex("home.slot.x"))
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: [mine], homeIDs: home, catalogIDs: catalog, account: "A"),
            ["seven_day"], "本账号的槽位按序号映射，条数照勾选"
        )
        XCTAssertEqual(
            WidgetEditorPrefill.entitiesToShow(identifiers: [WidgetEditorPrefill.slotID(0, owner: "B")], homeIDs: home, catalogIDs: catalog, account: "A"),
            ["seven_day", "five_hour", "seven_day_opus", "extra_usage"], "别的账号的槽位 = 默认值被污染，展开成本账号全部预填"
        )
        let foreign = WidgetEditorPrefill.editorItems(
            identifiers: [WidgetEditorPrefill.slotID(0, owner: "B")], homeIDs: home, catalogIDs: catalog, account: "A"
        )
        XCTAssertEqual(foreign.map(\.id), (0..<4).map { WidgetEditorPrefill.slotID($0, owner: "A") }, "重来的槽位标上本账号")
        XCTAssertEqual(foreign.map(\.catalogID), ["seven_day", "five_hour", "seven_day_opus", "extra_usage"])
        XCTAssertEqual(
            WidgetEditorPrefill.editorItems(identifiers: [mine, "extra_usage"], homeIDs: home, catalogIDs: catalog, account: "A").map(\.id),
            [mine, "extra_usage"], "混有手选项就不算默认值，原样解析"
        )

        let widget = try widgetSource()
        XCTAssertTrue(widget.contains("enum EditorDependencyCache"), "缺依赖账号缓存")
        XCTAssertTrue(widget.contains("default: MetricChoiceDefaults.slots"), "静态默认值 = 按缓存账号定条数的占位槽")
        let accountQuery = widget.components(separatedBy: "struct AccountChoiceQuery").dropFirst().first?
            .components(separatedBy: "\n}\n").first ?? ""
        XCTAssertTrue(accountQuery.contains("EditorDependencyCache.note("), "选账号时系统会按 id 回查账号，先记下它")
        XCTAssertTrue(widget.contains("account: configuration.account?.id") || widget.contains("account: account?.id"), "时间线按本账号识别被污染的默认槽位")
        XCTAssertFalse(widget.contains("typealias DefaultValue"), "数组 DefaultValue 真机上让所有编辑页无法载入（DEVLOG #56）")
        let query = widget.components(separatedBy: "struct MetricChoiceQuery").dropFirst().first?
            .components(separatedBy: "struct OverviewAccountChoiceQuery").first ?? ""
        for hook in ["func entities(for identifiers:", "func suggestedEntities()", "func entities(matching string:", "func defaultResult()"] {
            let body = query.components(separatedBy: hook).dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
            XCTAssertTrue(
                body.contains("EditorDependencyCache.note(config?.account)") || body.contains("EditorDependencyCache.note(account)"),
                "\(hook) 须记下依赖账号"
            )
        }
        XCTAssertTrue(query.contains("func defaultResult() async -> MetricChoiceEntity?"), "defaultResult 保持单实体")
        let entity = widget.components(separatedBy: "struct MetricChoiceEntity").dropFirst().first?
            .components(separatedBy: "enum WidgetMetricCatalog").first ?? ""
        XCTAssertTrue(entity.contains("EditorDependencyCache.recent()"), "占位槽显示名按刚换到的账号现算")
        XCTAssertTrue(entity.contains("MetricChoiceDefaults.prefillTitles"), "第 N 槽 = 该账号预填列表第 N 条的名字")
        XCTAssertTrue(entity.contains("WidgetEditorPrefill.slotTitle"), "拿不到账号 / 「最高用量（自动）」退回「首页额度 N」")
        XCTAssertTrue(entity.contains("WidgetEditorPrefill.emptySlotTitle"), "该账号额度不够 N 条时多余槽位标「（空）」")
        XCTAssertEqual(WidgetEditorPrefill.emptySlotTitle(language: .zh), "（空）")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertNotEqual(WidgetEditorPrefill.emptySlotTitle(language: lang), "widget.emptySlot", "\(lang) 缺空槽文案")
        }
        let defaults = widget.components(separatedBy: "enum MetricChoiceDefaults").dropFirst().first?
            .components(separatedBy: "enum OverviewDefaults").first ?? ""
        XCTAssertTrue(defaults.contains("HighestUsageChoice.id"), "「最高用量（自动）」会换账号，不预填具体名字")
        XCTAssertTrue(defaults.contains("WidgetEditorPrefill.prefillIDs"), "编辑页名字与时间线用同一份预填列表")
        XCTAssertFalse(defaults.contains("entities(for: nil"), "不得按 nil 账号（首页第一个实例）预填")
        XCTAssertFalse(defaults.contains("store.accounts"), "不得自己翻账号表猜实例")
    }

    func testWidgetRainbowGlowSharesRefreshGlowGeometry() throws {
        XCTAssertEqual(WidgetChrome.rainbowBloomLineWidth, 2)
        XCTAssertEqual(WidgetChrome.rainbowRimLayers.count, 3)
        XCTAssertEqual(WidgetChrome.rainbowRimLayers[0].stroke, 4.5)
        XCTAssertEqual(WidgetChrome.rainbowRimLayers[0].blur, 3.2)
        XCTAssertEqual(WidgetChrome.rainbowBloomReach, 15.4, accuracy: 0.000_001, "向内到达 = 最外层描边 + 模糊")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8
        )
        let preview = try String(
            contentsOf: root.appendingPathComponent("App/Views/WidgetPreviewView.swift"), encoding: .utf8
        )
        XCTAssertTrue(preview.contains("widgetPreviewRim(cornerRadius: 24)"))
        XCTAssertTrue(preview.contains(".padding(14)"))
    }

    func testWidgetEdgeRimLivesInContentLayerNotContainerBackground() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8
        )
        let backgrounds = widget.components(separatedBy: ".containerBackground(for: .widget)").dropFirst()
        XCTAssertEqual(backgrounds.count, 3, "三个小组件（2×2 / 单账号 2×4 / 4×4）都要设容器底色")
        for tail in backgrounds {
            let closure = tail.prefix(while: { $0 != "\n" })
            XCTAssertEqual(
                String(closure), " { WidgetAppearance.background }",
                "容器底色只能是纯色，不得含 EdgeRim / WidgetBackdrop"
            )
        }
        // 底色按 App 主题给纯白 / 纯黑，跟随系统才用系统动态色（DEVLOG #111）
        XCTAssertTrue(widget.contains("case .light: .white"))
        XCTAssertTrue(widget.contains("case .dark: .black"))
        XCTAssertTrue(widget.contains("case .system: Color(.systemBackground)"))
        XCTAssertFalse(widget.contains("WidgetBackdrop"), "底色 ZStack 已拆掉")
        XCTAssertTrue(widget.contains(".contentMarginsDisabled()"), "内容层要铺满容器才能让边缘装饰贴边")
        XCTAssertTrue(widget.contains("@Environment(\\.widgetContentMargins)"), "手动补回系统内容边距")
        XCTAssertTrue(widget.contains(".padding(margins)"), "内容仍按系统边距内缩，布局不变")
        XCTAssertEqual(WidgetChrome.rainbowEdgeInsetPixels, 1, "系统过渡只拉伸最外 1 个像素，边缘装饰让开这 1 像素即可（#113）")
        XCTAssertEqual(WidgetChrome.rainbowEdgeInset(displayScale: 3), 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(WidgetChrome.rainbowEdgeInset(displayScale: 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WidgetChrome.rainbowEdgeInset(displayScale: 0), 1, accuracy: 1e-9, "倍率异常时退回 1pt，宁可多让")
    }

}

extension WidgetAccountItems {
    /// 测试便利：只关心行的 metric。
    static func overviewMeters(
        from snap: ProviderSnapshot, pickedIDs: [String] = [], cap: Int? = nil
    ) -> [UsageMetric] {
        overviewRows(from: snap, pickedIDs: pickedIDs, cap: cap).map(\.metric)
    }
}

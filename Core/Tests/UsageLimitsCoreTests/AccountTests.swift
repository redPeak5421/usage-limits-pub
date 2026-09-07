import XCTest
@testable import UsageLimitsCore

/// 附加账号（同服务商多账号）：模型、持久化与界面源码契约。
final class AccountTests: XCTestCase {
    private func freshStore() -> (store: SharedStore, cleanup: () -> Void) {
        let suite = "test.accounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SharedStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    func testMovingCanInterleaveDifferentProviders() {
        let x1 = ProviderAccount(provider: .grok, name: "X1", isPrimary: true)
        let x2 = ProviderAccount(provider: .grok, name: "X2")
        let c1 = ProviderAccount(provider: .cursor, name: "C1", isPrimary: true)
        let c2 = ProviderAccount(provider: .cursor, name: "C2")
        let start = [x1, x2, c1, c2]
        // X1 X2 C1 C2 → 把 C1 挪到 X1 后面 → X1 C1 X2 C2
        let interleaved = AccountOrder.moving(start, fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(interleaved.map(\.name), ["X1", "C1", "X2", "C2"])
        let regrouped = [ProviderID.grok, .cursor].flatMap { (p) -> [ProviderAccount] in
            interleaved.filter { $0.provider == p }
        }
        XCTAssertEqual(regrouped.map(\.name), ["X1", "X2", "C1", "C2"], "旧的按服务商聚组会把穿插打回")
        XCTAssertNotEqual(interleaved.map(\.id), regrouped.map(\.id))

    }

    func testAccountsPersistRoundTrip() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        XCTAssertEqual(store.accounts, [])
        // ISO8601 编码只保留到秒：用整秒时间，round-trip 才能全等
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let a = ProviderAccount(provider: .claude, name: "", createdAt: now, isPrimary: true)
        let b = ProviderAccount(provider: .claude, name: "个人号", createdAt: now)
        let c = ProviderAccount(provider: .grok, name: "Grok 2", createdAt: now)
        store.accounts = [a, b, c]
        XCTAssertEqual(store.accounts, [a, b, c])
        XCTAssertEqual(store.accounts(of: .claude), [a, b])
        XCTAssertEqual(store.accounts(of: .grok), [c])
        XCTAssertEqual(store.accounts(of: .openai), [])
        XCTAssertEqual(store.primaryAccount(of: .claude), a)
        XCTAssertNil(store.primaryAccount(of: .grok), "grok 只有附加账号，没有主账号")
    }

    func testLegacyAccountJSONDecodesAsExtraAccount() throws {
        // 早期版本没有 isPrimary 键：解码后默认按附加账号处理
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","provider":"claude",\
        "name":"老账号","createdAt":"2026-08-18T12:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let accounts = try decoder.decode([ProviderAccount].self, from: Data(json.utf8))
        XCTAssertEqual(accounts.count, 1)
        XCTAssertFalse(accounts[0].isPrimary)
        XCTAssertEqual(accounts[0].name, "老账号")
    }

    func testMigrationKeepsProvidersWithSnapshotsAndDisablesRest() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        // 迁移前：claude 有历史快照（在用），其余没有；全部默认启用
        store.save(ProviderSnapshot(provider: .claude, fetchedAt: Date(), status: .ok))
        store.migrateToManualAccountsIfNeeded()
        let primary = store.primaryAccount(of: .claude)
        XCTAssertNotNil(primary, "有快照的服务商应保留为主账号")
        XCTAssertEqual(primary?.displayName, ProviderID.claude.displayName, "迁移名默认回退产品名")
        XCTAssertTrue(store.isEnabled(.claude))
        for provider in ProviderID.allCases where provider != .claude {
            XCTAssertNil(store.primaryAccount(of: provider))
            XCTAssertFalse(store.isEnabled(provider), "\(provider) 未使用应被关闭")
        }
        // 幂等：再跑一次不重复建账号
        store.migrateToManualAccountsIfNeeded()
        XCTAssertEqual(store.accounts.filter { $0.provider == .claude && $0.isPrimary }.count, 1)
    }

    func testMigrationOnFreshInstallLeavesEverythingEmpty() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        store.migrateToManualAccountsIfNeeded()
        XCTAssertTrue(store.accounts.isEmpty)
        for provider in ProviderID.allCases {
            XCTAssertFalse(store.isEnabled(provider))
        }
    }

    func testAccountSnapshotStorageIndependentOfPrimary() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let account = ProviderAccount(provider: .claude, name: "第二账号")
        store.accounts = [account]
        let primary = ProviderSnapshot(
            provider: .claude, planName: "Max 5x", metrics: [], fetchedAt: Date(), status: .ok
        )
        var secondary = primary
        secondary.planName = "Pro"
        store.save(primary)
        store.saveAccountSnapshot(secondary, accountID: account.id)
        // 两份快照互不覆盖
        XCTAssertEqual(store.snapshot(for: .claude)?.planName, "Max 5x")
        XCTAssertEqual(store.accountSnapshot(for: account.id)?.planName, "Pro")
        // 删账号快照不影响主快照
        store.removeAccountSnapshot(for: account.id)
        XCTAssertNil(store.accountSnapshot(for: account.id))
        XCTAssertEqual(store.snapshot(for: .claude)?.planName, "Max 5x")
    }

    func testDisplayNameFallsBackToProviderName() {
        XCTAssertEqual(ProviderAccount(provider: .claude, name: "小号").displayName, "小号")
        XCTAssertEqual(
            ProviderAccount(provider: .claude, name: "   ").displayName,
            ProviderID.claude.localizedName(.system)
        )
        XCTAssertEqual(
            ProviderAccount(provider: .zhipu, name: "").displayName(language: .en),
            ProviderID.zhipu.localizedName(.en)
        )
        XCTAssertNotEqual(
            ProviderAccount(provider: .zhipu, name: "").displayName(language: .en),
            ProviderID.zhipu.displayName,
            "空名附加账号不得把中文 displayName 写进英文界面"
        )
    }

    func testProviderMenuL10nKeysResolvedInAllLanguages() {
        let keys = [
            "providers.add", "providers.accounts",
            "providers.choose", "providers.choose.tintHint",
            "providers.customName",
            "providers.custom", "providers.custom.footer", "providers.startSetup",
            "custom.wizard.title", "custom.wizard.save", "custom.wizard.saveHint", "card.updateToken",
            "custom.card.usedShare",
            "custom.wizard.displayName",
            "custom.wizard.chooseIcon", "custom.wizard.replaceIcon", "custom.wizard.clearIcon",
            "providers.addAndLogin", "providers.empty", "account.rename", "account.delete",
            "account.login", "account.loggedIn", "account.disable", "account.enable",
            "account.disabled",
            "custom.wizard.editTemplate",
        ]
        for key in keys {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                let value = L10n.tr(key, lang)
                XCTAssertFalse(value.isEmpty, "\(key) \(lang) 缺文案")
                XCTAssertNotEqual(value, key, "\(key) \(lang) 未翻译")
            }
        }
        XCTAssertEqual(L10n.tr("providers.startSetup", .zh), "开始配置")
        XCTAssertEqual(L10n.tr("providers.custom.footer", .zh), "用 HTTPS GET + Bearer 对接自己的用量接口。")
        XCTAssertEqual(L10n.tr("providers.add", .zh), "新增供应商")
        XCTAssertEqual(L10n.tr("providers.choose.tintHint", .zh), "点右侧色环，可改该供应商的默认颜色。")
        XCTAssertEqual(L10n.tr("custom.wizard.saveHint", .zh), "先勾选至少一项要展示的字段。")
        XCTAssertEqual(L10n.tr("custom.card.usedShare", .zh, 50), "已用占比 50%")
        XCTAssertEqual(L10n.tr("custom.wizard.editTemplate", .zh), "编辑模板")
    }

    /// 源码契约：服务商全部手动新增（无固定开关列表）；
    /// 选择器含 8 预设 + 自定义向导入口。
    func testProvidersSettingsSourceContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8
        )
        XCTAssertTrue(settings.contains("NavigationLink"), "服务商应为二级菜单入口")
        XCTAssertTrue(settings.contains("ProvidersSettingsView()"))
        XCTAssertFalse(settings.contains("providersExpanded"), "旧的折叠展开实现应移除")
        XCTAssertFalse(settings.contains("settings.providers.footer"), "服务商入口不写点进去就能看懂的说明")
        XCTAssertFalse(settings.contains("settings.addWidget.footer"), "添加小组件的步骤写在预览页，不占设置首页")

        let providers = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProvidersSettingsView.swift"), encoding: .utf8
        )
        XCTAssertFalse(providers.contains("Toggle("), "固定开关列表应全部取消")
        XCTAssertTrue(providers.contains("providers.empty"), "无账号时应有空态提示")
        XCTAssertTrue(providers.contains("providers.add"))
        XCTAssertTrue(providers.contains("AddProviderSheet"))
        XCTAssertTrue(providers.contains("ForEach(catalogEntries)"), "加号页须把官方/预设/模板合成一份名称列表")
        XCTAssertTrue(providers.contains("ProviderCatalog.sortedProviders"), "加号页官方供应商须按名称排序")
        XCTAssertTrue(providers.contains("ProviderLogo(provider: provider"), "预设行应带 logo")
        XCTAssertTrue(providers.contains("providers.startSetup"), "自定义应进入向导而不是敬请期待")
        XCTAssertTrue(providers.contains("CustomUsageWizardView"), "自定义入口须打开向导")
        XCTAssertFalse(providers.contains("custom.template.section"), "服务商页不再放自定义模板段")
        XCTAssertTrue(providers.contains("savedTemplateRow"), "选择供应商须列出已存模板")
        XCTAssertTrue(providers.contains(".addAccount(template)"), "点已有模板须走从模板加账号")
        XCTAssertTrue(providers.contains("custom.template.delete"), "自定义模板行须能删除")
        XCTAssertFalse(providers.contains("L10n.tr(\"providers.comingSoon\""), "自定义不得再显示敬请期待")
        XCTAssertFalse(providers.contains(".disabled(customSelected)"), "选中自定义时预设应保持可选")
        XCTAssertTrue(providers.contains("customSelected = false"),
                      "点预设应取消自定义选中并切回预设流程")
        XCTAssertTrue(providers.contains("selected = provider"))
        XCTAssertFalse(providers.contains("providers.accounts.footer"), "账号列表不写可发现的手势说明")
        XCTAssertTrue(providers.contains("providers.choose.tintHint"), "改颜色的提示只出现在新增供应商页")
        XCTAssertTrue(providers.contains("TintPaletteButton"), "账号行改色仍是调色盘")
        XCTAssertTrue(providers.contains("ProviderTintWell"), "新增供应商改色应是实心圆外环")
        XCTAssertTrue(providers.contains("AngularGradient"), "外环应按圈显示渐变")
        XCTAssertTrue(providers.contains("AddProviderTintChip"))
        let tintControlsStart = try XCTUnwrap(providers.range(of: "enum AddProviderTintChip"))
        let tintControls = String(providers[tintControlsStart.lowerBound...])
        XCTAssertFalse(tintControls.contains("RoundedRectangle"), "供应商色卡保持圆形；名称输入框可使用圆角")
        XCTAssertFalse(providers.contains("frame(width: 10, height: 10)"), "新增供应商色块不得再用 10pt 圆点")
        XCTAssertTrue(providers.contains("providers.addAndLogin"), "选择预设后应出现登录入口")
        XCTAssertTrue(providers.contains("safeAreaInset(edge: .bottom)"), "添加并登录须钉在目录下方可见")
        XCTAssertTrue(providers.contains("addActionBar"), "选中后的名称与 CTA 走底部 inset")
        XCTAssertTrue(providers.contains("state.renameAccount"), "应支持自定义名称（重命名）")
        XCTAssertTrue(providers.contains(".onMove"), "已添加账号应支持拖动排序")
        XCTAssertTrue(providers.contains(".contextMenu"), "已添加账号应支持长按操作菜单")
        XCTAssertTrue(providers.contains("openEditTemplate(for: account)"), "已添加自定义账号须能打开编辑向导")
        XCTAssertTrue(providers.contains("custom.wizard.editTemplate"), "自定义账号长按菜单须有编辑，不得只有 comingSoon")
        XCTAssertTrue(providers.contains(".swipeActions"), "应保留左滑删除")
        XCTAssertTrue(providers.contains("account.disable"), "左滑应暴露停用")
        XCTAssertTrue(providers.contains("state.setAccountEnabled") || providers.contains("setAccountEnabled("),
                      "停用不得删除配置，应走启用开关")
        XCTAssertTrue(providers.contains("account.delete"), "删除仍是独立动作")
        XCTAssertTrue(providers.contains("state.applyAccountOrder"), "拖动结果应持久化并联动首页顺序")
        XCTAssertTrue(providers.contains("paintpalette.fill"), "账号行改色应是调色盘，而不是夹在 logo 与名称之间的圆点")
        XCTAssertTrue(providers.contains("accountTintButton"), "改色入口应在状态文字前，位置对齐")
        XCTAssertFalse(providers.contains("frame(width: 12, height: 12)"), "账号行不得再用 12pt 圆点夹在名称前")

        let dashboard = try String(
            contentsOf: root.appendingPathComponent("App/Views/DashboardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(dashboard.contains("state.showsPrimaryCard(account.provider)"), "主卡只在手动添加后显示")
        XCTAssertTrue(dashboard.contains("for account in state.accounts"), "首页按账号存储顺序建立唯一 scene 目录")
        XCTAssertTrue(dashboard.contains("showAddProvider"), "空首页须能直接打开加号页")
        XCTAssertTrue(dashboard.contains("AddProviderSheet"), "空首页 CTA 打开现有加号 sheet")
        XCTAssertTrue(dashboard.contains("CustomTokenSheet"), "自定义 CTA 须是更新令牌，禁止 LoginSheetView")
        XCTAssertTrue(dashboard.contains("CustomUsageDisplay.metaLine"), "元信息须走展示层，不写 usedPercent")
        XCTAssertTrue(dashboard.contains("CustomUsageWizardView"), "首页须能打开自定义编辑向导")
        XCTAssertTrue(dashboard.contains(".editTemplate"), "首页自定义编辑须走现有模板模式")
        XCTAssertTrue(dashboard.contains("openEditTemplate"), "首页自定义卡须有编辑入口")
        XCTAssertTrue(dashboard.contains("onEdit:"), "自定义卡菜单须接到 onEdit")
        XCTAssertFalse(dashboard.contains("onReorderDrag"), "排序由 scene 手势统一拥有")
        XCTAssertFalse(dashboard.contains("AccountListDropDelegate"), "竖向列表 drop delegate 已移到 DashboardFlatView，首页容器不再直接持有")
        XCTAssertFalse(dashboard.contains("ProviderCardDropDelegate"), "演示卡 drop delegate 已移到 DashboardFlatView")
        XCTAssertFalse(dashboard.contains("DragSessionItemProvider"), "NSItemProvider 生命周期桥已移到 DashboardFlatView")
        XCTAssertTrue(providers.contains("providers.reorder"), "设置页须有排序按钮")
        XCTAssertTrue(providers.contains("editMode"), "排序按钮切换系统拖柄")

        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(card.contains("CustomUsageCardBody"), "自定义卡须用专用 body，不能再走内置 metricsList")
        XCTAssertTrue(card.contains("if isCustom"), "专用 body 只对 isCustom 分支")
        XCTAssertFalse(card.contains("usedPercent:"), "首页自定义卡不得写入 usedPercent")
        XCTAssertTrue(card.contains("onEdit"), "自定义卡须暴露编辑回调")
        XCTAssertTrue(card.contains("private var cardMenuButtons"), "自定义卡编辑须留在现有「…」菜单")
        XCTAssertTrue(card.contains("if let onEdit"), "「…」菜单须按需暴露编辑动作")
        XCTAssertFalse(card.contains("card.contextMenu"), "自定义编辑不得另挂整卡上下文菜单")
        XCTAssertFalse(card.contains("onLongPressGesture"), "独占长按会挡住整卡拖动")
        XCTAssertTrue(card.contains("custom.wizard.editTemplate"), "「…」菜单须有编辑")
        XCTAssertFalse(card.contains("onReorderDrag"), "自定义卡不得再挂独立拖动手柄")
        XCTAssertFalse(card.contains("line.3.horizontal"), "自定义卡不得再画排序手柄")
        XCTAssertFalse(card.contains("customHeader"), "自定义卡抬头须与内置卡同一套 chrome")
        XCTAssertTrue(card.contains("ellipsis.circle"), "菜单钮须与内置卡同款圆形省略号")
        XCTAssertFalse(card.contains("cardCornerRadius"), "自定义卡不得另设圆角")
        let specializedBodies = try XCTUnwrap(card.range(of: "struct DeepSeekCardBody"))
        let cardChrome = String(card[..<specializedBodies.lowerBound])
        XCTAssertFalse(cardChrome.contains("strokeBorder"), "自定义卡不得描 separator 边；即梦明细框的描边独立")
        let customBody = try String(
            contentsOf: root.appendingPathComponent("App/Views/CustomUsageCardBody.swift"), encoding: .utf8
        )
        XCTAssertTrue(customBody.contains("Font.title2"), "折叠态主指标数字须 title2 做主角")
        XCTAssertTrue(customBody.contains("Font.largeTitle"), "展开态主指标数字须 largeTitle")
        XCTAssertTrue(customBody.contains("Font.title3"), "网格格数字须 title3")
        XCTAssertTrue(customBody.contains("CustomUsageDisplay.presentation"), "主指标 / 进度条 / 时间戳分组须由 Core 展示层推导")
        XCTAssertTrue(customBody.contains("monospacedDigit()"), "数字须等宽")
        XCTAssertTrue(customBody.contains(".semibold"), "数字须 semibold，不要再走左右行 bold")
        XCTAssertTrue(customBody.contains("foregroundStyle(.primary)"), "数字须主色，不要中灰")
        XCTAssertTrue(customBody.contains("foregroundStyle(.secondary)"), "展示名须 secondary 在上")
        XCTAssertTrue(customBody.contains("VStack(alignment: .leading"), "标签+数字须上标签下数字左对齐")
        XCTAssertTrue(customBody.contains("GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)"), "展开态其余项须 2 列网格")
        XCTAssertTrue(customBody.contains("gaugeBar"), "占比条须走统一 gaugeBar（阈值配色 + 展开态说明）")
        XCTAssertTrue(customBody.contains("usageLevelColor"), "占比条颜色须按阈值")
        XCTAssertTrue(customBody.contains("tertiarySystemFill"), "内容区内可铺极轻内衬")
        XCTAssertFalse(customBody.contains("design: .rounded"), "不得再走钱包式 rounded 数字")
        XCTAssertFalse(customBody.contains("MetricRowView"), "自定义内容区不得再复用左右 MetricRow")
        XCTAssertFalse(customBody.contains(".subheadline.monospacedDigit().bold()"), "不得再走标签左数字右")
        XCTAssertFalse(customBody.contains("minHeight: 14"), "不得再预留左右行空白把卡撑空")
        XCTAssertTrue(customBody.contains("CustomUsageDisplay.presentation"), "自定义卡数字与占比条须走展示推导")
        XCTAssertFalse(customBody.contains(".usedPercent"), "占比条不得写回 UsageMetric.usedPercent")
        XCTAssertFalse(customBody.contains("usedPercent:"), "占比条不得写回 UsageMetric.usedPercent")
        XCTAssertTrue(dashboard.contains("collapseAndFocus"), "深链必须收起当前卡再聚焦目标")
        XCTAssertTrue(dashboard.contains("state.applyAccountOrder"), "scene 账号排序必须一次持久化完整结果")
        XCTAssertTrue(dashboard.contains("state.setOrder"), "scene 演示排序必须一次持久化完整结果")
        XCTAssertTrue(providers.contains("state.accounts"), "设置页账号列表不得用 providerOrder.flatMap 重新聚组")
        XCTAssertFalse(providers.contains("flatMap"), "设置页拖动后不能按服务商重排回去")
        XCTAssertTrue(dashboard.contains("let title = state.store.displayName(for: account)"), "账号卡片标题须走本地化 displayName")
        XCTAssertTrue(dashboard.contains("state.showsAccount(account)"), "附加账号须按停用标志隐藏")
        XCTAssertTrue(dashboard.contains("displayedShareItems"), "分享列表应与首页可见卡片一致")
        XCTAssertTrue(dashboard.contains("catalog:"), "分享预览须带上首页目录，供编辑多选")
        XCTAssertTrue(dashboard.contains("selectedIDs"), "单卡分享只预勾该实例，编辑可再加选")
        XCTAssertTrue(dashboard.contains("shareCard(account:"), "单卡分享须用账号 id 对齐目录，不能只用供应商")
        XCTAssertTrue(
            dashboard.contains("padding(.leading, 10)"),
            "导航栏分享/设置胶囊左侧须补边距，和右边对称"
        )

        let appState = try String(
            contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8
        )
        XCTAssertTrue(appState.contains("AccountVisibility.shouldProbe"),
                      "refresh 循环只应对非停用配置发官网探针")
        XCTAssertTrue(appState.contains("showsAccount"), "首页可见性应咨询停用标志")

        XCTAssertTrue(
            appState.contains("allowWhenDisabled"),
            "refreshAccount 须能区分登录探测与自动刷新"
        )
        XCTAssertTrue(
            appState.contains("guard AccountVisibility.shouldProbe(account, providerEnabled"),
            "refreshAccount 默认路径必须跳过停用账号"
        )
        XCTAssertTrue(appState.contains("open-custom-wizard"), "须支持 --open-custom-wizard")
        XCTAssertTrue(appState.contains("handleOpenURL"), "App 须处理小组件深链")
        XCTAssertTrue(
            appState.contains("revealTarget(accounts: accounts, demoMode: demoMode)"),
            "服务商深链须换算成该服务商主账号卡（新小组件写 usagelimits://open/<provider>，旧链接仍兼容）"
        )
        let enterBackground = try XCTUnwrap(appState.range(of: "func sceneDidEnterBackground()"))
        XCTAssertTrue(
            appState[enterBackground.upperBound...].prefix(200).contains("pendingDeepLink = nil"),
            "退到后台须作废未消费的深链，否则目标卡之后出现会莫名跳过去"
        )
        let app = try String(contentsOf: root.appendingPathComponent("App/UsageLimitsApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("state.sceneDidEnterBackground()"), "退后台的收尾统一走 AppState")

        let wizard = try String(
            contentsOf: root.appendingPathComponent("App/Views/CustomUsageWizardView.swift"), encoding: .utf8
        )
        XCTAssertTrue(wizard.contains(".buttonStyle(.borderedProminent)"), "保存须是主色大按钮，不能是灰字 footer")
        XCTAssertTrue(wizard.contains("custom.wizard.saveHint"), "未勾选字段时须说明为何不能保存")
        XCTAssertFalse(wizard.contains(".toggleStyle(.button)"), "勾选不得再用无选中态的 button Toggle")
        XCTAssertTrue(wizard.contains("checkmark.circle.fill"), "勾选须有明确选中样式")
        XCTAssertTrue(wizard.contains("custom.wizard.displayName"), "须能自定义展示名")
        XCTAssertFalse(wizard.contains("custom.wizard.used"), "不得再强制已用角色 pill")
        XCTAssertFalse(wizard.contains("custom.wizard.balance"), "不得再强制余额角色 pill")
        XCTAssertTrue(wizard.contains("PhotosPicker"), "向导须能选择/替换图标")
        XCTAssertTrue(wizard.contains("resolveTemplateLogo"), "无图标时测试连接才解析 origin favicon")
        XCTAssertTrue(wizard.contains("CustomUsageLogoPolicy.shouldResolveOnTest"), "已有图标则测试不再抓 favicon")
        XCTAssertTrue(wizard.contains("logoIsManual"), "手动替换后须记住，避免以后被覆盖")

        let background = try String(
            contentsOf: root.appendingPathComponent("App/BackgroundRefresh.swift"), encoding: .utf8
        )
        XCTAssertTrue(background.contains("enabledProviders"), "后台探针只遍历未停用服务商")

        let widget = try String(
            contentsOf: root.appendingPathComponent("Widget/UsageLimitsWidget.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            widget.contains("AccountVisibility.shouldShowOnHome")
                || widget.contains("store.isEnabled(account.provider)"),
            "小组件须跳过停用账号，不能只按服务商开关"
        )
        XCTAssertTrue(widget.contains("title: store.displayName(for: $0)"), "账号选择器空名须跟 appLanguage / 模板名")
        XCTAssertFalse(widget.contains("title: $0.displayName"), "选择器不得再用无语言 displayName")
        XCTAssertTrue(
            widget.contains("store.primaryAccount(of: provider).map { store.displayName(for: $0) }"),
            "单账号回退标题须走 store.displayName"
        )
        XCTAssertTrue(
            widget.contains("account.map { store.displayName(for: $0) }"),
            "总览实例标题须走 store.displayName"
        )

        XCTAssertTrue(appState.contains("AccountIdentity.clearFingerprint"), "退出须清指纹才能换绑")
        XCTAssertTrue(appState.contains("!account.isPrimary"), "前台静默刷新须覆盖附加内置账号")
        XCTAssertTrue(appState.contains("scheduleWidgetReload()") || appState.contains("WidgetCenter.shared.reloadAllTimelines()"),
                      "重命名须刷新小组件")

        XCTAssertTrue(background.contains("AccountIdentity.apply"), "后台须做身份绑定")
        XCTAssertTrue(background.contains("accountID: account.id"), "后台须刷附加账号独立 WebKit")
        XCTAssertTrue(background.contains("saveAccountSnapshot"), "附加账号快照不得写进服务商主槽")
        XCTAssertTrue(background.contains("RefreshSweep.order"), "后台须按陈旧度排队，附加不得永远排在主号后面")
        XCTAssertTrue(background.contains("WatchSync.shared.pushState()"), "后台收尾须推手表，否则表端停在上次前台")
        XCTAssertTrue(background.contains("store.snapshot(for: provider)?.fetchedAt == startFetchedAt")
                      || background.contains("store.snapshot(for: provider) != nil"),
                      "后台主号探针返回后须再确认快照")
        XCTAssertTrue(background.contains("store.accountSnapshot(for: accountID)?.fetchedAt == startFetchedAt")
                      || background.contains("store.accountSnapshot(for: accountID) != nil"),
                      "后台附加/自定义探针返回后须再确认快照")
        XCTAssertTrue(appState.contains("store.snapshot(for: provider)?.fetchedAt != startFetchedAt"),
                      "前台主号 await 后须核 fetchedAt，避免盖掉更新快照")
        XCTAssertTrue(appState.contains("store.accountSnapshot(for: account.id)?.fetchedAt != startFetchedAt"),
                      "前台附加/自定义 await 后须核 fetchedAt")
        XCTAssertTrue(appState.contains("adoptAccountSnapshotFromStore"),
                      "fetchedAt CAS 须灌回 store 赢家，不得只返回内存 last-good")
        XCTAssertTrue(appState.contains("adoptPrimarySnapshotFromStore"),
                      "主号 fetchedAt CAS 须灌回 store 赢家")
        XCTAssertTrue(appState.contains("if Task.isCancelled { return snapshots[provider] }"),
                      "前台主号 await 后须认取消")
        XCTAssertTrue(appState.contains("if Task.isCancelled { return accountSnapshots[account.id] }"),
                      "前台附加/自定义 await 后须认取消")

        let watchSync = try String(
            contentsOf: root.appendingPathComponent("App/WatchSync.swift"), encoding: .utf8
        )
        let watchStore = try String(
            contentsOf: root.appendingPathComponent("Watch/WatchStore.swift"), encoding: .utf8
        )
        let watchViews = try String(
            contentsOf: root.appendingPathComponent("Watch/WatchViews.swift"), encoding: .utf8
        )
        XCTAssertTrue(watchSync.contains("WatchExtraPayload"), "手表推送须带附加内置账号")
        XCTAssertTrue(watchStore.contains("extraItems"), "表端须收下附加内置账号")
        XCTAssertTrue(watchViews.contains("extraItems"), "表端翻页须露出附加内置账号")
        XCTAssertTrue(watchViews.contains("WatchPagerPage.extra") || watchViews.contains("case extra"),
                      "附加账号不得和主号抢同一个 ProviderID 页")
        XCTAssertTrue(watchViews.contains("localizedName(lang)"), "表端设置名须本地化，不得写死 vendorName")
        XCTAssertTrue(watchViews.contains("UsagePresentation.barPercent"), "表端圆环须跟展示口径")
        XCTAssertTrue(watchViews.contains("emptyUsageCaption"), "表端错误态须走 emptyUsageCaption，不得一律未登录")
        XCTAssertTrue(watchViews.contains("L10n.metricLabel"), "表端选中环指标名须走 L10n.metricLabel")
        XCTAssertFalse(watchViews.contains("[Showing" + " lines"), "表端不得再被 Read 页脚截断")
        XCTAssertTrue(watchViews.contains("emptyWatchHintKey"), "运输错误不得再提示 watch.loginOnPhone")
        XCTAssertTrue(watchSync.contains("watchProviderOverrides"), "主号账号色须叠进表端 tintOverrides")
        XCTAssertTrue(appState.contains("DiagnosticRedactor.probeLine"), "探针诊断须走可单测的 probeLine")
        if let languageRange = appState.range(of: "@Published var language: AppLanguage") {
            XCTAssertTrue(
                String(appState[languageRange.lowerBound...].prefix(350)).contains("scheduleReminderReload()"),
                "改语言须重排日历提醒"
            )
        } else {
            XCTFail("missing language")
        }
        XCTAssertTrue(
            appState.contains("冷启动 didSet 不会跑"),
            "冷启动须主动重排日历提醒"
        )
        XCTAssertTrue(dashboard.contains("blocksAccountDeepLink"), "设置页打开时不得清掉账号深链")
        XCTAssertTrue(dashboard.contains("showSettings = true"), "齿轮须走 showSettings，才能挡住深链")
        XCTAssertTrue(background.contains("if Task.isCancelled { return false }"), "后台自定义 await 后须认取消")

        let diagnostics = try String(
            contentsOf: root.appendingPathComponent("App/Views/DiagnosticsView.swift"), encoding: .utf8
        )
        XCTAssertTrue(diagnostics.contains("L10n.tr(\"diagnostics.empty\""), "诊断空态须本地化")
        XCTAssertTrue(diagnostics.contains("L10n.tr(\"settings.diagLog\""), "诊断标题须走已有键")
        XCTAssertFalse(diagnostics.contains("\"暂无诊断记录\""), "诊断页不得写死中文")
        XCTAssertFalse(diagnostics.contains("\"诊断日志\""), "诊断标题不得写死中文")

        XCTAssertTrue(appState.contains("scheduleReminderReload()"), "附加账号停用/退出/删除须重排日历提醒")
        if let logoutRange = appState.range(of: "func logoutAccount") {
            XCTAssertTrue(String(appState[logoutRange.lowerBound...].prefix(900)).contains("scheduleReminderReload()"),
                          "logoutAccount 须撤该账号日历")
        } else {
            XCTFail("missing logoutAccount")
        }
        if let removeRange = appState.range(of: "func removeAccount") {
            XCTAssertTrue(String(appState[removeRange.lowerBound...].prefix(2000)).contains("scheduleReminderReload()"),
                          "removeAccount 须撤已删账号日历")
        } else {
            XCTFail("missing removeAccount")
        }
        if let enableRange = appState.range(of: "func setAccountEnabled") {
            XCTAssertTrue(String(appState[enableRange.lowerBound...].prefix(700)).contains("scheduleReminderReload()"),
                          "附加账号停用须重排日历")
        } else {
            XCTFail("missing setAccountEnabled")
        }

        let notificationManager = try String(
            contentsOf: root.appendingPathComponent("App/NotificationManager.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            notificationManager.contains("removeAllPendingNotificationRequests"),
            "重排须先清全部 pending，否则已删附加账号的日历会漏"
        )
        XCTAssertTrue(notificationManager.contains("NotificationDecider.extraCalendarIDs"))

        if let tintRange = appState.range(of: "func setAccountTint") {
            let body = String(appState[tintRange.lowerBound...].prefix(800))
            XCTAssertTrue(body.contains("WidgetCenter.shared.reloadAllTimelines()"), "改色须刷新小组件")
            XCTAssertTrue(body.contains("WatchSync.shared.pushState()"), "改色须刷新手表")
        } else {
            XCTFail("missing setAccountTint")
        }
        if let logoRange = appState.range(of: "func setCustomLogo") {
            XCTAssertTrue(String(appState[logoRange.lowerBound...].prefix(1400)).contains("WidgetCenter.shared.reloadAllTimelines()"),
                          "换 logo 须刷新小组件")
        } else {
            XCTFail("missing setCustomLogo")
        }
        if let replaceRange = appState.range(of: "func replaceCustomTemplate") {
            let body = String(appState[replaceRange.lowerBound...].prefix(900))
            XCTAssertTrue(body.contains("WidgetCenter.shared.reloadAllTimelines()"), "改模板须立刻刷新小组件")
            XCTAssertTrue(body.contains("WatchSync.shared.pushState()"), "改模板须立刻刷新手表")
            XCTAssertTrue(body.contains("bumpAccountRefreshGeneration"), "改模板须推进在飞世代")
        } else {
            XCTFail("missing replaceCustomTemplate")
        }
        if let reloadRange = appState.range(of: "func reloadFromStore") {
            XCTAssertTrue(
                String(appState[reloadRange.lowerBound...].prefix(900)).contains("accounts = store.accounts"),
                "reloadFromStore 须灌回后台写过的账号表，否则指纹会被陈旧副本冲掉"
            )
        } else {
            XCTFail("missing reloadFromStore")
        }
        XCTAssertTrue(appState.contains("var latest = store.accounts"), "身份绑定以 store.accounts 为源")
        XCTAssertTrue(appState.contains("accounts: &latest"), "只 patch store 再回写目标指纹，禁止整表用内存副本覆盖")
        XCTAssertTrue(appState.contains("persistAccounts"), "改名/拖动/改色须合并 store 指纹再写回")
        XCTAssertTrue(appState.contains("preservingStoredFingerprints"))
        XCTAssertTrue(appState.contains("case .matched:"), "matched 也要把后台指纹灌回内存")
        XCTAssertTrue(appState.contains("shouldAbortInFlightRefresh"), "探针返回后须核对账号仍在且未登出")
        XCTAssertTrue(appState.contains("InFlightRefresh.shouldAbort"), "在飞刷新须走可单测的世代/指纹/账号闸门")
        XCTAssertTrue(appState.contains("bumpAccountRefreshGeneration"), "logout/remove/停用须推进附加账号刷新世代")
        XCTAssertTrue(appState.contains("bumpPrimaryRefreshGeneration"), "主号 logout/停用须推进主号刷新世代")
        if let logoutRange = appState.range(of: "func logout(_ provider: ProviderID)") {
            let body = String(appState[logoutRange.lowerBound...].prefix(700))
            let snap = body.range(of: "store.removeSnapshot(for: provider)")
            let web = body.range(of: "await fetcher.clearWebsiteData(for: provider)")
            XCTAssertNotNil(snap, "logout 须先清主号快照")
            XCTAssertNotNil(web, "logout 仍须清 WebKit")
            if let snap, let web {
                XCTAssertLessThan(snap.lowerBound, web.lowerBound, "logout 必须先清快照再 await WebKit，避免后台 CAS 投递")
            }
        } else {
            XCTFail("missing logout(_ provider)")
        }
        if let jimengExtra = appState.range(of: "await appendJimengDiagnostics(results: results, accountID: account.id)") {
            XCTAssertTrue(
                String(appState[jimengExtra.upperBound...].prefix(800)).contains("shouldAbortInFlightRefresh"),
                "即梦附加刷新在诊断 await 之后须再核对在飞闸门才能落盘"
            )
        } else {
            XCTFail("missing extra jimeng diagnostics await")
        }
        if let jimengPrimary = appState.range(of: "await appendJimengDiagnostics(results: results, accountID: nil)") {
            XCTAssertTrue(
                String(appState[jimengPrimary.upperBound...].prefix(800)).contains("shouldAbortInFlightPrimaryRefresh"),
                "即梦主号刷新在诊断 await 之后须再核对在飞闸门才能落盘"
            )
        } else {
            XCTFail("missing primary jimeng diagnostics await")
        }
        if let customRange = appState.range(of: "func refreshCustomAccount") {
            let body = String(appState[customRange.lowerBound...].prefix(4500))
            XCTAssertTrue(body.contains("shouldAbortInFlightRefresh"), "自定义刷新须走在飞闸门")
            if let missing = body.range(of: "custom.error.unreadable") {
                let around = String(body[..<missing.lowerBound].suffix(500))
                XCTAssertTrue(around.contains("shouldAbortInFlightRefresh"), "缺模板路径须先 abort")
                XCTAssertTrue(around.contains("store.accounts.contains"), "缺模板路径须确认账号仍在")
            } else {
                XCTFail("missing custom.error.unreadable path")
            }
            if let snap = body.range(of: "accountSnapshots[account.id] = committed"),
               let deliver = body.range(of: "await NotificationManager.shared.deliver") {
                XCTAssertLessThan(
                    snap.lowerBound,
                    deliver.lowerBound,
                    "自定义内存回写须在 deliver await 之前，避免删除后复活"
                )
            } else {
                XCTFail("custom refresh missing snapshot write or deliver")
            }
        } else {
            XCTFail("missing refreshCustomAccount")
        }
    }

    func testLegacyAccountJSONDefaultsToEnabled() throws {
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","provider":"claude",\
        "name":"老账号","createdAt":"2026-08-18T12:00:00Z","isPrimary":true}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let accounts = try decoder.decode([ProviderAccount].self, from: Data(json.utf8))
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts[0].isEnabled, "存量账号缺 isEnabled 键时应视为启用")
    }

    func testDisabledAccountStaysInStoreAndSkipsHomeAndProbe() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var primary = ProviderAccount(provider: .claude, name: "主号", createdAt: now, isPrimary: true)
        var extra = ProviderAccount(provider: .claude, name: "小号", createdAt: now)
        store.accounts = [primary, extra]
        store.setEnabled(true, for: .claude)

        XCTAssertTrue(AccountVisibility.shouldProbe(primary, providerEnabled: true))
        XCTAssertTrue(AccountVisibility.shouldShowOnHome(extra, providerEnabled: true))

        extra.isEnabled = false
        store.accounts = [primary, extra]
        XCTAssertEqual(store.accounts.count, 2, "停用不得删除配置")
        XCTAssertFalse(store.accounts[1].isEnabled)
        XCTAssertTrue(AccountVisibility.shouldProbe(primary, providerEnabled: true))
        XCTAssertFalse(AccountVisibility.shouldShowOnHome(extra, providerEnabled: true))
        XCTAssertFalse(AccountVisibility.shouldProbe(extra, providerEnabled: true))

        primary.isEnabled = false
        store.accounts = [primary, extra]
        store.setEnabled(false, for: .claude)
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertNil(store.displaySnapshot(for: .claude))
        XCTAssertFalse(AccountVisibility.shouldShowOnHome(primary, providerEnabled: false))
        XCTAssertFalse(AccountVisibility.shouldProbe(extra, providerEnabled: false),
                       "主配置停用后附加账号不得再探针")
    }

    func testDisableEnableL10nKeys() {
        XCTAssertEqual(L10n.tr("account.disable", .zh), "停用")
        XCTAssertEqual(L10n.tr("account.enable", .zh), "启用")
        XCTAssertEqual(L10n.tr("account.disabled", .zh), "已停用")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            for key in ["account.disable", "account.enable", "account.disabled"] {
                XCTAssertNotEqual(L10n.tr(key, lang), key)
            }
        }
    }
}

import XCTest
@testable import UsageLimitsCore

final class CustomUsageStoreTests: XCTestCase {
    private func freshStore() -> (store: SharedStore, cleanup: () -> Void) {
        let suite = "test.custom.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SharedStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func template(
        name: String = "中转",
        url: String = "https://api.example.com/v1/usage?token=secret",
        fields: [CustomUsageField] = [
            CustomUsageField(path: "data.used", displayName: "已用"),
            CustomUsageField(path: "data.remain", displayName: "余额"),
        ]
    ) -> CustomUsageTemplate {
        CustomUsageTemplate(name: name, requestURL: url, fields: fields)!
    }

    func testAccountSourceStableJSON() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let builtinJSON = """
        {"kind":"builtin","provider":"claude"}
        """
        let builtin = try decoder.decode(AccountSource.self, from: Data(builtinJSON.utf8))
        XCTAssertEqual(builtin, .builtin(.claude))

        let templateID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let customJSON = """
        {"kind":"custom","templateID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}
        """
        let custom = try decoder.decode(AccountSource.self, from: Data(customJSON.utf8))
        XCTAssertEqual(custom, .custom(templateID: templateID))

        let encodedBuiltin = try encoder.encode(AccountSource.builtin(.grok))
        let object = try JSONSerialization.jsonObject(with: encodedBuiltin) as? [String: String]
        XCTAssertEqual(object?["kind"], "builtin")
        XCTAssertEqual(object?["provider"], "grok")
        XCTAssertNil(object?["templateID"])
    }

    func testLegacyAccountJSONStillDecodesAsBuiltin() throws {
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","provider":"claude",\
        "name":"老账号","createdAt":"2026-08-18T12:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let accounts = try decoder.decode([ProviderAccount].self, from: Data(json.utf8))
        XCTAssertEqual(accounts[0].source, .builtin(.claude))
        XCTAssertFalse(accounts[0].isPrimary)
        XCTAssertFalse(accounts[0].isCustom)
    }

    func testAccountJSONWithSourceRoundTrips() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let builtinJSON = """
        {"id":"11111111-2222-3333-4444-555555555555","source":{"kind":"builtin","provider":"cursor"},\
        "provider":"cursor","name":"主号","createdAt":"2026-08-18T12:00:00Z","isPrimary":true}
        """
        let builtin = try decoder.decode(ProviderAccount.self, from: Data(builtinJSON.utf8))
        XCTAssertEqual(builtin.source, .builtin(.cursor))
        XCTAssertTrue(builtin.isPrimary)
        XCTAssertEqual(builtin.provider, .cursor)

        let templateID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let customJSON = """
        {"id":"22222222-3333-4444-5555-666666666666","source":{"kind":"custom",\
        "templateID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},\
        "name":"中转A","createdAt":"2026-08-18T12:00:00Z"}
        """
        let custom = try decoder.decode(ProviderAccount.self, from: Data(customJSON.utf8))
        XCTAssertEqual(custom.source, .custom(templateID: templateID))
        XCTAssertFalse(custom.isPrimary)
        XCTAssertNil(custom.provider)

        let encoded = try encoder.encode(custom)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(object?["provider"], "自定义 encode 不得写 provider")
        XCTAssertNotNil(object?["source"])
    }

    func testCustomAccountForcesIsPrimaryFalse() {
        let templateID = UUID()
        let account = ProviderAccount(
            source: .custom(templateID: templateID),
            name: "x",
            isPrimary: true
        )
        XCTAssertFalse(account.isPrimary)
        XCTAssertTrue(account.isCustom)
    }

    func testCustomDisplayNameFallsBackToTemplateNotClaude() {
        let templateID = UUID()
        let tmpl = CustomUsageTemplate(
            id: templateID,
            name: "我的中转",
            requestURL: "https://api.example.com/v1/usage",
            fields: [CustomUsageField(path: "used", displayName: "已用")]
        )!
        let account = ProviderAccount(source: .custom(templateID: templateID), name: "   ")
        XCTAssertEqual(account.displayName, "")
        XCTAssertNotEqual(account.displayName, ProviderID.claude.displayName)
        XCTAssertEqual(account.displayName(templates: [tmpl]), "我的中转")
    }

    func testSaveRejectsCustomSnapshotAndKeepsProviderKeys() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let builtin = ProviderSnapshot(
            provider: .claude, planName: "Max", fetchedAt: Date(), status: .ok
        )
        store.save(builtin)
        let custom = ProviderSnapshot(
            provider: .claude,
            planName: "should-not-write",
            metrics: [UsageMetric(id: "used", label: "已用", amount: 1, pinned: true)],
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        store.save(custom)
        XCTAssertEqual(store.snapshot(for: .claude)?.planName, "Max")
        XCTAssertTrue(store.diagnostics().contains { $0.contains("refused") })
        for provider in ProviderID.allCases where provider != .claude {
            XCTAssertNil(store.snapshot(for: provider))
        }
    }

    func testCustomSnapshotsOnlyUseAccountKeys() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let templateID = UUID()
        let first = ProviderAccount(source: .custom(templateID: templateID), name: "A")
        let second = ProviderAccount(source: .custom(templateID: templateID), name: "B")
        store.accounts = [first, second]
        let snapA = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 12.5, pinned: true)],
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        var snapB = snapA
        snapB.metrics = [UsageMetric(id: "used", label: "已用", amount: 99, pinned: true)]
        store.saveAccountSnapshot(snapA, accountID: first.id)
        store.saveAccountSnapshot(snapB, accountID: second.id)
        XCTAssertEqual(store.accountSnapshot(for: first.id)?.metrics.first?.amount, 12.5)
        XCTAssertEqual(store.accountSnapshot(for: second.id)?.metrics.first?.amount, 99)
        for provider in ProviderID.allCases {
            XCTAssertNil(store.snapshot(for: provider), "不得写入 snapshot.\(provider.rawValue)")
        }
    }

    func testTemplateJSONHasNoTokenAndStripsQuery() throws {
        let tmpl = template()
        XCTAssertFalse(tmpl.requestURL.contains("?"))
        XCTAssertFalse(tmpl.requestURL.contains("token"))
        XCTAssertEqual(tmpl.requestURL, "https://api.example.com/v1/usage")
        XCTAssertNil(CustomUsageTemplate.sanitizedURLString("http://api.example.com/v1/usage"))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tmpl)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["token"])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("secret"))
        XCTAssertEqual(Set((object ?? [:]).keys), [
            "id", "name", "requestURL", "fields", "createdAt",
        ])
        XCTAssertNil(object?["usedPath"])
        XCTAssertNil(object?["balancePath"])
        let encodedFields = object?["fields"] as? [[String: String]]
        XCTAssertEqual(encodedFields?.map { $0["path"] }, ["data.used", "data.remain"])
        XCTAssertEqual(encodedFields?.map { $0["displayName"] }, ["已用", "余额"])
    }

    func testLegacyUsedBalanceJSONDecodesToFields() throws {
        let json = """
        {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"旧模板",\
        "requestURL":"https://api.example.com/v1/usage","usedPath":"used",\
        "balancePath":"remain","usedLabel":"已用","balanceLabel":"余额",\
        "createdAt":"2026-08-18T12:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tmpl = try decoder.decode(CustomUsageTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(tmpl.fields.map(\.path), ["used", "remain"])
        XCTAssertEqual(tmpl.fields.map(\.displayName), ["已用", "余额"])
    }

    func testTemplateRequiresAtLeastOneField() {
        XCTAssertNil(CustomUsageTemplate(
            name: "x", requestURL: "https://api.example.com/v1/usage", fields: []
        ))
        XCTAssertNotNil(CustomUsageTemplate(
            name: "x",
            requestURL: "https://api.example.com/v1/usage",
            fields: [CustomUsageField(path: "used", displayName: "已用")]
        ))
        XCTAssertNotNil(CustomUsageTemplate(
            name: "x",
            requestURL: "https://api.example.com/v1/usage",
            fields: [CustomUsageField(path: "remain", displayName: "余额")]
        ))
    }

    func testTokenStoredSeparatelyAndClearedWithAccount() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let account = ProviderAccount(source: .custom(templateID: UUID()), name: "A")
        store.accounts = [account]
        store.setAccountToken("sk-live-secret", for: account.id)
        XCTAssertEqual(store.accountToken(for: account.id), "sk-live-secret")
        store.saveAccountSnapshot(
            ProviderSnapshot(provider: .claude, fetchedAt: Date(), status: .ok, isCustom: true),
            accountID: account.id
        )
        store.removeCustomAccountData(accountID: account.id)
        XCTAssertNil(store.accountToken(for: account.id))
        XCTAssertNil(store.accountSnapshot(for: account.id))
    }

    func testTemplateTintAndLogoRoundTrip() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        var tmpl = template()
        tmpl.tint = BrandTint(startHex: "#112233")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 8))
        tmpl.logoRelativePath = store.writeCustomLogo(data: png, for: tmpl.id, fileExtension: "png")
        tmpl.logoIsManual = true
        store.customTemplates = [tmpl]
        let loaded = store.customTemplate(id: tmpl.id)
        XCTAssertEqual(loaded?.tint?.startHex, "#112233")
        XCTAssertTrue(loaded?.logoIsManual == true)
        XCTAssertEqual(store.customLogoData(for: loaded!), png)
        XCTAssertTrue(CustomFaviconParser.looksLikeImage(store.customLogoData(for: tmpl)!))
        XCTAssertEqual(
            TintResolver.resolve(accountTint: nil, templateTint: tmpl.tint).startHex,
            "#112233"
        )
        XCTAssertEqual(
            TintResolver.resolve(accountTint: BrandTint(startHex: "#AA0000"), templateTint: tmpl.tint).startHex,
            "#AA0000"
        )
    }

    func testDeleteTemplateRemovesLogoAndBlockedKeepsFile() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        var tmpl = template()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 1, count: 8))
        tmpl.logoRelativePath = store.writeCustomLogo(data: png, for: tmpl.id, fileExtension: "png")
        store.customTemplates = [tmpl]
        store.accounts = [ProviderAccount(source: .custom(templateID: tmpl.id), name: "A")]
        XCTAssertFalse(store.removeCustomTemplate(id: tmpl.id))
        XCTAssertEqual(store.customLogoData(for: tmpl), png)
        store.accounts = []
        XCTAssertTrue(store.removeCustomTemplate(id: tmpl.id))
        XCTAssertNil(store.customLogoData(relativePath: tmpl.logoRelativePath))
        XCTAssertTrue(store.customTemplates.isEmpty)
    }

    func testDeleteTemplateBlockedWhenReferenced() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let tmpl = template()
        store.customTemplates = [tmpl]
        store.accounts = [ProviderAccount(source: .custom(templateID: tmpl.id), name: "A")]
        XCTAssertFalse(store.removeCustomTemplate(id: tmpl.id))
        XCTAssertEqual(store.customTemplates.count, 1)
        store.accounts = []
        XCTAssertTrue(store.removeCustomTemplate(id: tmpl.id))
        XCTAssertTrue(store.customTemplates.isEmpty)
    }

    func testCustomVisibilityIgnoresProviderSwitch() {
        let account = ProviderAccount(source: .custom(templateID: UUID()), name: "A")
        XCTAssertTrue(AccountVisibility.shouldShowOnHome(account, providerEnabled: false))
        XCTAssertTrue(AccountVisibility.shouldProbe(account, providerEnabled: false))
        var disabled = account
        disabled.isEnabled = false
        XCTAssertFalse(AccountVisibility.shouldShowOnHome(disabled, providerEnabled: true))
    }

    func testAccountsOfAndPrimaryIgnoreCustom() {
        let (store, cleanup) = freshStore()
        defer { cleanup() }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let primary = ProviderAccount(provider: .claude, name: "主", createdAt: now, isPrimary: true)
        let custom = ProviderAccount(source: .custom(templateID: UUID()), name: "中转", createdAt: now)
        store.accounts = [primary, custom]
        XCTAssertEqual(store.accounts(of: .claude).map(\.id), [primary.id])
        XCTAssertEqual(store.primaryAccount(of: .claude)?.id, primary.id)
        XCTAssertEqual(store.accounts.count, 2)
    }

    func testIsPrepaidCardFalseForCustomPlaceholder() {
        let snap = ProviderSnapshot(
            provider: .deepseek,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 1, pinned: true)],
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        XCTAssertFalse(snap.isPrepaidCard)
        XCTAssertTrue(ProviderSnapshot(
            provider: .deepseek, fetchedAt: Date(), status: .ok
        ).isPrepaidCard)
    }

    func testWidgetAndWatchSourcesDoNotReferenceTokenKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let banned = ["custom.accountTokens", "accountTokens"]
        for folder in ["Widget", "Watch"] {
            let directory = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, "\(folder) 应有 Swift 源文件")
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for needle in banned {
                    XCTAssertFalse(
                        source.contains(needle),
                        "\(file.lastPathComponent) 不得出现 \(needle)"
                    )
                }
            }
        }
    }

    func testOverviewMarksCustomExtraAccountID() {
        let custom = ProviderAccount(source: .custom(templateID: UUID()), name: "中转")
        let items = WidgetAccountItems.overview(
            pickedIDs: [],
            accounts: [custom],
            providerOrder: [.claude],
            preview: false,
            isProviderEnabled: { _ in false }
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isCustom)
        XCTAssertEqual(items[0].extraAccountID, custom.id)
    }

    func testCustomTintResolverDoesNotUseGrokProvider() {
        let tint = TintResolver.resolve(accountTint: nil)
        XCTAssertEqual(tint, TintResolver.customDefault)
        XCTAssertEqual(tint.startHex, "#616B80")
        let custom = BrandTint(startHex: "#112233")
        XCTAssertEqual(TintResolver.resolve(accountTint: custom), custom)
    }

    func testAppDeepLinkParsesCustomAccountURL() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let url = AppDeepLink.accountURL(id)
        XCTAssertEqual(url.absoluteString, "usagelimits://open/account/\(id.uuidString)")
        XCTAssertEqual(AppDeepLink.parse(url), .account(id))
        XCTAssertEqual(AppDeepLink.parse(URL(string: "aiusage://open")!), .home)
    }

    func testWatchCustomPayloadHasNoTokenAndDropsOldest() {
        let items = (0..<80).map { i in
            WatchCustomItem(
                id: UUID(),
                title: "账号\(i)",
                tint: TintResolver.customDefault,
                metrics: [
                    WatchCustomMetric(id: "used", label: "已用", amount: Double(i)),
                    WatchCustomMetric(id: "balance", label: "余额", amount: 10),
                ]
            )
        }
        let encoder = JSONEncoder()
        let packed = WatchCustomPayload.encode(items, encoder: encoder)
        XCTAssertGreaterThan(packed.droppedOldest, 0)
        XCTAssertLessThanOrEqual(packed.data.count, WatchCustomPayload.maxEncodedBytes)
        let decoded = WatchCustomPayload.decode(packed.data, decoder: JSONDecoder())
        XCTAssertFalse(decoded.isEmpty)
        let json = String(data: packed.data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("Authorization"))
        XCTAssertFalse(json.contains("accountTokens"))
    }

    func testWatchCustomItemsHiddenInDemoAndCapMetrics() {
        let account = ProviderAccount(source: .custom(templateID: UUID()), name: "中转")
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "已用", amount: 1, pinned: true),
                UsageMetric(id: "balance", label: "余额", amount: 2, pinned: true),
                UsageMetric(id: "extra", label: "多", amount: 3, pinned: true),
            ],
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        let hidden = WatchCustomPayload.items(
            accounts: [account], templates: [], snapshot: { _ in snap }, demoMode: true
        )
        XCTAssertTrue(hidden.isEmpty)
        let shown = WatchCustomPayload.items(
            accounts: [account], templates: [], snapshot: { _ in snap }, demoMode: false
        )
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].metrics.count, 3)
        XCTAssertEqual(shown[0].title, "中转")
    }

    func testWatchCustomPayloadPreservesRolesAndSharedPresentationInputs() {
        let account = ProviderAccount(source: .custom(templateID: UUID()), name: "中转")
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(
                    id: "ratio", label: "占比", amount: 42, pinned: true,
                    displayValue: "42%", kind: CustomFieldRole.percent.rawValue
                ),
                UsageMetric(
                    id: "expiry", label: "到期", resetsAt: reset,
                    amount: reset.timeIntervalSince1970, pinned: true,
                    displayValue: "1800000000", kind: CustomFieldRole.timestamp.rawValue
                ),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        let item = WatchCustomPayload.items(
            accounts: [account], templates: [], snapshot: { _ in snap }, demoMode: false
        )[0]

        XCTAssertEqual(item.metrics.map(\.kind), ["percent", "timestamp"])
        XCTAssertEqual(item.metrics.map(\.displayValue), ["42%", "1800000000"])
        XCTAssertEqual(item.metrics[1].resetsAt, reset)
        XCTAssertEqual(
            CustomUsageDisplay.valueText(for: item.metrics[0].usageMetric, mode: .remaining),
            "58%"
        )
        XCTAssertNil(item.metrics[0].usageMetric.usedPercent)
    }

    func testWatchCustomItemsCapAtEightMetrics() {
        let account = ProviderAccount(source: .custom(templateID: UUID()), name: "中转")
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: (0..<10).map {
                UsageMetric(id: "f\($0)", label: "F\($0)", amount: Double($0), pinned: true)
            },
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        let shown = WatchCustomPayload.items(
            accounts: [account], templates: [], snapshot: { _ in snap }, demoMode: false
        )
        XCTAssertEqual(shown[0].metrics.count, WatchCustomPayload.maxMetricsPerItem)
    }

    func testWatchCustomItemsCarrySnapshotStatus() {
        let account = ProviderAccount(source: .custom(templateID: UUID()), name: "中转")
        let failed = ProviderSnapshot(
            provider: .claude,
            fetchedAt: Date(),
            status: .error("custom.error.unreadable"),
            isCustom: true
        )
        let login = ProviderSnapshot(
            provider: .claude,
            fetchedAt: Date(),
            status: .needsLogin,
            isCustom: true
        )
        XCTAssertEqual(
            WatchCustomPayload.items(
                accounts: [account], templates: [], snapshot: { _ in failed }, demoMode: false
            )[0].status,
            .error("custom.error.unreadable")
        )
        XCTAssertEqual(
            WatchCustomPayload.items(
                accounts: [account], templates: [], snapshot: { _ in login }, demoMode: false
            )[0].status,
            .needsLogin
        )
        let leftover = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 80, pinned: true)],
            fetchedAt: Date(),
            status: .error("custom.error.unreadable"),
            isCustom: true
        )
        let leftoverItem = WatchCustomPayload.items(
            accounts: [account], templates: [], snapshot: { _ in leftover }, demoMode: false
        )[0]
        XCTAssertEqual(leftoverItem.status, .error("custom.error.unreadable"))
        XCTAssertTrue(leftoverItem.metrics.isEmpty, "失败快照不得把 leftover 数字下发到表")
        XCTAssertTrue(leftoverItem.visibleMetrics.isEmpty)

        let unfetched = WatchCustomPayload.items(
            accounts: [account], templates: [], snapshot: { _ in nil }, demoMode: false
        )[0]
        XCTAssertEqual(unfetched.status, .needsLogin)
        XCTAssertTrue(unfetched.metrics.isEmpty)

        let legacy = #"[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","title":"旧","metrics":[{"id":"balance","label":"余额","amount":9}]}]"#
        let decoded = WatchCustomPayload.decode(Data(legacy.utf8), decoder: JSONDecoder())
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].status)
        XCTAssertEqual(decoded[0].metrics.count, 1)
        XCTAssertEqual(decoded[0].visibleMetrics.count, 1, "旧包无 status 仍展示数字")

        let failedLegacy = WatchCustomItem(
            id: UUID(), title: "旧失败",
            metrics: [WatchCustomMetric(id: "balance", label: "余额", amount: 9)],
            status: .needsLogin
        )
        XCTAssertTrue(failedLegacy.visibleMetrics.isEmpty)
    }

    func testWatchExtraPayloadIncludesEnabledBuiltinExtras() {
        let primary = ProviderAccount(provider: .claude, name: "主号", isPrimary: true)
        var extra = ProviderAccount(provider: .claude, name: "工作号")
        var disabled = ProviderAccount(provider: .claude, name: "停用号")
        disabled.isEnabled = false
        let custom = ProviderAccount(source: .custom(templateID: UUID()), name: "中转")
        let extraSnap = ProviderSnapshot(
            provider: .claude,
            planName: "Claude Pro",
            metrics: [
                UsageMetric(id: "five_hour", label: "Current session", usedPercent: 12, pinned: true),
                UsageMetric(id: "history", label: "流水", amount: 1),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
            status: .ok,
            creditHistory: [
                CreditLedgerEntry(
                    id: "h1",
                    title: "x",
                    amount: 1,
                    historyType: 1,
                    createdAt: Date(timeIntervalSince1970: 1_760_000_000)
                )
            ]
        )
        let hidden = WatchExtraPayload.items(
            accounts: [primary, extra, disabled, custom],
            snapshot: { id in id == extra.id ? extraSnap : nil },
            demoMode: true
        )
        XCTAssertTrue(hidden.isEmpty, "演示模式不推附加账号")
        extra.tint = BrandTint(startHex: "#AABBCC")
        let openaiExtra = ProviderAccount(provider: .openai, name: "GPT号")
        let shown = WatchExtraPayload.items(
            accounts: [primary, extra, disabled, custom, openaiExtra],
            snapshot: { id in id == extra.id ? extraSnap : nil },
            demoMode: false,
            providerEnabled: { $0 == .claude },
            tintOverrides: [:]
        )
        XCTAssertEqual(shown.map(\.id), [extra.id], "已关服务商的附加账号不得进手表")
        XCTAssertEqual(shown[0].title, "工作号")
        XCTAssertEqual(shown[0].provider, .claude)
        XCTAssertEqual(shown[0].snapshot.planName, "Claude Pro")
        XCTAssertEqual(shown[0].snapshot.metrics.map(\.id), ["five_hour", "history"])
        XCTAssertEqual(shown[0].tint?.startHex, "#AABBCC")
        XCTAssertNil(shown[0].snapshot.creditHistory, "手表附加账号不得带流水")
        let packed = WatchExtraPayload.encode(shown, encoder: JSONEncoder())
        XCTAssertFalse(String(data: packed.data, encoding: .utf8)?.contains("token") == true)
        let decoded = WatchExtraPayload.decode(packed.data, decoder: JSONDecoder())
        XCTAssertEqual(decoded.map(\.id), [extra.id])
        XCTAssertEqual(decoded.first?.tint?.startHex, "#AABBCC")
    }

    func testOverviewMetersIncludeCustomAmountsWithoutPercent() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "已用", amount: 12.5, pinned: true),
                UsageMetric(id: "balance", label: "余额", amount: 87.5, pinned: true),
            ],
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        let collapsed = WidgetAccountItems.overviewMeters(from: snap)
        XCTAssertEqual(collapsed.map(\.id), ["used", "balance"], "总览每家最多 2 条，跟展开顺序一致")
        XCTAssertNil(collapsed[0].usedPercent)
        XCTAssertEqual(collapsed[0].amount, 12.5)
        let expanded = WidgetAccountItems.overviewMeters(from: snap)
        XCTAssertEqual(expanded.map(\.id), ["used", "balance"])
    }

    func testOverviewMetersExpandedKeepsZeroPercentWindows() {
        // ChatGPT 三条限额里两条 0%：展开态必须全画，折叠态仍只画周额度
        let snap = ProviderSnapshot(
            provider: .openai,
            metrics: [
                UsageMetric(id: "primary", label: "5h", usedPercent: 0),
                UsageMetric(id: "secondary", label: "7d", usedPercent: 100),
                UsageMetric(id: "codex", label: "Codex", usedPercent: 0),
            ],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(
            WidgetAccountItems.overviewMeters(from: snap).map(\.id),
            ["secondary"],
            "0% 未钉住不进 activeMetrics；总览最多 2 条且不再改走 weeklySummary"
        )
        XCTAssertEqual(WidgetAccountItems.overviewMeters(from: snap).map(\.id), ["secondary"])
    }

    func testOverviewRowsCustomCollapsedUsesHeroGauge() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
                UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
                UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        let rows = WidgetAccountItems.overviewRows(from: snap)
        XCTAssertEqual(rows.map(\.metric.id), ["credits", "requests_plan"])
        XCTAssertNil(rows[0].displayedPercent, "hero 不在前 2 条时不附 gauge")
        XCTAssertNil(rows[0].metric.usedPercent, "不得把展示百分比写回 metric")
        let reordered = ProviderSnapshot(
            provider: .claude,
            metrics: MetricOrdering.apply(snap.metrics, order: ["usable_requests", "credits", "requests_plan"]),
            fetchedAt: snap.fetchedAt,
            status: .ok,
            isCustom: true
        )
        let gauged = WidgetAccountItems.overviewRows(from: reordered)
        XCTAssertEqual(gauged.map(\.metric.id), ["usable_requests", "credits"])
        XCTAssertEqual(gauged[0].displayedPercent ?? -1, 75, accuracy: 0.001)
    }

}

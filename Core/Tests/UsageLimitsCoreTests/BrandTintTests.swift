import XCTest
@testable import UsageLimitsCore

final class BrandTintTests: XCTestCase {
    private func makeStore() -> (SharedStore, () -> Void) {
        let suite = "tint-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let cleanup = { defaults.removePersistentDomain(forName: suite) }
        return (SharedStore(defaults: defaults), cleanup)
    }

    // MARK: hex 解析

    func testHexParseAndNormalize() {
        XCTAssertEqual(BrandTint.rgb(fromHex: "#FF6633"), .init(red: 255, green: 102, blue: 51))
        XCTAssertEqual(BrandTint.rgb(fromHex: "ff6633"), .init(red: 255, green: 102, blue: 51))
        XCTAssertEqual(BrandTint.normalized(hex: " ff6633 "), "#FF6633")
        XCTAssertNil(BrandTint.rgb(fromHex: "#FFF"), "只接受 6 位")
        XCTAssertNil(BrandTint.rgb(fromHex: "#GGGGGG"))
        XCTAssertNil(BrandTint.rgb(fromHex: ""))
        XCTAssertEqual(BrandTint.hexString(.init(red: 226, green: 22, blue: 128)), "#E21680")
    }

    func testRGBClampsToByteRange() {
        let rgb = BrandTint.RGB(red: 300, green: -5, blue: 128)
        XCTAssertEqual(rgb, .init(red: 255, green: 0, blue: 128))
    }

    func testIsGradient() {
        XCTAssertFalse(BrandTint(startHex: "#FF6633").isGradient)
        XCTAssertFalse(BrandTint(startHex: "#FF6633", endHex: "#ff6633").isGradient, "首尾同色视为纯色")
        XCTAssertTrue(BrandTint(startHex: "#E21680", endHex: "#FF633A").isGradient)
    }

    // MARK: 三层回落

    func testTintResolverFallbackChain() {
        let accountTint = BrandTint(startHex: "#112233")
        let providerTint = BrandTint(startHex: "#445566")
        let overrides = ["grok": providerTint]

        XCTAssertEqual(
            TintResolver.resolve(accountTint: accountTint, provider: .grok, overrides: overrides),
            accountTint, "账号自定义优先"
        )
        XCTAssertEqual(
            TintResolver.resolve(accountTint: nil, provider: .grok, overrides: overrides),
            providerTint, "无账号色回落供应商默认"
        )
        XCTAssertEqual(
            TintResolver.resolve(accountTint: nil, provider: .grok, overrides: [:]),
            ProviderID.grok.builtinTint, "都没有回落内置品牌色"
        )
    }

    func testBuiltinTintMiniMaxIsGradient() {
        XCTAssertTrue(ProviderID.minimax.builtinTint.isGradient, "MiniMax 内置即官网渐变")
        for provider in ProviderID.allCases where provider != .minimax {
            XCTAssertFalse(provider.builtinTint.isGradient)
        }
    }

    /// 2026 现行官方色：Claude Clay / ChatGPT Green / Cursor Orange /
    /// DeepSeek 鲸蓝 / 智谱 Z.ai 紫 / Kimi 新 VI 电光蓝。Grok 无彩色品牌色，
    /// 用石板灰；MiniMax 保持官网粉→珊瑚。
    func testBuiltinTintsMatchOfficialBrandColors() {
        XCTAssertEqual(ProviderID.claude.builtinTint, BrandTint(startHex: "#D97757"))
        XCTAssertEqual(ProviderID.openai.builtinTint, BrandTint(startHex: "#10A37F"))
        XCTAssertEqual(ProviderID.grok.builtinTint, BrandTint(startHex: "#616B80"))
        XCTAssertEqual(ProviderID.cursor.builtinTint, BrandTint(startHex: "#F54E00"))
        XCTAssertEqual(ProviderID.deepseek.builtinTint, BrandTint(startHex: "#4D6BFE"))
        XCTAssertEqual(ProviderID.zhipu.builtinTint, BrandTint(startHex: "#6C63FF"))
        XCTAssertEqual(ProviderID.kimi.builtinTint, BrandTint(startHex: "#007CFF"))
        XCTAssertEqual(
            ProviderID.minimax.builtinTint,
            BrandTint(startHex: "#E21680", endHex: "#FF633A")
        )
        XCTAssertEqual(ProviderID.jimeng.builtinTint, BrandTint(startHex: "#7C3AED"))
        XCTAssertEqual(ProviderID.opencode.builtinTint, BrandTint(startHex: "#5A5858"))
        XCTAssertEqual(
            Set(ProviderID.allCases.map(\.rawValue)).count, ProviderID.allCases.count,
            "每个 ProviderID 都要有内置色，漏加会让上表静默过期"
        )
        XCTAssertEqual(ProviderID.allCases.count, 25)
        XCTAssertTrue(ProviderID.allCases.contains(.jimeng), "即梦是官方第 9 家")
        XCTAssertTrue(ProviderID.allCases.contains(.opencode), "OpenCode 是官方第 10 家")
    }

    // MARK: 账号字段兼容

    func testAccountWithoutTintKeyDecodes() throws {
        let legacy = #"""
        [{"id":"6E4A0B47-0000-0000-0000-000000000000","provider":"grok",
          "name":"老账号","createdAt":700000000}]
        """#
        let accounts = try JSONDecoder().decode([ProviderAccount].self, from: Data(legacy.utf8))
        XCTAssertNil(accounts[0].tint, "老 JSON 无 tint 键应解码为 nil")
    }

    func testAccountTintRoundTrips() throws {
        var account = ProviderAccount(provider: .cursor, name: "C1", isPrimary: true)
        account.tint = BrandTint(startHex: "#7361B8", endHex: "#FF633A")
        let data = try JSONEncoder().encode([account])
        let decoded = try JSONDecoder().decode([ProviderAccount].self, from: data)
        XCTAssertEqual(decoded[0].tint, account.tint)
    }

    // MARK: 存储与一键重置

    func testProviderTintOverridesRoundTripAndResolve() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let tint = BrandTint(startHex: "#123456")
        store.providerTintOverrides = ["cursor": tint]
        XCTAssertEqual(store.providerTintOverrides["cursor"], tint)
        XCTAssertEqual(store.resolvedTint(provider: .cursor), tint)
        XCTAssertEqual(store.resolvedTint(provider: .grok), ProviderID.grok.builtinTint)
    }

    func testResolvedTintPrefersAccountOverProvider() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        var account = ProviderAccount(provider: .cursor, name: "C1", isPrimary: true)
        account.tint = BrandTint(startHex: "#AA0000")
        store.accounts = [account]
        store.providerTintOverrides = ["cursor": BrandTint(startHex: "#00BB00")]
        XCTAssertEqual(
            store.resolvedTint(provider: .cursor, accountID: account.id).startHex, "#AA0000"
        )
    }

    func testResetAllCustomTintsClearsAccountsAndProviders() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        var a1 = ProviderAccount(provider: .grok, name: "X1", isPrimary: true)
        a1.tint = BrandTint(startHex: "#111111")
        var a2 = ProviderAccount(provider: .grok, name: "X2")
        a2.tint = BrandTint(startHex: "#222222", endHex: "#333333")
        store.accounts = [a1, a2]
        store.providerTintOverrides = ["grok": BrandTint(startHex: "#444444")]

        store.resetAllCustomTints()

        XCTAssertTrue(store.accounts.allSatisfy { $0.tint == nil }, "所有账号色清空")
        XCTAssertTrue(store.providerTintOverrides.isEmpty, "供应商默认覆盖一并清空")
        XCTAssertEqual(
            store.resolvedTint(provider: .grok), ProviderID.grok.builtinTint,
            "重置后回落内置品牌色"
        )
    }

    // MARK: 分享链路

    func testShareModelSectionsResolveTintAndRender() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snap = SharedStore.demoSnapshots(now: now).first { $0.provider == .grok }!
        var options = ShareComposeOptions()
        options.sameColorBars = true
        let gradient = BrandTint(startHex: "#E21680", endHex: "#FF633A")
        let result = ShareImageComposer.compose(
            snapshots: [snap, snap],
            titles: ["自定义", "默认"],
            tints: [gradient, nil],
            expanded: true,
            language: .zh,
            options: options
        )
        XCTAssertEqual(result.model.sections[0].resolvedTint, gradient)
        XCTAssertEqual(
            result.model.sections[1].resolvedTint, ProviderID.grok.builtinTint,
            "未传 tint 回落内置品牌色"
        )
        XCTAssertTrue(result.model.sections.contains { $0.meters.contains { $0.usedPercent != nil } })
        XCTAssertEqual(result.canvasWidth, ShareLayout.canvasWidth, "渐变同色条不改画布尺寸")
    }

    func testWatchProviderOverridesPreferPrimaryAccountTint() {
        var primary = ProviderAccount(provider: .cursor, name: "主号", isPrimary: true)
        primary.tint = BrandTint(startHex: "#AA0000")
        var extra = ProviderAccount(provider: .cursor, name: "小号")
        extra.tint = BrandTint(startHex: "#00AA00")
        let merged = TintResolver.watchProviderOverrides(
            providerOverrides: ["cursor": BrandTint(startHex: "#0000AA")],
            accounts: [primary, extra]
        )
        XCTAssertEqual(merged["cursor"]?.startHex, "#AA0000", "主号账号色覆盖供应商色")
        XCTAssertEqual(
            TintResolver.resolve(accountTint: extra.tint, provider: .cursor, overrides: ["cursor": BrandTint(startHex: "#0000AA")]).startHex,
            "#00AA00",
            "附加账号仍走自己的 tint，不吃主号覆盖表"
        )
    }

}

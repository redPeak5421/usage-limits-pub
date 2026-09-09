import XCTest
@testable import UsageLimitsCore

/// PlanCatalog 标价表与 UsageMetric「未使用」判定。
final class CatalogTests: XCTestCase {
    func testListPriceForKnownPlans() {
        XCTAssertEqual(PlanCatalog.listPrice(planName: "SuperGrok Heavy"), "$300")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Max 5x"), "$100")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Max 20x"), "$200")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "ChatGPT Plus"), "$20")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "ChatGPT Pro 5x"), "$100")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "ChatGPT Pro"), "$200")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "SuperGrok"), "$30")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Cursor Pro"), "$20")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Cursor Ultra"), "$200")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Coding Plan Pro"), "¥538")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Kimi Code Allegretto"), "¥159")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Token Plan Max"), "¥119")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Token Plan Max 年"), "¥1,190")
        XCTAssertNil(PlanCatalog.listPrice(planName: "DeepSeek"))
    }

    func testListPriceMatchesBillingCycle() {
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Token Plan Max", billingCycle: .monthly), "¥119")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Token Plan Max", billingCycle: .yearly), "¥1,190")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Kimi Code Allegretto", billingCycle: .monthly), "¥159")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Kimi Code Allegretto", billingCycle: .yearly), "¥1,908")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Coding Plan Pro", billingCycle: .yearly), "¥4,519")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Coding Plan Pro", billingCycle: .yearly, productID: "product-733034"), "¥2,400")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Coding Plan Pro", billingCycle: .monthly, productID: "product-92f659"), "¥538")
        XCTAssertEqual(PlanCatalog.zhipuSKU("product-733034")?.cycle, .yearly)
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Pro", billingCycle: .yearly), "$200")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "ChatGPT Plus", billingCycle: .yearly), "$200")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Max 5x", billingCycle: .yearly), "$1200")
        XCTAssertEqual(BillingCycle.monthly.tag, "月")
        XCTAssertEqual(BillingCycle.yearly.tag, "年")
    }

    func testMiniMaxListPriceIsScopedToDomesticProvider() {
        XCTAssertEqual(
            PlanCatalog.listPrice(
                planName: "Token Plan Max",
                billingCycle: .monthly,
                provider: .minimax
            ),
            "¥119"
        )
        XCTAssertEqual(
            PlanCatalog.listPrice(
                planName: "Token Plan Max",
                billingCycle: .yearly,
                provider: .minimax
            ),
            "¥1,190"
        )
        XCTAssertNil(
            PlanCatalog.listPrice(
                planName: "Token Plan Max",
                billingCycle: .monthly,
                provider: .minimaxGlobal
            )
        )
        XCTAssertNil(
            PlanCatalog.listPrice(
                planName: "Token Plan Max",
                billingCycle: .yearly,
                provider: .minimaxGlobal
            )
        )
        // 国际站任何同名静态价格都必须禁用，避免未来套餐名碰撞时显示错误币种。
        XCTAssertNil(PlanCatalog.listPrice(planName: "Claude Pro", provider: .minimaxGlobal))
        XCTAssertFalse(PlanCatalog.hasListPrice("Token Plan Max", provider: .minimaxGlobal))
    }

    func testMiniMaxDomesticAndGlobalCookieDomainsAreExactAndDisjoint() {
        XCTAssertEqual(ProviderID.minimax.cookieDomains, ["minimaxi.com"])
        XCTAssertEqual(ProviderID.minimaxGlobal.cookieDomains, ["minimax.io"])
        XCTAssertTrue(
            Set(ProviderID.minimax.cookieDomains)
                .isDisjoint(with: Set(ProviderID.minimaxGlobal.cookieDomains)),
            "退出登录与 Cookie 同步必须只处理当前 MiniMax 站点"
        )
    }

    func testListPriceProviderContextKeepsLegacyCallSourceCompatible() {
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Token Plan Plus"), "¥49")
        XCTAssertTrue(PlanCatalog.hasListPrice("Token Plan Plus"))
    }

    func testProviderCardPassesProviderContextToPlanCatalog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"),
            encoding: .utf8
        )

        func planPriceRow(in text: String) throws -> String {
            let start = try XCTUnwrap(text.range(of: "private func planPriceRow"))
            let end = try XCTUnwrap(
                text.range(of: "\n    private func capsule", range: start.upperBound..<text.endIndex)
            )
            return String(text[start.lowerBound..<end.lowerBound])
        }

        func normalizingWhitespace(_ text: String) -> String {
            text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        }

        let expectedCall = #"PlanCatalog.listPrice(planName:plan,billingCycle:cycle,appStoreBilling:snapshot?.billingSource=="app_store",productID:snapshot?.planProductID,provider:provider)"#
        XCTAssertTrue(
            normalizingWhitespace(try planPriceRow(in: source)).contains(expectedCall),
            "planPriceRow 的价格查询必须携带卡片 ProviderID"
        )

        // 证明旧的全文件 contains 断言会被 ProviderLogo(provider: provider) 假阳性命中。
        let regressed = source.replacingOccurrences(
            of: ",\n            provider: provider\n        )",
            with: "\n        )"
        )
        XCTAssertTrue(regressed.contains("provider: provider"), "旧断言应仍被无关调用命中")
        XCTAssertFalse(
            normalizingWhitespace(try planPriceRow(in: regressed)).contains(expectedCall),
            "精确契约必须能捕获 listPrice 丢失 provider 参数"
        )
    }

    func testMiniMaxPercentPairMatchesOfficialFormat() {
        XCTAssertEqual(MiniMaxParser.percentPair(used: 0, total: 100), "0%/100%")
        XCTAssertEqual(MiniMaxParser.percentPair(used: 12.4, total: 100), "12%/100%")
        XCTAssertEqual(MiniMaxParser.percentPair(used: nil, total: nil), "0%/100%")
    }

    func testEveryProviderHasALogoAssetOnDisk() {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UsageLimitsCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // repo
            .appendingPathComponent("SharedUI/Assets.xcassets")
        for provider in ProviderID.allCases {
            let imageset = catalog.appendingPathComponent("\(provider.logoAssetName).imageset/logo.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: imageset.path),
                          "缺少商标 \(provider.logoAssetName)")
        }
        XCTAssertEqual(Set(ProviderID.allCases.map(\.logoAssetName)).count, ProviderID.allCases.count)
        for name in ["LogoWeChat", "LogoMoments"] {
            let path = catalog.appendingPathComponent("\(name).imageset/logo.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "缺少 \(name)")
        }
    }

    func testOfficialBrandMarksUseProvidedColorAssets() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedUI/Assets.xcassets")
        let marks: [(String, String, Int)] = [
            ("LogoPoe", "https://poe.com/favicon.ico", 8_000),
            ("LogoOpenRouter", "https://openrouter.ai/favicon.ico", 8_000),
            ("LogoCrof", "https://files.nahcrof.com/file/crofaicolor.png", 15_000),
            ("LogoQoder", "https://qoder.com/favIcon.svg", 15_000),
            ("LogoLongCat", "https://s3plus.meituan.net/aigc-media-resources/longcat/yeqian-logo.svg", 12_000),
            ("LogoAbacus", "https://abacus.ai/static/h23c4bfa0/icon2/favicon-192.png", 12_000),
            ("LogoT3Chat", "https://t3.chat/favicon.ico", 8_000),
            ("LogoGemini", "https://www.gstatic.com/lamda/images/gemini_sparkle_aurora_33f86dc0c0257da337c63.svg", 20_000),
            ("LogoAntigravity", "https://antigravity.google/apple-touch-icon-precomposed.png", 12_000),
            ("LogoKiro", "https://kiro.dev/icon.svg?fe599162bb293ea0", 12_000),
        ]
        for (name, source, minBytes) in marks {
            let dir = catalog.appendingPathComponent("\(name).imageset")
            let json = try String(contentsOf: dir.appendingPathComponent("Contents.json"), encoding: .utf8)
            XCTAssertTrue(json.contains("\"template-rendering-intent\" : \"original\""), "\(name) 彩色商标不得做成 template")
            XCTAssertTrue(json.contains(source), "\(name) 须锁官方源 \(source)")
            let png = try Data(contentsOf: dir.appendingPathComponent("logo.png"))
            XCTAssertGreaterThan(png.count, minBytes, "\(name) 仍像占位图")
            XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }

    func testVendorNameIsCompanyHomeKeepsProductName() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.claude.vendorName, "Anthropic")
        XCTAssertEqual(ProviderID.openai.displayName, "ChatGPT")
        XCTAssertEqual(ProviderID.openai.vendorName, "OpenAI")
        XCTAssertNotEqual(ProviderID.claude.displayName, ProviderID.claude.vendorName)
        XCTAssertNotEqual(ProviderID.openai.displayName, ProviderID.openai.vendorName)
    }

    func testKimiLoginUsesCodeHomeNotConsole() {
        XCTAssertEqual(ProviderID.kimi.loginURL.absoluteString, "https://www.kimi.com/code")
    }

    func testGrokLoginStartsFromWebClient() {
        XCTAssertEqual(ProviderID.grok.loginURL.absoluteString, "https://grok.com/")
        XCTAssertEqual(ProviderID.grok.probeURL.absoluteString, "https://grok.com/")
        XCTAssertTrue(ProviderID.grok.cookieDomains.contains("x.ai"))
        XCTAssertTrue(ProviderID.grok.cookieDomains.contains("grok.com"))
    }

    func testJimengIsOfficialNinthBuiltin() {
        XCTAssertEqual(ProviderID.jimeng.displayName, "即梦")
        XCTAssertEqual(ProviderID.jimeng.vendorName, "剪映 / 字节")
        XCTAssertEqual(ProviderID.jimeng.origin.host, "jimeng.jianying.com")
        XCTAssertEqual(ProviderID.jimeng.loginURL.absoluteString, "https://jimeng.jianying.com/ai-tool/home")
        XCTAssertEqual(ProviderID.jimeng.probeURL.absoluteString, "https://jimeng.jianying.com/ai-tool/home")
        XCTAssertFalse(ProviderID.jimeng.loginURL.absoluteString.hasSuffix("jimeng.jianying.com/"), "根路径是营销页，不能当登录入口")
        XCTAssertFalse(ProviderID.jimeng.probeURL.absoluteString.contains("generate"), "探针页是产品首页 /ai-tool/home，不是 /generate")
        XCTAssertFalse(ProviderID.jimeng.probeURL.absoluteString.contains("MS4wLj"), "探针页禁止写死 sec_uid")
        XCTAssertNil(PlanCatalog.listPrice(planName: "即梦"))
        XCTAssertEqual(ProviderID.allCases.count, 25)
        XCTAssertEqual(ProviderID.minimaxGlobal.rawValue, "minimax_global")
        XCTAssertEqual(ProviderID.longcat.displayName, "LongCat")
        XCTAssertEqual(ProviderID.stepfun.origin.host, "platform.stepfun.com")
        XCTAssertEqual(ProviderID.copilot.displayName, "Copilot")
        XCTAssertEqual(ProviderID.copilot.vendorName, "GitHub")
        XCTAssertEqual(ProviderID.copilot.loginURL.absoluteString, "https://github.com/login")
        XCTAssertEqual(ProviderID.copilot.probeURL.absoluteString, "https://github.com/settings/copilot")
        XCTAssertEqual(ProviderID.gemini.loginURL.absoluteString, "https://gemini.google.com/usage")
        XCTAssertEqual(ProviderID.gemini.probeURL.absoluteString, "https://gemini.google.com/usage")
        XCTAssertEqual(ProviderID.antigravity.origin.host, "antigravity.google")
        XCTAssertEqual(ProviderID.kiro.loginURL.absoluteString, "https://app.kiro.dev/")
        XCTAssertEqual(ProviderID.kiro.logoAssetName, "LogoKiro")
        XCTAssertEqual(ProviderID.copilot.logoAssetName, "LogoCopilot")
        XCTAssertEqual(ProviderID.gemini.logoAssetName, "LogoGemini")
        XCTAssertEqual(ProviderID.antigravity.logoAssetName, "LogoAntigravity")
    }

    func testProbeResultFailureStatusAndOptionalHeaders() {
        XCTAssertTrue(ProbeResult(status: 401, body: "").isUnauthorized)
        XCTAssertTrue(ProbeResult(status: 403, body: "").isUnauthorized)
        XCTAssertFalse(ProbeResult(status: 500, body: "").isUnauthorized)
        XCTAssertEqual(ProbeResult(status: 401, body: "").failureStatus, .needsLogin)
        XCTAssertEqual(ProbeResult(status: 403, body: "").failureStatus, .needsLogin)
        if case .error(let message) = ProbeResult(status: 500, body: "").failureStatus {
            XCTAssertEqual(message, "HTTP 500")
        } else {
            XCTFail("5xx must be HTTP error, not needsLogin")
        }
        if case .error(let message) = ProbeResult(status: -3, body: "").failureStatus {
            XCTAssertEqual(message, "请求超时")
        } else {
            XCTFail("timeout must stay an error")
        }
        let withHeaders = ProbeResult(
            status: 429, body: "", headers: ["x-vercel-mitigated": "challenge"]
        )
        XCTAssertEqual(withHeaders.headers?["x-vercel-mitigated"], "challenge")
    }

    func testOpenCodeIsOfficialTenthBuiltin() {
        XCTAssertEqual(ProviderID.opencode.displayName, "OpenCode")
        XCTAssertEqual(ProviderID.opencode.vendorName, "OpenCode")
        for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
            XCTAssertEqual(ProviderID.opencode.localizedVendor(lang), "OpenCode")
        }
        XCTAssertEqual(ProviderID.opencode.origin.host, "opencode.ai")
        XCTAssertEqual(ProviderID.opencode.loginURL.absoluteString, "https://opencode.ai/auth")
        XCTAssertEqual(ProviderID.opencode.probeURL.absoluteString, "https://opencode.ai/auth")
        XCTAssertEqual(ProviderID.opencode.cookieDomains, ["opencode.ai"])
        XCTAssertEqual(PlanCatalog.listPrice(planName: "OpenCode Go"), "$10")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "OpenCode Go", billingCycle: .yearly), "$120")
        XCTAssertNil(PlanCatalog.listPrice(planName: "OpenCode Black"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "OpenCode Zen"))
    }

    func testListPriceUnknownOrFreeReturnsNil() {
        XCTAssertNil(PlanCatalog.listPrice(planName: nil))
        XCTAssertNil(PlanCatalog.listPrice(planName: "Claude Free"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "游客额度"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "ChatGPT"))
        XCTAssertNil(PlanCatalog.listPrice(planName: "Cursor Free"))
    }

    /// iOS 内购价与官网价区分（2026-08-16 需求）：Max 20x 内购 $249.99 vs 官网 $200。
    func testListPriceAppStoreBilling() {
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Max 20x", appStoreBilling: true), "$249.99")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Max 5x", appStoreBilling: true), "$124.99")
        XCTAssertEqual(PlanCatalog.listPrice(planName: "Claude Max 20x", appStoreBilling: false), "$200")
        // 未收录内购价的档位回落官网价
        XCTAssertEqual(PlanCatalog.listPrice(planName: "ChatGPT Plus", appStoreBilling: true), "$20")
    }

    func testL10nTablesAndFallback() {
        XCTAssertEqual(L10n.tr("card.retry", .zh), "重试")
        XCTAssertEqual(L10n.tr("card.retry", .en), "Retry")
        XCTAssertEqual(L10n.tr("card.retry", .fr), "Réessayer")
        XCTAssertEqual(L10n.tr("card.retry", .ja), "再試行")
        XCTAssertEqual(L10n.tr("card.retry", .ru), "Повторить")
        XCTAssertEqual(SnapshotStatus.error("请求超时").displayText(.zh), "请求超时")
        XCTAssertEqual(SnapshotStatus.error("请求超时").displayText(.en), "Request timed out")
        XCTAssertEqual(SnapshotStatus.error("网络错误").displayText(.en), "Network error")
        XCTAssertEqual(SnapshotStatus.error("用量数据异常").displayText(.en), "Usage data is invalid")
        XCTAssertNotEqual(SnapshotStatus.error("请求超时").displayText(.en), "请求超时")
        for key in ["diagnostics.empty", "diagnostics.emptyHint", "diagnostics.copy", "diagnostics.copied", "diagnostics.clear", "diagnostics.shareSubject"] {
            for lang in [AppLanguage.zh, .en, .ja, .fr, .ru] {
                XCTAssertNotEqual(L10n.tr(key, lang), key, "\(key) 缺 \(lang) 文案")
            }
        }
        // 未知 key 原样返回，带参格式化正常
        XCTAssertEqual(L10n.tr("no.such.key", .en), "no.such.key")
        XCTAssertEqual(L10n.tr("card.expandMore", .en, 3), "Expand to see 3 more metrics")
        XCTAssertEqual(L10n.tr("jimeng.historyTitle", .zh), "近1个月明细")
        XCTAssertEqual(L10n.tr("jimeng.historyCaption", .zh), "仅展示近1个月，更新可能有延迟")
        XCTAssertEqual(L10n.tr("jimeng.creditsUnavailable", .zh), "积分暂未获取到")
        XCTAssertEqual(L10n.tr("jimeng.creditsUnavailableHint", .zh), "系统繁忙，下拉重试")
    }

    func testSpecializedCardsKeepJimengHistoryInFiveRowScroll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let card = try String(
            contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"), encoding: .utf8
        )

        func slice(_ source: String, from startToken: String, to endToken: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: startToken))
            let end = try XCTUnwrap(source.range(of: endToken, range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.lowerBound])
        }

        XCTAssertEqual(
            card.components(separatedBy: "usesExternalVerticalScroll: isExpanded").count - 1,
            1,
            "only DeepSeek delegates its vertical list to the expanded card; Jimeng keeps an internal history viewport"
        )

        let deepSeek = try slice(card, from: "struct DeepSeekCardBody", to: "struct JimengCardBody")
        let keyList = try slice(deepSeek, from: "private func keyList", to: "private func keyRow")
        let keyExternal = try slice(keyList, from: "if usesExternalVerticalScroll", to: "} else {")
        let keyFallback = try slice(keyList, from: "} else {", to: "\n        }\n    }")
        XCTAssertTrue(keyExternal.contains("LazyVStack"))
        XCTAssertFalse(keyExternal.contains("ScrollView"), "DeepSeek external branch must flatten its vertical list")
        XCTAssertTrue(keyFallback.contains("ScrollView"))
        XCTAssertTrue(keyFallback.contains(".frame(height: height)"))
        XCTAssertTrue(keyFallback.contains(".scrollDisabled"))

        let periodPicker = try slice(
            deepSeek,
            from: "private var periodPicker",
            to: "private func periodNumbers"
        )
        XCTAssertTrue(periodPicker.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertFalse(
            periodPicker.contains("usesExternalVerticalScroll"),
            "the horizontal period picker must remain independent of vertical-scroll ownership"
        )

        let jimeng = try slice(card, from: "struct JimengCardBody", to: "struct UsageSparkline")
        let historyList = try slice(jimeng, from: "private var historyList", to: "private func historyRow")
        XCTAssertFalse(jimeng.contains("usesExternalVerticalScroll"), "展开时也不能平铺全部积分记录")
        XCTAssertTrue(jimeng.contains("historyVisibleSlots = 5"))
        XCTAssertTrue(historyList.contains("min(history.count, Self.historyVisibleSlots)"))
        XCTAssertTrue(historyList.contains("ScrollView"))
        XCTAssertTrue(historyList.contains("ForEach(history)"), "超出的记录保留在内部滚动区，不应被 prefix 截断")
        XCTAssertTrue(historyList.contains(".frame(height: height)"))
        XCTAssertTrue(historyList.contains(".environment(\\.isScrollEnabled, history.count > Self.historyVisibleSlots)"),
                      "短卡禁用父滚动时，积分滚动仍须独立启用")
        XCTAssertTrue(historyList.contains("dashboardSceneControlRegion"), "积分区域拖动不得被轮盘/螺旋场景抢走")
        XCTAssertTrue(jimeng.contains("jimeng.creditsUnavailable"))
        XCTAssertTrue(jimeng.contains("remainingUnavailable"))
    }

    func testRelativeTimeLocalized() {
        let now = Date(timeIntervalSince1970: 1_766_000_000)
        let inOneHour = now.addingTimeInterval(3600)
        XCTAssertEqual(TimeFormat.relative(inOneHour, now: now, language: .zh), "1 小时后")
        XCTAssertEqual(TimeFormat.relative(inOneHour, now: now, language: .en), "in 1h")
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(-1), now: now, language: .en), "Reset")
    }

    func testRefreshStampSameDayVersusCrossDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 9, minute: 5))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 8, minute: 30))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 22, minute: 21))!
        // 当天只给 HH:mm；跨天必须带月日，否则昨晚的 22:21 会被当成刚刷新
        XCTAssertEqual(TimeFormat.refreshStamp(sameDay, now: now, calendar: cal).count, 5)
        XCTAssertTrue(TimeFormat.refreshStamp(yesterday, now: now, calendar: cal).hasPrefix("08-26 "))
    }


    func testMetricHasUsage() {
        XCTAssertTrue(UsageMetric(id: "weekly", label: "本周限额", usedPercent: 3).hasUsage)
        XCTAssertTrue(UsageMetric(id: "auto", label: "自动", remaining: 148, total: 150).hasUsage)
        // 0% / 未动额度 / 无任何数值 → 未使用
        XCTAssertFalse(UsageMetric(id: "fast", label: "快速", usedPercent: 0).hasUsage)
        XCTAssertFalse(UsageMetric(id: "expert", label: "专家", remaining: 2, total: 2).hasUsage)
        XCTAssertFalse(UsageMetric(id: "x", label: "空", resetsAt: Date()).hasUsage)
        XCTAssertTrue(UsageMetric(id: "spent", label: "累计消费金额", amount: 95.65, currency: "CNY").hasUsage)
        XCTAssertFalse(UsageMetric(id: "balance", label: "重置余额", amount: 0, currency: "CNY").hasUsage)
    }

    func testActiveMetricsAndPrimaryMetricSkipUnused() {
        let snap = ProviderSnapshot(
            provider: .grok,
            planName: "SuperGrok Heavy",
            metrics: [
                UsageMetric(id: "a", label: "未用", usedPercent: 0),
                UsageMetric(id: "b", label: "已用", usedPercent: 42),
                UsageMetric(id: "c", label: "空", resetsAt: Date()),
            ],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(snap.activeMetrics.map(\.id), ["b"])
        XCTAssertEqual(snap.primaryMetric?.id, "b")
    }

    func testPrimaryMetricFallsBackWhenAllUnused() {
        let snap = ProviderSnapshot(
            provider: .grok,
            metrics: [UsageMetric(id: "a", label: "未用", usedPercent: 0)],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(snap.primaryMetric?.id, "a")
    }

    /// 折叠卡片摘要：取重置时间最远（窗口最长）的指标，并列时取列表中靠前的一条。
    func testLongestWindowMetricPrefersFarthestReset() {
        let now = Date()
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "five_hour", label: "Current session", usedPercent: 34,
                            resetsAt: now.addingTimeInterval(2 * 3600)),
                UsageMetric(id: "seven_day", label: "All models", usedPercent: 61,
                            resetsAt: now.addingTimeInterval(3 * 86400)),
                UsageMetric(id: "weekly_scoped", label: "Fable", usedPercent: 44,
                            resetsAt: now.addingTimeInterval(3 * 86400)),
            ],
            fetchedAt: now,
            status: .ok
        )
        XCTAssertEqual(snap.longestWindowMetric?.id, "seven_day")
    }

    /// 没有任何带重置时间的百分比指标时，回退主指标（如 Grok 游客额度）。
    func testLongestWindowMetricFallsBackToPrimary() {
        let snap = ProviderSnapshot(
            provider: .grok,
            metrics: [UsageMetric(id: "b", label: "已用", usedPercent: 42)],
            fetchedAt: Date(),
            status: .ok
        )
        XCTAssertEqual(snap.longestWindowMetric?.id, "b")
    }
}

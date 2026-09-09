import XCTest
@testable import UsageLimitsCore

/// 字符串表契约：任何一条文案漏填某种语言都会静默回落英语，用户看到的是半英半中的界面。
/// 这里把「六种语言必须齐、繁体必须真的是繁体、占位符不许漂移」钉成回归。
final class LocalizationTests: XCTestCase {
    /// 系统里未本地化的快捷指令名，各语言步骤都原样保留简体写法。
    private static let untranslatedShortcutName = "侧边菜单"

    /// 本 App 文案域内实际出现过的简体专有字形。繁体值里出现任意一个都说明没转换干净。
    /// 「里」不在其中：阿里巴巴等专名的正体就是「里」。
    private static let simplifiedOnly = Set(
        """
        专两为乐书买义仅从会传体侧储关内册减凭击则删别动务单发变叠号后启周响团国图圆场处复实审对将层带并应\
        开异张弹当录彻态总战扫报拟拦择换据携数断无时显晕暂机权条来标档梦检浅测浏渐满点状独环现盘码确积称竖\
        类级纯线组细终经结络统继续维编网节荐获装观视览触计订认记许设访证识诊试话该语误请读调谱败账购费赖赠\
        跃转轮载辑边达过还这进连迟适选邮针钟钥钮铺锁错键长闭问间阅阈队阶际随隐页顶项顺须预频题颜额风馈验余
        """.filter { !$0.isWhitespace }
    )

    func testEveryKeyCoversAllConcreteLanguages() {
        let expected = Set(AppLanguage.concrete)
        XCTAssertEqual(expected.count, 6)
        XCTAssertFalse(L10n.table.isEmpty)
        for (key, translations) in L10n.table {
            XCTAssertEqual(Set(translations.keys), expected, "\(key) 语言不齐")
            for (lang, value) in translations {
                XCTAssertFalse(value.isEmpty, "\(key) 的 \(lang) 文案为空")
            }
        }
    }

    func testTraditionalChineseKeepsFormatSpecifiers() {
        for (key, translations) in L10n.table {
            guard let zh = translations[.zh], let hant = translations[.zhHant] else {
                return XCTFail("\(key) 缺中文文案")
            }
            XCTAssertEqual(
                Self.formatSpecifiers(zh).sorted(),
                Self.formatSpecifiers(hant).sorted(),
                "\(key) 繁体占位符与简体不一致"
            )
        }
    }

    func testTraditionalChineseHasNoSimplifiedOnlyCharacters() {
        for (key, translations) in L10n.table {
            guard let hant = translations[.zhHant] else { return XCTFail("\(key) 缺繁体") }
            let scanned = hant.replacingOccurrences(of: Self.untranslatedShortcutName, with: "")
            let leaked = scanned.filter { Self.simplifiedOnly.contains($0) }
            XCTAssertTrue(leaked.isEmpty, "\(key) 繁体里残留简体字形：\(String(leaked))")
        }
    }

    /// 防的是「把简体整表复制到繁体槽位」这种假补齐：中文文案绝大多数字形应当真的换过。
    func testTraditionalCopyActuallyDiffersFromSimplified() {
        var containsHan = 0
        var differs = 0
        for translations in L10n.table.values {
            guard let zh = translations[.zh], let hant = translations[.zhHant] else { continue }
            guard zh.contains(where: { ("\u{4E00}"..."\u{9FFF}").contains($0) }) else { continue }
            containsHan += 1
            if zh != hant { differs += 1 }
        }
        XCTAssertGreaterThan(containsHan, 300)
        XCTAssertGreaterThan(Double(differs) / Double(containsHan), 0.7, "繁体与简体差异过少，疑似未真正转换")
    }

    /// 快捷指令在系统里显示的名字未本地化，繁体步骤必须原样保留，否则用户在「捷徑」里找不到。
    func testSideKeyGuideKeepsUntranslatedShortcutName() {
        let steps = L10n.tr("settings.sideKey.guideSteps", .zhHant)
        XCTAssertTrue(steps.contains(Self.untranslatedShortcutName), "繁体步骤丢了快捷指令原名")
        XCTAssertTrue(steps.contains("捷徑"), "繁体步骤应使用台港澳的「捷徑」说法")
    }

    func testSystemLanguageMatching() {
        let cases: [(String, AppLanguage?)] = [
            ("zh-Hant-TW", .zhHant), ("zh-Hant-HK", .zhHant), ("zh-Hant", .zhHant),
            ("zh-TW", .zhHant), ("zh-HK", .zhHant), ("zh-MO", .zhHant), ("zh_TW", .zhHant),
            ("zh-Hans-CN", .zh), ("zh-Hans", .zh), ("zh-CN", .zh), ("zh-SG", .zh), ("zh", .zh),
            ("en-US", .en), ("en", .en), ("ja-JP", .ja), ("fr-CA", .fr), ("ru-RU", .ru),
            ("ko-KR", nil), ("de-DE", nil), ("", nil),
        ]
        for (tag, expected) in cases {
            XCTAssertEqual(AppLanguage.match(tag), expected, "系统语言 \(tag) 匹配错误")
        }
        XCTAssertNil(AppLanguage.match(nil))
    }

    /// rawValue 会写进 UserDefaults 并经 WatchConnectivity 传给手表，改了就丢用户设置。
    func testLanguageRawValuesAreStable() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["system", "zh", "zh-Hant", "en", "ja", "fr", "ru"])
        XCTAssertEqual(AppLanguage(rawValue: "zh-Hant"), .zhHant)
        XCTAssertEqual(AppLanguage.concrete.first, .zh)
        XCTAssertFalse(AppLanguage.concrete.contains(.system))
    }

    func testLanguageDisplayNamesAreDistinct() {
        let names = AppLanguage.concrete.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "语言选项展示名重复：\(names)")
        XCTAssertEqual(AppLanguage.zhHant.displayName, "繁體中文")
        XCTAssertEqual(AppLanguage.zh.displayName, "简体中文")
    }

    func testResolvedIsIdentityForConcreteLanguages() {
        for lang in AppLanguage.concrete {
            XCTAssertEqual(lang.resolved, lang)
        }
    }

    /// 抽查几条：繁体走的是繁体表，不是回落英语或简体。
    func testTraditionalLookupsHitTheTraditionalTable() {
        XCTAssertEqual(L10n.tr("settings.title", .zhHant), "設定")
        XCTAssertEqual(L10n.tr("account.login", .zhHant), "登入")
        XCTAssertEqual(L10n.tr("card.refresh", .zhHant), "重新整理用量")
        XCTAssertEqual(L10n.tr("settings.widgetPreview", .zhHant), "小工具")
        XCTAssertEqual(L10n.tr("widget.accountType", .zhHant), "帳號")
        XCTAssertEqual(L10n.tr("metric.weeklyService", .zhHant, "Grok"), "Grok（週）")
        XCTAssertEqual(L10n.tr("dashboard.position", .zhHant, 2, 7), "2 / 7")
    }

    /// 解析器给的是简体源文案，繁体界面要能查到对应繁体标签。
    func testMetricLabelTranslatesSimplifiedFallbacks() {
        XCTAssertEqual(
            L10n.metricLabel(provider: .claude, id: "unknown", fallback: "剩余请求", language: .zhHant),
            "剩餘請求"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .claude, id: "unknown", fallback: "订阅积分（积分）", language: .zhHant),
            "訂閱點數（點數）"
        )
        XCTAssertEqual(
            L10n.metricLabel(provider: .claude, id: "unknown", fallback: "本周用量（周）", language: .zhHant),
            "本週用量（週）"
        )
    }

    private static func formatSpecifiers(_ value: String) -> [String] {
        var out: [String] = []
        var rest = Substring(value)
        while let start = rest.firstIndex(of: "%") {
            var i = rest.index(after: start)
            while i < rest.endIndex, "0123456789$.".contains(rest[i]) {
                i = rest.index(after: i)
            }
            guard i < rest.endIndex else { break }
            out.append(String(rest[start...i]))
            rest = rest[rest.index(after: i)...]
        }
        return out
    }
}

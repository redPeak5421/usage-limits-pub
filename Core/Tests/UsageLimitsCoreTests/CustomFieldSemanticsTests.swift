import XCTest
@testable import UsageLimitsCore

final class CustomFieldSemanticsTests: XCTestCase {
    func testRoleInferenceFromKeyNames() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "data.balance", value: 10, rawText: "10").role, .remaining)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "data.remainingQuota", value: 10, rawText: "10").role, .remaining)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage.total_used", value: 10, rawText: "10").role, .used)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage.spentUSD", value: 10, rawText: "10").role, .used)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "quota.limit", value: 100, rawText: "100").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "quota.total", value: 100, rawText: "100").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "used_percent", value: 42, rawText: "42").role, .percent)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "requests", value: 12, rawText: "12").role, .count)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "expires_at", value: 1_800_000_000, rawText: "1800000000").role, .timestamp)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "reset_at", value: 1_800_000_000_000, rawText: "1800000000000").role, .timestamp)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "subscription.current_period_end", value: 1_800_000_000, rawText: "1800000000").role, .timestamp)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "data.id", value: 7, rawText: "7").role, .other)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "data.id", value: 7, rawText: "7").score, 0)
    }

    func testCurrencyFromTextKeyAndSibling() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "balance", value: 5, rawText: "$5.00").currency, "USD")
        XCTAssertEqual(CustomFieldSemantics.infer(path: "balance_cny", value: 5, rawText: "5").currency, "CNY")
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "wallet.balance", value: 5, rawText: "5", siblings: ["currency": "usd", "balance": 5]).currency,
            "USD"
        )
        XCTAssertNil(CustomFieldSemantics.infer(path: "balance", value: 5, rawText: "5").currency)
    }

    func testLenientNumberParsesSymbolsAndGrouping() {
        XCTAssertEqual(CustomFieldSemantics.lenientNumber("$168.80"), 168.8)
        XCTAssertEqual(CustomFieldSemantics.lenientNumber("¥1,024.5"), 1024.5)
        XCTAssertEqual(CustomFieldSemantics.lenientNumber("42%"), 42)
        XCTAssertEqual(CustomFieldSemantics.lenientNumber("12 USD"), 12)
        XCTAssertNil(CustomFieldSemantics.lenientNumber("abc"))
        XCTAssertNil(CustomFieldSemantics.lenientNumber(""))
    }

    func testPreviewIncludesCurrencyAndPercentStrings() {
        let result = CustomJSONPreview.preview(body: #"{"balance":"$168.80","used_pct":"42%","name":"x","ok":true}"#)
        XCTAssertEqual(result.leaves.map(\.path), ["balance", "used_pct"])
        XCTAssertEqual(result.leaves[0].value, 168.8)
        XCTAssertEqual(result.leaves[0].hint.currency, "USD")
        XCTAssertEqual(result.leaves[1].hint.role, .percent)
    }

    func testSuggestedPathsPrefersRolesAndCapsPerRole() {
        let leaves = CustomJSONPreview.preview(body: #"""
        {"id":123,"data":{"used":20,"balance":80,"total":100,"balance_bonus":5,"balance_gift":3,"version":2}}
        """#).leaves
        let picked = CustomFieldSemantics.suggestedPaths(leaves.map { (path: $0.path, hint: $0.hint) })
        XCTAssertEqual(picked.count, 4)
        XCTAssertTrue(picked.contains("data.used"))
        XCTAssertTrue(picked.contains("data.balance"))
        XCTAssertTrue(picked.contains("data.total"))
        XCTAssertFalse(picked.contains("id"))
        XCTAssertFalse(picked.contains("data.version"))
        XCTAssertEqual(picked.filter { $0.hasPrefix("data.balance") }.count, 2, "同角色最多两条")
    }

    func testParserEmitsRoleCurrencyPercentAndTimestamp() throws {
        let template = try XCTUnwrap(CustomUsageTemplate(
            name: "T", requestURL: "https://api.example.com/v1/usage",
            fields: [
                CustomUsageField(path: "used", displayName: "已用", role: .used, currency: "USD"),
                CustomUsageField(path: "limit", displayName: "总额", role: .limit, currency: "USD"),
                CustomUsageField(path: "pct", displayName: "占比", role: .percent),
                CustomUsageField(path: "expires_at", displayName: "到期", role: .timestamp),
                CustomUsageField(path: "wallet", displayName: "余额", role: .remaining),
            ]
        ))
        let snap = CustomUsageParser.parse(
            status: 200,
            body: #"{"used":20,"limit":100,"pct":"20%","expires_at":1800000000,"wallet":"$80"}"#,
            template: template
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.map(\.kind), ["used", "limit", "percent", "timestamp", "remaining"])
        XCTAssertEqual(snap.metrics[0].currency, "USD")
        XCTAssertEqual(snap.metrics[2].displayValue, "20%")
        XCTAssertEqual(snap.metrics[3].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snap.metrics[4].id, "balance", "唯一余额角色 → id balance，预充值提醒可认")
        XCTAssertEqual(snap.metrics[4].currency, "USD", "原始文本 $80 推出币种")
        XCTAssertTrue(snap.metrics.allSatisfy { $0.usedPercent == nil }, "不得触发百分比阈值提醒")
    }

    func testFieldRoleRoundTripsAndOldTemplatesDecode() throws {
        let field = CustomUsageField(path: "a.b", displayName: "X", role: .limit, currency: "CNY")
        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(CustomUsageField.self, from: data)
        XCTAssertEqual(decoded, field)
        let legacy = try JSONDecoder().decode(CustomUsageField.self, from: Data(#"{"path":"p","displayName":"n"}"#.utf8))
        XCTAssertNil(legacy.role)
        let unknown = try JSONDecoder().decode(CustomUsageField.self, from: Data(#"{"path":"p","displayName":"n","role":"future"}"#.utf8))
        XCTAssertNil(unknown.role, "未知角色不能让解码失败")
        let migrated = CustomUsageTemplate.fieldsFromLegacy(usedPath: "used", balancePath: "balance")
        XCTAssertEqual(migrated.first { $0.path == "used" }?.role, .used)
        XCTAssertEqual(migrated.first { $0.path == "balance" }?.role, .remaining)
    }

    func testPresentationPicksHeroAndGauge() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "已用", amount: 20, pinned: true, kind: "used"),
                UsageMetric(id: "balance", label: "余额", amount: 80, pinned: true, kind: "remaining"),
                UsageMetric(id: "limit", label: "总额", amount: 100, pinned: true, kind: "limit"),
                UsageMetric(id: "exp", label: "到期", resetsAt: Date(timeIntervalSince1970: 1_800_000_000), amount: 1_800_000_000, pinned: true, kind: "timestamp"),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        let shown = CustomUsageDisplay.presentation(from: snap)
        XCTAssertEqual(shown.hero?.id, "balance")
        XCTAssertEqual(shown.secondary.map(\.id), ["used", "limit"])
        XCTAssertEqual(shown.timestamps.map(\.id), ["exp"])
        XCTAssertEqual(shown.gauge?.source, .usedOverLimit)
        XCTAssertEqual(shown.gauge?.displayedPercent ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(shown.gauge?.caption, "已用 20 / 总额 100")
    }

    func testGaugeFallsBackToPercentFieldAndRemainingOverLimit() {
        let percentOnly = CustomUsageDisplay.gauge(tiles: [
            .init(id: "p", label: "占比", valueText: "42%", amount: 42, role: .percent),
            .init(id: "u", label: "已用", valueText: "1", amount: 1, role: .used),
            .init(id: "l", label: "总额", valueText: "2", amount: 2, role: .limit),
        ], share: nil)
        XCTAssertEqual(percentOnly?.source, .percentField)
        XCTAssertEqual(percentOnly?.displayedPercent, 42)
        let remainingLimit = CustomUsageDisplay.gauge(tiles: [
            .init(id: "r", label: "余额", valueText: "25", amount: 25, role: .remaining),
            .init(id: "l", label: "总额", valueText: "100", amount: 100, role: .limit),
        ], share: nil)
        XCTAssertEqual(remainingLimit?.source, .remainingOverLimit)
        XCTAssertEqual(remainingLimit?.displayedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertNil(CustomUsageDisplay.gauge(tiles: [
            .init(id: "a", label: "x", valueText: "1", amount: 1, role: .other),
        ], share: nil))
    }

    func testFormatAmountGroupsThousandsOnlyFromTenThousand() {
        XCTAssertEqual(CustomUsageDisplay.formatAmount(1234), "1234")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(1_234_567), "1,234,567")
        XCTAssertEqual(CustomUsageDisplay.formatAmount(12_345.678), "12,345.68")
        XCTAssertEqual(CustomUsageDisplay.percentText(42), "42%")
        XCTAssertEqual(CustomUsageDisplay.percentText(42.5), "42.5%")
    }

    func testUnusedCreditsIsRemainingNotUsed() {
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "unused_credits", value: 10, rawText: "10").role,
            .remaining,
            "unused 含 used 子串，不得判成已用"
        )
        XCTAssertEqual(CustomFieldSemantics.infer(path: "unspent", value: 8, rawText: "8").role, .remaining)
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "unconsumed_tokens", value: 3, rawText: "3").role,
            .remaining
        )
        XCTAssertEqual(CustomFieldSemantics.infer(path: "credits_used", value: 4, rawText: "4").role, .used)
    }

    func testUsableRequestsIsRemainingNotCount() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usable_requests", value: 250, rawText: "250").role, .remaining)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "requests", value: 12, rawText: "12").role, .count)
    }

    func testRemainingPercentIsNotUsedPercent() {
        let remaining = CustomFieldSemantics.infer(path: "remaining_percent", value: 80, rawText: "80")
        XCTAssertEqual(remaining.role, .remaining, "剩 80% 不得判成已用百分比")
        XCTAssertTrue(remaining.isPercentString)
        let available = CustomFieldSemantics.infer(path: "available_pct", value: 25, rawText: "25%")
        XCTAssertEqual(available.role, .remaining)
        XCTAssertTrue(available.isPercentString)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "used_percent", value: 42, rawText: "42").role, .percent)
        let nested = CustomFieldSemantics.infer(path: "remaining.percent", value: 80, rawText: "80")
        XCTAssertEqual(nested.role, .remaining, "父键 remaining + 叶 percent 仍是剩余占比")
        XCTAssertTrue(nested.isPercentString)
        let nestedAvailable = CustomFieldSemantics.infer(path: "quota.available.pct", value: 25, rawText: "25%")
        XCTAssertEqual(nestedAvailable.role, .remaining)
        XCTAssertTrue(nestedAvailable.isPercentString)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "used.percent", value: 42, rawText: "42").role, .percent)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage.percent", value: 42, rawText: "42").role, .percent)
    }

    func testCreditUsedIsNotRemaining() {
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "balance.credits_used_usd", value: 4, rawText: "4").role,
            .used
        )
        XCTAssertEqual(CustomFieldSemantics.infer(path: "credits_used", value: 4, rawText: "4").role, .used)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "credits", value: 12, rawText: "12").role, .remaining)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "credit_usage", value: 3, rawText: "3").role, .used)
    }

    func testRateAndUsageDoNotStealLimit() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "rate_limit", value: 100, rawText: "100").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage_limit", value: 1000, rawText: "1000").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "data.usage", value: 20, rawText: "20").role, .used)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage_rate", value: 42, rawText: "42").role, .percent)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "remainingQuota", value: 10, rawText: "10").role, .remaining)
    }

    func testDefaultDisplayNameKeepsSpecificBalanceKeys() {
        XCTAssertEqual(CustomFieldSemantics.defaultDisplayName(path: "data.balance", role: .remaining), "余额")
        XCTAssertEqual(CustomFieldSemantics.defaultDisplayName(path: "credits", role: .remaining), "余额")
        XCTAssertEqual(CustomFieldSemantics.defaultDisplayName(path: "data.cash_balance", role: .remaining), "cash_balance")
        XCTAssertEqual(
            CustomFieldSemantics.defaultDisplayName(path: "data.available_balance", role: .remaining),
            "available_balance"
        )
        XCTAssertEqual(
            CustomFieldSemantics.defaultDisplayName(path: "prepaid_credits", role: .remaining),
            "prepaid_credits"
        )
        XCTAssertEqual(
            CustomFieldSemantics.defaultDisplayName(path: "data.cash_balance", role: .remaining, language: .en),
            "cash_balance"
        )
        XCTAssertEqual(CustomFieldSemantics.defaultDisplayName(path: "balance", role: .remaining, language: .en), "Balance")
    }


    func testRequestsPlanIsLimitNotCount() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "requests_plan", value: 1000, rawText: "1000").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "credit_limit", value: 50, rawText: "50").role, .limit)
    }


    func testCostLimitAndCycleEndRoles() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "cost_limit", value: 20, rawText: "20").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "spent_limit", value: 20, rawText: "20").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage.total_used", value: 10, rawText: "10").role, .used)
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "cycle_end", value: 1_800_000_000, rawText: "1800000000").role,
            .timestamp
        )
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "window_end", value: 1_800_000_000, rawText: "1800000000").role,
            .timestamp
        )
        XCTAssertEqual(
            CustomFieldSemantics.infer(path: "billing_end", value: 1_800_000_000, rawText: "1800000000").role,
            .timestamp
        )
    }

    func testParentKeyRolesForGenericLeaves() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage.amount", value: 20, rawText: "20").role, .used)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "quota.value", value: 100, rawText: "100").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "balance.amount", value: 8, rawText: "8").role, .remaining)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "credits.value", value: 12, rawText: "12").role, .remaining)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "tokens.amount", value: 40, rawText: "40").role, .count)
        let usd = CustomFieldSemantics.infer(path: "usage.amount_usd", value: 3, rawText: "3")
        XCTAssertEqual(usd.role, .used)
        XCTAssertEqual(usd.currency, "USD")
        XCTAssertEqual(CustomFieldSemantics.infer(path: "data.amount", value: 9, rawText: "9").role, .other)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "amount", value: 9, rawText: "9").role, .other)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "usage.total_used", value: 10, rawText: "10").role, .used)
    }

    func testTotalTokensAndUsedQuotaAreNotLimits() {
        XCTAssertEqual(CustomFieldSemantics.infer(path: "total_tokens", value: 1200, rawText: "1200").role, .count)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "total_requests", value: 40, rawText: "40").role, .count)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "used_quota", value: 8, rawText: "8").role, .used)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "cost_limit", value: 20, rawText: "20").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "total_quota", value: 100, rawText: "100").role, .limit)
        XCTAssertEqual(CustomFieldSemantics.infer(path: "max_tokens", value: 8000, rawText: "8000").role, .limit)
    }

}

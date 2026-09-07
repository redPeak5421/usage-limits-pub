import XCTest
@testable import UsageLimitsCore

final class PerplexityParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesAllPoolsBalanceAndStableOrder() throws {
        let snapshot = parse(try fixture("perplexity_credits"))

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Perplexity Max")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["monthly", "purchased", "promotional", "balance"])

        let monthly = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "monthly" }))
        XCTAssertEqual(monthly.usedPercent, 100)
        XCTAssertEqual(monthly.remaining, 0)
        XCTAssertEqual(monthly.total, 10_000)
        XCTAssertEqual(monthly.resetsAt, Date(timeIntervalSince1970: 1_788_134_400))
        XCTAssertEqual(monthly.detail, "已用 10.0K / 10.0K credits")
        XCTAssertEqual(monthly.pinned, true)

        let purchased = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "purchased" }))
        XCTAssertEqual(purchased.usedPercent, 100)
        XCTAssertEqual(purchased.remaining, 0)
        XCTAssertEqual(purchased.total, 8_000)
        XCTAssertNil(purchased.pinned)

        let promotional = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "promotional" }))
        XCTAssertEqual(promotional.usedPercent, 25)
        XCTAssertEqual(promotional.remaining, 3_000)
        XCTAssertEqual(promotional.total, 4_000)
        XCTAssertEqual(promotional.resetsAt, Date(timeIntervalSince1970: 1_790_812_800))

        let balance = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "balance" }))
        XCTAssertEqual(try XCTUnwrap(balance.amount), 230.65, accuracy: 0.0001)
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertNil(balance.remaining)
        XCTAssertNil(balance.total)
        XCTAssertEqual(balance.pinned, true)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testWaterfallOrderAndPurchasedUsesMaximumSource() throws {
        let snapshot = parse(try fixture("perplexity_purchased_max"))
        XCTAssertEqual(snapshot.status, .ok)
        let monthly = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "monthly" }))
        let purchased = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "purchased" }))
        let promotional = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "promotional" }))
        XCTAssertEqual(monthly.usedPercent, 100)
        XCTAssertEqual(purchased.total, 8_000)
        XCTAssertEqual(purchased.usedPercent, 100)
        XCTAssertEqual(promotional.usedPercent, 25)
        XCTAssertEqual(promotional.remaining, 3_000)
    }

    func testExpiredPromotionalGrantsAreFilteredAndNearestExpiryWins() throws {
        let snapshot = parse(try fixture("perplexity_expired_promo"))
        XCTAssertEqual(snapshot.status, .ok)
        let promo = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "promotional" }))
        XCTAssertEqual(promo.total, 4_000)
        XCTAssertEqual(promo.usedPercent, 25)
        XCTAssertEqual(promo.remaining, 3_000)
        XCTAssertEqual(promo.resetsAt, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertEqual(promo.detail, "已用 1.0K / 4.0K credits · 最近到期 2026-10-01")
    }

    func testEmptyPoolsOnlyProducePinnedBalanceInsteadOfFakeBars() throws {
        let snapshot = parse(try fixture("perplexity_empty"))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["balance"])
        XCTAssertEqual(snapshot.metrics.first?.amount, 0)
        XCTAssertEqual(snapshot.metrics.first?.pinned, true)
        XCTAssertTrue(snapshot.metrics.first?.hasUsage == true)
    }

    func testPlanInferenceBoundaries() {
        XCTAssertNil(parse(body(recurring: 0)).planName)
        XCTAssertEqual(parse(body(recurring: 1)).planName, "Perplexity Pro")
        XCTAssertEqual(parse(body(recurring: 4_999)).planName, "Perplexity Pro")
        XCTAssertEqual(parse(body(recurring: 5_000)).planName, "Perplexity Max")
    }

    func testUsageBeyondAllPoolsIsIgnoredAfterWaterfall() {
        let snapshot = parse(body(recurring: 100, purchased: 50, promotional: 25, usage: 1_000))
        XCTAssertEqual(snapshot.status, .ok)
        for metric in snapshot.metrics where metric.id != "balance" {
            XCTAssertEqual(metric.usedPercent, 100)
            XCTAssertEqual(metric.remaining, 0)
        }
    }

    func testExpiryAtNowIsAlreadyExpired() {
        let timestamp = now.timeIntervalSince1970
        let body = #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[{"type":"promotional","amount_cents":10,"expires_at_ts":\#(timestamp)}],"total_usage_cents":0}"#
        XCTAssertEqual(parse(body).metrics.map(\.id), ["balance"])
    }

    func testInvalidRenewalIsDroppedWithoutPoisoningCredits() {
        for renewal in [#""Infinity""#, #""NaN""#, "-1", "0", "1e308"] {
            let body = #"{"balance_cents":0,"renewal_date_ts":\#(renewal),"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":100}],"total_usage_cents":10}"#
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertNil(snapshot.metrics.first?.resetsAt)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
        let missing = #"{"balance_cents":0,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":100}],"total_usage_cents":10}"#
        XCTAssertEqual(parse(missing).status, .ok)
        XCTAssertNil(parse(missing).metrics.first?.resetsAt)
    }

    func testHTTPMissingAndEmptyStatusTiers() {
        XCTAssertEqual(parse("", status: 401).status, .needsLogin)
        XCTAssertEqual(parse("", status: 403).status, .needsLogin)
        XCTAssertEqual(parse("", status: 503).status, .error("HTTP 503"))
        XCTAssertEqual(parse("timeout", status: -3).status, .error("请求超时"))
        XCTAssertEqual(
            PerplexityParser.parse(results: ["other": ProbeResult(status: 200, body: "{}")], now: now).status,
            .error("未获取到额度响应")
        )
        XCTAssertEqual(PerplexityParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
    }

    func testMalformedAndMissingRequiredShapesAreRejected() {
        let bodies = [
            "not json",
            #"{"balance_cents":0,"renewal_date_ts":1788134400,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":null,"total_usage_cents":0}"#,
            #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[]}"#,
        ]
        for body in bodies {
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .error("额度数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testNegativeAndNonFiniteNumbersAreRejected() {
        let bodies = [
            #"{"balance_cents":"NaN","renewal_date_ts":1,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":"Infinity","renewal_date_ts":1,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":-1,"renewal_date_ts":1,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":0,"renewal_date_ts":1,"current_period_purchased_cents":-1,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":0,"renewal_date_ts":1,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":"Infinity"}"#,
            #"{"balance_cents":0,"renewal_date_ts":1,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":-1}],"total_usage_cents":0}"#,
        ]
        for body in bodies {
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .error("额度数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testTopLevelBooleansNeverBridgeIntoAmountsOrUsage() {
        let bodies = [
            #"{"balance_cents":true,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":false,"credit_grants":[],"total_usage_cents":0}"#,
            #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":true}"#,
        ]
        for body in bodies {
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .error("额度数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testBooleanRenewalIsDroppedInsteadOfBecomingEpochOne() throws {
        let body = #"{"balance_cents":0,"renewal_date_ts":true,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":100}],"total_usage_cents":10}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .ok)
        let monthly = try XCTUnwrap(snapshot.metrics.first(where: { $0.id == "monthly" }))
        XCTAssertNil(monthly.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testGrantAmountBooleanIsRejected() {
        let body = #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":true}],"total_usage_cents":0}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .error("额度数据异常"))
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testInvalidGrantExpiryDropsOnlyThatGrant() {
        for expiry in ["false", #""Infinity""#, "-1", "0", "1e308"] {
            let body = #"{"balance_cents":90,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":100},{"type":"promotional","amount_cents":10,"expires_at_ts":\#(expiry)}],"total_usage_cents":10}"#
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .ok, expiry)
            XCTAssertEqual(snapshot.metrics.map(\.id), ["monthly", "balance"], expiry)
            XCTAssertTrue(snapshot.metrics.compactMap(\.resetsAt).allSatisfy { $0.timeIntervalSince1970 <= 253_402_300_799 })
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot), expiry)
        }
    }

    func testExplicitNullGrantExpiryIsInvalidRatherThanNeverExpiring() throws {
        let snapshot = parse(try fixture("perplexity_null_expiry"))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["monthly", "balance"])
        XCTAssertNil(snapshot.metrics.first(where: { $0.id == "promotional" }))
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testGrantAdditionOverflowIsRejected() {
        let body = #"{"balance_cents":0,"renewal_date_ts":1,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":1e308},{"type":"recurring","amount_cents":1e308}],"total_usage_cents":0}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .error("额度数据异常"))
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testUnknownGrantTypeDoesNotRequireInterpretingItsPayload() {
        let body = #"{"balance_cents":0,"renewal_date_ts":1788134400,"current_period_purchased_cents":0,"credit_grants":[{"type":"future_kind","amount_cents":"not-a-number"}],"total_usage_cents":0}"#
        let snapshot = parse(body)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["balance"])
    }

    private func parse(_ body: String, status: Int = 200) -> ProviderSnapshot {
        PerplexityParser.parse(results: ["credits": ProbeResult(status: status, body: body)], now: now)
    }

    private func body(
        recurring: Double,
        purchased: Double = 0,
        promotional: Double = 0,
        usage: Double = 0
    ) -> String {
        let grants: [[String: Any]] = [
            ["type": "recurring", "amount_cents": recurring],
            ["type": "promotional", "amount_cents": promotional, "expires_at_ts": now.timeIntervalSince1970 + 10_000],
        ]
        let root: [String: Any] = [
            "balance_cents": 0,
            "renewal_date_ts": now.timeIntervalSince1970 + 20_000,
            "current_period_purchased_cents": purchased,
            "credit_grants": grants,
            "total_usage_cents": usage,
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

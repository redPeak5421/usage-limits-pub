import XCTest
@testable import UsageLimitsCore

final class AugmentParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesCreditsSubscriptionAndPlan() throws {
        let snapshot = AugmentParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("augment_credits")),
            "subscription": ProbeResult(status: 200, body: try fixture("augment_subscription")),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Augment Developer")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.count, 1)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.id, "credits")
        XCTAssertEqual(metric.label, "Credits")
        XCTAssertEqual(metric.usedPercent, 62)
        XCTAssertEqual(metric.remaining, 380)
        XCTAssertEqual(metric.total, 1000)
        XCTAssertEqual(metric.resetsAt, iso("2026-09-15T00:00:00Z"))
        XCTAssertEqual(metric.detail, "active")
        XCTAssertEqual(metric.pinned, true)
    }

    func testNonpositiveAvailableFallsBackToRemainingPlusConsumed() throws {
        let snapshot = AugmentParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("augment_credits_available")),
        ], now: now)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.total, 1000)
        XCTAssertEqual(metric.usedPercent, 10)
        XCTAssertEqual(metric.detail, "trial")
    }

    func testMissingConsumedDerivesPercentFromRemaining() {
        let body = #"{"usageUnitsRemaining":200,"usageUnitsAvailable":500}"#
        let snapshot = AugmentParser.parse(results: [
            "credits": ProbeResult(status: 200, body: body),
        ], now: now)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 60)
    }

    func testPlanNormalizesKnownTierAndAvoidsDuplicatePrefix() {
        let pro = parse(credits: #"{"usageUnitsRemaining":1}"#, subscription: #"{"planName":"pro"}"#)
        XCTAssertEqual(pro.planName, "Augment Pro")

        let prefixed = parse(credits: #"{"usageUnitsRemaining":1}"#, subscription: #"{"planName":"Augment Team"}"#)
        XCTAssertEqual(prefixed.planName, "Augment Team")
    }

    func testBareAugmentPlanNameIsNotDuplicated() {
        let snapshot = parse(
            credits: #"{"usageUnitsRemaining":1}"#,
            subscription: #"{"planName":"Augment"}"#
        )
        XCTAssertEqual(snapshot.planName, "Augment")
    }

    func testExistingAugmentPrefixIsCaseInsensitive() {
        for raw in ["AUGMENT pro", "aUgMeNt Team"] {
            let snapshot = parse(
                credits: #"{"usageUnitsRemaining":1}"#,
                subscription: "{\"planName\":\"\(raw)\"}"
            )
            let expected = raw.lowercased().contains("pro") ? "Augment Pro" : "Augment Team"
            XCTAssertEqual(snapshot.planName, expected)
        }
    }

    func testOptionalSubscriptionFailureDoesNotDowngradeCredits() throws {
        let snapshot = AugmentParser.parse(results: [
            "credits": ProbeResult(status: 200, body: try fixture("augment_credits")),
            "subscription": ProbeResult(status: 403, body: ""),
        ], now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
        XCTAssertNil(snapshot.metrics.first?.resetsAt)
    }

    func testMissingCreditsMetricUsesFailureTiers() {
        XCTAssertEqual(parse(credits: "", creditsStatus: 401).status, .needsLogin)
        XCTAssertEqual(parse(credits: "", creditsStatus: 500).status, .error("HTTP 500"))
        XCTAssertEqual(parse(credits: "timeout", creditsStatus: -3).status, .error("请求超时"))

        let subscriptionUnauthorized = parse(
            credits: #"{"unexpected":true}"#,
            subscription: "",
            subscriptionStatus: 403
        )
        XCTAssertEqual(subscriptionUnauthorized.status, .needsLogin)
    }

    func testRecognizedSubscriptionAloneDoesNotProveLogin() {
        let snapshot = parse(
            credits: #"{"unexpected":true}"#,
            subscription: #"{"planName":"Developer"}"#
        )
        XCTAssertEqual(snapshot.status, .needsLogin)
        XCTAssertTrue(snapshot.metrics.isEmpty)
    }

    func testInvalidCreditsAndEmptyResultsAreDefensive() {
        XCTAssertEqual(parse(credits: "not json").status, .needsLogin)
        XCTAssertEqual(AugmentParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
    }

    func testNegativeAndNonFiniteCreditValuesAreRejected() {
        let bodies = [
            #"{"usageUnitsRemaining":-1,"usageUnitsConsumedThisBillingCycle":1}"#,
            #"{"usageUnitsRemaining":"NaN","usageUnitsConsumedThisBillingCycle":1}"#,
            #"{"usageUnitsRemaining":1,"usageUnitsConsumedThisBillingCycle":"Infinity"}"#,
            #"{"usageUnitsRemaining":1,"usageUnitsAvailable":"Infinity"}"#,
        ]
        for body in bodies {
            let snapshot = parse(credits: body)
            XCTAssertEqual(snapshot.status, .needsLogin)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testOverflowingFallbackTotalIsRejected() {
        let body = #"{"usageUnitsRemaining":1e308,"usageUnitsConsumedThisBillingCycle":1e308,"usageUnitsAvailable":0}"#
        let snapshot = parse(credits: body)
        XCTAssertEqual(snapshot.status, .needsLogin)
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testNonFiniteBillingDateIsDropped() {
        let snapshot = parse(
            credits: #"{"usageUnitsRemaining":9,"usageUnitsConsumedThisBillingCycle":1}"#,
            subscription: #"{"planName":"pro","billingPeriodEnd":"Infinity"}"#
        )
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.metrics.first?.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    private func parse(
        credits: String,
        creditsStatus: Int = 200,
        subscription: String? = nil,
        subscriptionStatus: Int = 200
    ) -> ProviderSnapshot {
        var results = ["credits": ProbeResult(status: creditsStatus, body: credits)]
        if let subscription {
            results["subscription"] = ProbeResult(status: subscriptionStatus, body: subscription)
        }
        return AugmentParser.parse(results: results, now: now)
    }

    private func iso(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

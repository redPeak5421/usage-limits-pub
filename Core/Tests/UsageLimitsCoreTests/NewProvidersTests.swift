import XCTest
@testable import UsageLimitsCore

final class NewProvidersTests: XCTestCase {
    func testCopilotBudgets401Wins() {
        let snap = CopilotParser.parse(
            results: ["budgets": ProbeResult(status: 401, body: "")],
            now: Date()
        )
        XCTAssertTrue(snap.status.isNeedsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testCopilotBudgetsMapUsedPercent() {
        let body = #"{"budgets":[{"name":"Copilot","budgetAmount":100,"currentAmount":25,"budgetProductSkus":["copilot"]}]}"#
        let snap = CopilotParser.parse(
            results: ["budgets": ProbeResult(status: 200, body: body)],
            now: Date()
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.first?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(snap.metrics.first?.label, "Copilot")
    }

    func testGeminiQuotaRemainingFractionIsUsedPercent() {
        let body = #"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.2,"resetTime":"2026-09-01T00:00:00Z"}]}"#
        let snap = GeminiParser.parse(
            results: ["quota": ProbeResult(status: 200, body: body)],
            now: Date()
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.first?.usedPercent ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(snap.metrics.first?.id, "gemini-2.5-pro")
    }

    func testGeminiQuota401Wins() {
        let snap = GeminiParser.parse(
            results: ["quota": ProbeResult(status: 401, body: "")],
            now: Date()
        )
        XCTAssertTrue(snap.status.isNeedsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testAntigravitySummaryMapsGroupBuckets() {
        let body = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","displayName":"Weekly","remainingFraction":0.4}]}]}"#
        let snap = AntigravityParser.parse(
            results: ["quota": ProbeResult(status: 200, body: body)],
            now: Date()
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.first?.usedPercent ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(snap.metrics.first?.id, "weekly")
    }

    func testKiroUsagePlanCredits() {
        let body = #"{"planLimit":50,"planUsed":12.5,"nextDateReset":1783224000}"#
        let snap = KiroParser.parse(
            results: ["usage": ProbeResult(status: 200, body: body)],
            now: Date()
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.first?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(snap.metrics.first?.remaining, 37.5)
        XCTAssertEqual(snap.metrics.first?.total, 50)
        XCTAssertEqual(snap.metrics.first?.resetsAt, Date(timeIntervalSince1970: 1_783_224_000))
    }

    func testKiroUsage401Wins() {
        let leftover = #"{"planLimit":50,"planUsed":1}"#
        let snap = KiroParser.parse(
            results: ["usage": ProbeResult(status: 401, body: leftover)],
            now: Date()
        )
        XCTAssertTrue(snap.status.isNeedsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testNeuralwattPresetIsGone() {
        XCTAssertFalse(CustomUsagePreset.all.contains { $0.id == "neuralwatt" })
        XCTAssertEqual(CustomUsagePreset.all.count, 5)
    }

    func testGeminiHTMLIsErrorNotFakeUsage() {
        let snap = GeminiParser.parse(
            results: ["quota": ProbeResult(status: 200, body: "<html>gemini app</html>")],
            now: Date()
        )
        XCTAssertFalse(snap.status.isOK)
        XCTAssertFalse(snap.status.isNeedsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
    }

    func testCopilotPayloadWrapperMapsBudget() {
        let body = #"{"payload":{"budgets":[{"name":"Copilot","budgetAmount":100,"currentAmount":25,"budgetProductSkus":["copilot"]}]}}"#
        let snap = CopilotParser.parse(
            results: ["budgets": ProbeResult(status: 200, body: body)],
            now: Date()
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.first?.usedPercent ?? -1, 25, accuracy: 0.001)
    }

    func testCopilotBudgetsBodyIsOmittedFromDiagnostics() {
        let body = #"{"budgets":[{"name":"Acme Corp","budgetEntityName":"secret-org"}]}"#
        let line = DiagnosticRedactor.probeLine(
            prefix: ProviderID.copilot.rawValue,
            name: "budgets",
            status: 200,
            body: body
        )
        XCTAssertFalse(line.contains("body="))
        XCTAssertFalse(line.contains("Acme Corp"))
        XCTAssertTrue(line.contains("HTTP 200"))
    }
}

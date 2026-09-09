import XCTest
@testable import UsageLimitsCore

final class NewProvidersTests: XCTestCase {
    func testGeminiAppHTMLExplainsUnavailableUsage() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "gemini_app", withExtension: "html", subdirectory: "Fixtures"))
        let html = try String(contentsOf: url, encoding: .utf8)
        for body in [html, "\u{FEFF} \n" + html.uppercased(), "<html>gemini app</html>"] {
            let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: body)], now: Date())
            XCTAssertEqual(snap.status, .error("Gemini 未返回用量数据，请在官网确认账号与用量页"))
            XCTAssertTrue(snap.metrics.isEmpty)
            XCTAssertFalse(LoginProbePolicy.isAuthenticated(snap))
        }
    }

    func testGeminiHTMLDoesNotOverrideHTTPFailure() {
        for status in [401, 403, 429, 500] {
            let result = ProbeResult(status: status, body: "<!DOCTYPE html><html>error</html>")
            XCTAssertEqual(GeminiParser.parse(results: ["quota": result], now: Date()).status, result.failureStatus)
        }
    }

    func testGeminiMalformedJSONStillReportsInvalidData() {
        let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: "{\"buckets\":[")], now: Date())
        XCTAssertEqual(snap.status, .error("配额数据异常"))
    }

    func testGeminiHTMLPreservesLastGoodUsage() {
        let now = Date()
        let old = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: #"{"buckets":[{"modelId":"model","remainingFraction":0.2}]}"#)], now: now)
        let results = ["quota": ProbeResult(status: 200, body: "<html>app</html>")]
        let snap = GeminiParser.parse(results: results, now: now)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: snap, results: results))
        XCTAssertTrue(RefreshPolicy.shouldCommit(old: nil, new: snap, results: results))
    }

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

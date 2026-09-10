import XCTest
@testable import UsageLimitsCore

final class OpenAIResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_031_840)

    private func snapshot(_ credits: String, history: String = "{}", session: String = "{\"user\":{\"email\":\"fixture@example.invalid\"}}") -> ProviderSnapshot {
        OpenAIParser.parse(results: [
            "session": ProbeResult(status: 200, body: session),
            "reset_credits": ProbeResult(status: 200, body: credits),
            "reset_history": ProbeResult(status: 200, body: history)
        ], now: now)
    }

    func testAvailableAndWindowHistoryAreSeparateFromUsage() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "openai-reset-credits", withExtension: "json", subdirectory: "Fixtures"))
        let credits = try String(contentsOf: url)
        let snap = snapshot(credits, history: """
        {"events":[{"id":"fixture-used","kind":"used","occurred_at":"2026-09-05T08:03:45Z"},{"id":"fixture-used","kind":"used","occurred_at":"2026-09-05T08:03:45Z"},{"id":"fixture-granted","kind":"granted","occurred_at":"2026-09-05T04:21:20Z"}],"window_start":"2026-08-11T09:17:17Z","as_of":"2026-09-10T09:17:17Z","next_cursor":null}
        """)
        XCTAssertEqual(snap.openAIResetCredits?.availableCount, 1)
        XCTAssertEqual(snap.openAIResetCredits?.expiresAt, JSONHelp.date("2026-10-05T04:21:20.321054Z"))
        XCTAssertEqual(snap.openAIResetCredits?.usedCount, 1)
        XCTAssertEqual(snap.openAIResetCredits?.historyComplete, true)
        XCTAssertTrue(snap.metrics.isEmpty)
        XCTAssertFalse(RefreshPolicy.hasNumericUsage(snap))
        XCTAssertEqual(try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snap)), snap)
    }

    func testGuestAndMalformedCountsNeverBecomeResetEvidence() {
        XCTAssertNil(snapshot("{\"available_count\":1,\"credits\":[]}", session: "{}").openAIResetCredits)
        for raw in ["true", "-1", "0.5", "1e100", "null"] {
            XCTAssertNil(snapshot("{\"available_count\":\(raw),\"credits\":[]}").openAIResetCredits)
        }
        XCTAssertEqual(snapshot("{\"available_count\":0,\"credits\":[]}").openAIResetCredits?.availableCount, 0)
    }

    func testIncompleteHistoryIsNotAnExactTotal() {
        let snap = snapshot("{}", history: """
        {"events":[{"id":"fixture-used","kind":"used","occurred_at":"2026-09-05T08:03:45Z"}],"window_start":"2026-08-11T09:17:17Z","as_of":"2026-09-10T09:17:17Z","next_cursor":"fixture-next"}
        """)
        XCTAssertEqual(snap.openAIResetCredits?.usedCount, 1)
        XCTAssertEqual(snap.openAIResetCredits?.historyComplete, false)
        XCTAssertNil(snap.openAIResetCredits?.availableCount)
    }

    func testOptionalProbeFailuresDoNotChangeLoginOrUsage() {
        for status in [401, 403, 429, 500, -3] {
            let results: [String: ProbeResult] = [
                "session": ProbeResult(status: 200, body: "{\"user\":{\"email\":\"fixture@example.invalid\"}}"),
                "wham_usage": ProbeResult(status: 200, body: "{\"rate_limit\":{\"primary_window\":{\"used_percent\":42}}}"),
                "reset_credits": ProbeResult(status: status, body: "{\"available_count\":1}"),
                "reset_history": ProbeResult(status: status, body: "{}")
            ]
            let snap = OpenAIParser.parse(results: results, now: now)
            XCTAssertEqual(snap.status, .ok)
            XCTAssertEqual(snap.metrics.first?.usedPercent, 42)
            XCTAssertNil(snap.openAIResetCredits)
            XCTAssertTrue(RefreshPolicy.shouldCommit(old: snap, new: snap, results: results))
            var unauthorized = results
            unauthorized["session"] = ProbeResult(status: 401, body: "{}")
            XCTAssertNil(OpenAIParser.parse(results: unauthorized, now: now).openAIResetCredits)
        }
    }

    func testOlderSnapshotAndDiagnosticPrivacy() throws {
        let old = ProviderSnapshot(provider: .openai, fetchedAt: now, status: .ok)
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("openAIResetCredits"))
        XCTAssertNil(try JSONDecoder().decode(ProviderSnapshot.self, from: data).openAIResetCredits)
        for name in ["reset_credits", "reset_history"] {
            let line = DiagnosticRedactor.probeLine(prefix: "openai", name: name, status: 200, body: "private-credit-id")
            XCTAssertFalse(line.contains("private-credit-id"))
        }
    }

    func testInvalidSummaryCannotPersist() {
        var snap = snapshot("{\"available_count\":1}")
        snap.openAIResetCredits?.availableCount = -1
        XCTAssertNotNil(snap.persistenceValidationIssue)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: nil, new: snap, results: [:]))
    }

    func testSupplementalHTTPDoesNotOverrideCoreFailureProtection() {
        let old = ProviderSnapshot(provider: .openai, metrics: [UsageMetric(id: "primary", label: "Codex", usedPercent: 42)], fetchedAt: now, status: .ok)
        for coreStatus in [503, -3] {
            for sideStatus in [200, 401] {
                let results: [String: ProbeResult] = [
                    "session": ProbeResult(status: coreStatus, body: "{}"),
                    "wham_usage": ProbeResult(status: coreStatus, body: "{}"),
                    "reset_credits": ProbeResult(status: sideStatus, body: "{\"available_count\":1}"),
                    "reset_history": ProbeResult(status: sideStatus, body: "{}")
                ]
                let new = OpenAIParser.parse(results: results, now: now)
                XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: new, results: results))
            }
        }
    }
}

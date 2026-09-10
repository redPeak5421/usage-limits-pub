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

    func testListsSortAndKeepRowsBeyondThree() throws {
        let credits = """
        {"available_count":4,"credits":[
        {"id":"d","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":true,"expires_at":"2026-10-04T00:00:00Z"},
        {"id":"b","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":true,"expires_at":"2026-10-02T00:00:00Z"},
        {"id":"a","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":true,"expires_at":"2026-10-01T00:00:00Z"},
        {"id":"c","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":true,"expires_at":"2026-10-03T00:00:00Z"},
        {"id":"c","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":true,"expires_at":"2026-10-03T00:00:00Z"}]}
        """
        let events = [2, 4, 1, 3, 3].map { "{\"id\":\"used-\($0)\",\"kind\":\"used\",\"occurred_at\":\"2026-09-0\($0)T00:00:00Z\"}" }.joined(separator: ",")
        let snap = snapshot(credits, history: "{\"events\":[\(events)],\"window_start\":\"2026-08-11T00:00:00Z\",\"as_of\":\"2026-09-10T00:00:00Z\",\"next_cursor\":null}")
        let summary = try XCTUnwrap(snap.openAIResetCredits)
        XCTAssertEqual(summary.availableExpirations, (1...4).compactMap { JSONHelp.date("2026-10-0\($0)T00:00:00Z") })
        XCTAssertEqual(summary.usedDates, (1...4).reversed().compactMap { JSONHelp.date("2026-09-0\($0)T00:00:00Z") })
        XCTAssertEqual(summary.usedCount, 4)
        XCTAssertEqual(try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snap)), snap)
    }

    func testSummaryCacheWithoutListsStillDecodes() throws {
        let data = Data("{\"availableCount\":1,\"historyComplete\":true}".utf8)
        let summary = try JSONDecoder().decode(OpenAIResetCredits.self, from: data)
        XCTAssertNil(summary.availableExpirations)
        XCTAssertNil(summary.usedDates)
        XCTAssertEqual(summary.availableCount, 1)
    }

    func testListViewportAndIndependentScrollContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Views/OpenAIResetCreditsView.swift"))
        XCTAssertTrue(source.contains("private static let visibleSlots = 3"))
        XCTAssertTrue(source.contains("ForEach(Array(dates.enumerated()), id: \\.offset)"))
        XCTAssertTrue(source.contains(".environment(\\.isScrollEnabled, dates.count > Self.visibleSlots)"))
        XCTAssertTrue(source.contains("Color.clear.dashboardSceneControlRegion()"))
        XCTAssertFalse(source.contains("summary.usedCount"))
        XCTAssertFalse(source.contains("summary.usedDates"))
        XCTAssertFalse(source.contains("openai.reset.title"))
        XCTAssertFalse(source.contains("RoundedRectangle"))
    }

    func testInvalidListDateCannotPersist() {
        var snap = snapshot("{\"available_count\":1}")
        snap.openAIResetCredits?.usedDates = [Date(timeIntervalSince1970: .infinity)]
        XCTAssertNotNil(snap.persistenceValidationIssue)
    }

    func testResetPanelOnlyRendersInsideExpandedCard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"))
        XCTAssertEqual(source.components(separatedBy: "OpenAIResetCreditsView(").count - 1, 1)
        XCTAssertTrue(source.contains("if isExpanded, !isCustom, snap.provider == .openai"))
        XCTAssertFalse(source.contains("(sceneTheme == nil || isExpanded || snap.metrics.isEmpty)"))
    }
}

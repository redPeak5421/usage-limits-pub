import XCTest
@testable import UsageLimitsCore

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class OllamaParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testParsesStrictSafeSummaryAndBothWindows() throws {
        let snapshot = parse(#"{"plan":"pro","signedOut":false,"session":{"usedPercent":12.5,"resetsAt":"2026-08-29T02:00:00Z"},"weekly":{"usedPercent":34,"resetsAt":"2026-09-01T00:00:00.000Z"}}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Ollama Pro")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["session", "weekly"])
        let session = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(session.label, "Session usage")
        XCTAssertEqual(session.usedPercent, 12.5)
        XCTAssertEqual(session.resetsAt, iso("2026-08-29T02:00:00Z"))
        XCTAssertEqual(session.pinned, true)
        let weekly = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(weekly.label, "Weekly usage")
        XCTAssertEqual(weekly.usedPercent, 34)
        XCTAssertEqual(weekly.resetsAt, iso("2026-09-01T00:00:00Z"))
        XCTAssertEqual(weekly.pinned, true)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testHourlyFallbackUsesStableSessionIDAndAllowlistedPlans() throws {
        for (tier, expected) in [("free", "Ollama Free"), ("pro", "Ollama Pro"), ("max", "Ollama Max")] {
            let snapshot = parse("{\"plan\":\"\(tier)\",\"signedOut\":false,\"hourly\":{\"usedPercent\":7.25}}")
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertEqual(snapshot.planName, expected)
            XCTAssertEqual(snapshot.metrics.map(\.id), ["session"])
            XCTAssertEqual(snapshot.metrics.first?.label, "Hourly usage")
            XCTAssertEqual(snapshot.metrics.first?.usedPercent, 7.25)
        }
    }

    func testEachWindowCanStandAlone() {
        let primary = parse(#"{"signedOut":false,"session":{"usedPercent":0}}"#)
        XCTAssertEqual(primary.status, .ok)
        XCTAssertEqual(primary.metrics.map(\.id), ["session"])
        XCTAssertEqual(primary.metrics.first?.pinned, true)

        let weekly = parse(#"{"signedOut":false,"weekly":{"usedPercent":100}}"#)
        XCTAssertEqual(weekly.status, .ok)
        XCTAssertEqual(weekly.metrics.map(\.id), ["weekly"])
    }

    func testHTTPAndSignedOutStatusTiers() {
        XCTAssertEqual(OllamaParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
        XCTAssertEqual(parse("{}", status: 401).status, .needsLogin)
        XCTAssertEqual(parse("{}", status: 403).status, .needsLogin)
        XCTAssertEqual(parse("{}", status: 500).status, .error("HTTP 500"))
        XCTAssertEqual(parse("{}", status: -3).status, .error("请求超时"))
        XCTAssertEqual(parse(#"{"signedOut":true}"#).status, .needsLogin)
    }

    func testMalformedUnsafeAndIdentityBearingSummariesAreRejected() {
        let bodies = [
            "not json",
            "{}",
            #"{"signedOut":"false","session":{"usedPercent":1}}"#,
            #"{"signedOut":0,"session":{"usedPercent":1}}"#,
            #"{"signedOut":false,"plan":"enterprise","session":{"usedPercent":1}}"#,
            #"{"signedOut":false,"email":"person-placeholder@example.invalid","session":{"usedPercent":1}}"#,
            #"{"signedOut":false,"name":"Person Placeholder","session":{"usedPercent":1}}"#,
            #"{"signedOut":true,"plan":"pro"}"#,
            #"{"signedOut":false,"session":{"usedPercent":1},"hourly":{"usedPercent":2}}"#,
        ]
        for body in bodies {
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .error("Ollama 用量数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty, body)
        }
    }

    func testInvalidWindowDoesNotSuppressOtherSafeWindow() {
        let invalidWindows = [
            #"{"usedPercent":true}"#,
            #"{"usedPercent":"25"}"#,
            #"{"usedPercent":"NaN"}"#,
            #"{"usedPercent":"Infinity"}"#,
            #"{"resetsAt":"2026-08-29T02:00:00Z"}"#,
        ]
        for invalid in invalidWindows {
            let snapshot = parse("{\"signedOut\":false,\"session\":\(invalid),\"weekly\":{\"usedPercent\":40}}")
            XCTAssertEqual(snapshot.status, .ok, invalid)
            XCTAssertEqual(snapshot.metrics.map(\.id), ["weekly"], invalid)
        }

        XCTAssertEqual(
            parse(#"{"signedOut":false,"session":{"usedPercent":true}}"#).status,
            .error("Ollama 用量数据异常")
        )
        XCTAssertEqual(
            parse(#"{"signedOut":false,"session":{"usedPercent":1e309}}"#).status,
            .error("Ollama 用量数据异常")
        )
    }

    func testUnknownOrIdentityKeyInAnyWindowRejectsEntireSummary() {
        let bodies = [
            #"{"signedOut":false,"session":{"usedPercent":25,"email":"person-placeholder@example.invalid"},"weekly":{"usedPercent":40}}"#,
            #"{"signedOut":false,"session":{"usedPercent":25,"name":"Person Placeholder"},"weekly":{"usedPercent":40}}"#,
            #"{"signedOut":false,"session":{"usedPercent":25,"id":"account-placeholder"},"weekly":{"usedPercent":40}}"#,
            #"{"signedOut":false,"session":{"usedPercent":25,"unknown":1},"weekly":{"usedPercent":40}}"#,
        ]

        for body in bodies {
            let snapshot = parse(body)
            XCTAssertEqual(snapshot.status, .error("Ollama 用量数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty, body)
        }
    }

    func testNumericPercentClampsAndUnsafeDatesAreDropped() throws {
        let snapshot = parse(#"{"signedOut":false,"session":{"usedPercent":-5,"resetsAt":true},"weekly":{"usedPercent":150,"resetsAt":"9999-12-31T23:59:59Z"}}"#)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.usedPercent), [0, 100])
        XCTAssertNil(snapshot.metrics.first?.resetsAt)
        XCTAssertEqual(snapshot.metrics.last?.resetsAt, iso("9999-12-31T23:59:59Z"))
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))

        let beyondFoundation = parse(#"{"signedOut":false,"weekly":{"usedPercent":1,"resetsAt":"+010000-01-01T00:00:00Z"}}"#)
        XCTAssertEqual(beyondFoundation.status, .ok)
        XCTAssertNil(beyondFoundation.metrics.first?.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(beyondFoundation))

        let preEpoch = parse(#"{"signedOut":false,"weekly":{"usedPercent":1,"resetsAt":"1969-12-31T23:59:59Z"}}"#)
        XCTAssertEqual(preEpoch.status, .ok)
        XCTAssertEqual(preEpoch.metrics.first?.usedPercent, 1)
        XCTAssertNil(preEpoch.metrics.first?.resetsAt)
        XCTAssertNil(preEpoch.persistenceValidationIssue)
        XCTAssertNoThrow(try JSONEncoder().encode(preEpoch))
    }

    func testSwiftParserRejectsCalendarInvalidISOWithoutDroppingUsage() throws {
        let cases: [(String, Bool)] = [
            ("2028-02-29T12:34:56Z", true),
            ("2027-02-29T12:34:56Z", false),
            ("2026-02-31T00:00:00Z", false),
            ("2026-13-01T00:00:00Z", false),
            ("2026-01-01T24:00:00Z", false),
        ]
        for (date, valid) in cases {
            let snapshot = parse("{\"signedOut\":false,\"session\":{\"usedPercent\":25,\"resetsAt\":\"\(date)\"}}")
            XCTAssertEqual(snapshot.status, .ok, date)
            XCTAssertEqual(snapshot.metrics.first?.usedPercent, 25, date)
            if valid {
                XCTAssertEqual(snapshot.metrics.first?.resetsAt, iso(date), date)
            } else {
                XCTAssertNil(snapshot.metrics.first?.resetsAt, date)
            }
        }
    }

    func testProductionBodyAndAppCompositionHaveRequiredPrivacyAndBudgetContract() throws {
        let block = OllamaProbeScript.body
        XCTAssertTrue(block.contains("const rawSettings = await __probe('/settings'"))
        XCTAssertTrue(block.contains("timeoutMs: 12000"))
        XCTAssertTrue(block.contains("retry: true"))
        XCTAssertTrue(block.contains("noAuth: true"))
        XCTAssertTrue(block.contains("rawSettings.finalURL"))
        XCTAssertTrue(block.contains("JSON.stringify"))
        XCTAssertFalse(block.contains("document.body"))
        XCTAssertFalse(block.contains("innerHTML"))
        XCTAssertFalse(block.contains("outerHTML"))

        let helper = ProviderProbeScript.helper
        let source = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("private static let probeHelper = ProviderProbeScript.helper"))
        XCTAssertTrue(source.contains("static let ollama = probeHelper + OllamaProbeScript.body"))
        XCTAssertTrue(helper.contains("const final = new URL(response.url)"))
        XCTAssertTrue(helper.contains("out.finalURL = final.origin + final.pathname"))
        XCTAssertFalse(helper.contains("out.finalURL = r.url"))
        XCTAssertFalse(helper.contains("out.finalURL = final.href"))
    }

    #if canImport(JavaScriptCore)
    func testActualProductionBodyExtractsSafeSummaryAndNeverBridgesIdentityOrQueryToken() throws {
        let html = try fixture("ollama_settings_normal")
        let queryToken = "authorization_session_id=secret-query-token"
        let execution = try executeProbeScript(
            body: html,
            finalURL: "https://ollama.com/settings?\(queryToken)#usage"
        )

        XCTAssertEqual(execution.fetchCalls.count, 1)
        let call = try XCTUnwrap(execution.fetchCalls.first)
        XCTAssertEqual(call["url"] as? String, "/settings")
        let options = try XCTUnwrap(call["options"] as? [String: Any])
        XCTAssertEqual(options["credentials"] as? String, "include")
        XCTAssertEqual(options["hasTimeoutMs"] as? Bool, false)
        XCTAssertEqual(options["hasRetry"] as? Bool, false)
        XCTAssertEqual(options["hasNoAuth"] as? Bool, false)
        XCTAssertEqual(options["hasSignal"] as? Bool, true)
        let headers = try XCTUnwrap(options["headers"] as? [String: Any])
        XCTAssertEqual(headers["Accept"] as? String, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        XCTAssertNil(headers["Authorization"], "noAuth 必须阻止 helper 附加 localStorage token")
        XCTAssertTrue(execution.timers.contains(12_000))
        XCTAssertEqual(execution.probeResults.first?["finalURL"] as? String, "https://ollama.com/settings")

        let probe = try probe(execution.probes)
        XCTAssertEqual(probe.status, 200)
        let safe = try object(probe.body)
        XCTAssertEqual(safe["plan"] as? String, "pro")
        XCTAssertEqual(safe["signedOut"] as? Bool, false)
        XCTAssertEqual((safe["session"] as? [String: Any])?["usedPercent"] as? Double, 12.5)
        XCTAssertEqual((safe["weekly"] as? [String: Any])?["usedPercent"] as? Double, 34)
        XCTAssertNil(execution.probes["finalURL"])

        let bridged = try jsonString(execution.probes)
        for sensitive in [
            "person-placeholder@example.invalid",
            "Person Placeholder",
            queryToken,
            "secret-query-token",
            "<html>",
        ] {
            XCTAssertTrue(html.contains(sensitive) || sensitive.contains("query"), "fixture/URL 必须覆盖敏感值：\(sensitive)")
            XCTAssertFalse(bridged.contains(sensitive), sensitive)
        }

        let snapshot = OllamaParser.parse(results: ["settings": probe], now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Ollama Pro")
        XCTAssertEqual(snapshot.metrics.map(\.id), ["session", "weekly"])
    }

    func testActualProductionBodyHandlesHourlyWidthCaseAndUsageBlockBoundaries() throws {
        let hourly = try executeProbeScript(body: try fixture("ollama_settings_hourly"))
        let hourlyBody = try probe(hourly.probes).body
        let hourlySnapshot = OllamaParser.parse(
            results: ["settings": ProbeResult(status: 200, body: hourlyBody)],
            now: now
        )
        XCTAssertEqual(hourlySnapshot.status, .ok)
        XCTAssertEqual(hourlySnapshot.planName, "Ollama Max")
        XCTAssertEqual(hourlySnapshot.metrics.map(\.id), ["session"])
        XCTAssertEqual(hourlySnapshot.metrics.first?.label, "Hourly usage")
        XCTAssertEqual(hourlySnapshot.metrics.first?.usedPercent, 7.25)

        let boundary = "<span>Session usage</span><span>Weekly usage</span><span>88% used</span>"
        let boundaryResult = try executeProbeScript(body: boundary)
        let boundarySummary = try object(try probe(boundaryResult.probes).body)
        XCTAssertNil(boundarySummary["session"])
        XCTAssertEqual((boundarySummary["weekly"] as? [String: Any])?["usedPercent"] as? Double, 88)

        let longBlock = "<span>Session usage</span>" + String(repeating: "x", count: 4_001) + "22% used"
        let longResult = try executeProbeScript(body: longBlock)
        let longSummary = try object(try probe(longResult.probes).body)
        XCTAssertNil(longSummary["session"])
        XCTAssertEqual(OllamaParser.parse(results: ["settings": try probe(longResult.probes)], now: now).status, .error("Ollama 用量数据异常"))
    }

    func testActualProductionBodyRejectsPartialOrSignedPercentTokens() throws {
        let invalidTokens = [
            "-5% used",
            "+5% used",
            ".5% used",
            "1e2% used",
            #"style="width:-5%""#,
        ]
        for token in invalidTokens {
            let html = "<span>Session usage</span><b>\(token)</b><span>Weekly usage</span><b>40% used</b>"
            let execution = try executeProbeScript(body: html)
            let summary = try object(try probe(execution.probes).body)
            XCTAssertNil(summary["session"], token)
            XCTAssertEqual((summary["weekly"] as? [String: Any])?["usedPercent"] as? Double, 40, token)
        }

        let valid = try executeProbeScript(
            body: #"<span>Session usage</span><strong>(12.5% used)</strong><span>Weekly usage</span><div style="width: 33.3%; color:red"></div>"#
        )
        let summary = try object(try probe(valid.probes).body)
        XCTAssertEqual((summary["session"] as? [String: Any])?["usedPercent"] as? Double, 12.5)
        XCTAssertEqual((summary["weekly"] as? [String: Any])?["usedPercent"] as? Double, 33.3)
    }

    func testActualProductionBodyRejectsCalendarInvalidDatesButKeepsLeapDay() throws {
        let cases: [(String, Bool)] = [
            ("2028-02-29T12:34:56Z", true),
            ("2027-02-29T12:34:56Z", false),
            ("2026-02-31T00:00:00Z", false),
            ("2026-13-01T00:00:00Z", false),
            ("2026-01-01T24:00:00Z", false),
        ]
        for (date, valid) in cases {
            let html = #"<span>Session usage</span><b>25% used</b><time data-time="\#(date)"></time>"#
            let execution = try executeProbeScript(body: html)
            let session = try XCTUnwrap(try object(try probe(execution.probes).body)["session"] as? [String: Any])
            XCTAssertEqual(session["usedPercent"] as? Double, 25, date)
            XCTAssertEqual(session["resetsAt"] as? String, valid ? date : nil, date)
        }
    }

    func testFullProductionHelperRetriesTransientResponseAndStillReturnsOnlySafeSummary() throws {
        let sensitiveFailure = "<html>first-attempt-placeholder@example.invalid Secret First Attempt</html>"
        let success = try fixture("ollama_settings_normal")
        let execution = try executeProbeScript(
            body: success,
            responseSequence: [
                ["status": 503, "body": sensitiveFailure, "url": "https://ollama.com/settings?token=first-secret#failure"],
                ["status": 200, "body": success, "url": "https://ollama.com/settings?token=second-secret#ok"],
            ]
        )

        XCTAssertEqual(execution.fetchCalls.count, 2)
        XCTAssertTrue(execution.timers.contains(300))
        XCTAssertTrue(execution.timers.contains(12_000))
        XCTAssertEqual(execution.probeResults.first?["finalURL"] as? String, "https://ollama.com/settings")
        XCTAssertNil(execution.probes["finalURL"])

        let probe = try probe(execution.probes)
        XCTAssertEqual(probe.status, 200)
        let safe = try object(probe.body)
        XCTAssertEqual(safe["plan"] as? String, "pro")
        XCTAssertEqual(safe["signedOut"] as? Bool, false)
        XCTAssertEqual((safe["session"] as? [String: Any])?["usedPercent"] as? Double, 12.5)
        XCTAssertEqual((safe["weekly"] as? [String: Any])?["usedPercent"] as? Double, 34)

        let bridged = try jsonString(execution.probes)
        for sensitive in [
            "first-attempt-placeholder@example.invalid",
            "Secret First Attempt",
            "first-secret",
            "second-secret",
            "person-placeholder@example.invalid",
            "Person Placeholder",
            "<html>",
        ] {
            XCTAssertFalse(bridged.contains(sensitive), sensitive)
        }

        let snapshot = OllamaParser.parse(results: ["settings": probe], now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Ollama Pro")
        XCTAssertEqual(snapshot.metrics.map(\.id), ["session", "weekly"])
    }

    func testActualProductionBodyClassifiesAllSafeFinalURLSignInShapes() throws {
        let usage = try fixture("ollama_settings_normal")
        let signInURLs = [
            "https://ollama.com/signin",
            "https://ollama.com/signin/",
            "https://www.ollama.com/signin?return_to=%2Fsettings",
            "https://signin.ollama.com/",
            "https://signin.ollama.com/callback?authorization_session_id=secret-query-token",
            "https://api.workos.com/user_management/authorize?client_id=placeholder&authorization_session_id=secret-query-token",
            "https://auth.workos.com/user_management/authorize/continue?client_id=placeholder",
        ]
        for raw in signInURLs {
            let execution = try executeProbeScript(body: usage, finalURL: raw)
            let probe = try probe(execution.probes)
            XCTAssertEqual(probe.status, 200, raw)
            let summary = try object(probe.body)
            XCTAssertEqual(summary["signedOut"] as? Bool, true, raw)
            XCTAssertEqual(Set(summary.keys), ["signedOut"], raw)
            XCTAssertNil(execution.probes["finalURL"], raw)
            let bridged = try jsonString(execution.probes)
            for sensitive in ["secret-query-token", "authorization_session_id", "person-placeholder@example.invalid", "<html>"] {
                XCTAssertFalse(bridged.contains(sensitive), "\(raw) leaked \(sensitive)")
            }
            XCTAssertEqual(
                OllamaParser.parse(results: ["settings": probe], now: now).status,
                .needsLogin,
                raw
            )
        }

        let ordinaryURLs = [
            "https://ollama.com/settings",
            "https://www.ollama.com/settings",
            "https://ollama.com/signin-something",
            "https://example.com/signin",
            "https://evilworkos.com/user_management/authorize",
            "https://workos.com/user_management/authorize",
            "https://api.workos.com/other",
            "http://ollama.com/signin",
        ]
        for raw in ordinaryURLs {
            let execution = try executeProbeScript(body: usage, finalURL: raw)
            let probe = try probe(execution.probes)
            let summary = try object(probe.body)
            XCTAssertEqual(summary["signedOut"] as? Bool, false, raw)
            XCTAssertEqual((summary["session"] as? [String: Any])?["usedPercent"] as? Double, 12.5, raw)
            XCTAssertEqual(
                OllamaParser.parse(results: ["settings": probe], now: now).status,
                .ok,
                raw
            )
        }
    }

    func testActualProductionBodyClassifiesStrongAuthSignalsButNotGenericSignInText() throws {
        let signedOut = try executeProbeScript(body: try fixture("ollama_settings_signed_out"))
        let signedOutSummary = try object(try probe(signedOut.probes).body)
        XCTAssertEqual(signedOutSummary["signedOut"] as? Bool, true)
        XCTAssertEqual(Set(signedOutSummary.keys), ["signedOut"])
        XCTAssertEqual(
            OllamaParser.parse(results: ["settings": try probe(signedOut.probes)], now: now).status,
            .needsLogin
        )

        let strongSignals = [
            #"<form><h1>Sign in to Ollama</h1><input type="email" name="email"></form>"#,
            #"<form><h1>Log in to Ollama</h1><input type="password" name="password"></form>"#,
            #"<form action="/api/auth/signin"><button>Continue</button></form>"#,
            #"<form><a href="/signin">Continue</a></form>"#,
            #"<form><input type="email" name="email"><input type="password" name="password"></form>"#,
        ]
        for html in strongSignals {
            let execution = try executeProbeScript(body: html + #"<span>Weekly usage</span><span>4% used</span>"#)
            let summary = try object(try probe(execution.probes).body)
            XCTAssertEqual(summary["signedOut"] as? Bool, true, html)
            XCTAssertNil(summary["weekly"], html)
        }

        let generic = try executeProbeScript(body: try fixture("ollama_settings_generic_signin"))
        let genericSummary = try object(try probe(generic.probes).body)
        XCTAssertEqual(genericSummary["signedOut"] as? Bool, false)
        XCTAssertEqual((genericSummary["weekly"] as? [String: Any])?["usedPercent"] as? Double, 4)
        XCTAssertEqual(
            OllamaParser.parse(results: ["settings": try probe(generic.probes)], now: now).status,
            .ok
        )

        let weakSignals = [
            #"<p>Sign in to Ollama</p><span>Weekly usage</span><span>4% used</span>"#,
            #"<form><h1>Sign in to Ollama</h1></form><span>Weekly usage</span><span>4% used</span>"#,
            #"<article>Please sign in to continue</article><span>Weekly usage</span><span>4% used</span>"#,
        ]
        for html in weakSignals {
            let execution = try executeProbeScript(body: html)
            let summary = try object(try probe(execution.probes).body)
            XCTAssertEqual(summary["signedOut"] as? Bool, false, html)
            XCTAssertEqual((summary["weekly"] as? [String: Any])?["usedPercent"] as? Double, 4, html)
        }
    }

    func testActualProductionBodyRedactsFailuresAndRejectsMissingUsage() throws {
        let identityHTML = try fixture("ollama_settings_normal")
        let failed = try executeProbeScript(status: 500, body: identityHTML)
        XCTAssertEqual(try probe(failed.probes), ProbeResult(status: 500, body: "{}"))
        XCTAssertFalse(try jsonString(failed.probes).contains("person-placeholder"))
        XCTAssertFalse(try jsonString(failed.probes).contains("<html>"))
        XCTAssertEqual(
            OllamaParser.parse(results: ["settings": try probe(failed.probes)], now: now).status,
            .error("HTTP 500")
        )

        let unauthorized = try executeProbeScript(status: 401, body: identityHTML)
        XCTAssertEqual(try probe(unauthorized.probes), ProbeResult(status: 401, body: "{}"))
        XCTAssertEqual(
            OllamaParser.parse(results: ["settings": try probe(unauthorized.probes)], now: now).status,
            .needsLogin
        )

        let empty = try executeProbeScript(body: "<html>Cloud Usage person-placeholder@example.invalid</html>")
        let emptySummary = try object(try probe(empty.probes).body)
        XCTAssertEqual(emptySummary["signedOut"] as? Bool, false)
        XCTAssertNil(emptySummary["session"])
        XCTAssertNil(emptySummary["weekly"])
        XCTAssertFalse(try jsonString(empty.probes).contains("person-placeholder@example.invalid"))
        XCTAssertEqual(
            OllamaParser.parse(results: ["settings": try probe(empty.probes)], now: now).status,
            .error("Ollama 用量数据异常")
        )
    }
    #endif

    private func parse(_ body: String, status: Int = 200) -> ProviderSnapshot {
        OllamaParser.parse(results: ["settings": ProbeResult(status: status, body: body)], now: now)
    }

    private func iso(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func providerScriptsURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    #if canImport(JavaScriptCore)
    private struct ScriptExecution {
        let probes: [String: Any]
        let probeResults: [[String: Any]]
        let fetchCalls: [[String: Any]]
        let timers: [Int]
    }

    private func executeProbeScript(
        status: Int = 200,
        body: String,
        finalURL: String = "https://ollama.com/settings",
        responseSequence: [[String: Any]] = []
    ) throws -> ScriptExecution {
        let responses: [[String: Any]]
        if responseSequence.isEmpty {
            responses = [["status": status, "body": body, "url": finalURL]]
        } else {
            responses = responseSequence.map { item in
                var next = item
                if next["body"] == nil { next["body"] = body }
                if next["url"] == nil { next["url"] = finalURL }
                if next["status"] == nil { next["status"] = status }
                return next
            }
        }
        let responsesJSON = try jsonString(responses)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() }
        let script = """
        var __ollamaDone = false;
        var __ollamaResult = null;
        var __ollamaError = null;
        var __ollamaRequested = [];
        var __ollamaFetchCalls = [];
        var __ollamaTimers = [];
        var __ollamaProbeResults = [];
        var __ollamaResponses = \(responsesJSON);
        var __ollamaIndex = 0;
        var localStorage = {
            getItem: function (key) { return key === 'access_token' ? 'secret-local-storage-token' : null; }
        };
        var document = { cookie: 'token=cookie-placeholder-token' };
        function AbortController() {
            this.signal = { aborted: false };
            this.abort = function () { this.signal.aborted = true; };
        }
        function setTimeout(callback, delay) {
            __ollamaTimers.push(delay);
            if (delay === 300) { callback(); }
            return __ollamaTimers.length;
        }
        function clearTimeout(identifier) {}
        function URL(raw) {
            const match = String(raw).match(/^([a-z]+:[/][/][^/?#]+)([/][^?#]*)?/i);
            if (!match) { throw new Error('invalid URL'); }
            this.origin = match[1];
            this.pathname = match[2] || '/';
        }
        async function fetch(url, options) {
            const index = Math.min(__ollamaIndex, __ollamaResponses.length - 1);
            const response = __ollamaResponses[index];
            __ollamaIndex += 1;
            __ollamaFetchCalls.push({
                url: url,
                options: {
                    credentials: options.credentials,
                    method: options.method || 'GET',
                    headers: Object.assign({}, options.headers || {}),
                    body: options.body,
                    hasTimeoutMs: Object.prototype.hasOwnProperty.call(options, 'timeoutMs'),
                    hasNoAuth: Object.prototype.hasOwnProperty.call(options, 'noAuth'),
                    hasRetry: Object.prototype.hasOwnProperty.call(options, 'retry'),
                    hasSignal: Object.prototype.hasOwnProperty.call(options, 'signal')
                }
            });
            return {
                status: response.status,
                url: response.url || 'https://ollama.com/settings',
                headers: { get: function (name) { return null; } },
                text: async function () { return response.body; }
            };
        }
        \(ProviderProbeScript.helper)
        const __ollamaProductionProbe = __probe;
        __probe = async function (url, options) {
            __ollamaRequested.push({ url: url, options: options });
            const result = await __ollamaProductionProbe(url, options);
            __ollamaProbeResults.push(result);
            return result;
        };
        (async function () {
        \(OllamaProbeScript.body)
        })().then(function (value) {
            __ollamaResult = JSON.stringify({
                probes: value.probes,
                probeResults: __ollamaProbeResults,
                fetchCalls: __ollamaFetchCalls,
                timers: __ollamaTimers
            });
            __ollamaDone = true;
        }, function (error) {
            __ollamaError = String(error && error.stack ? error.stack : error);
            __ollamaDone = true;
        });
        """
        context.evaluateScript(script)

        let deadline = Date().addingTimeInterval(2)
        while context.objectForKeyedSubscript("__ollamaDone")?.toBool() != true, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let exception {
            throw NSError(domain: "OllamaProbeScriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: exception])
        }
        guard context.objectForKeyedSubscript("__ollamaDone")?.toBool() == true else {
            throw NSError(domain: "OllamaProbeScriptTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "JavaScript Promise timed out"])
        }
        if let error = context.objectForKeyedSubscript("__ollamaError")?.toString(), error != "null" {
            throw NSError(domain: "OllamaProbeScriptTests", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
        }
        let raw = try XCTUnwrap(context.objectForKeyedSubscript("__ollamaResult")?.toString())
        let root = try object(raw)
        return ScriptExecution(
            probes: try XCTUnwrap(root["probes"] as? [String: Any]),
            probeResults: try XCTUnwrap(root["probeResults"] as? [[String: Any]]),
            fetchCalls: try XCTUnwrap(root["fetchCalls"] as? [[String: Any]]),
            timers: try XCTUnwrap(root["timers"] as? [Int])
        )
    }

    private func probe(_ probes: [String: Any], named name: String = "settings") throws -> ProbeResult {
        let raw = try XCTUnwrap(probes[name] as? [String: Any])
        let status = try XCTUnwrap(raw["status"] as? NSNumber)
        return ProbeResult(status: status.intValue, body: try XCTUnwrap(raw["body"] as? String))
    }

    private func object(_ body: String) throws -> [String: Any] {
        let data = try XCTUnwrap(body.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonString(_ value: Any) throws -> String {
        if JSONSerialization.isValidJSONObject(value) {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        let data = try JSONSerialization.data(withJSONObject: [value], options: [])
        let wrapped = try XCTUnwrap(String(data: data, encoding: .utf8))
        return String(wrapped.dropFirst().dropLast())
    }
    #endif
}

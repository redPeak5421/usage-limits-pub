import XCTest
@testable import UsageLimitsCore

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class NotionParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testParsesSafeWorkspaceSummaryAndBothAllowanceWindows() throws {
        let snapshot = parse(
            spaces: spacesSummary(tier: "business"),
            credit: try fixture("notion_credit_limit")
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Notion AI Business")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["rolling", "billing_period"])

        let rolling = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(rolling.label, "Rolling（6 小时）")
        XCTAssertEqual(rolling.usedPercent, 50)
        XCTAssertEqual(rolling.remaining, 25)
        XCTAssertEqual(rolling.total, 50)
        XCTAssertEqual(rolling.resetsAt, now, "resetsInSeconds == 0 必须保留")
        XCTAssertNil(rolling.detail)
        XCTAssertEqual(rolling.pinned, true)

        let billing = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(billing.label, "Billing Period")
        XCTAssertEqual(billing.usedPercent, 18)
        XCTAssertEqual(billing.remaining, 82)
        XCTAssertEqual(billing.total, 100)
        XCTAssertEqual(billing.resetsAt, Date(timeIntervalSince1970: 1_788_000_000))
        XCTAssertNil(billing.detail)
        XCTAssertEqual(billing.pinned, true)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testParsesAllowlistedEnterpriseTier() throws {
        let snapshot = parse(
            spaces: spacesSummary(tier: "enterprise"),
            credit: try fixture("notion_credit_limit")
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Notion AI Enterprise")
    }

    func testWorkspaceSummaryMayOmitUnknownTierWithoutInventingAPlan() throws {
        let snapshot = parse(spaces: spacesSummary(tier: nil), credit: try fixture("notion_credit_limit"))

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
    }

    func testBusinessSummaryMapsToBusinessPlan() throws {
        let snapshot = parse(
            spaces: spacesSummary(tier: "business"),
            credit: try fixture("notion_credit_limit")
        )

        XCTAssertEqual(snapshot.planName, "Notion AI Business")
    }

    func testSafeSummaryWithoutWorkspaceIsAnExplicitError() throws {
        let snapshot = parse(spaces: spacesSummary(hasWorkspace: false), credit: nil)

        XCTAssertEqual(snapshot.status, .error("未找到 Notion workspace"))
        XCTAssertTrue(snapshot.metrics.isEmpty)
    }

    func testSafeSummaryTypeDriftAndUnknownFieldsAreRejected() throws {
        let invalidSummaries = [
            #"{}"#,
            #"{"hasWorkspace":"true","subscriptionTier":"business"}"#,
            #"{"hasWorkspace":1,"subscriptionTier":"business"}"#,
            #"{"hasWorkspace":true,"subscriptionTier":true}"#,
            #"{"hasWorkspace":true,"subscriptionTier":"Business"}"#,
            #"{"hasWorkspace":true,"subscriptionTier":"team_plan"}"#,
            #"{"hasWorkspace":true,"subscriptionTier":"business","workspaceId":"workspace-secret"}"#,
            #"{"hasWorkspace":false,"subscriptionTier":"business"}"#,
        ]

        for summary in invalidSummaries {
            let snapshot = parse(spaces: summary, credit: nil)
            XCTAssertEqual(snapshot.status, .error("Notion workspace 摘要异常"), summary)
            XCTAssertTrue(snapshot.metrics.isEmpty, summary)
        }
    }

    func testNotApplicableIsNotZeroUsageOrLogin() throws {
        let snapshot = parse(
            spaces: spacesSummary(tier: "business"),
            credit: #"{"status":"not_applicable"}"#
        )

        XCTAssertEqual(snapshot.status, .error("当前 workspace 不适用 Notion AI 额度"))
        XCTAssertTrue(snapshot.metrics.isEmpty)
    }

    func testOnlyHTTP401NeedsLoginWhile403AndOtherFailuresStayErrors() throws {
        let spaces = spacesSummary(tier: "business")
        let credit = try fixture("notion_credit_limit")

        XCTAssertEqual(parse(spaces: "", credit: nil, spacesStatus: 401).status, .needsLogin)
        XCTAssertEqual(parse(spaces: "", credit: nil, spacesStatus: 403).status, .error("HTTP 403"))
        XCTAssertEqual(parse(spaces: spaces, credit: "", creditStatus: 401).status, .needsLogin)
        XCTAssertEqual(parse(spaces: spaces, credit: "", creditStatus: 403).status, .error("HTTP 403"))
        XCTAssertEqual(parse(spaces: "timeout", credit: nil, spacesStatus: -3).status, .error("请求超时"))
        XCTAssertEqual(parse(spaces: spaces, credit: "unavailable", creditStatus: 503).status, .error("HTTP 503"))
        XCTAssertEqual(parse(spaces: spaces, credit: credit, creditStatus: 200).status, .ok)
    }

    func testNegativeProbeStatusesNeverEchoRedactedBodies() {
        let spaces = spacesSummary(tier: "business")

        XCTAssertEqual(parse(spaces: "{}", credit: nil, spacesStatus: -1).status, .error("网络错误"))
        XCTAssertEqual(parse(spaces: "{}", credit: nil, spacesStatus: -3).status, .error("请求超时"))
        XCTAssertEqual(parse(spaces: spaces, credit: "{}", creditStatus: -1).status, .error("网络错误"))
        XCTAssertEqual(parse(spaces: spaces, credit: "{}", creditStatus: -3).status, .error("请求超时"))
    }

    func testMissingResponsesAndMalformedJSONAreExplicitErrors() throws {
        XCTAssertEqual(NotionParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
        XCTAssertEqual(
            NotionParser.parse(
                results: ["credit_limit": ProbeResult(status: 200, body: try fixture("notion_credit_limit"))],
                now: now
            ).status,
            .error("未获取到 Notion workspace 响应")
        )
        XCTAssertEqual(parse(spaces: "not json", credit: nil).status, .error("Notion workspace 摘要异常"))
        XCTAssertEqual(
            parse(spaces: spacesSummary(tier: "business"), credit: nil).status,
            .error("未获取到 Notion AI 额度响应")
        )
        XCTAssertEqual(
            parse(spaces: spacesSummary(tier: "business"), credit: "not json").status,
            .error("Notion AI 额度数据异常")
        )
        XCTAssertEqual(
            parse(spaces: spacesSummary(tier: "business"), credit: "{}").status,
            .error("Notion AI 额度数据异常")
        )
    }

    func testInvalidNumbersAreRejectedAndNeverLeakIntoSnapshot() throws {
        let spaces = spacesSummary(tier: "business")
        let badWindowValues = [
            #"{"window":{"used":true,"limit":100}}"#,
            #"{"window":{"used":"25","limit":100}}"#,
            #"{"window":{"used":-1,"limit":100}}"#,
            #"{"window":{"used":25,"limit":false}}"#,
            #"{"window":{"used":25,"limit":"NaN"}}"#,
            #"{"window":{"used":25,"limit":"Infinity"}}"#,
            #"{"window":{"used":25,"limit":0}}"#,
        ]

        for body in badWindowValues {
            let snapshot = parse(spaces: spaces, credit: body)
            XCTAssertEqual(snapshot.status, .error("Notion AI 额度数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty, body)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot), body)
        }
    }

    func testPercentagesClampButCountsUseReportedNonHundredLimit() throws {
        let body = #"{"window":{"window":"30m","used":75,"limit":50},"resetsInSeconds":60}"#
        let snapshot = parse(spaces: spacesSummary(tier: "business"), credit: body)
        let metric = try XCTUnwrap(snapshot.metrics.first)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(metric.label, "Rolling（30 分钟）")
        XCTAssertEqual(metric.usedPercent, 100)
        XCTAssertEqual(metric.remaining, 0)
        XCTAssertEqual(metric.total, 50)
        XCTAssertEqual(metric.resetsAt, now.addingTimeInterval(60))
    }

    func testWindowTokenOverflowAndUnsafeDatesAreDropped() throws {
        let body = #"{"window":{"window":"999999999999999999999w","used":1,"limit":2},"resetsInSeconds":1e308,"billingPeriodWindow":{"used":1,"limit":4,"periodEndMs":1e308}}"#
        let snapshot = parse(spaces: spacesSummary(tier: "business"), credit: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["rolling", "billing_period"])
        let rolling = try XCTUnwrap(snapshot.metrics.first)
        let billing = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(rolling.label, "Rolling")
        XCTAssertNil(rolling.resetsAt)
        XCTAssertNil(billing.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testWindowTokenLengthMatchesProbeNineDigitLimit() throws {
        let nineDigits = #"{"window":{"window":"999999999m","used":1,"limit":2}}"#
        let tenDigits = #"{"window":{"window":"1234567890m","used":1,"limit":2}}"#

        XCTAssertEqual(
            parse(spaces: spacesSummary(tier: "business"), credit: nineDigits).metrics.first?.label,
            "Rolling（999999999 分钟）"
        )
        XCTAssertEqual(
            parse(spaces: spacesSummary(tier: "business"), credit: tenDigits).metrics.first?.label,
            "Rolling"
        )
    }

    func testEachAllowanceWindowCanStandAlone() throws {
        let rollingOnly = #"{"status":"within_limit","window":{"window":"1d","used":1,"limit":4},"resetsInSeconds":3600}"#
        let billingOnly = #"{"status":"within_limit","billingPeriodWindow":{"cadence":"billing_period","used":3,"limit":4,"periodEndMs":1788000000000}}"#

        let rolling = parse(spaces: spacesSummary(tier: "business"), credit: rollingOnly)
        XCTAssertEqual(rolling.status, .ok)
        XCTAssertEqual(rolling.metrics.map(\.id), ["rolling"])
        XCTAssertEqual(rolling.metrics.first?.label, "Rolling（1 天）")

        let billing = parse(spaces: spacesSummary(tier: "business"), credit: billingOnly)
        XCTAssertEqual(billing.status, .ok)
        XCTAssertEqual(billing.metrics.map(\.id), ["billing_period"])
        XCTAssertEqual(billing.metrics.first?.usedPercent, 75)
    }

    func testBadOptionalWindowDoesNotSuppressTheOtherValidWindow() throws {
        let body = #"{"window":{"window":"6h","used":true,"limit":100},"billingPeriodWindow":{"used":2,"limit":8,"periodEndMs":1788000000000}}"#
        let snapshot = parse(spaces: spacesSummary(tier: "business"), credit: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["billing_period"])
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 25)
    }

    func testPersistableProbeResultsAndSnapshotNeverContainRawWorkspaceIdentity() throws {
        let rawSpaces = try fixture("notion_spaces_double")
        let sensitiveValues = [
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "11111111-2222-3333-4444-555555555555",
            "99999999-8888-7777-6666-555555555555",
            "person-placeholder@example.invalid",
            "Person Placeholder",
            "Workspace Business Placeholder",
        ]
        for value in sensitiveValues {
            XCTAssertTrue(rawSpaces.contains(value), "fixture 必须真实覆盖敏感字段：\(value)")
        }

        let persistedResults = [
            "spaces": ProbeResult(status: 200, body: spacesSummary(tier: "business")),
            "credit_limit": ProbeResult(status: 200, body: safeCreditSummary()),
        ]
        let snapshot = NotionParser.parse(results: persistedResults, now: now)
        let encodedResults = String(decoding: try JSONEncoder().encode(persistedResults), as: UTF8.self)
        let encodedSnapshot = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertEqual(snapshot.status, .ok)
        for value in sensitiveValues {
            XCTAssertFalse(encodedResults.contains(value), value)
            XCTAssertFalse(encodedSnapshot.contains(value), value)
        }
    }

    func testProbeUsesOneDeterministicallySelectedWorkspaceWithinBudget() throws {
        let block = NotionProbeScript.body

        XCTAssertEqual(block.components(separatedBy: "/api/v3/getSpaces").count - 1, 1)
        XCTAssertEqual(block.components(separatedBy: "/api/v3/getCreditRateLimitStatus").count - 1, 1)
        XCTAssertTrue(block.contains("method: 'POST'"))
        XCTAssertTrue(block.contains("'Accept': '*/*'"))
        XCTAssertTrue(block.contains("'Content-Type': 'application/json'"))
        XCTAssertTrue(block.contains("body: '{}'"))
        XCTAssertTrue(block.contains("body: JSON.stringify({ spaceId: selected.id })"))
        XCTAssertEqual(block.components(separatedBy: "noAuth: true").count - 1, 2)
        XCTAssertTrue(block.contains("timeoutMs: 7000"))
        XCTAssertTrue(block.contains("timeoutMs: 8000"))
        XCTAssertTrue(block.contains("retry: false"))
        XCTAssertTrue(block.contains("const rawSpaces = await __probe"))
        XCTAssertTrue(block.contains("const rawCredit = await __probe"))
        XCTAssertTrue(block.contains("JSON.parse(rawSpaces.body)"))
        XCTAssertTrue(block.contains("JSON.parse(rawCredit.body)"))
        XCTAssertTrue(block.contains("__notionResolveUserKey"))
        XCTAssertTrue(block.contains("__notionSelectWorkspace"))
        XCTAssertTrue(block.contains("__notionSafeTier"))
        XCTAssertTrue(block.contains("['free', 'plus', 'business', 'enterprise']"))
        XCTAssertTrue(block.contains("Object.keys(spaces).sort()"))
        XCTAssertTrue(block.contains("tier === 'business' || tier === 'enterprise'"))
        XCTAssertTrue(block.contains("JSON.stringify({ hasWorkspace: false })"))
        XCTAssertFalse(block.contains("probes.spaces = await __probe"))
        XCTAssertFalse(block.contains("probes.credit_limit = await __probe"))
        XCTAssertFalse(block.contains("probes.spaces = rawSpaces"))
        XCTAssertFalse(block.contains("probes.credit_limit = rawCredit"))
        XCTAssertFalse(block.contains("body: rawSpaces.body"))
        XCTAssertFalse(block.contains("body: rawCredit.body"))
        XCTAssertFalse(block.contains("creditType"))
        XCTAssertFalse(block.contains("enforcement"))
        XCTAssertFalse(block.contains("source.scope"))
        XCTAssertFalse(block.contains("ids.length < 5"))
        XCTAssertFalse(block.contains("const limits = {}"))
    }

    func testAppComposesNotionProbeFromCoreOwnedBody() throws {
        let source = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("static let notion = probeHelper + NotionProbeScript.body"))
    }

    #if canImport(JavaScriptCore)
    func testActualProbeScriptSelectsBusinessFromDoubleWrappedFixtureAndRedactsOutput() throws {
        let rawSpaces = try fixture("notion_spaces_double")
        let rawCredit = #"{"status":"within_limit","accountEmail":"credit-placeholder@example.invalid","workspaceId":"99999999-8888-7777-6666-555555555555","name":"Credit Name Placeholder","window":{"creditType":"basic_ai_credits","scope":"per_user","window":"6h","used":25,"limit":50},"resetsInSeconds":0,"billingPeriodWindow":{"cadence":"billing_period","used":18,"limit":100,"periodEndMs":1788000000000},"enforcement":"preview"}"#
        let execution = try executeProbeScript(spacesBody: rawSpaces, creditBody: rawCredit)

        XCTAssertEqual(execution.calls.count, 2)
        let spacesProbe = try probe(execution.probes, named: "spaces")
        XCTAssertEqual(spacesProbe.status, 200)
        XCTAssertEqual(try object(spacesProbe.body)["hasWorkspace"] as? Bool, true)
        XCTAssertEqual(try object(spacesProbe.body)["subscriptionTier"] as? String, "business")

        let firstCall = try XCTUnwrap(execution.calls.first)
        XCTAssertEqual(firstCall["url"] as? String, "/api/v3/getSpaces")
        let firstOptions = try XCTUnwrap(firstCall["options"] as? [String: Any])
        XCTAssertEqual(firstOptions["method"] as? String, "POST")
        XCTAssertEqual(firstOptions["body"] as? String, "{}")
        XCTAssertEqual((firstOptions["timeoutMs"] as? NSNumber)?.intValue, 7_000)
        XCTAssertEqual(firstOptions["retry"] as? Bool, true)
        XCTAssertEqual(firstOptions["noAuth"] as? Bool, true)
        let firstHeaders = try XCTUnwrap(firstOptions["headers"] as? [String: Any])
        XCTAssertEqual(firstHeaders["Accept"] as? String, "*/*")
        XCTAssertEqual(firstHeaders["Content-Type"] as? String, "application/json")

        let secondCall = try XCTUnwrap(execution.calls.last)
        XCTAssertEqual(secondCall["url"] as? String, "/api/v3/getCreditRateLimitStatus")
        let secondOptions = try XCTUnwrap(secondCall["options"] as? [String: Any])
        XCTAssertEqual((secondOptions["timeoutMs"] as? NSNumber)?.intValue, 8_000)
        XCTAssertEqual(secondOptions["retry"] as? Bool, false)
        XCTAssertEqual(secondOptions["noAuth"] as? Bool, true)
        XCTAssertEqual(
            try object(try XCTUnwrap(secondOptions["body"] as? String))["spaceId"] as? String,
            "99999999-8888-7777-6666-555555555555"
        )

        let creditProbe = try probe(execution.probes, named: "credit_limit")
        let safeCredit = try object(creditProbe.body)
        XCTAssertEqual((safeCredit["window"] as? [String: Any])?["window"] as? String, "6h")
        XCTAssertNil((safeCredit["window"] as? [String: Any])?["creditType"])
        XCTAssertNil(safeCredit["enforcement"])

        let encodedProbes = try jsonString(execution.probes)
        for sensitive in [
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "11111111-2222-3333-4444-555555555555",
            "99999999-8888-7777-6666-555555555555",
            "person-placeholder@example.invalid",
            "Person Placeholder",
            "Workspace Business Placeholder",
            "credit-placeholder@example.invalid",
            "Credit Name Placeholder",
        ] {
            XCTAssertFalse(encodedProbes.contains(sensitive), sensitive)
        }

        let snapshot = NotionParser.parse(results: try probeResults(execution.probes), now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Notion AI Business")
        XCTAssertEqual(snapshot.metrics.map(\.id), ["rolling", "billing_period"])
    }

    func testActualProbeScriptUnwrapsSingleValueRecords() throws {
        let execution = try executeProbeScript(
            spacesBody: try fixture("notion_spaces_single"),
            creditBody: safeCreditSummary()
        )

        XCTAssertEqual(execution.calls.count, 2)
        let summary = try object(try probe(execution.probes, named: "spaces").body)
        XCTAssertEqual(summary["subscriptionTier"] as? String, "enterprise")
        let options = try XCTUnwrap(execution.calls.last?["options"] as? [String: Any])
        XCTAssertEqual(
            try object(try XCTUnwrap(options["body"] as? String))["spaceId"] as? String,
            "workspace-enterprise"
        )
        XCTAssertFalse(try jsonString(execution.probes).contains("workspace-enterprise"))
    }

    func testActualProbeScriptRejectsAmbiguousMultiUserWithoutCreditRequest() throws {
        let rawSpaces = try fixture("notion_spaces_multi")
        let execution = try executeProbeScript(spacesBody: rawSpaces, creditBody: safeCreditSummary())

        XCTAssertEqual(execution.calls.count, 1)
        XCTAssertNil(execution.probes["credit_limit"])
        let summary = try object(try probe(execution.probes, named: "spaces").body)
        XCTAssertEqual(summary["hasWorkspace"] as? Bool, false)
        let encoded = try jsonString(execution.probes)
        for value in [
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
            "first-placeholder@example.invalid",
            "second-placeholder@example.invalid",
        ] {
            XCTAssertTrue(rawSpaces.contains(value))
            XCTAssertFalse(encoded.contains(value))
        }
    }

    func testActualProbeScriptRedactsFailureBodiesAndPreservesStatus() throws {
        let spacesFailure = try executeProbeScript(
            spacesStatus: 403,
            spacesBody: #"{"email":"failure-placeholder@example.invalid"}"#,
            creditBody: "{}"
        )
        XCTAssertEqual(spacesFailure.calls.count, 1)
        XCTAssertEqual(try probe(spacesFailure.probes, named: "spaces"), ProbeResult(status: 403, body: "{}"))
        XCTAssertFalse(try jsonString(spacesFailure.probes).contains("failure-placeholder@example.invalid"))

        let creditFailure = try executeProbeScript(
            spacesBody: try fixture("notion_spaces_double"),
            creditStatus: 403,
            creditBody: #"{"workspaceId":"99999999-8888-7777-6666-555555555555","name":"failure"}"#
        )
        XCTAssertEqual(creditFailure.calls.count, 2)
        XCTAssertEqual(try probe(creditFailure.probes, named: "credit_limit"), ProbeResult(status: 403, body: "{}"))
        let encoded = try jsonString(creditFailure.probes)
        XCTAssertFalse(encoded.contains("99999999-8888-7777-6666-555555555555"))
        XCTAssertFalse(encoded.contains("failure"))
    }

    func testActualProbeAndParserBothRejectTenDigitWindowToken() throws {
        let rawCredit = #"{"status":"within_limit","window":{"window":"1234567890m","used":1,"limit":2}}"#
        let execution = try executeProbeScript(
            spacesBody: try fixture("notion_spaces_double"),
            creditBody: rawCredit
        )
        let credit = try object(try probe(execution.probes, named: "credit_limit").body)
        XCTAssertNil((credit["window"] as? [String: Any])?["window"])

        let snapshot = NotionParser.parse(results: try probeResults(execution.probes), now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.label, "Rolling")
    }
    #endif

    private func parse(
        spaces: String,
        credit: String?,
        spacesStatus: Int = 200,
        creditStatus: Int = 200
    ) -> ProviderSnapshot {
        var results = ["spaces": ProbeResult(status: spacesStatus, body: spaces)]
        if let credit {
            results["credit_limit"] = ProbeResult(status: creditStatus, body: credit)
        }
        return NotionParser.parse(results: results, now: now)
    }

    #if canImport(JavaScriptCore)
    private struct ScriptExecution {
        let probes: [String: Any]
        let calls: [[String: Any]]
    }

    private func executeProbeScript(
        spacesStatus: Int = 200,
        spacesBody: String,
        creditStatus: Int = 200,
        creditBody: String
    ) throws -> ScriptExecution {
        let responses: [String: Any] = [
            "spaces": ["status": spacesStatus, "body": spacesBody],
            "credit": ["status": creditStatus, "body": creditBody],
        ]
        let responsesJSON = try jsonString(responses)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, error in
            exception = error?.toString()
        }
        let script = """
        var __notionDone = false;
        var __notionResult = null;
        var __notionError = null;
        var __notionCalls = [];
        var __notionResponses = \(responsesJSON);
        async function __probe(url, options) {
            __notionCalls.push({ url: url, options: options });
            return url.indexOf('getSpaces') >= 0 ? __notionResponses.spaces : __notionResponses.credit;
        }
        (async function () {
        \(NotionProbeScript.body)
        })().then(function (value) {
            __notionResult = JSON.stringify({ probes: value.probes, calls: __notionCalls });
            __notionDone = true;
        }, function (error) {
            __notionError = String(error && error.stack ? error.stack : error);
            __notionDone = true;
        });
        """
        context.evaluateScript(script)

        let deadline = Date().addingTimeInterval(2)
        while context.objectForKeyedSubscript("__notionDone")?.toBool() != true, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let exception {
            throw NSError(domain: "NotionProbeScriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: exception])
        }
        guard context.objectForKeyedSubscript("__notionDone")?.toBool() == true else {
            throw NSError(
                domain: "NotionProbeScriptTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "JavaScript Promise timed out"]
            )
        }
        if let error = context.objectForKeyedSubscript("__notionError")?.toString(), error != "null" {
            throw NSError(domain: "NotionProbeScriptTests", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
        }
        let result = try XCTUnwrap(context.objectForKeyedSubscript("__notionResult")?.toString())
        let root = try object(result)
        return ScriptExecution(
            probes: try XCTUnwrap(root["probes"] as? [String: Any]),
            calls: try XCTUnwrap(root["calls"] as? [[String: Any]])
        )
    }

    private func probe(_ probes: [String: Any], named name: String) throws -> ProbeResult {
        let raw = try XCTUnwrap(probes[name] as? [String: Any])
        let status = try XCTUnwrap(raw["status"] as? NSNumber)
        return ProbeResult(status: status.intValue, body: try XCTUnwrap(raw["body"] as? String))
    }

    private func probeResults(_ probes: [String: Any]) throws -> [String: ProbeResult] {
        try Dictionary(uniqueKeysWithValues: probes.keys.map { key in
            (key, try probe(probes, named: key))
        })
    }

    private func object(_ body: String) throws -> [String: Any] {
        let data = try XCTUnwrap(body.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
    #endif

    private func spacesSummary(tier: String? = nil, hasWorkspace: Bool = true) -> String {
        if let tier {
            return #"{"hasWorkspace":\#(hasWorkspace),"subscriptionTier":"\#(tier)"}"#
        }
        return #"{"hasWorkspace":\#(hasWorkspace)}"#
    }

    private func safeCreditSummary() -> String {
        #"{"status":"within_limit","window":{"window":"6h","used":25,"limit":50},"resetsInSeconds":0,"billingPeriodWindow":{"used":18,"limit":100,"periodEndMs":1788000000000}}"#
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
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
}

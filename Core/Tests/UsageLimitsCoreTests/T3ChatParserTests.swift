import XCTest
@testable import UsageLimitsCore

final class T3ChatParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_778_000_000)

    func testParsesNestedJSONLinesAndMapsBothWindows() throws {
        let snapshot = parse(body: try fixture("t3chat_customer"))

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["four_hour", "overage"])

        let primary = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(primary.label, "Base（4 小时）")
        XCTAssertEqual(primary.usedPercent, 12.5)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_779_366_216.92))
        XCTAssertEqual(primary.detail, "Base - max")
        XCTAssertEqual(primary.pinned, true)

        let overage = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(overage.label, "Overage")
        XCTAssertEqual(overage.usedPercent, 34.25)
        XCTAssertEqual(overage.resetsAt, Date(timeIntervalSince1970: 1_780_763_009))
        XCTAssertNil(overage.pinned)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testFallbackFieldsUseSecondsAndNormalizeSubTier() throws {
        let snapshot = parse(body: try fixture("t3chat_customer_fallback"))

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Team Plan")
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 5)
        XCTAssertEqual(snapshot.metrics.first?.resetsAt, Date(timeIntervalSince1970: 1_779_366_216))
        XCTAssertEqual(snapshot.metrics.last?.usedPercent, 65)
        XCTAssertEqual(snapshot.metrics.last?.resetsAt, Date(timeIntervalSince1970: 1_780_763_009))
    }

    func testGarbageLinesAreSkippedAndRecursiveCustomerLookupContinues() {
        let body = """
        not-json
        {"noise":[1,2,3]}
        {"outer":{"nested":[{"usageFourHourPercentage":20}]}}
        """
        let snapshot = parse(body: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["four_hour"])
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 20)
        XCTAssertEqual(snapshot.metrics.first?.detail, "Base")
    }

    func testOptionalOnlyCandidateDoesNotHideLaterPrimaryCustomer() {
        let body = """
        {"event":{"usageMonthPercentage":90}}
        {"result":{"usageFourHourPercentage":20,"usageMonthPercentage":30}}
        """
        let snapshot = parse(body: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 20)
        XCTAssertEqual(snapshot.metrics.last?.usedPercent, 30)
    }

    func testMalformedPrimaryCandidateBeforeValidLineDoesNotWin() {
        let body = """
        {"event":{"usageFourHourPercentage":"NaN","usageMonthPercentage":90}}
        {"result":{"usageFourHourPercentage":42,"usageMonthPercentage":30}}
        """
        let snapshot = parse(body: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 42)
        XCTAssertEqual(snapshot.metrics.last?.usedPercent, 30)
    }

    func testMalformedAndValidCandidatesOnSameLineAreScoredBeforeSelection() {
        let body = #"{"items":[{"usageFourHourPercentage":true,"usageMonthPercentage":99},{"usageFourHourPercentage":35,"usageBand":"standard","usageMonthPercentage":45}]}"#
        let snapshot = parse(body: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 35)
        XCTAssertEqual(snapshot.metrics.first?.detail, "Base - standard")
        XCTAssertEqual(snapshot.metrics.last?.usedPercent, 45)
    }

    func testExcessiveJSONDepthFailsSafely() {
        var body = #"{"usageFourHourPercentage":10}"#
        for _ in 0..<80 {
            body = "{\"nested\":\(body)}"
        }

        let snapshot = parse(body: body)
        XCTAssertEqual(snapshot.status, .error("T3 Chat 主窗口数据异常"))
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testOptionalOverageAndMetadataFailuresDoNotSuppressPrimary() {
        let body = #"{"data":{"usageFourHourPercentage":25,"usageMonthPercentage":false,"usagePeriodPercentage":"NaN","usageFourHourNextResetAt":"Infinity","usageWindowNextResetAt":1779366216,"subscription":{"productName":true,"currentPeriodEnd":false},"subTier":"pro"}}"#
        let snapshot = parse(body: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.metrics.map(\.id), ["four_hour"])
        XCTAssertEqual(snapshot.metrics.first?.resetsAt, Date(timeIntervalSince1970: 1_779_366_216))
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testPercentageValuesFollowCodexBarClampSemantics() {
        let snapshot = parse(body: #"{"usageFourHourPercentage":-5,"usageMonthPercentage":120}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 0)
        XCTAssertEqual(snapshot.metrics.last?.usedPercent, 100)
    }

    func testMainWindowRejectsBoolStringsAndMissingValues() {
        let bodies = [
            #"{"usageFourHourPercentage":true}"#,
            #"{"usageFourHourPercentage":"12.5"}"#,
            #"{"usageFourHourPercentage":"NaN"}"#,
            #"{"usageFourHourPercentage":"Infinity"}"#,
            #"{"usageMonthPercentage":10,"subscription":{"productName":"pro"}}"#,
        ]

        for body in bodies {
            let snapshot = parse(body: body)
            XCTAssertEqual(snapshot.status, .error("T3 Chat 主窗口数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        }
    }

    func testMissingCustomerObjectIsParseError() {
        for body in ["not-json", #"{"json":[1,2,3]}"#, "\n\n"] {
            let snapshot = parse(body: body)
            XCTAssertEqual(snapshot.status, .error("未找到 T3 Chat 用量数据"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty)
        }
    }

    func testDateFallbackAndSafeUpperBound() {
        let body = #"{"usageFourHourPercentage":10,"usageFourHourNextResetAt":253402300800000,"usageWindowNextResetAt":1779366216,"usageMonthPercentage":20,"subscription":{"currentPeriodEnd":253402300800000}}"#
        let snapshot = parse(body: body)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.resetsAt, Date(timeIntervalSince1970: 1_779_366_216))
        XCTAssertNil(snapshot.metrics.last?.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testOverageResetNeverUsesBillingNextResetAt() {
        let snapshot = parse(body: #"{"usageFourHourPercentage":10,"usageMonthPercentage":20,"billingNextResetAt":1779366216920}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.metrics.last?.resetsAt)
    }

    func testAuthenticationVercelChallengeAndOrdinaryRateLimitAreDistinct() {
        XCTAssertEqual(parse(body: "", status: 401).status, .needsLogin)
        XCTAssertEqual(parse(body: "", status: 403).status, .needsLogin)

        let challenge = parse(
            body: "checkpoint",
            status: 429,
            headers: ["X-Vercel-Mitigated": "Challenge"]
        )
        XCTAssertEqual(challenge.status, .error("T3 Chat 遇到 Vercel 风控挑战"))
        XCTAssertEqual(parse(body: "rate limited", status: 429).status, .error("HTTP 429"))
    }

    func testMissingProbeEmptyResultsAndNetworkFailuresAreExplicit() {
        XCTAssertEqual(T3ChatParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
        XCTAssertEqual(
            T3ChatParser.parse(
                results: ["other": ProbeResult(status: 200, body: "{}")],
                now: now
            ).status,
            .error("未获取到 T3 Chat 响应")
        )
        XCTAssertEqual(parse(body: "", status: 503).status, .error("HTTP 503"))
        XCTAssertEqual(parse(body: "timeout", status: -3).status, .error("请求超时"))
    }

    func testProbeUsesExactTRPCInputAndMinimalChallengeHeaderPlumbing() throws {
        let providerSource = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        let start = try XCTUnwrap(providerSource.range(of: "static let t3chat = probeHelper"))
        let end = try XCTUnwrap(providerSource.range(of: "/// Notion AI", range: start.upperBound..<providerSource.endIndex))
        let block = String(providerSource[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(block.contains(#"{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}"#))
        XCTAssertTrue(block.contains("encodeURIComponent("))
        XCTAssertTrue(block.contains("__probe('/api/trpc/getCustomerData?batch=1&input=' + input"))
        XCTAssertTrue(block.contains("'Accept': '*/*'"))
        XCTAssertTrue(block.contains("'trpc-accept': 'application/jsonl'"))
        XCTAssertTrue(block.contains("'x-trpc-source': 'web-client'"))
        XCTAssertTrue(block.contains("'x-trpc-batch': 'true'"))
        XCTAssertTrue(block.contains("noAuth: true"))
        XCTAssertTrue(block.contains("timeoutMs: 12000"), "一次重试总预算需严格低于外层 30 秒")
        XCTAssertTrue(block.contains("retry: true"), "T3 重试策略必须显式锁定为一次")
        XCTAssertFalse(block.contains("Sec-Fetch-"), "浏览器负责 Sec-Fetch 系列请求头")

        let helperSource = ProviderProbeScript.helper
        XCTAssertTrue(helperSource.contains("out.vercelMitigated"))
        XCTAssertTrue(helperSource.contains("response.headers.get('x-vercel-mitigated')"))

        let fetcherSource = try String(contentsOf: webViewFetcherURL(), encoding: .utf8)
        XCTAssertTrue(fetcherSource.contains(#"p["vercelMitigated"]"#))
        XCTAssertTrue(fetcherSource.contains(#""x-vercel-mitigated""#))
        XCTAssertTrue(fetcherSource.contains(#""grpc-status""#), "不得破坏既有 gRPC 响应头透传")
    }

    func testProbeResultHeadersRemainCodable() throws {
        let original = ProbeResult(
            status: 429,
            body: "checkpoint",
            headers: ["x-vercel-mitigated": "challenge"]
        )
        let roundTrip = try JSONDecoder().decode(ProbeResult.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(roundTrip, original)
    }

    private func parse(
        body: String,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> ProviderSnapshot {
        T3ChatParser.parse(
            results: ["customer": ProbeResult(status: status, body: body, headers: headers)],
            now: now
        )
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func providerScriptsURL() -> URL {
        repositoryURL().appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    private func webViewFetcherURL() -> URL {
        repositoryURL().appendingPathComponent("App/Networking/WebViewFetcher.swift")
    }
}

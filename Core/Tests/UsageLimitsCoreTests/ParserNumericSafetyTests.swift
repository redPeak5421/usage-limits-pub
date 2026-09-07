import XCTest
@testable import UsageLimitsCore

final class ParserNumericSafetyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testMiniMaxSkipsExtremeIntegerFieldsAndKeepsSafeFormatting() {
        let snap = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: #"{"model_remains":[]}"#),
            "usage_summary": ProbeResult(status: 200, body: #"{"active_days":1e308}"#),
        ], now: now)
        XCTAssertNil(snap.metrics.first { $0.id == "active_days" })
        XCTAssertEqual(MiniMaxParser.percentPair(used: .greatestFiniteMagnitude, total: .infinity), "0%/100%")

        let badCode = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: #"{"base_resp":{"status_code":1e308,"status_msg":"bad"}}"#),
        ], now: now)
        if case .error = badCode.status {} else { XCTFail("invalid status code must be a safe error") }
    }

    func testMiniMaxProductionParseRejectsOutOfRangeDirectPercentages() {
        let snapshot = MiniMaxParser.parse(results: [
            "remains": ProbeResult(
                status: 200,
                body: #"{"model_remains":[{"model_name":"general","current_interval_used_percent":"150%","current_weekly_remaining_percent":-1}]}"#
            ),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.metrics.first { $0.id == "five_hour" })
        XCTAssertNil(snapshot.metrics.first { $0.id == "seven_day" })
        XCTAssertNil(snapshot.persistenceValidationIssue)
    }

    func testZhipuDropsExtremeUnitsWindowsToolCountsAndEnvelopeCodes() {
        let rows: [[String: Any]] = [
            ["type": "TOKENS_LIMIT", "unit": 1e308, "number": 1, "percentage": 10],
            ["type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 10,
             "usageDetails": [["modelCode": "search-prime", "usage": 1e308]]],
        ]
        let metrics = ZhipuParser.quotaMetrics(rows, now: now)
        XCTAssertFalse(metrics.contains { $0.id.hasPrefix("window_") })
        XCTAssertNil(metrics.first { $0.id == "mcp_monthly" }?.detail)
        XCTAssertEqual(ZhipuParser.windowLabel(.greatestFiniteMagnitude), "限额")
        XCTAssertNotNil(ZhipuParser.envelopeError(["code": 1e308]))
    }

    func testZhipuDropsPre1970ValidStartAndEndWithoutPoisoningSnapshot() {
        let unsafeStart = ZhipuParser.parse(results: [
            "subscription": ProbeResult(
                status: 200,
                body: #"{"data":[{"status":1,"productName":"Unsafe Range Tier","valid":"1960-01-01 00:00:00-2026-02-01 00:00:00"}]}"#
            ),
        ], now: now)
        XCTAssertEqual(unsafeStart.status, .ok)
        XCTAssertNotNil(unsafeStart.planExpiresAt)
        XCTAssertNil(unsafeStart.billingCycle, "unsafe start must not infer a billing cycle")
        XCTAssertNil(unsafeStart.persistenceValidationIssue)

        let unsafeEnd = ZhipuParser.parse(results: [
            "subscription": ProbeResult(
                status: 200,
                body: #"{"data":[{"status":1,"productName":"Unsafe Range Tier","valid":"2026-01-01 00:00:00-1960-02-01 00:00:00"}]}"#
            ),
        ], now: now)
        XCTAssertEqual(unsafeEnd.status, .ok)
        XCTAssertNil(unsafeEnd.planExpiresAt)
        XCTAssertNil(unsafeEnd.persistenceValidationIssue)
    }

    func testDeepSeekExtremeBusinessCodesAreIgnoredWithoutTrap() {
        let snap = DeepSeekParser.parse(results: [
            "current": ProbeResult(status: 200, body: #"{"code":1e308,"msg":"bad"}"#),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
    }

    func testGrokDropsExtremeStatusWindowAndWeeklyProductCode() throws {
        let badStatus = #"{"results":[{"status":1e308,"body":{"remainingQueries":1}}]}"#
        XCTAssertEqual(
            GrokParser.parse(results: ["rate_limits": ProbeResult(status: 200, body: badStatus)], now: now).status,
            .needsLogin
        )

        let hugeWindow = #"{"results":[{"status":200,"modelName":"auto","body":{"remainingQueries":1,"totalQueries":2,"windowSizeSeconds":1e308}}]}"#
        let metric = try XCTUnwrap(GrokParser.parse(
            results: ["rate_limits": ProbeResult(status: 200, body: hugeWindow)], now: now
        ).metrics.first)
        XCTAssertNil(metric.resetsAt)
        XCTAssertNil(metric.detail)

        let weekly = try XCTUnwrap(GrokWeeklyParser.parse(json:
            #"{"config":{"creditUsagePercent":5,"productUsage":[{"code":1e308,"usagePercent":2}]}}"#
        ))
        XCTAssertTrue(weekly.products.isEmpty)
    }

    func testGrokProductionParseDropsOutOfRangeWeeklyPercentFieldsLocally() throws {
        let body = #"{"config":{"creditUsagePercent":101,"resetsAt":1767003600,"productUsage":[{"code":4,"usagePercent":25},{"code":5,"usagePercent":-1},{"code":6,"usagePercent":101}]}}"#
        let snapshot = GrokParser.parse(results: [
            "credits": ProbeResult(status: 200, body: body),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(try XCTUnwrap(snapshot.metrics.first { $0.id == "weekly" }).usedPercent)
        XCTAssertEqual(snapshot.metrics.filter { $0.id.hasPrefix("weekly.") }.map(\.id), ["weekly.4"])
        XCTAssertNil(snapshot.persistenceValidationIssue)
    }

    func testGrokProductionParseRejectsNegativeShortLimitFieldsLocally() {
        let body = #"{"results":[{"status":200,"modelName":"negative-remaining","body":{"remainingQueries":-1,"totalQueries":10,"windowSizeSeconds":60}},{"status":200,"modelName":"negative-total","body":{"remainingQueries":1,"totalQueries":-10,"windowSizeSeconds":60}},{"status":200,"modelName":"negative-window","body":{"remainingQueries":1,"totalQueries":10,"windowSizeSeconds":-60}},{"status":200,"modelName":"safe","body":{"remainingQueries":4,"totalQueries":10,"windowSizeSeconds":60}}]}"#
        let snapshot = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: body),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["safe-DEFAULT"])
        XCTAssertEqual(snapshot.metrics.first?.remaining, 4)
        XCTAssertEqual(snapshot.metrics.first?.total, 10)
        XCTAssertNil(snapshot.persistenceValidationIssue)
    }

    func testMiniMaxPresentMalformedEnvelopeCodeIsShapeErrorAndCannotContributeUsage() {
        for rawCode in ["true", #""bad""#] {
            let body = #"{"base_resp":{"status_code":\#(rawCode)},"model_remains":[{"model_name":"general","current_interval_used_percent":25}]}"#
            let snapshot = MiniMaxParser.parse(results: [
                "remains": ProbeResult(status: 200, body: body),
            ], now: now)
            XCTAssertEqual(snapshot.status, .error("响应状态码异常"))
            XCTAssertTrue(snapshot.metrics.isEmpty)
        }
    }

    func testMiniMaxUsageSummaryMalformedEnvelopeCannotContributeLoginOrMetrics() {
        for rawCode in ["true", #""bad""#] {
            let body = #"{"base_resp":{"status_code":\#(rawCode)},"total_token_consumed":"9.99B","active_days":99,"daily_token_usage":[100,200,300]}"#
            let snapshot = MiniMaxParser.parse(results: [
                "usage_summary": ProbeResult(status: 200, body: body),
            ], now: now)

            XCTAssertEqual(snapshot.status, .error("响应状态码异常"))
            XCTAssertNil(snapshot.planName)
            XCTAssertTrue(snapshot.metrics.isEmpty)
        }
    }

    func testMiniMaxUsageSummarySessionExpiryCannotBeMaskedByFakeMetrics() {
        let body = #"{"base_resp":{"status_code":1004,"status_msg":"login expired"},"total_token_consumed":"9.99B","active_days":99,"daily_token_usage":[100,200,300]}"#
        let snapshot = MiniMaxParser.parse(results: [
            "usage_summary": ProbeResult(status: 200, body: body),
        ], now: now)

        XCTAssertEqual(snapshot.status, .needsLogin)
        XCTAssertNil(snapshot.planName)
        XCTAssertTrue(snapshot.metrics.isEmpty)
    }

    func testMiniMaxUsageSummaryBadEnvelopeDoesNotDiscardIndependentSuccessfulProbe() {
        let snapshot = MiniMaxParser.parse(results: [
            "remains": ProbeResult(
                status: 200,
                body: #"{"model_remains":[{"model_name":"general","current_interval_used_percent":25}]}"#
            ),
            "usage_summary": ProbeResult(
                status: 200,
                body: #"{"base_resp":{"status_code":1004,"status_msg":"login expired"},"total_token_consumed":"9.99B","daily_token_usage":[100]}"#
            ),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.metrics.first { $0.id == "five_hour" })
        XCTAssertNil(snapshot.metrics.first { $0.id == "lifetime_tokens" })
        XCTAssertNil(snapshot.metrics.first { $0.id == "last_7d_calls" })
    }

    func testZhipuPresentMalformedEnvelopeCodeIsShapeErrorAndCannotContributeUsage() {
        for rawCode in ["true", #""bad""#] {
            let body = #"{"code":\#(rawCode),"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":25}]}}"#
            let snapshot = ZhipuParser.parse(results: [
                "quota": ProbeResult(status: 200, body: body),
            ], now: now)
            XCTAssertEqual(snapshot.status, .error("智谱响应状态码异常"))
            XCTAssertTrue(snapshot.metrics.isEmpty)
        }
    }

    func testCursorAndKimiDropExtremeWindowAndCountConversions() {
        let cursor = CursorParser.parse(results: [
            "usage_summary": ProbeResult(status: 200, body: #"{"membershipType":"pro"}"#),
            "request_usage": ProbeResult(status: 200, body: #"{"gpt-4":{"numRequests":1e308,"maxRequestUsage":1e308}}"#),
        ], now: now)
        XCTAssertEqual(cursor.status, .ok)
        XCTAssertNil(cursor.metrics.first { $0.id == "requests" })

        let kimi = KimiParser.parse(results: [
            "usages": ProbeResult(status: 200, body: #"{"usages":[{"scope":"CODING","limits":[{"used":1,"limit":10,"window":{"duration":1e308,"timeUnit":"TIME_UNIT_WEEK"}}]}]}"#),
        ], now: now)
        XCTAssertEqual(kimi.status, .ok)
        XCTAssertEqual(kimi.metrics.first?.id, "window_1")
        XCTAssertEqual(kimi.metrics.first?.label, "配额")
    }

    func testClaudeAndOpenAIFormattingUsesSafePlaceholdersForExtremeValues() {
        XCTAssertEqual(ClaudeParser.money(.greatestFiniteMagnitude, currency: "USD"), "$—")
        XCTAssertEqual(OpenAIParser.moneyUSD(.greatestFiniteMagnitude), "$—")
        XCTAssertEqual(OpenAIParser.durationText(minutes: .greatestFiniteMagnitude), "未知时长")
    }

    func testJimengDropsExtremeHistoryTypesIDsAndEpochs() {
        XCTAssertNil(JimengParser.stringID(1e308))
        XCTAssertNil(JimengParser.unixDate(1e308))
        XCTAssertTrue(JimengParser.parseRecords([[
            "title": "消耗", "amount": 1, "history_type": 1e308,
            "create_time": 1_766_000_000,
        ]]).isEmpty)
    }

    func testJimengProductionParseDropsOutOfRangeIntegerAmountsLocally() throws {
        let snapshot = JimengParser.parse(results: [
            "credit": ProbeResult(
                status: 200,
                body: #"{"vip_credit":2,"purchase_credit":1e308,"gift_credit":3}"#
            ),
        ], now: now)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "subscription" }?.amount, 2)
        XCTAssertNil(snapshot.metrics.first { $0.id == "recharge" })
        XCTAssertEqual(snapshot.metrics.first { $0.id == "gift" }?.amount, 3)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "remaining" }?.amount, 5)
        XCTAssertNil(snapshot.persistenceValidationIssue)
    }

    func testDeepSeekProductionParseDropsOutOfRangeSemanticCountsLocally() throws {
        let body = #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"api_key":{"tracking_id":"safe","name":"Safe"},"model":"deepseek-safe","buckets":[{"time":1766000000,"usage":{"REQUEST":1e308,"RESPONSE_TOKEN":1e308,"PROMPT_CACHE_HIT_TOKEN":2,"PROMPT_CACHE_MISS_TOKEN":3}},{"time":1766003600,"usage":{"REQUEST":4,"RESPONSE_TOKEN":5}}]},{"api_key":{"tracking_id":"bad","name":"Bad"},"model":"deepseek-bad","buckets":[{"time":1766007200,"usage":{"REQUEST":1e308,"RESPONSE_TOKEN":1e308}}]}]}}}"#
        let snapshot = DeepSeekParser.parse(results: [
            "usage_amount": ProbeResult(status: 200, body: body),
        ], now: now)

        let period = try XCTUnwrap(snapshot.timeBreakdowns?.first)
        XCTAssertEqual(period.requests, 4)
        XCTAssertEqual(period.tokens, 10)
        XCTAssertEqual(period.cacheHitTokens, 2)
        XCTAssertEqual(period.cacheMissTokens, 3)
        XCTAssertEqual(period.outputTokens, 5)
        XCTAssertEqual(snapshot.keyBreakdowns?.first?.requests, 4)
        XCTAssertEqual(snapshot.keyBreakdowns?.map(\.id), ["safe"])
        XCTAssertEqual(snapshot.modelBreakdowns?.first?.tokens, 10)
        XCTAssertEqual(snapshot.modelBreakdowns?.map(\.id), ["deepseek-safe"])
        XCTAssertNil(snapshot.persistenceValidationIssue)
    }
}

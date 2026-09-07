import XCTest
@testable import UsageLimitsCore

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class StepFunParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testParsesRateWindowSummaryWithActualIntegerRateAndNumericTimestamps() throws {
        let snapshot = parse(rate: #"{"apiSuccess":true,"fiveHourLeftRate":1,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.99781543,"weeklyResetTime":1777899600}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName)
        XCTAssertNil(snapshot.billingCycle)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["five_hour", "weekly"])
        let fiveHour = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(fiveHour.label, "5 小时窗口")
        XCTAssertEqual(fiveHour.usedPercent, 0)
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1_777_528_800))
        XCTAssertEqual(fiveHour.pinned, true)
        let weekly = try XCTUnwrap(snapshot.metrics.last)
        XCTAssertEqual(weekly.label, "每周窗口")
        XCTAssertEqual(weekly.usedPercent ?? -1, 0.218457, accuracy: 0.000001)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_777_899_600))
        XCTAssertEqual(weekly.pinned, true)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testRateWindowLeftRateEdgesMapToUsedPercentEdges() {
        let snapshot = parse(rate: #"{"apiSuccess":true,"fiveHourLeftRate":0,"fiveHourResetTime":1777528800,"weeklyLeftRate":1,"weeklyResetTime":1777899600}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.usedPercent), [100, 0])
    }

    func testLiveWindowsWinOverCreditFamilyAndCreditPayload() {
        let snapshot = parse(rate: #"{"apiSuccess":true,"fiveHourLeftRate":0.8,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.6,"weeklyResetTime":1777899600,"planFamily":2,"credit":{"subscriptionLeftRate":0.1,"subscriptionResetTime":1786288293,"buckets":[{"total":100,"residual":10}]}}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(snapshot.metrics[0].usedPercent ?? -1, 20, accuracy: 0.000001)
        XCTAssertEqual(snapshot.metrics[1].usedPercent ?? -1, 40, accuracy: 0.000001)
    }

    func testLiveWindowShapeRequiresBothRatesAndBothPositiveSafeResets() {
        let bad = [
            #"{"apiSuccess":true,"fiveHourLeftRate":0.8,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.6}"#,
            #"{"apiSuccess":true,"fiveHourLeftRate":0.8,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.6,"weeklyResetTime":0}"#,
            #"{"apiSuccess":true,"fiveHourLeftRate":-0.1,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.6,"weeklyResetTime":1777899600}"#,
            #"{"apiSuccess":true,"fiveHourLeftRate":1.1,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.6,"weeklyResetTime":1777899600}"#,
            #"{"apiSuccess":true,"fiveHourLeftRate":0.8,"fiveHourResetTime":253402300800,"weeklyLeftRate":0.6,"weeklyResetTime":1777899600}"#,
        ]

        for body in bad {
            let snapshot = parse(rate: body)
            XCTAssertEqual(snapshot.status, .error("StepFun 用量数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty, body)
        }
    }

    func testCreditPlanUsesSubscriptionRateAndOnlyPositiveSubscriptionReset() throws {
        let withReset = parse(rate: #"{"apiSuccess":true,"planFamily":2,"credit":{"subscriptionLeftRate":0.75,"subscriptionResetTime":1786288293,"topupLeftRate":0.25}}"#)

        XCTAssertEqual(withReset.status, .ok)
        XCTAssertEqual(withReset.metrics.map(\.id), ["credits"])
        let metric = try XCTUnwrap(withReset.metrics.first)
        XCTAssertEqual(metric.label, "Credits")
        XCTAssertEqual(metric.usedPercent, 25)
        XCTAssertNil(metric.remaining)
        XCTAssertNil(metric.total)
        XCTAssertEqual(metric.resetsAt, Date(timeIntervalSince1970: 1_786_288_293))
        XCTAssertEqual(metric.detail, "按月重置")
        XCTAssertEqual(metric.pinned, true)

        let zeroReset = parse(rate: #"{"apiSuccess":true,"planFamily":2,"credit":{"subscriptionLeftRate":0.5,"subscriptionResetTime":0}}"#)
        XCTAssertEqual(zeroReset.status, .ok)
        XCTAssertNil(zeroReset.metrics.first?.resetsAt)
        XCTAssertNil(zeroReset.metrics.first?.detail)
    }

    func testCreditBucketsUseWeightedCombinedBalanceAndCounts() throws {
        let snapshot = parse(rate: #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":0.8,"topupLeftRate":0.5,"buckets":[{"total":100,"residual":80},{"total":300,"residual":150}]}}"#)

        XCTAssertEqual(snapshot.status, .ok)
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.id, "credits")
        XCTAssertEqual(metric.usedPercent ?? -1, 42.5, accuracy: 0.000001)
        XCTAssertEqual(metric.remaining, 230)
        XCTAssertEqual(metric.total, 400)
    }

    func testInvalidOrOverflowingBucketsFallBackWithoutAddingIndependentRates() {
        let invalidBuckets = parse(rate: #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":0.6,"topupLeftRate":0.4,"buckets":[{"total":100},{"total":20,"residual":25}]}}"#)
        XCTAssertEqual(invalidBuckets.status, .ok)
        XCTAssertEqual(invalidBuckets.metrics.first?.usedPercent, 40)
        XCTAssertNil(invalidBuckets.metrics.first?.remaining)
        XCTAssertNil(invalidBuckets.metrics.first?.total)

        let overflow = parse(rate: #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":0.7,"buckets":[{"total":1e308,"residual":5e307},{"total":1e308,"residual":5e307}]}}"#)
        XCTAssertEqual(overflow.status, .ok)
        XCTAssertEqual(overflow.metrics.first?.usedPercent ?? -1, 30, accuracy: 0.000001)

        let topupOnly = parse(rate: #"{"apiSuccess":true,"credit":{"topupLeftRate":0.25,"buckets":[]}}"#)
        XCTAssertEqual(topupOnly.status, .ok)
        XCTAssertEqual(topupOnly.metrics.first?.usedPercent, 75)
    }

    func testCreditShapeWinsWithoutFamilyAndFamilyTwoIsOnlyAnAmbiguousTieBreaker() {
        let poolWithoutFamily = parse(rate: #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":0}}"#)
        XCTAssertEqual(poolWithoutFamily.status, .ok)
        XCTAssertEqual(poolWithoutFamily.metrics.first?.usedPercent, 100)

        let familyTwoWithoutPool = parse(rate: #"{"apiSuccess":true,"planFamily":2}"#)
        XCTAssertEqual(familyTwoWithoutPool.status, .error("StepFun 用量数据异常"))

        let zeroRollingWithoutPool = parse(rate: #"{"apiSuccess":true,"planFamily":1,"fiveHourLeftRate":0,"fiveHourResetTime":0,"weeklyLeftRate":0,"weeklyResetTime":0}"#)
        XCTAssertEqual(zeroRollingWithoutPool.status, .error("StepFun 用量数据异常"))
        XCTAssertTrue(zeroRollingWithoutPool.metrics.isEmpty)
    }

    func testCreditPlanRequiresUsableRateAndRejectsOutOfRangeFallbacks() {
        let bodies = [
            #"{"apiSuccess":true,"planFamily":2,"credit":{}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":-0.1}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":1.1}}"#,
            #"{"apiSuccess":true,"credit":{"buckets":[{"total":0,"residual":0}]}}"#,
        ]
        for body in bodies {
            XCTAssertEqual(parse(rate: body).status, .error("StepFun 用量数据异常"), body)
        }
    }

    func testOptionalAllowlistedPlanIsPrefixedAndPlanFailureNeverSuppressesUsage() {
        let rate = #"{"apiSuccess":true,"fiveHourLeftRate":0.8,"fiveHourResetTime":1777528800,"weeklyLeftRate":0.6,"weeklyResetTime":1777899600}"#
        for plan in ["Free", "Mini", "Plus", "Pro", "Max", "Coding Plan", "Token Plan"] {
            XCTAssertEqual(
                parse(rate: rate, plan: #"{"apiSuccess":true,"plan":"\#(plan)"}"#).planName,
                "StepFun \(plan)"
            )
        }

        XCTAssertNil(parse(rate: rate, plan: #"{"apiSuccess":true}"#).planName)
        XCTAssertNil(parse(rate: rate, plan: #"{"apiSuccess":true,"plan":"Enterprise"}"#).planName)
        XCTAssertNil(parse(rate: rate, plan: #"{"apiSuccess":false,"authError":true}"#).planName)
        XCTAssertNil(parse(rate: rate, plan: "{}", planStatus: 503).planName)
        XCTAssertEqual(parse(rate: rate, plan: "{}", planStatus: 503).status, .ok)
    }

    func testHTTPAndSafeAPIAuthFailuresUseStatusTiersWithoutEchoingBodies() {
        XCTAssertEqual(StepFunParser.parse(results: [:], now: now).status, .error("未获取到任何响应"))
        XCTAssertEqual(StepFunParser.parse(results: ["plan_status": ProbeResult(status: 200, body: "{}")], now: now).status, .error("未获取到 StepFun 用量响应"))
        XCTAssertEqual(parse(rate: "{}", rateStatus: 401).status, .needsLogin)
        XCTAssertEqual(parse(rate: "{}", rateStatus: 403).status, .needsLogin)
        XCTAssertEqual(parse(rate: "{}", rateStatus: 500).status, .error("HTTP 500"))
        XCTAssertEqual(parse(rate: "sensitive-placeholder", rateStatus: -1).status, .error("网络错误"))
        XCTAssertEqual(parse(rate: "sensitive-placeholder", rateStatus: -3).status, .error("请求超时"))
        XCTAssertEqual(parse(rate: #"{"apiSuccess":false,"authError":true}"#).status, .needsLogin)
        XCTAssertEqual(parse(rate: #"{"apiSuccess":false,"authError":false}"#).status, .error("StepFun API 返回失败"))
    }

    func testSafeSummaryStrictlyRejectsTypeDriftExponentStringsNonfiniteAndUnknownKeys() {
        let invalid = [
            "not json",
            "{}",
            #"{"apiSuccess":1,"planFamily":2}"#,
            #"{"apiSuccess":"true","planFamily":2}"#,
            #"{"apiSuccess":true,"planFamily":true,"credit":{"subscriptionLeftRate":0.5}}"#,
            #"{"apiSuccess":true,"planFamily":"2","credit":{"subscriptionLeftRate":0.5}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":true}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":"0.5"}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":"1e-1"}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":1e309}}"#,
            #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":0.5,"token":"token-placeholder"}}"#,
            #"{"apiSuccess":true,"credit":{"buckets":[{"total":100,"residual":50,"owner":"person-placeholder"}]}}"#,
            #"{"apiSuccess":true,"planFamily":2,"accountEmail":"person-placeholder@example.invalid"}"#,
            #"{"apiSuccess":false,"authError":false,"message":"sensitive-placeholder"}"#,
        ]

        for body in invalid {
            let snapshot = parse(rate: body)
            XCTAssertEqual(snapshot.status, .error("StepFun 用量数据异常"), body)
            XCTAssertTrue(snapshot.metrics.isEmpty, body)
        }
    }

    func testCreditUnsafeResetIsDroppedWhileValidUsageSurvives() throws {
        let snapshot = parse(rate: #"{"apiSuccess":true,"credit":{"subscriptionLeftRate":0.5,"subscriptionResetTime":253402300800}}"#)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.usedPercent, 50)
        XCTAssertNil(snapshot.metrics.first?.resetsAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testProductionProbeBodyIsCoreOwnedAndAppUsesTheSharedComposition() throws {
        let fileURL = coreSourcesURL().appendingPathComponent("StepFunProbeScript.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let source = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("static let stepfun = probeHelper + StepFunProbeScript.body"))
        XCTAssertEqual(source.components(separatedBy: "QueryStepPlanRateLimit").count - 1, 0)
        XCTAssertEqual(source.components(separatedBy: "GetStepPlanStatus").count - 1, 0)
    }

    #if canImport(JavaScriptCore)
    func testActualProductionProbeRunsBothRequestsConcurrentlyAndReturnsOnlySafeSummaries() throws {
        let rawRate = try fixture("stepfun_rate_raw")
        let rawPlan = try fixture("stepfun_plan_raw")
        let execution = try executeProbeScript(rateBody: rawRate, planBody: rawPlan)

        XCTAssertEqual(execution.requested.count, 2)
        XCTAssertEqual(execution.fetchCalls.count, 2)
        XCTAssertEqual(execution.fetchCountAtFirstText, 2, "Promise.all 必须先启动两条 fetch，再等待任一正文")

        let requestedByURL = Dictionary(uniqueKeysWithValues: execution.requested.compactMap { item -> (String, [String: Any])? in
            guard let url = item["url"] as? String, let options = item["options"] as? [String: Any] else { return nil }
            return (url, options)
        })
        let rateOptions = try XCTUnwrap(requestedByURL["/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"])
        XCTAssertEqual(rateOptions["method"] as? String, "POST")
        XCTAssertEqual(rateOptions["body"] as? String, "{}")
        XCTAssertEqual((rateOptions["timeoutMs"] as? NSNumber)?.intValue, 12_000)
        XCTAssertEqual(rateOptions["retry"] as? Bool, true)
        XCTAssertEqual(rateOptions["noAuth"] as? Bool, true)

        let planOptions = try XCTUnwrap(requestedByURL["/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus"])
        XCTAssertEqual((planOptions["timeoutMs"] as? NSNumber)?.intValue, 8_000)
        XCTAssertEqual(planOptions["retry"] as? Bool, false)
        XCTAssertEqual(planOptions["noAuth"] as? Bool, true)

        for call in execution.fetchCalls {
            let options = try XCTUnwrap(call["options"] as? [String: Any])
            XCTAssertEqual(options["credentials"] as? String, "include")
            XCTAssertEqual(options["hasTimeoutMs"] as? Bool, false)
            XCTAssertEqual(options["hasRetry"] as? Bool, false)
            XCTAssertEqual(options["hasNoAuth"] as? Bool, false)
            XCTAssertEqual(options["hasSignal"] as? Bool, true)
            let headers = try XCTUnwrap(options["headers"] as? [String: Any])
            XCTAssertEqual(headers["Accept"] as? String, "application/json")
            XCTAssertEqual(headers["Content-Type"] as? String, "application/json")
            XCTAssertEqual(headers["oasis-appid"] as? String, "10300")
            XCTAssertEqual(headers["oasis-platform"] as? String, "web")
            XCTAssertEqual(headers["oasis-webid"] as? String, "webid-placeholder")
            XCTAssertNil(headers["Authorization"], "noAuth 必须阻止 helper 附加 localStorage token")
        }
        XCTAssertTrue(execution.timers.contains(12_000))
        XCTAssertTrue(execution.timers.contains(8_000))

        let rate = try probe(execution.probes, named: "rate_limit")
        let safeRate = try object(rate.body)
        XCTAssertEqual(safeRate["apiSuccess"] as? Bool, true)
        XCTAssertEqual((safeRate["fiveHourLeftRate"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual((safeRate["fiveHourResetTime"] as? NSNumber)?.doubleValue, 1_777_528_800)
        XCTAssertEqual((safeRate["weeklyLeftRate"] as? NSNumber)?.doubleValue, 0.99781543)
        XCTAssertEqual((safeRate["weeklyResetTime"] as? NSNumber)?.doubleValue, 1_777_899_600)

        let plan = try probe(execution.probes, named: "plan_status")
        XCTAssertEqual(try object(plan.body)["plan"] as? String, "Plus")
        let encoded = try jsonString(execution.probes)
        for sensitive in [
            "webid-placeholder", "token-placeholder-cookie", "token-placeholder-local-storage",
            "token-placeholder-raw", "person-placeholder@example.invalid", "Person Placeholder",
            "account-placeholder", "unknown_identity", "account_email",
        ] {
            XCTAssertFalse(encoded.contains(sensitive), sensitive)
        }

        let snapshot = StepFunParser.parse(results: try probeResults(execution.probes), now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "StepFun Plus")
        XCTAssertEqual(snapshot.metrics.map(\.id), ["five_hour", "weekly"])
    }

    func testActualProductionProbeConvertsStrictDecimalCreditStringsAndDropsBucketMetadata() throws {
        let rawCredit = try fixture("stepfun_credit_raw")
        let execution = try executeProbeScript(rateBody: rawCredit, planStatus: 503, planBody: "{}")
        let rate = try probe(execution.probes, named: "rate_limit")
        let safe = try object(rate.body)
        let credit = try XCTUnwrap(safe["credit"] as? [String: Any])
        XCTAssertEqual((credit["subscriptionLeftRate"] as? NSNumber)?.doubleValue, 0.8)
        XCTAssertEqual((credit["subscriptionResetTime"] as? NSNumber)?.doubleValue, 1_786_288_293)
        XCTAssertEqual((credit["topupLeftRate"] as? NSNumber)?.doubleValue, 0.5)
        let buckets = try XCTUnwrap(credit["buckets"] as? [[String: Any]])
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual((buckets[0]["total"] as? NSNumber)?.doubleValue, 100)
        XCTAssertEqual((buckets[0]["residual"] as? NSNumber)?.doubleValue, 80)
        XCTAssertNil(buckets[0]["expire_at"])
        XCTAssertNil(buckets[0]["next_reset_at"])
        XCTAssertNil(buckets[0]["owner"])

        let encoded = try jsonString(execution.probes)
        XCTAssertFalse(encoded.contains("token-placeholder-raw"))
        XCTAssertFalse(encoded.contains("person-placeholder@example.invalid"))
        let snapshot = StepFunParser.parse(results: try probeResults(execution.probes), now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNil(snapshot.planName, "可选套餐失败不能影响核心积分")
        XCTAssertEqual(snapshot.metrics.first?.usedPercent ?? -1, 42.5, accuracy: 0.000001)
        XCTAssertEqual(snapshot.metrics.first?.remaining, 230)
        XCTAssertEqual(snapshot.metrics.first?.total, 400)
    }

    func testActualProductionProbeDoesNotFetchWithoutVisibleWebID() throws {
        let execution = try executeProbeScript(
            cookie: "Oasis-Token=token-placeholder-cookie",
            rateBody: try fixture("stepfun_rate_raw"),
            planBody: try fixture("stepfun_plan_raw")
        )

        XCTAssertTrue(execution.requested.isEmpty)
        XCTAssertTrue(execution.fetchCalls.isEmpty)
        XCTAssertEqual(
            try probe(execution.probes, named: "rate_limit"),
            ProbeResult(status: 401, body: #"{"apiSuccess":false,"authError":true}"#)
        )
        XCTAssertNil(execution.probes["plan_status"])
        XCTAssertEqual(
            StepFunParser.parse(results: try probeResults(execution.probes), now: now).status,
            .needsLogin
        )
    }

    func testActualProductionProbeRedactsHTTPAndAPIFailureBodiesButPreservesAuthTier() throws {
        let authBody = #"{"status":0,"code":"403","message":"auth failed: Oasis-Token token-placeholder-raw","desc":"person-placeholder@example.invalid"}"#
        let auth = try executeProbeScript(rateBody: authBody, planBody: #"{"status":0,"message":"token expired token-placeholder-raw"}"#)
        let authRate = try probe(auth.probes, named: "rate_limit")
        XCTAssertEqual(try object(authRate.body)["authError"] as? Bool, true)
        XCTAssertEqual(StepFunParser.parse(results: try probeResults(auth.probes), now: now).status, .needsLogin)
        XCTAssertFalse(try jsonString(auth.probes).contains("placeholder"))

        let ordinary = try executeProbeScript(
            rateBody: #"{"status":0,"message":"quota service unavailable sensitive-placeholder"}"#,
            planBody: "{}"
        )
        let ordinaryRate = try probe(ordinary.probes, named: "rate_limit")
        XCTAssertEqual(try object(ordinaryRate.body)["authError"] as? Bool, false)
        XCTAssertEqual(StepFunParser.parse(results: try probeResults(ordinary.probes), now: now).status, .error("StepFun API 返回失败"))
        XCTAssertFalse(try jsonString(ordinary.probes).contains("sensitive-placeholder"))

        let http = try executeProbeScript(
            rateStatus: 500,
            rateBody: #"{"message":"person-placeholder@example.invalid token-placeholder-raw"}"#,
            planStatus: 403,
            planBody: #"{"message":"token-placeholder-raw"}"#
        )
        XCTAssertEqual(try probe(http.probes, named: "rate_limit"), ProbeResult(status: 500, body: "{}"))
        XCTAssertEqual(try probe(http.probes, named: "plan_status"), ProbeResult(status: 403, body: "{}"))
        XCTAssertFalse(try jsonString(http.probes).contains("placeholder"))
    }

    func testActualProductionProbeRejectsExponentStringsBooleansAndUnknownPlan() throws {
        let raw = #"{"status":1,"five_hour_usage_left_rate":true,"five_hour_usage_reset_time":"1e9","weekly_usage_left_rate":"NaN","weekly_usage_reset_time":"Infinity","plan_family":"2e0","plan_credit_rate_limit":{"subscription_credit_left_rate":"1e-1","topup_credit_left_rate":false,"subscription_credit_reset_time":"+1786288293","credit_buckets":[{"credit_total":"1e3","credit_residual":"500"}]},"token":"token-placeholder-raw"}"#
        let plan = #"{"status":1,"subscription":{"name":"Enterprise","email":"person-placeholder@example.invalid"}}"#
        let execution = try executeProbeScript(rateBody: raw, planBody: plan)
        let safe = try object(try probe(execution.probes, named: "rate_limit").body)
        XCTAssertEqual(safe["apiSuccess"] as? Bool, true)
        XCTAssertNil(safe["fiveHourLeftRate"])
        XCTAssertNil(safe["fiveHourResetTime"])
        XCTAssertNil(safe["weeklyLeftRate"])
        XCTAssertNil(safe["weeklyResetTime"])
        XCTAssertNil(safe["planFamily"])
        let credit = try XCTUnwrap(safe["credit"] as? [String: Any])
        let buckets = try XCTUnwrap(credit["buckets"] as? [[String: Any]])
        XCTAssertEqual(buckets.count, 1, "无效 bucket 不能静默消失后改变加权分母")
        XCTAssertNil(buckets[0]["total"], "指数 total 必须拒绝")
        XCTAssertEqual((buckets[0]["residual"] as? NSNumber)?.doubleValue, 500)
        XCTAssertNil(try object(try probe(execution.probes, named: "plan_status").body)["plan"])
        XCTAssertFalse(try jsonString(execution.probes).contains("placeholder"))
        XCTAssertEqual(StepFunParser.parse(results: try probeResults(execution.probes), now: now).status, .error("StepFun 用量数据异常"))
    }

    func testFullProductionHelperRetriesOnlyRateAndStillRedactsFirstFailure() throws {
        let firstFailure = #"{"message":"person-placeholder@example.invalid token-placeholder-first"}"#
        let execution = try executeProbeScript(
            rateResponses: [
                ["status": 503, "body": firstFailure],
                ["status": 200, "body": try fixture("stepfun_rate_raw")],
            ],
            planResponses: [["status": 200, "body": try fixture("stepfun_plan_raw")]]
        )

        XCTAssertEqual(execution.fetchCalls.count, 3)
        XCTAssertTrue(execution.timers.contains(300))
        XCTAssertEqual(try probe(execution.probes, named: "rate_limit").status, 200)
        let encoded = try jsonString(execution.probes)
        XCTAssertFalse(encoded.contains("person-placeholder@example.invalid"))
        XCTAssertFalse(encoded.contains("token-placeholder-first"))
        XCTAssertFalse(encoded.contains("token-placeholder-raw"))
        XCTAssertEqual(StepFunParser.parse(results: try probeResults(execution.probes), now: now).status, .ok)
    }
    #endif

    private func parse(
        rate: String,
        plan: String? = nil,
        rateStatus: Int = 200,
        planStatus: Int = 200
    ) -> ProviderSnapshot {
        var results = ["rate_limit": ProbeResult(status: rateStatus, body: rate)]
        if let plan {
            results["plan_status"] = ProbeResult(status: planStatus, body: plan)
        }
        return StepFunParser.parse(results: results, now: now)
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func coreSourcesURL() -> URL {
        repositoryRootURL().appendingPathComponent("Core/Sources/UsageLimitsCore")
    }

    private func providerScriptsURL() -> URL {
        repositoryRootURL().appendingPathComponent("App/Networking/ProviderScripts.swift")
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    #if canImport(JavaScriptCore)
    private struct ScriptExecution {
        let probes: [String: Any]
        let requested: [[String: Any]]
        let fetchCalls: [[String: Any]]
        let timers: [Int]
        let fetchCountAtFirstText: Int
    }

    private func executeProbeScript(
        cookie: String = "Oasis-Webid=webid-placeholder; Oasis-Token=token-placeholder-cookie",
        rateStatus: Int = 200,
        rateBody: String,
        planStatus: Int = 200,
        planBody: String
    ) throws -> ScriptExecution {
        try executeProbeScript(
            cookie: cookie,
            rateResponses: [["status": rateStatus, "body": rateBody]],
            planResponses: [["status": planStatus, "body": planBody]]
        )
    }

    private func executeProbeScript(
        cookie: String = "Oasis-Webid=webid-placeholder; Oasis-Token=token-placeholder-cookie",
        rateResponses: [[String: Any]],
        planResponses: [[String: Any]]
    ) throws -> ScriptExecution {
        let responses = ["rate": rateResponses, "plan": planResponses]
        let responsesJSON = try jsonString(responses)
        let cookieJSON = try jsonString(cookie)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() }
        let script = """
        var __stepDone = false;
        var __stepResult = null;
        var __stepError = null;
        var __stepRequested = [];
        var __stepFetchCalls = [];
        var __stepTimers = [];
        var __stepFirstTextFetchCount = -1;
        var __stepResponses = \(responsesJSON);
        var __stepIndices = { rate: 0, plan: 0 };
        var localStorage = {
            getItem: function (key) { return key === 'userToken' ? 'token-placeholder-local-storage' : null; }
        };
        var document = { cookie: \(cookieJSON) };
        function AbortController() {
            this.signal = { aborted: false };
            this.abort = function () { this.signal.aborted = true; };
        }
        function setTimeout(callback, delay) {
            __stepTimers.push(delay);
            if (delay === 300) { callback(); }
            return __stepTimers.length;
        }
        function clearTimeout(identifier) {}
        function URL(raw) {
            const match = String(raw).match(/^([a-z]+:[/][/][^/?#]+)([/][^?#]*)?/i);
            if (!match) { throw new Error('invalid URL'); }
            this.origin = match[1];
            this.pathname = match[2] || '/';
        }
        async function fetch(url, options) {
            const kind = String(url).indexOf('QueryStepPlanRateLimit') >= 0 ? 'rate' : 'plan';
            const list = __stepResponses[kind];
            const index = Math.min(__stepIndices[kind], list.length - 1);
            const response = list[index];
            __stepIndices[kind] += 1;
            __stepFetchCalls.push({
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
                url: 'https://platform.stepfun.com' + url + '?Oasis-Token=token-placeholder-query',
                headers: { get: function (name) { return null; } },
                text: async function () {
                    if (__stepFirstTextFetchCount < 0) { __stepFirstTextFetchCount = __stepFetchCalls.length; }
                    return response.body;
                }
            };
        }
        \(ProviderProbeScript.helper)
        const __stepProductionProbe = __probe;
        __probe = function (url, options) {
            __stepRequested.push({ url: url, options: options });
            return __stepProductionProbe(url, options);
        };
        (async function () {
        \(StepFunProbeScript.body)
        })().then(function (value) {
            __stepResult = JSON.stringify({
                probes: value.probes,
                requested: __stepRequested,
                fetchCalls: __stepFetchCalls,
                timers: __stepTimers,
                fetchCountAtFirstText: __stepFirstTextFetchCount
            });
            __stepDone = true;
        }, function (error) {
            __stepError = String(error && error.stack ? error.stack : error);
            __stepDone = true;
        });
        """
        context.evaluateScript(script)

        let deadline = Date().addingTimeInterval(2)
        while context.objectForKeyedSubscript("__stepDone")?.toBool() != true, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let exception {
            throw NSError(domain: "StepFunProbeScriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: exception])
        }
        guard context.objectForKeyedSubscript("__stepDone")?.toBool() == true else {
            throw NSError(domain: "StepFunProbeScriptTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "JavaScript Promise timed out"])
        }
        if let error = context.objectForKeyedSubscript("__stepError")?.toString(), error != "null" {
            throw NSError(domain: "StepFunProbeScriptTests", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
        }
        let raw = try XCTUnwrap(context.objectForKeyedSubscript("__stepResult")?.toString())
        let root = try object(raw)
        return ScriptExecution(
            probes: try XCTUnwrap(root["probes"] as? [String: Any]),
            requested: try XCTUnwrap(root["requested"] as? [[String: Any]]),
            fetchCalls: try XCTUnwrap(root["fetchCalls"] as? [[String: Any]]),
            timers: try XCTUnwrap(root["timers"] as? [Int]),
            fetchCountAtFirstText: try XCTUnwrap(root["fetchCountAtFirstText"] as? NSNumber).intValue
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

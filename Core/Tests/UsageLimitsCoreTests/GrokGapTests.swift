import XCTest
@testable import UsageLimitsCore

/// 对齐 CodexBar 的 Grok 缺口：gRPC 状态判定、缺值不当 0、通用扫描回退、周期标签、状态分流。
final class GrokGapTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testAuthenticatedWeeklyUsageConfirmsLoginDespiteOptionalCredits404() throws {
        // 周额度使用合成 protobuf，不包含用户日志中的交易号、身份或原始响应。
        let product = varintField(1, 2) + floatField(2, 2)
        let config = floatField(1, 2) + bytesField(7, product)
        let results: [String: ProbeResult] = [
            "rate_limits": ProbeResult(status: 200, body: try fixture("grok_authenticated_rate_limits")),
            "subscriptions": ProbeResult(status: 200, body: try fixture("grok_subscriptions")),
            "credits": ProbeResult(status: 404, body: #"{"code":5,"message":"Not Found","details":[]}"#),
            "weekly": ProbeResult(status: 200, body: Data(frame(bytesField(1, config))).base64EncodedString())
        ]
        let snap = GrokParser.parse(results: results, now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "SuperGrok Heavy")
        XCTAssertEqual(snap.metrics.first(where: { $0.id == "weekly" })?.usedPercent, 2)
        XCTAssertEqual(snap.metrics.first(where: { $0.id == "weekly.2" })?.usedPercent, 2)
        XCTAssertTrue(LoginProbePolicy.isAuthenticated(snap))
        XCTAssertTrue(RefreshPolicy.shouldCommit(old: nil, new: snap, results: results))
        XCTAssertNotEqual(LoginConfirm.action(probeOK: true, alreadyDetected: false,
            confirmationVisible: false, autoPromptSuppressed: false, siteIdentity: nil, displayName: "Grok"), .wait)
    }

    func testBrowserVerificationChallengeDoesNotClaimSessionExpired() throws {
        let body = #"{"code":7,"message":"A second factor must be presented in order to proceed. [WKE=unauthorized:second-factor-needed]","details":[]}"#
        let results: [String: ProbeResult] = [
            "rate_limits": ProbeResult(status: 200, body: try fixture("grok_wke_challenge")),
            "subscriptions": ProbeResult(status: 403, body: body),
            "credits": ProbeResult(status: 404, body: #"{"code":5,"message":"Not Found"}"#),
            "weekly": ProbeResult(status: 200, body: "")
        ]
        let snap = GrokParser.parse(results: results, now: now)
        XCTAssertEqual(snap.status, .error("Grok 需要浏览器验证"))
        XCTAssertTrue(snap.metrics.isEmpty)
        let old = ProviderSnapshot(provider: .grok, planName: "SuperGrok", metrics: [
            UsageMetric(id: "weekly", label: "Weekly", usedPercent: 25)
        ], fetchedAt: now, status: .ok)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: snap, results: results),
                       "浏览器校验失败不等于用户退出，不应清掉已知用量")
    }

    func testBrowserChallengeWithoutRateResponseStillExplainsVerification() {
        let results = ["subscriptions": ProbeResult(status: 403,
            body: #"{"message":"[WKE=unauthorized:second-factor-needed]"}"#)]
        XCTAssertEqual(GrokParser.parse(results: results, now: now).status,
                       .error(GrokParser.browserVerificationError))
    }

    func testMixedGrokResultsDoNotHideSuccessfulRateOrOrdinaryUnauthorized() throws {
        let challenge = #"{"message":"[WKE=unauthorized:second-factor-needed]"}"#
        let mixed = #"{"results":[{"modelName":"auto","status":200,"body":{"remainingQueries":1,"totalQueries":2}},{"modelName":"fast","status":403,"body":"[WKE=unauthorized:second-factor-needed]"}]}"#
        let results = ["rate_limits": ProbeResult(status: 200, body: mixed),
                       "subscriptions": ProbeResult(status: 403, body: challenge)]
        XCTAssertFalse(GrokParser.requiresBrowserVerification(results))
        XCTAssertTrue(GrokParser.parse(results: results, now: now).status.isOK)
        for status in [401, 403] {
            let results = ["rate_limits": ProbeResult(status: status, body: "unauthorized")]
            XCTAssertFalse(GrokParser.requiresBrowserVerification(results))
            XCTAssertEqual(GrokParser.parse(results: results, now: now).status, .needsLogin)
        }
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 字节拼装（不含任何真实凭据，全部是手工构造的报文）

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func tag(_ number: UInt64, _ wire: UInt64) -> [UInt8] { varint(number << 3 | wire) }

    private func bytesField(_ number: UInt64, _ payload: [UInt8]) -> [UInt8] {
        tag(number, 2) + varint(UInt64(payload.count)) + payload
    }

    private func floatField(_ number: UInt64, _ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return tag(number, 5) + [
            UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
            UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF),
        ]
    }

    private func varintField(_ number: UInt64, _ value: UInt64) -> [UInt8] {
        tag(number, 0) + varint(value)
    }

    private func frame(_ payload: [UInt8], trailer: Bool = false) -> [UInt8] {
        let n = payload.count
        return [trailer ? 0x80 : 0x00,
                UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + payload
    }

    private func trailerBody(_ lines: String) -> String {
        Data(frame(Array(lines.utf8), trailer: true)).base64EncodedString()
    }

    // MARK: - G1 / G2 / G3 gRPC 状态

    /// 状态 16 + no-credentials：端点要浏览器密钥（WKE），Cookie 登录不够。
    /// 不能判成未登录，只跳过 weekly 并记诊断。
    func testWeeklyTrailerStatus16MeansBrowserKeyNotLogout() throws {
        let body = trailerBody("grpc-status:16\r\ngrpc-message:no-credentials\r\n")
        let status = try XCTUnwrap(GrokParser.weeklyGRPCStatus(results: [
            "weekly": ProbeResult(status: 200, body: body),
        ]))
        XCTAssertEqual(status.code, 16)
        XCTAssertEqual(status.outcome, .needsBrowserKey)
        XCTAssertTrue(status.blocksParsing)
        XCTAssertEqual(status.note, "该端点需要浏览器密钥（WKE），Cookie 登录不够")

        // 主用量仍来自 /rest/*，卡片不该因此变成 needsLogin，也不该冒出 weekly 指标。
        let rate = #"{"results":[{"modelName":"auto","status":200,"body":{"windowSizeSeconds":7200,"remainingQueries":40,"totalQueries":50}}]}"#
        let snap = GrokParser.parse(
            results: [
                "rate_limits": ProbeResult(status: 200, body: rate),
                "weekly": ProbeResult(status: 200, body: body),
            ],
            now: now
        )
        XCTAssertEqual(snap.status, .ok)
        XCTAssertFalse(snap.metrics.contains { $0.id == "weekly" })
        XCTAssertEqual(snap.metrics.first?.id, "auto")
    }

    /// 响应头里的 grpc-status 同样要读；7 + bad-credentials 是 weekly 自身的未登录证据。
    func testWeeklyHeaderStatus7IsLoginEvidence() throws {
        let status = try XCTUnwrap(GrokWeeklyParser.grpcStatus(
            headers: ["grpc-status": "7", "grpc-message": "bad-credentials"], data: nil
        ))
        XCTAssertEqual(status.outcome, .needsLogin)
        XCTAssertTrue(status.note.contains("重新登录"))
    }

    /// 9 + no personal team：团队账号没有个人计费主体，跳过 weekly 并记诊断。
    func testWeeklyStatus9NoPersonalTeam() throws {
        let body = trailerBody("grpc-status:9\r\ngrpc-message:no personal team\r\n")
        let status = try XCTUnwrap(GrokWeeklyParser.grpcStatus(
            headers: nil, data: GrokWeeklyParser.decodeBase64(body)
        ))
        XCTAssertEqual(status.outcome, .noPersonalTeam)
        XCTAssertEqual(status.note, "该账号无个人计费主体（team 账号），周额度不可用")
    }

    /// trailer 优先于响应头；其它非 0 状态给通用文案；状态 0 视为正常（返回 nil）。
    func testWeeklyTrailerOverridesHeaderAndZeroIsOK() throws {
        let body = trailerBody("grpc-status:4\r\ngrpc-message:deadline exceeded\r\n")
        let status = try XCTUnwrap(GrokWeeklyParser.grpcStatus(
            headers: ["grpc-status": "0"], data: GrokWeeklyParser.decodeBase64(body)
        ))
        XCTAssertEqual(status.code, 4)
        XCTAssertEqual(status.outcome, .failed)
        XCTAssertEqual(status.note, "gRPC 状态 4：deadline exceeded")

        XCTAssertNil(GrokWeeklyParser.grpcStatus(headers: ["grpc-status": "0"], data: nil))
        XCTAssertNil(GrokWeeklyParser.grpcStatus(headers: [:], data: nil))
    }

    // MARK: - G6 缺值不当 0

    /// 只有周期、没有百分比：usagePercent 必须是 nil，指标不出百分比，也不该被当成 0%。
    func testPeriodOnlyCreditsDoesNotFakeZeroPercent() throws {
        let weekly = try XCTUnwrap(GrokWeeklyParser.parse(json: try fixture("grok_credits_period_only")))
        XCTAssertNil(weekly.usagePercent)
        XCTAssertFalse(weekly.percentIsWirePublished)
        XCTAssertNotNil(weekly.resetsAt)

        let snap = GrokParser.parse(
            results: ["credits": ProbeResult(status: 200, body: try fixture("grok_credits_period_only"))],
            now: now
        )
        let metric = try XCTUnwrap(snap.metrics.first { $0.id == "weekly" })
        XCTAssertNil(metric.usedPercent, "JSON 缺百分比就不画百分比")
        XCTAssertEqual(metric.pinned, true, "周限额常显：行还在，只是没有百分比")
        XCTAssertTrue(metric.hasUsage)
    }

    /// protobuf 路径：proto3 不上线默认值，只有 currentPeriod 的报文就是 0%（真机本周未用时的实际报文），
    /// 但 percentIsWirePublished 仍为 false 记录「报文里没出现」。
    func testProtobufPeriodOnlyMeansZeroPercent() throws {
        let end = varintField(1, 1_766_600_000)
        let period = bytesField(3, end)
        let config = bytesField(8, period)
        let message = bytesField(1, config)
        let data = Data(frame(message))
        let weekly = try XCTUnwrap(GrokWeeklyParser.parse(data: data, now: now))
        XCTAssertEqual(try XCTUnwrap(weekly.usagePercent), 0, accuracy: 0.000_001)
        XCTAssertFalse(weekly.percentIsWirePublished)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_766_600_000))

        let snap = GrokParser.parse(results: ["weekly": ProbeResult(status: 200, body: data.base64EncodedString())], now: now)
        let metric = try XCTUnwrap(snap.metrics.first { $0.id == "weekly" })
        XCTAssertEqual(try XCTUnwrap(metric.usedPercent), 0, accuracy: 0.000_001)
        XCTAssertTrue(metric.hasUsage, "0% 也要画出来，不能让卡片空着")
    }

    // MARK: - G7 通用扫描回退

    /// 字段号漂移（config 挂到了 field 2、百分比在 field 1、时间戳在 field 4）：
    /// 精确解析全落空，通用扫描仍能捞出百分比与重置时间。
    func testGenericScanRecoversDriftedFieldNumbers() throws {
        let inner = floatField(1, 42.5) + varintField(4, 1_766_600_000)
        let message = bytesField(2, inner)
        let data = Data(frame(message))
        let weekly = try XCTUnwrap(GrokWeeklyParser.parse(data: data, now: now))
        XCTAssertEqual(try XCTUnwrap(weekly.usagePercent), 42.5, accuracy: 0.001)
        XCTAssertTrue(weekly.percentIsWirePublished, "扫描出的百分比也算报文已发布")
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_766_600_000))
    }

    /// 扫描也捞不到任何东西时保持 nil，不许编数。
    func testGenericScanGivesUpOnGarbage() {
        let data = Data([0x11, 0x22, 0x33, 0x44])
        XCTAssertNil(GrokWeeklyParser.parse(data: data, now: now))
    }

    // MARK: - G10 周期标签

    /// currentPeriod.type = MONTHLY → 指标标签「本月限额」。
    func testMonthlyPeriodTypeChangesMetricLabel() throws {
        let snap = GrokParser.parse(
            results: ["credits": ProbeResult(status: 200, body: try fixture("grok_credits_monthly"))],
            now: now
        )
        let metric = try XCTUnwrap(snap.metrics.first { $0.id == "weekly" })
        XCTAssertEqual(metric.label, "本月限额")
        XCTAssertEqual(metric.usedPercent, 42)
        XCTAssertEqual(snap.metrics.map(\.label), ["本月限额", "Chat"])
    }

    /// type 缺失时按周期长度推断：30 天 → 本月限额，7 天 → 本周限额，其余默认本周。
    func testPeriodInferredFromLength() {
        let monthly = #"{"config":{"creditUsagePercent":5,"currentPeriod":{"start":"2026-08-01T00:00:00Z","end":"2026-08-31T00:00:00Z"}}}"#
        XCTAssertEqual(GrokWeeklyParser.parse(json: monthly)?.period, .monthly)
        let weekly = #"{"config":{"creditUsagePercent":5,"currentPeriod":{"start":"2026-08-01T00:00:00Z","end":"2026-08-08T00:00:00Z"}}}"#
        XCTAssertEqual(GrokWeeklyParser.parse(json: weekly)?.period, .weekly)
        let unknown = #"{"config":{"creditUsagePercent":5,"resetsAt":"2026-08-08T00:00:00Z"}}"#
        XCTAssertEqual(GrokWeeklyParser.parse(json: unknown)?.period, .weekly)
        XCTAssertEqual(GrokUsagePeriod.parse("USAGE_PERIOD_TYPE_DAILY"), .daily)
        XCTAssertEqual(GrokUsagePeriod.daily.metricLabel, "今日限额")
    }

    // MARK: - 状态分流

    /// 401 是凭据问题（needsLogin），5xx 不是——不该催用户重新登录。
    func testUnauthorizedVersusServerError() {
        let unauthorized = GrokParser.parse(results: ["rate_limits": ProbeResult(status: 401, body: "")], now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)

        let serverError = GrokParser.parse(results: ["rate_limits": ProbeResult(status: 500, body: "oops")], now: now)
        XCTAssertEqual(serverError.status, .error("HTTP 500"))

        let timeout = GrokParser.parse(results: ["rate_limits": ProbeResult(status: -3, body: "timeout after 12000ms")], now: now)
        XCTAssertEqual(timeout.status, .error("请求超时"))
    }

    func testUnauthorizedRateLimitsWipeCreditsLeftover() throws {
        let nested = #"{"results":[{"status":401,"modelName":"auto","requestKind":"DEFAULT","body":{}},{"status":401,"modelName":"fast","requestKind":"DEFAULT","body":{}}]}"#
        let snap = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: nested),
            "credits": ProbeResult(status: 200, body: try fixture("grok_credits_period_only")),
        ], now: now)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty, "rate_limits 全 401 不得留下 credits/weekly leftover")
        XCTAssertNil(snap.planName)
    }
}

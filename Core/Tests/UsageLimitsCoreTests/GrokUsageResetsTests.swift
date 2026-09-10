import XCTest
@testable import UsageLimitsCore

/// grok.com「Usage Limit Reset」的只读摘要。字段号取自官网 proto 描述符：
/// `prod_mc_billing.ConsumerUiSvc`（10/20/30）与 `grok_api_v2.GrokBuildBilling`（1/2/3）。
final class GrokUsageResetsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_031_840)

    // MARK: - gRPC-Web / protobuf 组包

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private func delimited(_ number: UInt64, _ payload: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    private func timestamp(_ number: UInt64, _ date: Date) -> Data {
        delimited(number, varint(1 << 3 | 0) + varint(UInt64(date.timeIntervalSince1970)))
    }

    /// 一个 ResetToken：id 用 `idField`，validity_end 用 `endField`（`startField` 只为证明我们不读它）。
    private func token(id: String, end: Date, start: Date? = nil, fields: (id: UInt64, start: UInt64, end: UInt64)) -> Data {
        var body = delimited(fields.id, Data(id.utf8))
        if let start { body += timestamp(fields.start, start) }
        body += timestamp(fields.end, end)
        return body
    }

    private func frame(_ payload: Data) -> Data {
        let count = UInt32(payload.count)
        return Data([0, UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF),
                     UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]) + payload
    }

    /// 完整响应：`tokens` 重复字段 + gRPC-Web 数据帧 + base64。
    private func body(tokens: [Data], listField: UInt64) -> String {
        frame(tokens.reduce(Data()) { $0 + delimited(listField, $1) }).base64EncodedString()
    }

    private func consumerBody(_ items: [(String, Date)]) -> String {
        body(tokens: items.map { token(id: $0.0, end: $0.1, start: now, fields: (10, 20, 30)) }, listField: 10)
    }

    private func facadeBody(_ items: [(String, Date)]) -> String {
        body(tokens: items.map { token(id: $0.0, end: $0.1, start: now, fields: (1, 2, 3)) }, listField: 1)
    }

    private func day(_ offset: Double) -> Date { now.addingTimeInterval(offset * 86400) }

    // MARK: - 快照

    func testAuthenticatedBrowserFixtureMatchesBothServicesWithoutPersistingTokenIDs() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "grok_resets_authenticated", withExtension: "json", subdirectory: "Fixtures"))
        let probes = try JSONDecoder().decode([String: ProbeResult].self, from: Data(contentsOf: url))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-12T18:49:00Z"))
        for (name, probe) in probes {
            let snap = snapshot([name: probe])
            XCTAssertEqual(snap.grokUsageResets?.availableCount, 1)
            XCTAssertEqual(snap.grokUsageResets?.expiresAt, expected)
            XCTAssertEqual(snap.grokUsageResets?.availableExpirations, [expected])
            let persisted = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
            XCTAssertFalse(persisted.contains("xxxxxxxxxxxxx"))
            XCTAssertFalse(persisted.contains("token_id"))
        }
    }

    func testIncompleteCompressedOrUnknownMessagesDoNotBecomeZero() {
        let corruptBodies = [
            frame(Data([0x52, 0x7F])), // 声称有 127 字节 token，实际缺失
            frame(Data([0x80])), // 截断的 protobuf varint
            frame(delimited(99, Data("schema-drift".utf8))),
            Data([1, 0, 0, 0, 0]), // 压缩帧不能按空消息解析
            frame(Data()) + Data([0x80, 0, 0]), // trailer 传输不完整
            frame(Data()) + frame(Data()) // unary RPC 不应有两条响应
        ]
        for corrupt in corruptBodies {
            let probe = ProbeResult(status: 200, body: corrupt.base64EncodedString())
            XCTAssertNil(snapshot(["resets": probe]).grokUsageResets)
            XCTAssertEqual(snapshot([
                "resets": probe,
                "resets_facade": ProbeResult(status: 200, body: facadeBody([("fixture-fallback", day(8))]))
            ]).grokUsageResets?.availableCount, 1)
        }
    }

    private func snapshot(_ probes: [String: ProbeResult]) -> ProviderSnapshot {
        var results = probes
        results["subscriptions"] = ProbeResult(status: 200, body: #"{"subscriptions":[{"tier":"SUPER_GROK_PRO"}]}"#)
        return GrokParser.parse(results: results, now: now)
    }

    func testCountsUnexpiredTokensAndTakesEarliestExpiry() throws {
        let snap = snapshot([
            "resets": ProbeResult(status: 200, body: consumerBody([
                ("token-c", day(26)),
                ("token-a", day(12)),
                ("token-expired", day(-1)),
                ("token-a", day(12)),
                ("token-b", day(19)),
            ]))
        ])
        let summary = try XCTUnwrap(snap.grokUsageResets)
        XCTAssertEqual(summary.availableCount, 3)
        XCTAssertEqual(summary.expiresAt, day(12))
        XCTAssertEqual(summary.availableExpirations, [day(12), day(19), day(26)])
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snap)), snap)
    }

    func testFacadeServiceIsUsedWhenTheDefaultBranchGivesNothing() throws {
        let facade = ProbeResult(status: 200, body: facadeBody([("token-a", day(9))]))
        for fallback in [
            ProbeResult(status: 200, body: "", headers: nil),
            ProbeResult(status: 500, body: consumerBody([("token-x", day(3))])),
            ProbeResult(status: 200, body: consumerBody([("token-x", day(3))]),
                        headers: ["grpc-status": "16", "grpc-message": "no-credentials"]),
        ] {
            let snap = snapshot(["resets": fallback, "resets_facade": facade])
            XCTAssertEqual(snap.grokUsageResets?.availableCount, 1)
            XCTAssertEqual(snap.grokUsageResets?.expiresAt, day(9))
        }
    }

    func testEmptyTokenListIsZeroButTrailerOnlyIsNoAnswer() throws {
        let empty = snapshot(["resets": ProbeResult(status: 200, body: body(tokens: [], listField: 10))])
        XCTAssertEqual(empty.grokUsageResets?.availableCount, 0)
        XCTAssertNil(empty.grokUsageResets?.expiresAt)
        XCTAssertNil(empty.grokUsageResets?.availableExpirations)

        // trailer 帧（flag 0x80）没有数据：不能当成 0 张
        let trailer = Data([0x80, 0, 0, 0, 16]) + Data("grpc-status: 0\r\n".utf8)
        XCTAssertNil(snapshot(["resets": ProbeResult(status: 200, body: trailer.base64EncodedString())]).grokUsageResets)
        XCTAssertNil(snapshot(["resets": ProbeResult(status: 200, body: "")]).grokUsageResets)
        XCTAssertNil(snapshot([:]).grokUsageResets)
    }

    func testMalformedTokensAreSkippedRatherThanCounted() throws {
        // 缺 token_id / 缺 validity_end / 时间戳为 0：整条跳过，不进次数
        let noID = timestamp(30, day(5))
        let noEnd = delimited(10, Data("token-a".utf8))
        let zeroStamp = delimited(10, Data("token-b".utf8)) + delimited(30, varint(1 << 3 | 0) + varint(0))
        let good = token(id: "token-c", end: day(7), fields: (10, 20, 30))
        let snap = snapshot([
            "resets": ProbeResult(status: 200, body: body(tokens: [noID, noEnd, zeroStamp, good], listField: 10))
        ])
        XCTAssertEqual(snap.grokUsageResets?.availableCount, 1)
        XCTAssertEqual(snap.grokUsageResets?.expiresAt, day(7))
    }

    func testGuestAndUnauthorizedNeverCarryResetCounts() {
        let good = ProbeResult(status: 200, body: consumerBody([("token-a", day(5))]))
        // 游客：没有订阅，套餐名是「游客额度」，不查重置券
        let guest = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: #"{"results":[{"modelName":"auto","status":200,"body":{"remainingQueries":2,"totalQueries":2,"windowSizeSeconds":7200}}]}"#),
            "resets": good
        ], now: now)
        XCTAssertEqual(guest.isAnonymous, true)
        XCTAssertNil(guest.grokUsageResets)

        // 未登录：rate_limits 401 会清掉整卡，重置券也不得留下
        let unauthorized = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 401, body: "{}"),
            "resets": good
        ], now: now)
        XCTAssertEqual(unauthorized.status, .needsLogin)
        XCTAssertNil(unauthorized.grokUsageResets)
    }

    func testResetProbesAreNeitherTransportEvidenceNorDiagnosticPreview() {
        let old = ProviderSnapshot(provider: .grok, metrics: [UsageMetric(id: "weekly", label: "本周限额", usedPercent: 3)],
                                   fetchedAt: now, status: .ok)
        // 核心探针 5xx / 超时时，补充探针的 200 不得解除 last-good 保护
        for coreStatus in [503, -3] {
            let results: [String: ProbeResult] = [
                "rate_limits": ProbeResult(status: coreStatus, body: "{}"),
                "subscriptions": ProbeResult(status: coreStatus, body: "{}"),
                "resets": ProbeResult(status: 200, body: consumerBody([("token-a", day(5))])),
                "resets_facade": ProbeResult(status: 200, body: "")
            ]
            let new = GrokParser.parse(results: results, now: now)
            XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: new, results: results))
        }
        // token_id 是兑换凭据，诊断日志只留状态与长度
        for name in ["resets", "resets_facade"] {
            let line = DiagnosticRedactor.probeLine(prefix: "grok", name: name, status: 200, body: "redeemable-token-id")
            XCTAssertFalse(line.contains("redeemable-token-id"))
        }
    }

    func testInvalidSummaryCannotPersist() throws {
        var snap = snapshot(["resets": ProbeResult(status: 200, body: consumerBody([("token-a", day(5))]))])
        XCTAssertNil(snap.persistenceValidationIssue)
        snap.grokUsageResets?.availableCount = -1
        XCTAssertEqual(snap.persistenceValidationIssue, "grokUsageResets")
        snap.grokUsageResets?.availableCount = 1
        snap.grokUsageResets?.availableExpirations = [Date(timeIntervalSince1970: .infinity)]
        XCTAssertEqual(snap.persistenceValidationIssue, "grokUsageResets")
    }

    func testOlderSnapshotWithoutTheSummaryStillDecodes() throws {
        let old = ProviderSnapshot(provider: .grok, fetchedAt: now, status: .ok)
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("grokUsageResets"))
        XCTAssertNil(try JSONDecoder().decode(ProviderSnapshot.self, from: data).grokUsageResets)
        let summary = try JSONDecoder().decode(GrokUsageResets.self, from: Data(#"{"availableCount":2}"#.utf8))
        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertNil(summary.availableExpirations)
    }

    func testCardExpandsOnResetsAloneAndPanelStaysInsideTheExpandedCard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent("App/Views/ProviderCardView.swift"))
        let compact = card.filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains("snapshot?.provider==.grok,snapshot?.isCustom!=true,snapshot?.grokUsageResets?.availableCount!=nil{returntrue}"))
        XCTAssertEqual(card.components(separatedBy: "GrokUsageResetsView(").count - 1, 1)
        XCTAssertTrue(card.contains("if isExpanded, !isCustom, snap.provider == .grok"))

        let wrapper = try String(contentsOf: root.appendingPathComponent("App/Views/GrokUsageResetsView.swift"))
        XCTAssertTrue(wrapper.contains("AvailableResetsView("))
        let view = try String(contentsOf: root.appendingPathComponent("App/Views/OpenAIResetCreditsView.swift"))
        XCTAssertTrue(view.contains("private static let visibleSlots = 3"))
        XCTAssertTrue(view.contains(".environment(\\.isScrollEnabled, dates.count > Self.visibleSlots)"))
        XCTAssertTrue(view.contains("Color.clear.dashboardSceneControlRegion()"))
        // 只读：App 内不得出现兑换入口
        XCTAssertFalse(view.lowercased().contains("redeem"))
    }

    /// 兑换会真的花掉用户的重置券：探针脚本里只许出现 GetRemainingResets。
    func testProbeScriptNeverRedeems() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("App/Networking/ProviderScripts.swift"))
        XCTAssertFalse(script.contains("/RedeemReset"), "兑换会真的花掉用户的重置券，探针不许请求它")
        XCTAssertTrue(script.contains("/prod_mc_billing.ConsumerUiSvc/GetRemainingResets"))
        XCTAssertTrue(script.contains("/grok_api_v2.GrokBuildBilling/GetRemainingResets"))
    }
}

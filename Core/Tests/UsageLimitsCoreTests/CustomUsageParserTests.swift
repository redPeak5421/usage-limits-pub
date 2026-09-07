import XCTest
@testable import UsageLimitsCore

final class CustomUsageParserTests: XCTestCase {
    private func template(
        fields: [CustomUsageField] = [
            CustomUsageField(path: "data.used", displayName: "已用"),
            CustomUsageField(path: "data.remain", displayName: "余额"),
        ]
    ) -> CustomUsageTemplate {
        CustomUsageTemplate(
            name: "中转",
            requestURL: "https://api.example.com/v1/usage",
            fields: fields
        )!
    }

    func testFlattenNestedObjectAndArrayIndex() {
        let body = """
        {"data":{"used":12.5,"remain":87.5},"items":[{"balance":3},{"balance":9}]}
        """
        let result = CustomJSONPreview.preview(body: body)
        XCTAssertNil(result.error)
        let paths = result.leaves.map(\.path)
        XCTAssertTrue(paths.contains("data.used"))
        XCTAssertTrue(paths.contains("data.remain"))
        XCTAssertTrue(paths.contains("items[0].balance"))
        XCTAssertTrue(paths.contains("items[1].balance"))
        XCTAssertEqual(result.leaves.first { $0.path == "data.used" }?.value, 12.5)
        XCTAssertEqual(CustomJSONPreview.value(at: "items[0].balance", in: JSONHelp.object(body)! ) as? Int, 3)
        XCTAssertNil(CustomJSONPreview.value(at: "items.balance", in: JSONHelp.object(body)!))
    }

    func testFlattenNumberStringAndSkipsBoolean() {
        let body = """
        {"used":"12.5","ok":true,"flag":false,"nested":{"n":"0"}}
        """
        let result = CustomJSONPreview.preview(body: body)
        let paths = Set(result.leaves.map(\.path))
        XCTAssertEqual(paths, ["used", "nested.n"])
        XCTAssertEqual(result.leaves.first { $0.path == "used" }?.value, 12.5)
        XCTAssertFalse(paths.contains("ok"))
        XCTAssertFalse(paths.contains("flag"))
    }

    func testFlattenDoesNotTreatFractionAsPercent() {
        let result = CustomJSONPreview.preview(body: #"{"used":0.5}"#)
        XCTAssertEqual(result.leaves.first?.value, 0.5)
    }

    func testFlattenExtremeFiniteNumberUsesBoundedRawDisplayAndRejectsNonFiniteStrings() throws {
        let result = CustomJSONPreview.preview(body: #"{"huge":1e308,"bad":"1e309","nan":"NaN"}"#)
        let huge = try XCTUnwrap(result.leaves.first { $0.path == "huge" })
        XCTAssertEqual(huge.value, 1e308)
        XCTAssertLessThan(huge.rawDisplay.count, 32)
        XCTAssertFalse(result.leaves.contains { $0.path == "bad" || $0.path == "nan" })
    }

    func testFlattenTruncatesDepthAndLeafCount() {
        var nested = "1"
        for _ in 0..<12 {
            nested = "{\"x\":\(nested)}"
        }
        let deep = CustomJSONPreview.preview(body: nested)
        XCTAssertTrue(deep.truncated)

        var dict: [String: Any] = [:]
        for index in 0..<250 { dict["k\(index)"] = index }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        let many = CustomJSONPreview.preview(body: String(data: data, encoding: .utf8)!)
        XCTAssertTrue(many.truncated)
        XCTAssertEqual(many.leaves.count, CustomJSONPreview.maxLeaves)
    }

    func testPreviewRejectsNonJSONAndOversize() {
        XCTAssertEqual(CustomJSONPreview.preview(body: "not-json").error, "custom.error.notJSON")
        let huge = String(repeating: "a", count: CustomJSONPreview.maxBodyBytes + 8)
        let oversize = CustomJSONPreview.preview(body: huge)
        XCTAssertEqual(oversize.error, "custom.error.tooLarge")
        XCTAssertTrue(oversize.truncated)
    }

    func testParseMappedFieldsUsePathIDs() {
        let body = #"{"data":{"used":12.5,"remain":87.5}}"#
        let snap = CustomUsageParser.parse(status: 200, body: body, template: template())
        XCTAssertTrue(snap.isCustom)
        XCTAssertEqual(snap.provider, .claude)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.metrics.map(\.id), ["data.used", "data.remain"])
        XCTAssertEqual(snap.metrics.map(\.label), ["已用", "余额"])
        XCTAssertEqual(snap.metrics[0].amount, 12.5)
        XCTAssertEqual(snap.metrics[1].amount, 87.5)
        XCTAssertTrue(snap.metrics.allSatisfy { $0.usedPercent == nil })
        XCTAssertTrue(snap.metrics.allSatisfy { $0.pinned == true })
    }

    func testParseSingleMappingAndZeroAmountPinned() {
        let usedOnly = CustomUsageParser.parse(
            status: 200,
            body: #"{"data":{"used":0,"remain":10}}"#,
            template: template(fields: [CustomUsageField(path: "data.used", displayName: "已用")])
        )
        XCTAssertEqual(usedOnly.metrics.map(\.id), ["data.used"])
        XCTAssertEqual(usedOnly.metrics[0].amount, 0)
        XCTAssertTrue(usedOnly.metrics[0].hasUsage)

        let balanceOnly = CustomUsageParser.parse(
            status: 200,
            body: #"{"data":{"used":1,"remain":2}}"#,
            template: template(fields: [CustomUsageField(path: "data.remain", displayName: "余额")])
        )
        XCTAssertEqual(balanceOnly.metrics.map(\.id), ["balance"])
        XCTAssertEqual(balanceOnly.metrics[0].label, "余额")
        XCTAssertEqual(balanceOnly.metrics[0].amount, 2)
    }

    func testParseDoesNotInventUsedWhenOnlyBalances() {
        let snap = CustomUsageParser.parse(
            status: 200,
            body: #"{"balance":10,"remaining":10}"#,
            template: template(fields: [
                CustomUsageField(path: "balance", displayName: "余额"),
                CustomUsageField(path: "remaining", displayName: "剩余额度"),
            ])
        )
        XCTAssertEqual(snap.metrics.map(\.id), ["balance", "remaining"])
        XCTAssertEqual(snap.metrics.map(\.label), ["余额", "剩余额度"])
        XCTAssertFalse(snap.metrics.contains { $0.id == "used" })
    }

    func testParseDoesNotScalePercent() {
        let snap = CustomUsageParser.parse(
            status: 200,
            body: #"{"used":0.5}"#,
            template: template(fields: [CustomUsageField(path: "used", displayName: "已用")])
        )
        XCTAssertEqual(snap.metrics.first?.amount, 0.5)
        XCTAssertNil(snap.metrics.first?.usedPercent)
    }

    func testDefaultDisplayNameUsesLastPathSegment() {
        XCTAssertEqual(CustomUsageTemplate.defaultDisplayName(for: "balance"), "balance")
        XCTAssertEqual(CustomUsageTemplate.defaultDisplayName(for: "data.remain"), "remain")
        XCTAssertEqual(CustomUsageTemplate.defaultDisplayName(for: "items[0].balance"), "balance")
    }

    func testLogoPolicySkipsWhenIconExists() {
        XCTAssertTrue(CustomUsageLogoPolicy.shouldResolveOnTest(hasExistingLogo: false))
        XCTAssertFalse(CustomUsageLogoPolicy.shouldResolveOnTest(hasExistingLogo: true))
    }

    func testParse401NeedsLoginWithEmptyMetrics() {
        let snap = CustomUsageParser.parse(
            status: 401,
            body: #"{"error":"unauthorized"}"#,
            template: template()
        )
        XCTAssertTrue(snap.status.isNeedsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
        XCTAssertTrue(snap.isCustom)
    }

    func testParseMissingPathsAndNonJSON() {
        let missing = CustomUsageParser.parse(
            status: 200,
            body: #"{"other":1}"#,
            template: template()
        )
        XCTAssertEqual(missing.status, .error("custom.error.unreadable"))
        XCTAssertEqual(missing.status.displayText(.zh), "字段无法读取")
        XCTAssertEqual(missing.status.displayText(.en), "Couldn't read fields")
        let notJSON = CustomUsageParser.parse(status: 200, body: "<html>", template: template())
        XCTAssertEqual(notJSON.status, .error("custom.error.notJSON"))
        XCTAssertEqual(CustomJSONPreview.preview(body: "not-json").error, "custom.error.notJSON")
        let server = CustomUsageParser.parse(status: 503, body: "{}", template: template())
        XCTAssertEqual(server.status, .error("HTTP 503"))
        XCTAssertEqual(server.status.displayText(.zh), "HTTP 503")
    }


    func testTransportStatusKeepsMappedClientMessage() {
        for message in ["证书不受信任", "超时", "无网络", "明文被拦"] {
            let snap = CustomUsageParser.parse(status: -1, body: message, template: template())
            XCTAssertEqual(snap.status, .error(message), message)
            XCTAssertTrue(snap.metrics.isEmpty)
        }
        let unknown = CustomUsageParser.parse(status: -1, body: "The Internet connection appears to be offline.", template: template())
        XCTAssertEqual(unknown.status, .error("custom.error.requestFailed"))
    }

    func testRefreshSynthesizesNeedsLoginKeepingOldMetrics() {
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 12.5, pinned: true)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ok,
            isCustom: true
        )
        let parsed = CustomUsageParser.parse(status: 401, body: "", template: template())
        let results = CustomUsageRefresh.results(from: ProbeResult(status: 401, body: ""))
        let committed = CustomUsageRefresh.commit(old: old, parsed: parsed, results: results)
        XCTAssertEqual(committed?.status, .needsLogin)
        XCTAssertEqual(committed?.metrics.first?.amount, 12.5)
        XCTAssertEqual(committed?.fetchedAt, old.fetchedAt)
        XCTAssertTrue(committed?.isCustom == true)
    }

    func testRefreshDoesNotCommitTransientFailure() {
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 3, pinned: true)],
            fetchedAt: Date(),
            status: .ok,
            isCustom: true
        )
        let parsed = CustomUsageParser.parse(status: 429, body: "slow", template: template())
        let results = CustomUsageRefresh.results(from: ProbeResult(status: 429, body: "slow"))
        XCTAssertNil(CustomUsageRefresh.commit(old: old, parsed: parsed, results: results))
        XCTAssertNil(CustomUsageRefresh.commit(
            old: old,
            parsed: CustomUsageParser.parse(status: -1, body: "超时", template: template()),
            results: CustomUsageRefresh.results(from: ProbeResult(status: -1, body: "超时"))
        ))
    }

    func testEmptyTokenSynthesizesNeedsLoginKeepingOldMetrics() async {
        let old = ProviderSnapshot(
            provider: .claude,
            metrics: [UsageMetric(id: "used", label: "已用", amount: 12.5, pinned: true)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .ok,
            isCustom: true
        )
        let client = CustomUsageClient(session: CustomUsageClient.makeSession(), timeout: 1)
        let outcome = await CustomUsageRefresh.perform(
            template: template(),
            token: nil,
            old: old,
            client: client
        )
        XCTAssertTrue(outcome.didCommit)
        XCTAssertTrue(outcome.snapshot.status.isNeedsLogin)
        XCTAssertEqual(outcome.snapshot.metrics.first?.amount, 12.5)
    }

    func testDiagnosticLineHasHostStatusBytesNoURL() {
        let line = CustomUsageRefresh.diagnosticLine(
            templateName: "中转", host: "api.example.com", status: 200, bytes: 123
        )
        XCTAssertEqual(line, "custom.中转: HTTP 200，123 字节 host=api.example.com")
        XCTAssertFalse(line.contains("https://"))
        XCTAssertFalse(line.contains("token"))
        XCTAssertFalse(line.contains("Authorization"))
    }

    func testTimestampRoleAcceptsISO8601String() {
        let iso = "2026-09-01T00:00:00Z"
        let body = "{\"subscription\":{\"current_period_end\":\"\(iso)\"}}"
        let snap = CustomUsageParser.parse(
            status: 200,
            body: body,
            template: template(fields: [
                CustomUsageField(
                    path: "subscription.current_period_end",
                    displayName: "账期结束",
                    role: .timestamp
                )
            ])
        )
        XCTAssertEqual(snap.status, .ok)
        let metric = snap.metrics.first { $0.id == "subscription.current_period_end" }
        XCTAssertNotNil(metric?.resetsAt)
        XCTAssertEqual(metric?.resetsAt, JSONHelp.date(iso))
        XCTAssertEqual(metric?.kind, CustomFieldRole.timestamp.rawValue)
        XCTAssertNotEqual(metric?.amount, 2026, "ISO 不得被 lenientNumber 收成年份")
    }

    func testPreviewIncludesISO8601TimestampLeaf() {
        let iso = "2026-09-01T00:00:00Z"
        let body = """
        {"balance":{"credits_remaining_usd":12.5},"subscription":{"current_period_end":"\(iso)"}}
        """
        let result = CustomJSONPreview.preview(body: body)
        let leaf = result.leaves.first { $0.path == "subscription.current_period_end" }
        XCTAssertNotNil(leaf, "向导必须露出 ISO 时间戳叶子，预设才能勾上账期结束")
        XCTAssertEqual(leaf?.hint.role, .timestamp)
        XCTAssertEqual(leaf?.rawDisplay, iso)
        XCTAssertNotNil(leaf?.value)
        XCTAssertEqual(leaf?.value, JSONHelp.date(iso)?.timeIntervalSince1970)
        XCTAssertNotEqual(leaf?.value, 2026)
    }

    func testCustomMdDocumentsISOTimestamp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let md = try String(
            contentsOf: root.appendingPathComponent("providers/custom.md"), encoding: .utf8
        )
        XCTAssertTrue(md.contains("ISO 8601") || md.contains("ISO8601"), "目录须写明 timestamp 接受 ISO 字符串")
        XCTAssertFalse(
            md.contains("timestamp` 角色只把 1970–9999 内的 epoch"),
            "不得再写成只认 epoch"
        )
        XCTAssertTrue(md.contains("UTC") || md.contains("无时区"), "目录须写明无时区 ISO 按 UTC")
    }

    func testOutOfRangeTimestampKeepsValueWithoutDate() {
        let pastSafe = 253_402_300_800.0
        let snap = CustomUsageParser.parse(
            status: 200,
            body: #"{"reset":253402300800}"#,
            template: template(fields: [
                CustomUsageField(path: "reset", displayName: "重置", role: .timestamp)
            ])
        )
        XCTAssertEqual(snap.status, .ok)
        let metric = snap.metrics.first { $0.id == "reset" }
        XCTAssertNotNil(metric)
        XCTAssertNil(metric?.resetsAt, "越界不得生成 Date")
        XCTAssertEqual(metric?.amount, pastSafe)
        XCTAssertEqual(metric?.kind, CustomFieldRole.timestamp.rawValue)

        let text = CustomUsageParser.parse(
            status: 200,
            body: #"{"reset":"not-a-date"}"#,
            template: template(fields: [
                CustomUsageField(path: "reset", displayName: "重置", role: .timestamp)
            ])
        )
        let raw = text.metrics.first { $0.id == "reset" }
        XCTAssertNil(raw?.resetsAt)
        XCTAssertEqual(raw?.displayValue, "not-a-date")
        XCTAssertEqual(
            CustomUsageParser.metric(
                for: CustomUsageField(path: "reset", displayName: "重置", role: .timestamp),
                amount: pastSafe,
                in: [],
                json: ["reset": pastSafe]
            ).resetsAt,
            nil,
            "metric() 不得把越界 epoch 收成 Date"
        )
    }


    func testUniqueRequestRemainingKeepsPathID() {
        let snap = CustomUsageParser.parse(
            status: 200,
            body: #"{"usable_requests":250}"#,
            template: template(fields: [
                CustomUsageField(path: "usable_requests", displayName: "剩余请求", role: .remaining),
            ])
        )
        XCTAssertEqual(snap.metrics.map(\.id), ["usable_requests"])
        XCTAssertNotEqual(snap.metrics.first?.id, "balance")
    }

}

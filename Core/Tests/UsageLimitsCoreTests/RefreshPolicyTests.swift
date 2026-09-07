import XCTest
@testable import UsageLimitsCore

final class RefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func snap(status: SnapshotStatus, metrics: [UsageMetric] = []) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            metrics: metrics,
            fetchedAt: now,
            status: status
        )
    }

    func testCommitsFreshOKSnapshot() {
        let old = snap(status: .ok)
        let new = snap(status: .ok, metrics: [
            UsageMetric(id: "five_hour", label: "5h", usedPercent: 12)
        ])
        XCTAssertTrue(RefreshPolicy.shouldCommit(
            old: old, new: new,
            results: ["usage": ProbeResult(status: 200, body: "{}")]
        ))
    }

    func testPersistenceInvalidSnapshotNeverCommitsWithOrWithoutOldValue() {
        let old = snap(status: .ok, metrics: [
            UsageMetric(id: "five_hour", label: "5h", usedPercent: 12),
        ])
        let invalid = snap(status: .ok, metrics: [
            UsageMetric(id: "five_hour", label: "5h", usedPercent: 101),
        ])
        let results = ["usage": ProbeResult(status: 200, body: "{}")]
        XCTAssertNotNil(invalid.persistenceValidationIssue)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: invalid, results: results))
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: nil, new: invalid, results: results))
    }

    func testVisibleSnapshotUsesPersistedThenOldThenSafeNumberFreeError() {
        let old = snap(status: .ok, metrics: [
            UsageMetric(id: "five_hour", label: "5h", usedPercent: 12),
        ])
        let parsed = ProviderSnapshot(
            provider: .deepseek,
            planName: "unsafe",
            metrics: [UsageMetric(id: "bad", label: "bad", amount: .infinity)],
            fetchedAt: Date(timeIntervalSince1970: .infinity),
            status: .ok,
            planExpiresAt: Date(timeIntervalSince1970: .infinity),
            timeBreakdowns: [UsageBreakdown(id: "bad", label: "bad", tokens: .infinity)],
            isCustom: true
        )
        let persisted = snap(status: .needsLogin)
        XCTAssertEqual(
            RefreshPolicy.visibleSnapshot(old: old, parsed: parsed, persisted: persisted, now: now),
            persisted
        )
        XCTAssertEqual(
            RefreshPolicy.visibleSnapshot(old: old, parsed: parsed, persisted: nil, now: now),
            old
        )

        let fallback = RefreshPolicy.visibleSnapshot(
            old: nil, parsed: parsed, persisted: nil,
            now: Date(timeIntervalSince1970: .infinity)
        )
        XCTAssertEqual(fallback.provider, .deepseek)
        XCTAssertTrue(fallback.isCustom)
        XCTAssertTrue(fallback.metrics.isEmpty)
        XCTAssertNil(fallback.planName)
        XCTAssertNil(fallback.planExpiresAt)
        XCTAssertNil(fallback.timeBreakdowns)
        XCTAssertNil(fallback.keyBreakdowns)
        XCTAssertNil(fallback.modelBreakdowns)
        XCTAssertNil(fallback.creditHistory)
        XCTAssertNil(fallback.persistenceValidationIssue)
        if case .error = fallback.status {} else { XCTFail("first rejected snapshot must become safe error") }
    }

    func testAppRefreshFlowsDoNotExposeSnapshotsRejectedByPersistence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8
        )
        let background = try String(
            contentsOf: root.appendingPathComponent("App/BackgroundRefresh.swift"), encoding: .utf8
        )
        XCTAssertTrue(appState.contains("RefreshPolicy.visibleSnapshot"))
        XCTAssertTrue(appState.contains("let didPersist"))
        XCTAssertFalse(appState.contains("store.snapshot(for: provider) ?? snap"))
        XCTAssertFalse(appState.contains("store.accountSnapshot(for: account.id) ?? snap"))
        XCTAssertFalse(appState.contains("old ?? snap"))
        XCTAssertFalse(appState.contains("old ?? outcome.snapshot"))
        XCTAssertFalse(appState.contains("new: outcome.snapshot"))
        XCTAssertTrue(background.contains("guard store.save(snap)"))
        XCTAssertTrue(background.contains("guard store.saveAccountSnapshot(outcome.snapshot"))
        XCTAssertTrue(background.contains("old: old, new: committed, settings: settings"))
        XCTAssertFalse(background.contains("new: outcome.snapshot"))
    }

    func testCommitsWhenThereIsNoPreviousSnapshot() {
        let new = snap(status: .needsLogin)
        XCTAssertTrue(RefreshPolicy.shouldCommit(
            old: nil, new: new,
            results: ["script": ProbeResult(status: -3, body: "执行失败：请求超时")]
        ))
    }

    func testDoesNotReplaceOKWithScriptTimeoutNeedsLogin() {
        let old = snap(status: .ok, metrics: [
            UsageMetric(id: "five_hour", label: "5h", usedPercent: 40)
        ])
        // WebView 超时只带回 script/-3，解析层会当成 needsLogin
        let parsed = ClaudeParser.parse(
            results: ["script": ProbeResult(status: -3, body: "执行失败：请求超时")],
            now: now
        )
        XCTAssertEqual(parsed.status, .needsLogin)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: [
            "script": ProbeResult(status: -3, body: "执行失败：请求超时")
        ]))
    }

    func testDoesNotReplaceOKWithEmptyProbeError() {
        let old = snap(status: .ok)
        let parsed = ClaudeParser.parse(results: [:], now: now)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: [:]))
    }

    func testDoesNotReplaceOKWithOriginDriftOnly() {
        let old = snap(status: .ok)
        let results = ["origin_drift": ProbeResult(status: 0, body: "源漂移：当前停留在 claude.com")]
        let parsed = ClaudeParser.parse(results: results, now: now)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: results))
    }

    func testDoesNotReplaceOKWithOriginDriftPlusJunkHTTP() {
        let old = snap(status: .ok)
        let results: [String: ProbeResult] = [
            "origin_drift": ProbeResult(status: 0, body: "源漂移：当前停留在 claude.com"),
            "organizations": ProbeResult(status: 200, body: "<html>login</html>")
        ]
        let parsed = ClaudeParser.parse(results: results, now: now)
        XCTAssertEqual(parsed.status, .needsLogin)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: results))
    }

    func testDoesNotReplaceOKWithGrokSynthetic200AndFailedInners() {
        let old = ProviderSnapshot(provider: .grok, planName: "SuperGrok", fetchedAt: now, status: .ok)
        let rate = #"{"results":[{"modelName":"auto","requestKind":"DEFAULT","status":-1,"body":{}},{"modelName":"fast","requestKind":"DEFAULT","status":-1,"body":{}}]}"#
        let results: [String: ProbeResult] = [
            "rate_limits": ProbeResult(status: 200, body: rate),
            "subscriptions": ProbeResult(status: -1, body: "failed"),
            "credits": ProbeResult(status: -1, body: "failed"),
            "weekly": ProbeResult(status: -1, body: "failed")
        ]
        let parsed = GrokParser.parse(results: results, now: now)
        XCTAssertEqual(parsed.status, .error("网络错误"))
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: results))
    }

    func testSyntheticAggregateChildHTTPStatusesAreRealForReliabilityAndTransientChecks() {
        let grok401 = #"{"results":[{"status":401,"body":{}},{"status":-3,"body":{}}]}"#
        XCTAssertFalse(RefreshPolicy.isUnreliableProbe([
            "rate_limits": ProbeResult(status: 200, body: grok401)
        ]), "固定 200 壳里的真实 401 不能被当成无 HTTP")

        let periods503 = #"{"today":{"cost":{"status":503,"body":"busy"},"amount":{"status":503,"body":"busy"}}}"#
        XCTAssertTrue(RefreshPolicy.isTransientFailure([
            "usage_periods": ProbeResult(status: 200, body: periods503)
        ]))

        let comboTimeout = #"{"yearly":{"status":-3,"body":"timeout"},"monthly":{"status":-3,"body":"timeout"}}"#
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "combo": ProbeResult(status: 200, body: comboTimeout)
        ]))
    }

    func testDoesNotReplaceOKWithHTTP500() {
        let old = snap(status: .ok)
        let results = ["organizations": ProbeResult(status: 500, body: "unavailable")]
        let parsed = ClaudeParser.parse(results: results, now: now)
        // 2026-08 起 5xx 不再谎报「需要重新登录」，如实报站点错误（401/403 才是 needsLogin）；
        // 这里真正要守的仍是「不能拿它盖掉上一份已登录快照」。
        XCTAssertEqual(parsed.status, .error("HTTP 500"))
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: results))
    }

    func testDoesNotReplaceOKWithHTTP429() {
        let old = snap(status: .ok)
        let results = ["organizations": ProbeResult(status: 429, body: "rate limited")]
        let parsed = ClaudeParser.parse(results: results, now: now)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: old, new: parsed, results: results))
    }

    func testReplacesOKWithGenuineHTTP401() {
        let old = snap(status: .ok)
        let results = ["organizations": ProbeResult(status: 401, body: "")]
        let parsed = ClaudeParser.parse(results: results, now: now)
        XCTAssertEqual(parsed.status, .needsLogin)
        XCTAssertTrue(RefreshPolicy.shouldCommit(old: old, new: parsed, results: results))
    }

    func testDoesNotReplaceOKMetricsWithEmptyOK() {
        let old = snap(status: .ok, metrics: [
            UsageMetric(id: "remaining", label: "剩余积分", amount: 179, pinned: true)
        ])
        let new = snap(status: .ok, metrics: [])
        XCTAssertFalse(
            RefreshPolicy.shouldCommit(
                old: old, new: new,
                results: ["credit": ProbeResult(status: 200, body: #"{"ret":"1014","errmsg":"system busy"}"#)]
            ),
            "额度 1014 的空 ok 不得盖掉已有积分数字"
        )
    }

    func testDoesNotReplaceNumericOKWithUnavailablePlaceholder() {
        let old = snap(status: .ok, metrics: [
            UsageMetric(id: "remaining", label: "剩余积分", amount: 179, pinned: true)
        ])
        let new = snap(status: .ok, metrics: [
            UsageMetric(
                id: "remaining",
                label: "剩余积分",
                detail: JimengParser.unavailableDetail,
                pinned: true,
                displayValue: "—"
            )
        ])
        XCTAssertTrue(RefreshPolicy.hasNumericUsage(old))
        XCTAssertFalse(RefreshPolicy.hasNumericUsage(new))
        XCTAssertFalse(
            RefreshPolicy.shouldCommit(
                old: old, new: new,
                results: ["credit": ProbeResult(status: 200, body: #"{"ret":"1014","errmsg":"system busy"}"#)]
            ),
            "「—」占位不得盖掉已有积分数字"
        )
    }

    func testCommitsEmptyOKWhenNoPreviousMetrics() {
        let new = snap(status: .ok, metrics: [])
        XCTAssertTrue(RefreshPolicy.shouldCommit(
            old: nil, new: new,
            results: ["session": ProbeResult(status: 200, body: #"{"hasSession":true}"#)]
        ))
    }

    func testCommitsUnavailablePlaceholderWhenNoPreviousNumbers() {
        let new = snap(status: .ok, metrics: [
            UsageMetric(
                id: "remaining",
                label: "剩余积分",
                detail: JimengParser.unavailableDetail,
                pinned: true,
                displayValue: "—"
            )
        ])
        XCTAssertTrue(RefreshPolicy.shouldCommit(
            old: snap(status: .ok, metrics: []), new: new,
            results: ["credit": ProbeResult(status: 200, body: #"{"ret":"1014","errmsg":"system busy"}"#)]
        ))
    }

    func testUnreliableProbeWhenOnlyScriptFailure() {
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "script": ProbeResult(status: -3, body: "执行失败：请求超时")
        ]))
        XCTAssertFalse(RefreshPolicy.isUnreliableProbe([
            "organizations": ProbeResult(status: 401, body: "")
        ]))
        XCTAssertFalse(RefreshPolicy.isUnreliableProbe([
            "usage": ProbeResult(status: 200, body: "{}")
        ]))
    }

    func testPreservingBreakdownsKeepsLastGoodChartsWhenNewIsEmpty() {
        let old = ProviderSnapshot(
            provider: .deepseek,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 12, currency: "USD")],
            fetchedAt: Date(timeIntervalSince1970: 100),
            status: .ok,
            timeBreakdowns: [UsageBreakdown(id: "today", label: "今天", cost: 1.5)]
        )
        let fresh = ProviderSnapshot(
            provider: .deepseek,
            metrics: [UsageMetric(id: "balance", label: "余额", amount: 11, currency: "USD")],
            fetchedAt: Date(timeIntervalSince1970: 200),
            status: .ok
        )
        let merged = RefreshPolicy.preservingBreakdowns(old: old, new: fresh)
        XCTAssertEqual(merged.metrics.first?.amount, 11)
        XCTAssertEqual(merged.timeBreakdowns?.first?.cost, 1.5)
    }

    func testDoesNotReplaceOKWithSystemBusyError() {
        let old = snap(status: .ok, metrics: [
            UsageMetric(id: "remaining", label: "剩余积分", amount: 179, pinned: true)
        ])
        let results: [String: ProbeResult] = [
            "credit": ProbeResult(status: 200, body: #"{"ret":"1014","errmsg":"system busy"}"#),
            "history": ProbeResult(status: 200, body: #"{"ret":"1014","errmsg":"system busy"}"#),
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#),
            "session": ProbeResult(status: 200, body: #"{"hasSession":false}"#),
        ]
        let parsed = JimengParser.parse(results: results, now: now)
        if case .error(let message) = parsed.status {
            XCTAssertTrue(message.contains("繁忙"))
        } else {
            XCTFail("无会话 1014 应为系统繁忙，实际 \(parsed.status)")
        }
        XCTAssertFalse(
            RefreshPolicy.shouldCommit(old: old, new: parsed, results: results),
            "HTTP 200 的系统繁忙不得盖掉上一份积分"
        )
    }

    func testHistoryAloneIsNotNumericUsage() {
        var withHistory = snap(
            status: .ok,
            metrics: [
                UsageMetric(
                    id: "remaining", label: "剩余积分",
                    detail: JimengParser.unavailableDetail, pinned: true, displayValue: "—"
                )
            ]
        )
        withHistory.creditHistory = [
            CreditLedgerEntry(
                id: "h1", title: "赠送", amount: 10, historyType: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ]
        XCTAssertFalse(RefreshPolicy.hasNumericUsage(withHistory))
    }

    func testLocalSnapshot200DoesNotCountAsRealHTTP() {
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#)
        ]), "即梦 page 是本地快照，不能当成真实 HTTP")
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "region": ProbeResult(status: 200, body: #"{"host":"https://www.minimaxi.com"}"#),
            "remains": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ]), "MiniMax region 固定 200 加上超时不得算有真实 HTTP")
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "bootstrap": ProbeResult(status: 200, body: #"{"authStatus":"logged_out","hasEmail":false}"#),
            "session": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ]), "ChatGPT bootstrap 不发请求，session 超时仍是不可靠探针")
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "identity": ProbeResult(status: 200, body: #"{"identityFingerprint":"abc"}"#)
        ]))
        XCTAssertFalse(RefreshPolicy.isUnreliableProbe([
            "page": ProbeResult(status: 200, body: #"{"isLogined":false}"#),
            "credit": ProbeResult(status: 401, body: ""),
        ]), "额度 401 仍是真实 HTTP")
        XCTAssertTrue(RefreshPolicy.isUnreliableProbe([
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#),
            "session": ProbeResult(status: 200, body: #"{"hasSession":false}"#),
            "credit": ProbeResult(status: -3, body: "timeout after 12000ms"),
            "history": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ]), "即梦 session 是本机 Cookie 快照，不得把额度超时当成真实 HTTP")
        XCTAssertFalse(RefreshPolicy.isUnreliableProbe([
            "session": ProbeResult(status: 200, body: #"{"user":{"email":"u@example.com"},"accessToken":"t"}"#)
        ]), "ChatGPT session 是真 HTTP，不得因即梦同名键被丢掉")
    }

    func testDoesNotReplaceOKWithMiniMaxRegionOnlyTimeout() {
        let old = ProviderSnapshot(
            provider: .minimax,
            planName: "Token Plan",
            metrics: [UsageMetric(id: "five_hour", label: "5 小时", usedPercent: 20)],
            fetchedAt: now,
            status: .ok
        )
        let results: [String: ProbeResult] = [
            "region": ProbeResult(status: 200, body: #"{"host":"https://www.minimaxi.com","platform":"https://platform.minimaxi.com"}"#),
            "remains": ProbeResult(status: -3, body: "timeout after 12000ms"),
            "credit": ProbeResult(status: -3, body: "timeout after 12000ms"),
            "usage_summary": ProbeResult(status: -3, body: "timeout after 12000ms"),
            "combo": ProbeResult(status: 200, body: #"{"yearly":{"status":-3,"body":"timeout"},"monthly":{"status":-3,"body":"timeout"}}"#),
            "billing": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ]
        let parsed = MiniMaxParser.parse(results: results, now: now)
        XCTAssertFalse(parsed.status.isOK)
        XCTAssertFalse(
            RefreshPolicy.shouldCommit(old: old, new: parsed, results: results),
            "region/combo 合成 200 不得盖掉上一份 MiniMax 额度"
        )
    }

    func testDoesNotReplaceOKWithJimengPagePlusCreditTimeout() {
        let old = ProviderSnapshot(
            provider: .jimeng,
            metrics: [UsageMetric(id: "remaining", label: "剩余积分", amount: 179, pinned: true)],
            fetchedAt: now,
            status: .ok
        )
        let results: [String: ProbeResult] = [
            "page": ProbeResult(status: 200, body: #"{"isLogined":false,"hasUserInfo":false}"#),
            "session": ProbeResult(status: 200, body: #"{"hasSession":false}"#),
            "credit": ProbeResult(status: -3, body: "timeout after 12000ms"),
            "history": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ]
        let parsed = JimengParser.parse(results: results, now: now)
        XCTAssertFalse(parsed.status.isOK)
        XCTAssertFalse(
            RefreshPolicy.shouldCommit(old: old, new: parsed, results: results),
            "即梦 page/session 本地 200 加上额度超时不得盖掉上一份积分"
        )
    }

    func testDoesNotReplaceOKWithChatGPTBootstrapPlusSessionTimeout() {
        let old = ProviderSnapshot(
            provider: .openai,
            planName: "ChatGPT Plus",
            metrics: [UsageMetric(id: "primary_window", label: "Codex 5 小时窗口", usedPercent: 12)],
            fetchedAt: now,
            status: .ok
        )
        let results: [String: ProbeResult] = [
            "bootstrap": ProbeResult(status: 200, body: #"{"authStatus":"logged_out","hasEmail":false}"#),
            "session": ProbeResult(status: -3, body: "timeout after 12000ms"),
        ]
        let parsed = OpenAIParser.parse(results: results, now: now)
        XCTAssertFalse(parsed.status.isOK)
        XCTAssertFalse(
            RefreshPolicy.shouldCommit(old: old, new: parsed, results: results),
            "bootstrap 本地快照不得把 session 超时写成真实退出"
        )
    }


}

import XCTest
@testable import UsageLimitsCore

final class DiagnosticRedactorTests: XCTestCase {
    func testPreviewRedactsCredentialsKeepsUsageFields() {
        let body = #"{"user":{"email":"me@example.com","id":"u1"},"accessToken":"eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limits":{"primary_window":{"used_percent":99.4,"limit_window_seconds":604800,"reset_after_seconds":300000}},"msToken":"x","sessionid":"abc"}"#
        let out = DiagnosticRedactor.preview(body)
        XCTAssertFalse(out.contains("me@example.com"))
        XCTAssertFalse(out.contains("eyJhbGci"))
        XCTAssertFalse(out.contains("\"abc\""))
        XCTAssertTrue(out.contains("\"used_percent\":99.4"))
        XCTAssertTrue(out.contains("\"limit_window_seconds\":604800"))
        XCTAssertTrue(out.contains("<redacted"))
    }

    func testPreviewHandlesNonJSONAndHTMLAndTruncation() {
        XCTAssertEqual(DiagnosticRedactor.preview("<!doctype html><html></html>"), "<HTML 28 字节>")
        XCTAssertEqual(DiagnosticRedactor.preview("   "), "<空>")
        let long = String(repeating: "a b ", count: 400)
        XCTAssertTrue(DiagnosticRedactor.preview(long, limit: 100).hasPrefix(String(long.prefix(100))))
        XCTAssertTrue(DiagnosticRedactor.preview("Bearer abcdef.ghijkl").contains("Bearer <redacted>"))
    }

    func testSensitiveKeyMatchingIsWholeWordForShortFragments() {
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("accessToken"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("passport_csrf_token"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("sec_uid"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("api_key"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("monkey"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("apiKey"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("uid_tt"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("used_percent"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("subscription_plan"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("subscriptionID"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("liteSubscriptionID"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("sub"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("hasSub"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("reset_after_seconds"))
    }

    func testOpenCodeBillingRedactsStripeIdentifiersKeepsAmounts() {
        let body = #"{"balance":11777936060,"customerID":"cus_abc","paymentMethodID":"pm_xyz","paymentMethodLast4":"9447","subscriptionID":"sub_live","liteSubscriptionID":"sub_lite","monthlyLimit":100}"#
        let out = DiagnosticRedactor.preview(body)
        XCTAssertFalse(out.contains("cus_abc"))
        XCTAssertFalse(out.contains("pm_xyz"))
        XCTAssertFalse(out.contains("9447"))
        XCTAssertFalse(out.contains("sub_live"))
        XCTAssertFalse(out.contains("sub_lite"))
        XCTAssertTrue(out.contains("11777936060"), "金额保留")
        XCTAssertTrue(out.contains("\"monthlyLimit\":100"))
    }

    func testSummaryListsMetricsWithValuesAndResets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = ProviderSnapshot(
            provider: .openai, planName: "ChatGPT Pro 5x",
            metrics: [
                UsageMetric(id: "primary_window", label: "Codex 周窗口", usedPercent: 99.4, resetsAt: now.addingTimeInterval(7200)),
                UsageMetric(id: "balance", label: "余额", amount: 12.5, kind: "remaining"),
            ],
            fetchedAt: now, status: .ok
        )
        let s = DiagnosticRedactor.summary(of: snap, now: now)
        XCTAssertTrue(s.hasPrefix("status=ok plan=ChatGPT Pro 5x"))
        XCTAssertTrue(s.contains("primary_window「Codex 周窗口」99.4% resets=120min"))
        XCTAssertTrue(s.contains("balance「余额」amount=12.50 kind=remaining"))
        XCTAssertTrue(DiagnosticRedactor.summary(of: ProviderSnapshot(provider: .grok, fetchedAt: now, status: .error("系统繁忙"))).contains("status=error(系统繁忙)"))
    }

    func testSummaryAndJSONRedactionNeverTrapOnInvalidOrHugeNumbers() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = ProviderSnapshot(
            provider: .openai,
            metrics: [
                UsageMetric(
                    id: "invalid", label: "异常值",
                    usedPercent: .nan,
                    remaining: .infinity,
                    total: .greatestFiniteMagnitude,
                    resetsAt: Date(timeIntervalSince1970: .infinity),
                    amount: -.infinity
                ),
            ],
            fetchedAt: now,
            status: .ok
        )

        let summary = DiagnosticRedactor.summary(of: snap, now: now)
        XCTAssertTrue(summary.contains("<invalid-number>"))
        XCTAssertTrue(summary.contains("resets=<invalid-date>"))

        let redacted = DiagnosticRedactor.redact([
            "valid": 3.5,
            "nan": Double.nan,
            "infinity": Double.infinity,
        ], key: "")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(redacted))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: redacted))
    }

    func testExactNameKeyIsRedactedButPlanNameKept() {
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("name"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("Name"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("plan_name"), "plan_name 是业务字段，不能被 name 片段误伤")
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("model_name"))
        let body = #"{"name":"SECRETNAME","plan_name":"Pro","email":"ada@example.com"}"#
        let out = DiagnosticRedactor.preview(body)
        XCTAssertFalse(out.contains("SECRETNAME"))
        XCTAssertTrue(out.contains("Pro"), "套餐名应保留")
        XCTAssertFalse(out.contains("ada@example.com"))
    }

    func testNicknameWorkspaceAndUUIDAreRedacted() {
        let body = #"{"nickname":"Ada","displayName":"Ada Lovelace","workspace":"team-room","id":"550e8400-e29b-41d4-a716-446655440000"}"#
        let out = DiagnosticRedactor.preview(body)
        XCTAssertFalse(out.contains("Ada"))
        XCTAssertFalse(out.contains("team-room"))
        XCTAssertFalse(out.contains("550e8400"))
        XCTAssertTrue(out.contains("<uuid>"))
        XCTAssertTrue(out.contains("<redacted"))
    }


    func testProbeLineOmitsLongCatUserBodyAndKeepsTokenUsage() {
        let user = #"{"code":0,"data":{"name":"SECRETNAME","nickName":"NICK","phone":"13800001111","token":"abc"}}"#
        let line = DiagnosticRedactor.probeLine(prefix: "longcat", name: "user", status: 200, body: user)
        XCTAssertFalse(line.contains("SECRETNAME"))
        XCTAssertFalse(line.contains("NICK"))
        XCTAssertFalse(line.contains("13800001111"))
        XCTAssertFalse(line.contains("body="))
        XCTAssertTrue(line.contains("HTTP 200"))
        let extra = DiagnosticRedactor.probeLine(prefix: "longcat(工作号)", name: "user", status: 200, body: user)
        XCTAssertFalse(extra.contains("SECRETNAME"))
        XCTAssertFalse(extra.contains("body="))

        let packs = #"{"data":{"currentLot":{"totalToken":500000,"consumedToken":1212,"consumedRatio":0.02}}}"#
        let packLine = DiagnosticRedactor.probeLine(prefix: "longcat", name: "token_packs", status: 200, body: packs)
        XCTAssertTrue(packLine.contains("500000"), packLine)
        XCTAssertTrue(packLine.contains("1212"), packLine)
        XCTAssertTrue(packLine.contains("body="))
    }

    func testProbeLineOmitsChatGPTSessionAndDeepSeekCurrent() {
        let session = #"{"user":{"email":"me@example.com","name":"SECRETNAME","id":"u1"},"accessToken":"tok"}"#
        let sessionLine = DiagnosticRedactor.probeLine(prefix: "openai", name: "session", status: 200, body: session)
        XCTAssertFalse(sessionLine.contains("SECRETNAME"))
        XCTAssertFalse(sessionLine.contains("me@example.com"))
        XCTAssertFalse(sessionLine.contains("body="))
        XCTAssertTrue(sessionLine.contains("HTTP 200"))
        let extra = DiagnosticRedactor.probeLine(prefix: "openai(工作号)", name: "session", status: 200, body: session)
        XCTAssertFalse(extra.contains("SECRETNAME"))
        XCTAssertFalse(extra.contains("body="))

        let current = #"{"id_profile":{"name":"SECRETNAME","id":"u1"},"currency":"USD"}"#
        let currentLine = DiagnosticRedactor.probeLine(prefix: "deepseek", name: "current", status: 200, body: current)
        XCTAssertFalse(currentLine.contains("SECRETNAME"))
        XCTAssertFalse(currentLine.contains("body="))
        XCTAssertTrue(currentLine.contains("HTTP 200"))
    }

    func testProbeLineOmitsKimiUserAndZhipuCustomer() {
        let kimiUser = #"{"user":{"id":"user_abc","globalId":"gid-1","nickname":"SECRETNAME"}}"#
        let kimiLine = DiagnosticRedactor.probeLine(prefix: "kimi", name: "user", status: 200, body: kimiUser)
        XCTAssertFalse(kimiLine.contains("SECRETNAME"))
        XCTAssertFalse(kimiLine.contains("user_abc"))
        XCTAssertFalse(kimiLine.contains("gid-1"))
        XCTAssertFalse(kimiLine.contains("body="))
        XCTAssertTrue(kimiLine.contains("HTTP 200"))
        let kimiExtra = DiagnosticRedactor.probeLine(prefix: "kimi(工作号)", name: "user", status: 200, body: kimiUser)
        XCTAssertFalse(kimiExtra.contains("user_abc"))
        XCTAssertFalse(kimiExtra.contains("body="))

        let customer = #"{"code":200,"data":{"id":10001,"openId":"oid-9","unionId":"uid-9"}}"#
        let customerLine = DiagnosticRedactor.probeLine(prefix: "zhipu", name: "customer", status: 200, body: customer)
        XCTAssertFalse(customerLine.contains("10001"))
        XCTAssertFalse(customerLine.contains("oid-9"))
        XCTAssertFalse(customerLine.contains("uid-9"))
        XCTAssertFalse(customerLine.contains("body="))
        XCTAssertTrue(customerLine.contains("HTTP 200"))

        let quota = #"{"code":200,"data":{"percent":12}}"#
        let quotaLine = DiagnosticRedactor.probeLine(prefix: "zhipu", name: "quota", status: 200, body: quota)
        XCTAssertTrue(quotaLine.contains("12"), quotaLine)
        XCTAssertTrue(quotaLine.contains("body="))
    }

    func testProbeLineOmitsClaudeAccountOpenCodeStatusAndAugmentSubscription() {
        let account = #"{"email_address":"me@example.com","full_name":"SECRETNAME","memberships":[]}"#
        let accountLine = DiagnosticRedactor.probeLine(prefix: "claude", name: "account", status: 200, body: account)
        XCTAssertFalse(accountLine.contains("SECRETNAME"))
        XCTAssertFalse(accountLine.contains("me@example.com"))
        XCTAssertFalse(accountLine.contains("body="))
        XCTAssertTrue(accountLine.contains("HTTP 200"))
        let usage = #"{"extra_usage":{"used":1}}"#
        let usageLine = DiagnosticRedactor.probeLine(prefix: "claude", name: "usage", status: 200, body: usage)
        XCTAssertTrue(usageLine.contains("body="))
        XCTAssertTrue(usageLine.contains("1"), usageLine)

        let status = #"{"account":{"id":"acc_9","email":"ada@example.com"},"current":"acc_9"}"#
        let statusLine = DiagnosticRedactor.probeLine(prefix: "opencode", name: "status", status: 200, body: status)
        XCTAssertFalse(statusLine.contains("acc_9"))
        XCTAssertFalse(statusLine.contains("ada@example.com"))
        XCTAssertFalse(statusLine.contains("body="))
        let billing = #"{"balance":12,"monthlyLimit":100}"#
        let billingLine = DiagnosticRedactor.probeLine(prefix: "opencode", name: "billing", status: 200, body: billing)
        XCTAssertTrue(billingLine.contains("12"), billingLine)
        XCTAssertTrue(billingLine.contains("body="))

        let subscription = #"{"email":"ada@example.com","organization":"SECRETORG","credits_remaining":9}"#
        let subLine = DiagnosticRedactor.probeLine(prefix: "augment", name: "subscription", status: 200, body: subscription)
        XCTAssertFalse(subLine.contains("SECRETORG"))
        XCTAssertFalse(subLine.contains("ada@example.com"))
        XCTAssertFalse(subLine.contains("body="))
        let credits = #"{"credits_remaining":9}"#
        let creditsLine = DiagnosticRedactor.probeLine(prefix: "augment", name: "credits", status: 200, body: credits)
        XCTAssertTrue(creditsLine.contains("9"), creditsLine)
        XCTAssertTrue(creditsLine.contains("body="))
    }


    func testProbeLineOmitsT3ChatCustomerJSONL() {
        let body = #"{"json":{"email":"ada@example.com","customerId":"cus_9","name":"SECRETNAME"}}"#
        let line = DiagnosticRedactor.probeLine(prefix: "t3chat", name: "customer", status: 200, body: body)
        XCTAssertFalse(line.contains("SECRETNAME"))
        XCTAssertFalse(line.contains("ada@example.com"))
        XCTAssertFalse(line.contains("cus_9"))
        XCTAssertFalse(line.contains("body="))
        XCTAssertTrue(line.contains("HTTP 200"))
        let other = DiagnosticRedactor.probeLine(prefix: "t3chat", name: "usage", status: 200, body: #"{"used":3}"#)
        XCTAssertTrue(other.contains("body="))
        XCTAssertTrue(other.contains("3"), other)
    }


    func testDeepSeekApiKeysBodyOmittedAndTrackingIDRedacted() {
        let keys = #"{"data":{"biz_data":{"api_keys":[{"tracking_id":"key-c","name":"Key C","sensitive_id":"sk-***0001"}]}}}"#
        let omitted = DiagnosticRedactor.probeLine(prefix: "deepseek", name: "api_keys", status: 200, body: keys)
        XCTAssertFalse(omitted.contains("body="))
        XCTAssertFalse(omitted.contains("key-c"))
        XCTAssertFalse(omitted.contains("Key C"))
        XCTAssertTrue(omitted.contains("HTTP 200"))

        let periods = #"{"tracking_id":"key-c","cost":1.25}"#
        let periodLine = DiagnosticRedactor.probeLine(prefix: "deepseek", name: "usage_periods", status: 200, body: periods)
        XCTAssertTrue(periodLine.contains("body="), periodLine)
        XCTAssertFalse(periodLine.contains("key-c"), periodLine)
        XCTAssertTrue(periodLine.contains("1.25"), periodLine)
    }

    func testFreeTextPreviewRedactsEmbeddedEmail() {
        let out = DiagnosticRedactor.preview("probe failed for ada@example.com after redirect")
        XCTAssertFalse(out.contains("ada@example.com"))
        XCTAssertTrue(out.contains("<email>"))
    }

}

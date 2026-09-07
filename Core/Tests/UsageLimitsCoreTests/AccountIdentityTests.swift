import XCTest
@testable import UsageLimitsCore

final class AccountIdentityTests: XCTestCase {
    func testIdentityFingerprintSurvivesEngineeringRename() {
        XCTAssertEqual(
            AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "migration-synthetic-org"),
            "69f55ec2db13909a99e1ca437ac8aa4d4c596153e045feb3b641e4792d762a89",
            "已保存的指纹必须继续匹配，不能随模块改名更换协议盐"
        )
    }

    func testFingerprintIsStableHexAndNeverContainsRawIdentity() throws {
        let email = "User@Example.com"
        let fp = try XCTUnwrap(AccountIdentity.fingerprint(provider: .openai, kind: "email", raw: email))
        XCTAssertEqual(fp.count, 64)
        XCTAssertEqual(fp, AccountIdentity.fingerprint(provider: .openai, kind: "email", raw: " user@example.com "))
        XCTAssertNotEqual(fp, AccountIdentity.fingerprint(provider: .openai, kind: "email", raw: "other@example.com"))
        XCTAssertFalse(fp.contains("example.com"))
        XCTAssertFalse(fp.contains("@"))
    }

    func testExtractHashesClaudeOrgAndCursorSubWithoutKeepingRawValues() {
        let orgs = #"[{"uuid":"org-aaaa-bbbb","capabilities":["chat"]},{"uuid":"org-api-only","capabilities":["api"]}]"#
        let claude = AccountIdentity.extract(provider: .claude, results: [
            "organizations": ProbeResult(status: 200, body: orgs),
        ])
        XCTAssertEqual(claude, AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "org-aaaa-bbbb"))

        let cursor = AccountIdentity.extract(provider: .cursor, results: [
            "auth_me": ProbeResult(status: 200, body: #"{"sub":"user_abc","email":"a@b.com"}"#),
        ])
        XCTAssertEqual(cursor, AccountIdentity.fingerprint(provider: .cursor, kind: "sub", raw: "user_abc"))
        XCTAssertFalse((cursor ?? "").contains("user_abc"))
    }

    func testOpenAIUsesHashedProbeAndIgnoresRawEmailInAccountsCheck() {
        let hashed = AccountIdentity.fingerprint(provider: .openai, kind: "email", raw: "a@b.com")!
        let body = #"{"identityFingerprint":"\#(hashed)"}"#
        let fromIdentity = AccountIdentity.extract(provider: .openai, results: [
            "identity": ProbeResult(status: 200, body: body),
            "accounts_check": ProbeResult(status: 200, body: #"{"email":"a@b.com"}"#),
        ])
        XCTAssertEqual(fromIdentity, hashed)

        let rawOnly = AccountIdentity.extract(provider: .openai, results: [
            "accounts_check": ProbeResult(status: 200, body: #"{"email":"a@b.com"}"#),
        ])
        XCTAssertNil(rawOnly, "accounts_check 里的邮箱原文不得直接当指纹")
    }

    func testBindWritesOnceAndRejectsMismatch() {
        var account = ProviderAccount(provider: .claude, name: "A")
        XCTAssertEqual(AccountIdentity.bind(account: &account, extracted: "not-hex", snapshotOK: true), .skipped)

        let first = AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "org-1")!
        XCTAssertEqual(AccountIdentity.bind(account: &account, extracted: first, snapshotOK: true), .bound)
        XCTAssertEqual(account.identityFingerprint, first)
        XCTAssertEqual(AccountIdentity.bind(account: &account, extracted: first, snapshotOK: true), .matched)

        let second = AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "org-2")!
        XCTAssertEqual(AccountIdentity.bind(account: &account, extracted: second, snapshotOK: true), .mismatch)
        XCTAssertEqual(account.identityFingerprint, first, "冲突时不得改绑")
    }

    func testAccountCodableKeepsFingerprintAndDefaultsMissingToNil() throws {
        var account = ProviderAccount(provider: .cursor, name: "C")
        account.identityFingerprint = AccountIdentity.fingerprint(provider: .cursor, kind: "sub", raw: "sub-1")
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(ProviderAccount.self, from: data)
        XCTAssertEqual(decoded.identityFingerprint, account.identityFingerprint)

        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","provider":"claude","name":"Old","createdAt":0,"isPrimary":true,"isEnabled":true}
        """
        let old = try JSONDecoder().decode(ProviderAccount.self, from: Data(legacy.utf8))
        XCTAssertNil(old.identityFingerprint)
    }

    func testChatGPTScriptHashesEmailAndNeverReturnsRawIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Networking/ProviderScripts.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("aiusage-identity-v1|openai|email|"))
        XCTAssertTrue(source.contains("identityFingerprint"))
        XCTAssertTrue(source.contains("crypto.subtle"))
        XCTAssertFalse(source.contains("body: JSON.stringify({ email"))
        XCTAssertTrue(source.contains("aiusage-identity-v1|cursor|sub|"))
        XCTAssertTrue(source.contains("hasSub"))
    }

    func testCursorPrefersHashedAuthMeAndKeepsRawSubFallback() {
        let hashed = AccountIdentity.fingerprint(provider: .cursor, kind: "sub", raw: "user_abc")!
        let fromHash = AccountIdentity.extract(provider: .cursor, results: [
            "auth_me": ProbeResult(status: 200, body: #"{"hasSub":true,"identityFingerprint":"\#(hashed)"}"#),
        ])
        XCTAssertEqual(fromHash, hashed)

        let raw = AccountIdentity.extract(provider: .cursor, results: [
            "auth_me": ProbeResult(status: 200, body: #"{"sub":"user_abc","email":"a@b.com"}"#),
        ])
        XCTAssertEqual(raw, hashed)
    }


    func testApplyBindsAndMismatchMarksNeedsLogin() {
        var accounts = [ProviderAccount(provider: .claude, name: "A", isPrimary: true)]
        let first = AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "org-1")!
        var snap = ProviderSnapshot(provider: .claude, fetchedAt: Date(), status: .ok)
        let orgs1 = #"[{"uuid":"org-1","capabilities":["chat"]}]"#
        XCTAssertEqual(
            AccountIdentity.apply(
                accounts: &accounts, provider: .claude, accountID: nil,
                results: ["organizations": ProbeResult(status: 200, body: orgs1)],
                snap: &snap
            ),
            .bound
        )
        XCTAssertEqual(accounts[0].identityFingerprint, first)
        XCTAssertEqual(snap.status, .ok)

        snap.planName = "Claude Max 20x"
        snap.metrics = [UsageMetric(id: "seven_day", label: "All models", usedPercent: 80)]
        let orgs2 = #"[{"uuid":"org-2","capabilities":["chat"]}]"#
        XCTAssertEqual(
            AccountIdentity.apply(
                accounts: &accounts, provider: .claude, accountID: nil,
                results: ["organizations": ProbeResult(status: 200, body: orgs2)],
                snap: &snap
            ),
            .mismatch
        )
        XCTAssertEqual(accounts[0].identityFingerprint, first)
        XCTAssertEqual(snap.status, .needsLogin)
        XCTAssertTrue(snap.metrics.isEmpty)
        XCTAssertNil(snap.planName)
    }

    func testRejectedSnapshotDropsForeignUsagePayload() {
        let now = Date()
        let parsed = ProviderSnapshot(
            provider: .claude,
            planName: "Claude Max 20x",
            metrics: [UsageMetric(id: "seven_day", label: "All models", usedPercent: 61)],
            fetchedAt: now,
            status: .ok,
            planExpiresAt: now.addingTimeInterval(86400)
        )
        let rejected = AccountIdentity.rejectedSnapshot(parsed)
        XCTAssertEqual(rejected.status, .needsLogin)
        XCTAssertEqual(rejected.provider, .claude)
        XCTAssertEqual(rejected.fetchedAt, now)
        XCTAssertTrue(rejected.metrics.isEmpty)
        XCTAssertNil(rejected.planName)
        XCTAssertNil(rejected.planExpiresAt)
        XCTAssertFalse(rejected.isCustom)
    }

    func testApplyMissingAccountIDDoesNotBindPrimary() {
        var accounts = [ProviderAccount(provider: .claude, name: "主号", isPrimary: true)]
        var snap = ProviderSnapshot(provider: .claude, fetchedAt: Date(), status: .ok)
        let orgs = #"[{"uuid":"org-1","capabilities":["chat"]}]"#
        XCTAssertEqual(
            AccountIdentity.apply(
                accounts: &accounts, provider: .claude, accountID: UUID(),
                results: ["organizations": ProbeResult(status: 200, body: orgs)],
                snap: &snap
            ),
            .skipped
        )
        XCTAssertNil(accounts[0].identityFingerprint, "找不到指定附加账号时不得绑到主号")
        XCTAssertEqual(snap.status, .ok)
    }

    func testClearFingerprintAllowsRebind() {
        var account = ProviderAccount(provider: .cursor, name: "C")
        let first = AccountIdentity.fingerprint(provider: .cursor, kind: "sub", raw: "sub-1")!
        XCTAssertEqual(AccountIdentity.bind(account: &account, extracted: first, snapshotOK: true), .bound)
        AccountIdentity.clearFingerprint(&account)
        XCTAssertNil(account.identityFingerprint)
        let second = AccountIdentity.fingerprint(provider: .cursor, kind: "sub", raw: "sub-2")!
        XCTAssertEqual(AccountIdentity.bind(account: &account, extracted: second, snapshotOK: true), .bound)
        XCTAssertEqual(account.identityFingerprint, second)
    }


    func testAppStateIdentityMismatchKeepsInMemoryLastGood() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8
        )
        XCTAssertTrue(app.contains("if !identityOK"))
        XCTAssertFalse(
            app.contains("accountSnapshots[account.id] = snap"),
            "附加号身份冲突不得把 rejected 快照写进内存"
        )
        XCTAssertFalse(
            app.contains("snapshots[provider] = snap"),
            "主号身份冲突不得把 rejected 快照写进内存"
        )
        XCTAssertTrue(app.contains("return accountSnapshots[account.id]"))
        XCTAssertTrue(app.contains("return snapshots[provider]"))
        if let mismatch = app.range(of: "if !identityOK") {
            XCTAssertTrue(
                String(app[mismatch.lowerBound...].prefix(280)).contains("scheduleReminderReload()"),
                "身份冲突须重排日历"
            )
        }
    }

    func testPreservingStoredFingerprintsKeepsStoreOnlyBind() {
        let alice = UUID()
        let bob = UUID()
        var memoryAlice = ProviderAccount(provider: .claude, name: "Alice", isPrimary: true)
        memoryAlice.id = alice
        var memoryBob = ProviderAccount(provider: .claude, name: "Bob")
        memoryBob.id = bob
        var storedAlice = memoryAlice
        storedAlice.identityFingerprint = AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "org-alice")
        var storedBob = memoryBob
        storedBob.identityFingerprint = AccountIdentity.fingerprint(provider: .claude, kind: "org", raw: "org-bob")

        let renamed = AccountIdentity.preservingStoredFingerprints(
            writing: [
                { var a = memoryAlice; a.name = "Alice 2"; return a }(),
                memoryBob,
            ],
            stored: [storedAlice, storedBob]
        )
        XCTAssertEqual(renamed[0].identityFingerprint, storedAlice.identityFingerprint)
        XCTAssertEqual(renamed[1].identityFingerprint, storedBob.identityFingerprint)
        XCTAssertEqual(renamed[0].name, "Alice 2")

        AccountIdentity.clearFingerprint(&memoryBob)
        let loggedOut = AccountIdentity.preservingStoredFingerprints(
            writing: [memoryAlice, memoryBob],
            stored: [storedAlice, storedBob],
            allowingCleared: [bob]
        )
        XCTAssertEqual(loggedOut[0].identityFingerprint, storedAlice.identityFingerprint)
        XCTAssertNil(loggedOut[1].identityFingerprint)
    }

    func testAppStatePersistsAccountsThroughFingerprintMerge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("App/AppState.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("persistAccounts"), "改名/拖动须走指纹合并写回")
        XCTAssertTrue(app.contains("preservingStoredFingerprints"))
        XCTAssertTrue(app.contains("case .matched:"))
        XCTAssertTrue(app.contains("copyIdentityFingerprint"))
        XCTAssertTrue(app.contains("scheduleReminderReload()"))
        if let mismatch = app.range(of: "if !identityOK") {
            XCTAssertTrue(
                String(app[mismatch.lowerBound...].prefix(280)).contains("scheduleReminderReload()"),
                "附加号身份冲突须重排日历，去掉 leftover extra 提醒"
            )
        } else {
            XCTFail("missing identityOK guard")
        }
    }

}

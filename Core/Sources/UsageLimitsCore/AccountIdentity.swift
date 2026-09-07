import CryptoKit
import Foundation

/// 多账号稳定身份：只存 SHA-256 指纹，永不落盘邮箱 / org UUID / sub 原文。
public enum AccountIdentity {
    public enum BindOutcome: Equatable, Sendable {
        case skipped
        case bound
        case matched
        case mismatch
    }

    /// `aiusage-identity-v1|<provider>|<kind>|<normalized>` 的 SHA-256 hex。
    /// 这是已持久化身份的协议盐，工程改名时不得更改；须与站内探针保持一致。
    public static func fingerprint(provider: ProviderID, kind: String, raw: String) -> String? {
        let normalized: String
        if kind == "email" {
            normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized.isEmpty else { return nil }
        let canonical = "aiusage-identity-v1|\(provider.rawValue)|\(kind)|\(normalized)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func extract(provider: ProviderID, results: [String: ProbeResult]) -> String? {
        if let probe = results["identity"], probe.isOK,
           let object = JSONHelp.object(probe.body),
           let fingerprint = normalizedFingerprint(object["identityFingerprint"]) {
            return fingerprint
        }
        switch provider {
        case .claude:
            guard let uuid = claudeOrgUUID(results) else { return nil }
            return fingerprint(provider: .claude, kind: "org", raw: uuid)
        case .openai:
            if let object = JSONHelp.object(results["accounts_check"]?.body ?? ""),
               let fingerprint = normalizedFingerprint(object["identityFingerprint"]) {
                return fingerprint
            }
            return nil
        case .cursor:
            guard let me = results["auth_me"], me.isOK,
                  let dict = JSONHelp.object(me.body) else { return nil }
            if let fingerprint = normalizedFingerprint(dict["identityFingerprint"]) {
                return fingerprint
            }
            guard let sub = JSONHelp.string(dict["sub"]), !sub.isEmpty else { return nil }
            return fingerprint(provider: .cursor, kind: "sub", raw: sub)
        default:
            return nil
        }
    }

    /// 绑定到 `accounts` 里的目标账号。冲突时把快照标成 `needsLogin`。
    /// 找不到账号或自定义账号：`.skipped`，调用方仍可提交快照。
    @discardableResult
    public static func apply(
        accounts: inout [ProviderAccount],
        provider: ProviderID,
        accountID: UUID?,
        results: [String: ProbeResult],
        snap: inout ProviderSnapshot
    ) -> BindOutcome {
        let target: ProviderAccount?
        if let accountID {
            target = accounts.first { $0.id == accountID }
        } else {
            target = accounts.first(where: { $0.provider == provider && $0.isPrimary })
        }
        guard let target else { return .skipped }
        if target.isCustom { return .skipped }
        guard let idx = accounts.firstIndex(where: { $0.id == target.id }) else { return .skipped }
        var account = accounts[idx]
        let extracted = extract(provider: provider, results: results)
        let outcome = bind(account: &account, extracted: extracted, snapshotOK: snap.status.isOK)
        switch outcome {
        case .mismatch:
            snap = rejectedSnapshot(snap)
        case .bound:
            accounts[idx] = account
        case .matched, .skipped:
            break
        }
        return outcome
    }

    /// 身份冲突：只留 needsLogin，丢掉对方账号的套餐/数字/流水，避免写进本卡内存。
    public static func rejectedSnapshot(_ parsed: ProviderSnapshot) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: parsed.provider,
            fetchedAt: parsed.fetchedAt,
            status: .needsLogin,
            isCustom: parsed.isCustom
        )
    }

    /// BackgroundRefresh 只写 store；AppState 内存表可能还是 nil。
    /// 整表写回前按 id 灌回 store 已有指纹，logout/清指纹的账号放进 `allowingCleared`。
    public static func preservingStoredFingerprints(
        writing proposed: [ProviderAccount],
        stored: [ProviderAccount],
        allowingCleared: Set<UUID> = []
    ) -> [ProviderAccount] {
        let kept = Dictionary(uniqueKeysWithValues: stored.compactMap { account -> (UUID, String)? in
            guard let fp = account.identityFingerprint else { return nil }
            return (account.id, fp)
        })
        return proposed.map { account in
            var next = account
            if next.identityFingerprint == nil,
               !allowingCleared.contains(next.id),
               let fp = kept[next.id] {
                next.identityFingerprint = fp
            }
            return next
        }
    }

    public static func clearFingerprint(_ account: inout ProviderAccount) {
        account.identityFingerprint = nil
    }

    /// 首次成功解析写入指纹；之后不一致则拒绝覆盖。
    public static func bind(
        account: inout ProviderAccount,
        extracted: String?,
        snapshotOK: Bool
    ) -> BindOutcome {
        guard let extracted, isHexSHA256(extracted) else { return .skipped }
        if let existing = account.identityFingerprint, isHexSHA256(existing) {
            return existing == extracted ? .matched : .mismatch
        }
        guard snapshotOK else { return .skipped }
        account.identityFingerprint = extracted
        return .bound
    }

    static func normalizedFingerprint(_ any: Any?) -> String? {
        guard let raw = JSONHelp.string(any) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isHexSHA256(trimmed) ? trimmed : nil
    }

    static func isHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    /// 与 Claude 探针 / `ClaudeParser.selectOrg` 同一挑选顺序。
    private static func claudeOrgUUID(_ results: [String: ProbeResult]) -> String? {
        guard let orgs = results["organizations"], orgs.isOK,
              let arr = JSONHelp.array(orgs.body) else { return nil }
        let dicts = arr.compactMap { $0 as? [String: Any] }
        func caps(_ org: [String: Any]) -> [String] {
            ((org["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []).map { $0.lowercased() }
        }
        let picked = dicts.first { caps($0).contains("chat") }
            ?? dicts.first { let c = caps($0); return !(c.count == 1 && c.first == "api") }
            ?? dicts.first
        return picked.flatMap { JSONHelp.string($0["uuid"]) }
    }
}

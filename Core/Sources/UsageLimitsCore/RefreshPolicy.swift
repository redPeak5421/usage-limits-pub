import Foundation

/// 决定本轮探针结果要不要覆盖已有快照。
///
/// 下拉刷新并发挤爆 WKWebView 时，超时/脚本失败常被解析层标成 `needsLogin`。
/// 这种运输层失败不能盖掉上一份已登录的有效快照。
public enum RefreshPolicy {
    /// 脚本层永远写成 200 的聚合壳，或本地快照（不发 HTTP）。
    /// page / region / bootstrap / identity 没有嵌套 status，展开后应视为「无真实 HTTP」。
    private static let syntheticOKKeys: Set<String> = [
        "rate_limits", "usage_periods", "combo",
        "page", "region", "bootstrap", "identity",
    ]

    /// 没有任何真实 HTTP 探针（仅 script 失败、超时、空结果、源漂移、合成 200）。
    public static func isUnreliableProbe(_ results: [String: ProbeResult]) -> Bool {
        if results.isEmpty { return true }
        if results["origin_drift"] != nil { return true }
        return !hasRealHTTP(results)
    }

    /// 5xx / 429 / 408 等瞬时失败：解析层也会标成 needsLogin，但不能当退出登录。
    public static func isTransientFailure(_ results: [String: ProbeResult]) -> Bool {
        let http = realHTTPStatuses(results)
        guard !http.isEmpty else { return false }
        return http.allSatisfy { status in
            [408, 425, 429].contains(status) || (500...599).contains(status)
        }
    }

    /// 新快照是否应落盘并进 UI。
    ///
    /// - 本轮 ok：总是提交
    /// - 没有可保护的旧快照：提交（让未登录/错误态能首次显示）
    /// - 旧快照 ok，但探针不可靠或瞬时失败：保留旧快照
    /// - 旧快照 ok，探针带回真实 HTTP（如 401）：提交（用户确实退出了）
    public static func shouldCommit(
        old: ProviderSnapshot?,
        new: ProviderSnapshot,
        results: [String: ProbeResult]
    ) -> Bool {
        guard new.persistenceValidationIssue == nil else { return false }
        if new.status.isOK {
            // 即梦会话 Cookie + 额度 1014：ok 但没有积分数字（空 metrics 或「—」占位）。
            // 这种空 ok / 占位不能盖掉上一轮已经拿到的积分数字。
            if let old, old.status.isOK, hasNumericUsage(old), !hasNumericUsage(new) {
                return false
            }
            return true
        }
        guard let old, old.status.isOK else { return true }
        if new.provider == .gemini, case .error = new.status { return false }
        if new.provider == .grok,
           new.status == .error(GrokParser.browserVerificationError),
           GrokParser.requiresBrowserVerification(results) { return false }
        if isSoftBusy(new) { return false }
        if isUnreliableProbe(results) || isTransientFailure(results) { return false }
        return true
    }

    /// 刷新后的唯一可见值解析规则：只有成功回读的持久化值可以替换旧值。
    /// 首次刷新被拒绝时返回不含任何解析数字/日期载荷的安全错误快照。
    public static func visibleSnapshot(
        old: ProviderSnapshot?,
        parsed: ProviderSnapshot,
        persisted: ProviderSnapshot?,
        now: Date = Date()
    ) -> ProviderSnapshot {
        if let persisted, persisted.persistenceValidationIssue == nil { return persisted }
        if let old, old.persistenceValidationIssue == nil { return old }
        let safeNow = JSONHelp.isSafeDate(now) ? now : Date(timeIntervalSince1970: 0)
        return ProviderSnapshot(
            provider: parsed.provider,
            fetchedAt: safeNow,
            status: .error("用量数据异常"),
            isCustom: parsed.isCustom
        )
    }

    /// DeepSeek 合成 usage_periods 全空时，新快照会带 nil/空图表；钱包数字仍 ok，不能盖掉上次图表。
    public static func preservingBreakdowns(old: ProviderSnapshot?, new: ProviderSnapshot) -> ProviderSnapshot {
        guard let old, old.status.isOK, new.status.isOK else { return new }
        var merged = new
        if emptyBreakdowns(new.timeBreakdowns), !emptyBreakdowns(old.timeBreakdowns) {
            merged.timeBreakdowns = old.timeBreakdowns
        }
        if emptyBreakdowns(new.keyBreakdowns), !emptyBreakdowns(old.keyBreakdowns) {
            merged.keyBreakdowns = old.keyBreakdowns
        }
        if emptyBreakdowns(new.modelBreakdowns), !emptyBreakdowns(old.modelBreakdowns) {
            merged.modelBreakdowns = old.modelBreakdowns
        }
        return merged
    }

    private static func emptyBreakdowns(_ rows: [UsageBreakdown]?) -> Bool {
        rows == nil || rows?.isEmpty == true
    }

    /// 有真实用量数字（金额 / 百分比 / 剩余次数 / 流水）。「—」占位不算。
    public static func hasNumericUsage(_ snap: ProviderSnapshot) -> Bool {
        if snap.metrics.contains(where: { metric in
            metric.amount != nil || metric.usedPercent != nil || metric.remaining != nil
        }) {
            return true
        }
        // 流水不是卡片数字；有 leftover history 也不能当成「这轮已拿到积分」。
        return false
    }

    private static func isSoftBusy(_ snap: ProviderSnapshot) -> Bool {
        if case .error(let message) = snap.status {
            return message.contains("繁忙")
        }
        return false
    }

    private static func hasRealHTTP(_ results: [String: ProbeResult]) -> Bool {
        !realHTTPStatuses(results).isEmpty
    }

    private static func realHTTPStatuses(_ results: [String: ProbeResult]) -> [Int] {
        results.flatMap { name, result -> [Int] in
            // Reset credits are optional metadata, never login or usage transport evidence.
            if name == "reset_credits" || name == "reset_history" { return [] }
            if name == "resets" || name == "resets_facade" { return [] }
            if name == "origin_drift" || name == "script" { return [] }
            if isLocalCookieSession(name, result) { return [] }
            if syntheticOKKeys.contains(name) { return syntheticHTTPStatuses(name: name, result: result) }
            return result.status >= 100 ? [result.status] : []
        }
    }

    /// 即梦 native 注入：键名与 ChatGPT `/api/auth/session` 撞车，但 body 只有 `hasSession`，不发 HTTP。
    /// 不得把该键加进 `syntheticOKKeys`，否则 ChatGPT 真 session 200 也会被展开成空。
    private static func isLocalCookieSession(_ name: String, _ result: ProbeResult) -> Bool {
        guard name == "session", result.isOK, let root = JSONHelp.object(result.body) else { return false }
        return root.count == 1 && root["hasSession"] != nil
    }

    private static func syntheticHTTPStatuses(name: String, result: ProbeResult) -> [Int] {
        guard result.isOK, let root = JSONHelp.object(result.body) else { return [] }
        var statuses: [Int] = []
        func append(_ raw: Any?) {
            if let status = JSONHelp.intExactly(raw), status >= 100 { statuses.append(status) }
        }
        switch name {
        case "rate_limits":
            for row in (root["results"] as? [[String: Any]]) ?? [] { append(row["status"]) }
        case "usage_periods":
            for value in root.values {
                guard let period = value as? [String: Any] else { continue }
                append((period["cost"] as? [String: Any])?["status"])
                append((period["amount"] as? [String: Any])?["status"])
            }
        case "combo":
            append((root["yearly"] as? [String: Any])?["status"])
            append((root["monthly"] as? [String: Any])?["status"])
        default:
            break
        }
        return statuses
    }
}

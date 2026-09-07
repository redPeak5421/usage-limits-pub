import Foundation

/// 解析 longcat 探针结果。接口目录见 `providers/longcat.md`。
public enum LongCatParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return ProviderSnapshot(
                provider: .longcat,
                fetchedAt: now,
                status: .error("未获取到任何响应")
            )
        }

        var loggedIn = false
        var userFailure: SnapshotStatus?
        if let user = results["user"] {
            if (300..<400).contains(user.status) || user.isUnauthorized {
                userFailure = .needsLogin
            } else if !user.isOK {
                userFailure = user.failureStatus
            } else if let root = JSONHelp.object(user.body) {
                let unpacked = envelope(root)
                if unpacked.data == nil {
                    userFailure = .error("LongCat 响应数据异常")
                } else if isSuccessCode(unpacked.code) {
                    loggedIn = true
                } else if isUnauthorizedCode(unpacked.code) {
                    userFailure = .needsLogin
                } else if let code = unpacked.code {
                    userFailure = envelopeError(code: code)
                }
            }
        }

        var metrics: [UsageMetric] = []
        if loggedIn {
            if let pack = activeTokenPack(results["token_packs"]) {
                metrics.append(pack)
            } else if let fallback = fallbackTokenPack(results["token_usage"]) {
                metrics.append(fallback)
            }
            if let fuel = fuelMetric(results["fuel"]) {
                metrics.append(fuel)
            }
        }

        let status: SnapshotStatus
        if let userFailure {
            status = userFailure
        } else if !loggedIn {
            status = .needsLogin
        } else if !metrics.isEmpty {
            status = .ok
        } else if let failed = quotaFailure(results) {
            status = failed
        } else {
            status = .error("未获取到用量数据")
        }

        return ProviderSnapshot(
            provider: .longcat,
            metrics: metrics,
            fetchedAt: now,
            status: status
        )
    }

    /// 美团信封。`data` 缺失或不是对象时回落整个根对象。
    static func envelope(_ root: [String: Any]) -> (data: [String: Any]?, code: Int?) {
        let code: Int?
        if let raw = nonNullValue(root["code"]) {
            guard let number = JSONHelp.double(raw), number.isFinite,
                  number.rounded(.towardZero) == number,
                  let exact = JSONHelp.intExactly(number) else { return (nil, nil) }
            code = exact
        } else {
            code = nil
        }
        return ((root["data"] as? [String: Any]) ?? root, code)
    }

    private static func activeTokenPack(_ result: ProbeResult?) -> UsageMetric? {
        guard let root = successfulEnvelope(result),
              let lot = root["currentLot"] as? [String: Any],
              JSONHelp.string(lot["status"])?.lowercased() == "active",
              let total = finiteNonnegative(lot["totalToken"]), total > 0,
              let used = finiteNonnegative(lot["consumedToken"], default: 0) else { return nil }
        return tokenMetric(label: "Token 包", used: used, total: total)
    }

    private static func fallbackTokenPack(_ result: ProbeResult?) -> UsageMetric? {
        guard let data = successfulEnvelope(result) else { return nil }
        let usage = (data["usage"] as? [String: Any]) ?? data
        guard let total = finiteNonnegative(usage["totalToken"]), total > 0 else { return nil }
        let used: Double
        if nonNullValue(usage["usedToken"]) != nil {
            guard let value = finiteNonnegative(usage["usedToken"]) else { return nil }
            used = value
        } else if nonNullValue(usage["availableToken"]) != nil {
            guard let available = finiteNonnegative(usage["availableToken"]), available <= total else { return nil }
            used = total - available
        } else {
            used = 0
        }
        return tokenMetric(label: "Token 额度", used: used, total: total)
    }

    private static func tokenMetric(label: String, used: Double, total: Double) -> UsageMetric? {
        guard used.isFinite, used >= 0, total.isFinite, total > 0 else { return nil }
        return UsageMetric(
            id: "token_pack",
            label: label,
            usedPercent: clamp(used / total * 100),
            remaining: min(max(total - used, 0), total),
            total: total,
            detail: "已用 \(MoneyFormat.string(used, currency: nil)) / \(MoneyFormat.string(total, currency: nil)) tokens",
            pinned: true
        )
    }

    private static func fuelMetric(_ result: ProbeResult?) -> UsageMetric? {
        guard let data = successfulEnvelope(result) else { return nil }
        let totalValue: Double?
        if nonNullValue(data["totalQuota"]) != nil {
            guard let value = finiteNonnegative(data["totalQuota"]) else { return nil }
            totalValue = value
        } else {
            totalValue = nil
        }
        let total = (totalValue ?? 0) > 0 ? totalValue : nil
        let rows = (data["list"] as? [[String: Any]]) ?? []
        var available: [Double] = []
        for row in rows where nonNullValue(row["availableToken"]) != nil {
            guard let value = finiteNonnegative(row["availableToken"]) else { return nil }
            available.append(value)
        }
        let sum = available.reduce(0, +)
        guard sum.isFinite else { return nil }
        let remaining = available.isEmpty ? total : sum
        guard total != nil || (remaining ?? 0) > 0 else { return nil }

        let resetsAt = rows.compactMap { fuelDate($0["expireTime"]) }.min()
        if let total, let remaining {
            guard remaining <= total else { return nil }
            return UsageMetric(
                id: "fuel_packages",
                label: "加油包",
                usedPercent: clamp((total - remaining) / total * 100),
                remaining: remaining,
                total: total,
                resetsAt: resetsAt
            )
        }

        guard let remaining, remaining > 0 else { return nil }
        return UsageMetric(
            id: "fuel_packages",
            label: "加油包",
            remaining: remaining,
            resetsAt: resetsAt,
            detail: "剩余 \(MoneyFormat.string(remaining, currency: nil)) tokens",
            amount: remaining
        )
    }

    private static func successfulEnvelope(_ result: ProbeResult?) -> [String: Any]? {
        guard let result, result.isOK, let root = JSONHelp.object(result.body) else { return nil }
        let unpacked = envelope(root)
        guard isSuccessCode(unpacked.code) else { return nil }
        return unpacked.data
    }

    private static func quotaFailure(_ results: [String: ProbeResult]) -> SnapshotStatus? {
        for key in ["token_packs", "token_usage"] {
            guard let result = results[key] else { continue }
            if !result.isOK { return result.failureStatus }
            guard let root = JSONHelp.object(result.body) else { continue }
            let unpacked = envelope(root)
            guard unpacked.data != nil else { return .error("LongCat 响应数据异常") }
            let code = unpacked.code
            if isUnauthorizedCode(code) { return .needsLogin }
            if let code, !isSuccessCode(code) { return envelopeError(code: code) }
        }
        return nil
    }

    private static func isSuccessCode(_ code: Int?) -> Bool {
        code == nil || code == 0 || code == 200
    }

    private static func isUnauthorizedCode(_ code: Int?) -> Bool {
        code == 401 || code == 403
    }

    private static func envelopeError(code: Int) -> SnapshotStatus {
        return .error("LongCat code \(code)")
    }

    private static func fuelDate(_ value: Any?) -> Date? {
        if let date = JSONHelp.date(value) { return date }
        guard let text = JSONHelp.string(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: text), JSONHelp.isSafeDate(date) else { return nil }
        return date
    }

    private static func finiteNonnegative(_ value: Any?, default defaultValue: Double? = nil) -> Double? {
        guard let value = nonNullValue(value) else { return defaultValue }
        guard let number = JSONHelp.double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func nonNullValue(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

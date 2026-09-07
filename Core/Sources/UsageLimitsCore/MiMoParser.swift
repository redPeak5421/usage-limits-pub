import Foundation
import CoreFoundation

/// 解析 MiMo 探针结果。接口目录见 `providers/mimo.md`。
public enum MiMoParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let balanceResult = results["balance"] else {
            return snapshot(now: now, status: .error("未获取到余额响应"))
        }
        if (300..<400).contains(balanceResult.status) || balanceResult.isUnauthorized {
            return snapshot(now: now, status: .needsLogin)
        }
        guard balanceResult.isOK else {
            return snapshot(now: now, status: balanceResult.failureStatus)
        }
        guard let root = JSONHelp.object(balanceResult.body),
              let envelope = envelope(root) else {
            return snapshot(now: now, status: .error("余额数据异常"))
        }
        if (300..<400).contains(envelope.code) || envelope.code == 401 || envelope.code == 403 {
            return snapshot(now: now, status: .needsLogin)
        }
        guard envelope.code == 0 else {
            return snapshot(now: now, status: balanceError(root))
        }
        guard let data = envelope.data, let balanceMetric = balanceMetric(data) else {
            return snapshot(now: now, status: .error("余额数据异常"))
        }

        let detail = planDetail(results["plan_detail"])
        var metrics: [UsageMetric] = []
        var planName: String?
        if detail?.expired != true {
            planName = planLabel(detail?.planCode)
            if let monthly = monthlyMetric(results["plan_usage"], resetsAt: detail?.periodEnd) {
                metrics.append(monthly)
            }
        }
        metrics.append(balanceMetric)

        return ProviderSnapshot(
            provider: .mimo,
            planName: planName,
            metrics: metrics,
            fetchedAt: now,
            status: .ok
        )
    }

    private struct Envelope {
        var code: Int
        var data: [String: Any]?
    }

    private struct PlanDetail {
        var planCode: String?
        var periodEnd: Date?
        var expired: Bool
    }

    private static func envelope(_ root: [String: Any]) -> Envelope? {
        guard let rawCode = nonNull(root["code"]),
              let number = strictNumber(rawCode), number.isFinite,
              number.rounded(.towardZero) == number,
              let code = JSONHelp.intExactly(number) else { return nil }
        return Envelope(code: code, data: root["data"] as? [String: Any])
    }

    private static func balanceMetric(_ data: [String: Any]) -> UsageMetric? {
        guard let balance = finiteNonnegativeString(data["balance"]),
              let rawCurrency = JSONHelp.string(data["currency"]) else { return nil }
        let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currency.isEmpty else { return nil }

        let cash = optionalFiniteNonnegative(data["cashBalance"])
        let gift = optionalFiniteNonnegative(data["giftBalance"])
        let detail: String?
        if cash.isValid, gift.isValid, let cashValue = cash.value, let giftValue = gift.value,
           (cashValue + giftValue).isFinite {
            detail = "付费 \(MoneyFormat.string(cashValue, currency: currency)) · 赠送 \(MoneyFormat.string(giftValue, currency: currency))"
        } else {
            detail = nil
        }

        return UsageMetric(
            id: "balance",
            label: "余额",
            detail: detail,
            amount: balance,
            currency: currency,
            pinned: true
        )
    }

    private static func planDetail(_ result: ProbeResult?) -> PlanDetail? {
        guard let data = successfulData(result), let expired = data["expired"] as? Bool else { return nil }
        return PlanDetail(
            planCode: JSONHelp.string(data["planCode"]),
            periodEnd: utcDate(JSONHelp.string(data["currentPeriodEnd"])),
            expired: expired
        )
    }

    private static func monthlyMetric(_ result: ProbeResult?, resetsAt: Date?) -> UsageMetric? {
        guard let data = successfulData(result),
              let monthUsage = data["monthUsage"] as? [String: Any],
              let items = monthUsage["items"] as? [[String: Any]],
              let first = items.first,
              let used = finiteNonnegativeNumber(first["used"]),
              let limit = finiteNonnegativeNumber(first["limit"]), limit > 0,
              let ratio = finiteNonnegativeNumber(first["percent"]) else { return nil }
        let remaining = max(0, limit - used)
        guard remaining.isFinite else { return nil }
        return UsageMetric(
            id: "monthly",
            label: "月度额度",
            usedPercent: clamp(ratio * 100),
            remaining: remaining,
            total: limit,
            resetsAt: resetsAt,
            detail: "已用 \(MoneyFormat.string(used, currency: nil)) / \(MoneyFormat.string(limit, currency: nil)) credits",
            pinned: true
        )
    }

    private static func successfulData(_ result: ProbeResult?) -> [String: Any]? {
        guard let result, result.isOK,
              let root = JSONHelp.object(result.body),
              let envelope = envelope(root), envelope.code == 0,
              let data = envelope.data else { return nil }
        return data
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.map { String($0).lowercased().capitalized }.joined(separator: " ")
    }

    private static func utcDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: text), JSONHelp.isSafeDate(date) else { return nil }
        return date
    }

    private static func balanceError(_ root: [String: Any]) -> SnapshotStatus {
        guard let raw = JSONHelp.string(root["message"]) else { return .error("余额数据异常") }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .error("余额数据异常") }
        return .error("余额数据异常：\(String(message.prefix(80)))")
    }

    private static func finiteNonnegativeString(_ value: Any?) -> Double? {
        guard let value = nonNull(value), let text = value as? String,
              let number = Double(text), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func finiteNonnegativeNumber(_ value: Any?) -> Double? {
        guard let value = nonNull(value), let number = strictNumber(value),
              number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func optionalFiniteNonnegative(_ value: Any?) -> (value: Double?, isValid: Bool) {
        guard let value = nonNull(value) else { return (nil, true) }
        guard let text = value as? String, let number = Double(text),
              number.isFinite, number >= 0 else { return (nil, false) }
        return (number, true)
    }

    /// JSONSerialization bridges booleans through NSNumber; type ID is the only reliable distinction
    /// because `NSNumber(1) is Bool` is also true on Darwin.
    private static func strictNumber(_ value: Any) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return JSONHelp.double(value)
    }

    private static func nonNull(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .mimo, fetchedAt: now, status: status)
    }
}

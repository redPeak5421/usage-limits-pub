import CoreFoundation
import Foundation

/// 解析 Abacus AI 探针结果。接口目录见 `providers/abacus.md`。
public enum AbacusParser {
    private enum Envelope {
        case success([String: Any])
        case needsLogin
        case failure
        case invalid
    }

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let compute = results["compute_points"] else {
            return snapshot(now: now, status: .error("未获取到算力点响应"))
        }
        guard compute.isOK else {
            return snapshot(now: now, status: compute.failureStatus)
        }

        let computeResult: [String: Any]
        switch envelope(compute.body) {
        case let .success(result):
            computeResult = result
        case .needsLogin:
            return snapshot(now: now, status: .needsLogin)
        case .failure:
            return snapshot(now: now, status: .error("Abacus 接口返回失败"))
        case .invalid:
            return snapshot(now: now, status: .error("Abacus 响应格式异常"))
        }

        guard let total = finiteNumber(computeResult["totalComputePoints"]),
              let remaining = finiteNumber(computeResult["computePointsLeft"]),
              total >= 0,
              remaining >= 0,
              remaining <= total
        else {
            return snapshot(now: now, status: .error("算力点数据异常"))
        }

        var planName: String?
        var resetsAt: Date?
        if let billing = results["billing"], billing.isOK,
           case let .success(billingResult) = envelope(billing.body) {
            planName = planLabel(billingResult["currentTier"] as? String)
            resetsAt = isoDate(billingResult["nextBillingDate"] as? String)
        }

        let used = total - remaining
        let percent = total > 0 ? clamp(used / total * 100) : 0
        let metric = UsageMetric(
            id: "compute_points",
            label: "Compute Points",
            usedPercent: percent,
            remaining: remaining,
            total: total,
            resetsAt: resetsAt,
            detail: "已用 \(formatNumber(used)) / \(formatNumber(total)) points",
            pinned: true
        )

        return ProviderSnapshot(
            provider: .abacus,
            planName: planName,
            metrics: [metric],
            fetchedAt: now,
            status: .ok
        )
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .abacus, fetchedAt: now, status: status)
    }

    private static func envelope(_ body: String) -> Envelope {
        guard let root = JSONHelp.object(body) else { return .invalid }
        let success = strictBool(root["success"])
        guard success == true else {
            if isAuthenticationError(root["error"]) { return .needsLogin }
            return success == false ? .failure : .invalid
        }
        guard let result = root["result"] as? [String: Any] else { return .invalid }
        return .success(result)
    }

    private static func isAuthenticationError(_ value: Any?) -> Bool {
        let message = (value as? String ?? "").lowercased()
        let authWords = [
            "expired", "session", "login", "authenticate", "unauthorized",
            "unauthenticated", "forbidden",
        ]
        return authWords.contains(where: message.contains)
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func isoDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value), JSONHelp.isSafeDate(date) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value), JSONHelp.isSafeDate(date) else {
            return nil
        }
        return date
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let known = ["free", "basic", "pro", "team", "enterprise"]
        return known.contains(value.lowercased()) ? value.lowercased().capitalized : value
    }

    private static func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

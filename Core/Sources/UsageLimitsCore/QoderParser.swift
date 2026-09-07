import Foundation

/// 解析 qoder 探针结果。接口目录见 `providers/qoder.md`。
public enum QoderParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let credits = results["credits"] else {
            return snapshot(now: now, status: .error("配额数据异常"))
        }
        guard credits.isOK else {
            return snapshot(now: now, status: credits.failureStatus)
        }
        guard let root = JSONHelp.object(credits.body),
              let mainNode = dictionary(root, camel: "totalQuota", snake: "total_quota"),
              let main = pool(mainNode) else {
            return snapshot(now: now, status: .error("配额数据异常"))
        }

        var used = main.used
        var total = main.total
        var remaining = main.remaining
        var unit = main.unit
        var hasShared = false

        if let sharedValue = nonNullValue(root, camel: "sharedQuota", snake: "shared_quota") {
            guard let sharedNode = sharedValue as? [String: Any], let shared = pool(sharedNode) else {
                return snapshot(now: now, status: .error("配额数据异常"))
            }
            hasShared = true
            used += shared.used
            total += shared.total
            remaining += shared.remaining
            if unit == nil { unit = shared.unit }
        }

        guard used.isFinite, total.isFinite, remaining.isFinite,
              used >= 0, total >= 0, remaining >= 0 else {
            return snapshot(now: now, status: .error("配额数据异常"))
        }

        let percent: Double
        if hasShared {
            percent = total > 0 ? clamp(used / total * 100) : 100
        } else if let published = main.percentage {
            percent = clamp(published)
        } else {
            percent = total > 0 ? clamp(used / total * 100) : 100
        }

        let suffix = unit.flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
        let metric = UsageMetric(
            id: "credits",
            label: "Credits",
            usedPercent: percent,
            remaining: remaining,
            total: total,
            resetsAt: qoderDate(root["nextResetAt"]) ?? qoderDate(root["next_reset_at"]),
            detail: "已用 \(format(used)) / \(format(total))\(suffix)",
            pinned: true
        )
        return ProviderSnapshot(
            provider: .qoder,
            metrics: [metric],
            fetchedAt: now,
            status: .ok
        )
    }

    private struct QuotaPool {
        var used: Double
        var total: Double
        var remaining: Double
        var percentage: Double?
        var unit: String?
    }

    private static func pool(_ container: [String: Any]) -> QuotaPool? {
        guard let summary = dictionary(container, camel: "quotaSummary", snake: "quota_summary"),
              let used = number(summary, camel: "usedValue", snake: "used_value"),
              let total = number(summary, camel: "limitValue", snake: "limit_value") else { return nil }
        guard used.isFinite, total.isFinite, used >= 0, total >= 0 else { return nil }
        let publishedRemaining: Double?
        switch numericField(summary, camel: "remainingValue", snake: "remaining_value") {
        case .missing:
            publishedRemaining = nil
        case let .value(value):
            publishedRemaining = value
        case .malformed:
            return nil
        }
        let remaining = publishedRemaining ?? max(0, total - used)
        let percentage: Double?
        switch numericField(summary, camel: "usagePercentage", snake: "usage_percentage") {
        case .missing:
            percentage = nil
        case let .value(value):
            percentage = value
        case .malformed:
            return nil
        }

        guard remaining.isFinite, remaining >= 0,
              percentage == nil || (percentage!.isFinite && percentage! >= 0) else { return nil }
        if total == 0, used != 0 || remaining != 0 { return nil }

        return QuotaPool(
            used: used,
            total: total,
            remaining: remaining,
            percentage: percentage,
            unit: JSONHelp.string(summary["unit"])
        )
    }

    private static func dictionary(
        _ root: [String: Any],
        camel: String,
        snake: String
    ) -> [String: Any]? {
        (root[camel] as? [String: Any]) ?? (root[snake] as? [String: Any])
    }

    private static func number(_ root: [String: Any], camel: String, snake: String) -> Double? {
        JSONHelp.double(root[camel]) ?? JSONHelp.double(root[snake])
    }

    private enum NumericField {
        case missing
        case value(Double)
        case malformed
    }

    private static func numericField(
        _ root: [String: Any],
        camel: String,
        snake: String
    ) -> NumericField {
        var foundValue = false
        for key in [camel, snake] {
            guard let raw = root[key], !(raw is NSNull) else { continue }
            foundValue = true
            if let value = JSONHelp.double(raw) { return .value(value) }
        }
        return foundValue ? .malformed : .missing
    }

    private static func nonNullValue(_ root: [String: Any], camel: String, snake: String) -> Any? {
        if let value = root[camel], !(value is NSNull) { return value }
        if let value = root[snake], !(value is NSNull) { return value }
        return nil
    }

    private static func qoderDate(_ value: Any?) -> Date? {
        if let epoch = JSONHelp.double(value) {
            guard epoch.isFinite, epoch > 0 else { return nil }
            return JSONHelp.date(epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        guard let date = JSONHelp.date(value), date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return date
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.0f", value) }
        var text = String(format: "%.2f", value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .qoder, fetchedAt: now, status: status)
    }
}

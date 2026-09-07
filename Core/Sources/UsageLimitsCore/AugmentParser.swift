import Foundation

/// 解析 augment 探针结果。接口目录见 `providers/augment.md`。
public enum AugmentParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return ProviderSnapshot(
                provider: .augment,
                fetchedAt: now,
                status: .error("未获取到任何响应")
            )
        }

        var planName: String?
        var resetsAt: Date?
        if let subscription = results["subscription"], subscription.isOK,
           let root = JSONHelp.object(subscription.body) {
            planName = planLabel(JSONHelp.string(root["planName"]))
            resetsAt = finiteDate(root["billingPeriodEnd"])
        }

        var metrics: [UsageMetric] = []
        if let credits = results["credits"], credits.isOK,
           let root = JSONHelp.object(credits.body),
           let metric = creditMetric(root, resetsAt: resetsAt) {
            metrics.append(metric)
        }

        let status: SnapshotStatus
        if !metrics.isEmpty {
            status = .ok
        } else if let credits = results["credits"], !credits.isOK {
            status = credits.failureStatus
        } else if results["credits"]?.isOK == true,
                  let subscription = results["subscription"], !subscription.isOK {
            status = subscription.failureStatus
        } else {
            status = .needsLogin
        }

        return ProviderSnapshot(
            provider: .augment,
            planName: planName,
            metrics: metrics,
            fetchedAt: now,
            status: status
        )
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var tier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tier.isEmpty else { return nil }
        if tier.caseInsensitiveCompare("Augment") == .orderedSame { return "Augment" }
        if tier.lowercased().hasPrefix("augment ") {
            tier = String(tier.dropFirst("augment ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let known = ["free", "community", "indie", "pro", "team", "enterprise"]
        if known.contains(tier.lowercased()) { tier = tier.lowercased().capitalized }
        return tier.isEmpty ? "Augment" : "Augment \(tier)"
    }

    private static func creditMetric(_ root: [String: Any], resetsAt: Date?) -> UsageMetric? {
        guard let values = creditValues(root) else { return nil }
        let remaining = values.remaining
        let consumed = values.consumed
        let available = values.available
        guard remaining != nil || consumed != nil || available != nil else { return nil }

        let total: Double?
        if let available, available > 0 {
            total = available
        } else if remaining != nil || consumed != nil {
            let combined = (remaining ?? 0) + (consumed ?? 0)
            guard combined.isFinite else { return nil }
            total = combined
        } else {
            total = nil
        }

        let percent: Double?
        if let total, total > 0, let consumed {
            percent = clamp(consumed / total * 100)
        } else if let total, total > 0, let remaining {
            percent = clamp((total - remaining) / total * 100)
        } else {
            percent = nil
        }
        let rawStatus = JSONHelp.string(root["usageBalanceStatus"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UsageMetric(
            id: "credits",
            label: "Credits",
            usedPercent: percent,
            remaining: remaining,
            total: total,
            resetsAt: resetsAt,
            detail: rawStatus?.isEmpty == false ? rawStatus : nil,
            pinned: true
        )
    }

    private static func creditValues(
        _ root: [String: Any]
    ) -> (remaining: Double?, consumed: Double?, available: Double?)? {
        let keys = [
            "usageUnitsRemaining",
            "usageUnitsConsumedThisBillingCycle",
            "usageUnitsAvailable",
        ]
        var values: [Double?] = []
        for key in keys {
            guard let raw = root[key], !(raw is NSNull) else {
                values.append(nil)
                continue
            }
            guard let value = JSONHelp.double(raw), value.isFinite, value >= 0 else { return nil }
            values.append(value)
        }
        return (values[0], values[1], values[2])
    }

    private static func finiteDate(_ value: Any?) -> Date? {
        guard let date = JSONHelp.date(value), date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return date
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

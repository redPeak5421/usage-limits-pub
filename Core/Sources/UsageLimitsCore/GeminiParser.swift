import Foundation

/// 解析 Gemini 的 quota JSON（若同源探针拿到 CodexBar 形状）。
/// 官网没有已确认的 Cookie 配额接口；HTML / 缺字段必须报错，不得编造数字。
/// 接口目录见 `providers/gemini.md`。
public enum GeminiParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let quota = results["quota"] else {
            return snapshot(now: now, status: .error("未获取到额度响应"))
        }
        guard quota.isOK else {
            return snapshot(now: now, status: quota.failureStatus)
        }
        guard let root = JSONHelp.object(quota.body) else {
            return snapshot(now: now, status: .error("配额数据异常"))
        }
        let buckets = quotaBuckets(in: root)
        guard !buckets.isEmpty else {
            return snapshot(now: now, status: .error("未获取到额度响应"))
        }

        var metrics: [UsageMetric] = []
        for (index, bucket) in buckets.enumerated() {
            guard let metric = remainingFractionMetric(bucket, fallbackIndex: index, pinned: index == 0) else {
                return snapshot(now: now, status: .error("配额数据异常"))
            }
            metrics.append(metric)
        }
        return ProviderSnapshot(provider: .gemini, metrics: metrics, fetchedAt: now, status: .ok)
    }

    static func quotaBuckets(in root: [String: Any]) -> [[String: Any]] {
        if let buckets = dictArray(root["buckets"]) { return buckets }
        if let models = dictArray(root["models"]) { return models }
        return []
    }

    static func remainingFractionMetric(
        _ bucket: [String: Any],
        fallbackIndex: Int,
        pinned: Bool
    ) -> UsageMetric? {
        guard let fraction = JSONHelp.double(bucket["remainingFraction"])
                ?? JSONHelp.double(bucket["remaining_fraction"]),
              fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        let used = clamp((1 - fraction) * 100)
        let id = JSONHelp.string(bucket["modelId"])
            ?? JSONHelp.string(bucket["model_id"])
            ?? JSONHelp.string(bucket["bucketId"])
            ?? JSONHelp.string(bucket["bucket_id"])
            ?? "quota-\(fallbackIndex)"
        let label = JSONHelp.string(bucket["displayName"])
            ?? JSONHelp.string(bucket["display_name"])
            ?? id
        return UsageMetric(
            id: id,
            label: label,
            usedPercent: used,
            resetsAt: JSONHelp.date(bucket["resetTime"]) ?? JSONHelp.date(bucket["reset_time"]),
            pinned: pinned
        )
    }

    static func dictArray(_ any: Any?) -> [[String: Any]]? {
        guard let values = any as? [Any] else { return nil }
        var rows: [[String: Any]] = []
        for value in values {
            guard let row = value as? [String: Any] else { return nil }
            rows.append(row)
        }
        return rows
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .gemini, fetchedAt: now, status: status)
    }
}

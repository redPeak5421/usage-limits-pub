import Foundation

/// 解析 Antigravity 的 quota JSON（groups + remainingFraction）。
/// 桌面端 OAuth / 本地 agy 不能搬到 iOS Cookie 探针；缺 JSON 必须报错。
/// 接口目录见 `providers/antigravity.md`。
public enum AntigravityParser {
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
        let buckets = groupedBuckets(in: root)
        guard !buckets.isEmpty else {
            return snapshot(now: now, status: .error("未获取到额度响应"))
        }

        var metrics: [UsageMetric] = []
        for (index, bucket) in buckets.enumerated() {
            guard let metric = GeminiParser.remainingFractionMetric(
                bucket,
                fallbackIndex: index,
                pinned: index == 0
            ) else {
                return snapshot(now: now, status: .error("配额数据异常"))
            }
            metrics.append(metric)
        }
        return ProviderSnapshot(provider: .antigravity, metrics: metrics, fetchedAt: now, status: .ok)
    }

    private static func groupedBuckets(in root: [String: Any]) -> [[String: Any]] {
        if let groups = GeminiParser.dictArray(root["groups"]) {
            var rows: [[String: Any]] = []
            for group in groups {
                guard let buckets = GeminiParser.dictArray(group["buckets"]) else { continue }
                rows.append(contentsOf: buckets)
            }
            if !rows.isEmpty { return rows }
        }
        return GeminiParser.quotaBuckets(in: root)
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .antigravity, fetchedAt: now, status: status)
    }
}

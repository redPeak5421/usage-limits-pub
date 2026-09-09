import Foundation
import CoreFoundation

/// 解析官网 GetUsageInfo RPC；HTML / 缺字段不得编造数字。
/// 接口目录见 `providers/gemini.md`。
public enum GeminiParser {
    public static let webUsageUnavailableError = "Gemini 未返回用量数据，请在官网确认账号与用量页"

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
        if quota.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(")]}'") {
            return parseWebUsage(quota.body, now: now)
        }
        let prefix = quota.body.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .prefix(32).lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
            return snapshot(now: now, status: .error(webUsageUnavailableError))
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

    private static func parseWebUsage(_ body: String, now: Date) -> ProviderSnapshot {
        for line in body.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let frames = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { continue }
            for frame in frames where frame.count >= 3 && frame[0] as? String == "wrb.fr" && frame[1] as? String == "jSf9Qc" {
                guard let payload = frame[2] as? String,
                      let data = payload.data(using: .utf8),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [Any], root.count >= 2,
                      let rows = root[1] as? [[Any]] else { continue }
                var metrics: [UsageMetric] = []
                for kind in [1, 2] {
                    guard let row = rows.first(where: { $0.count >= 3 && number($0[2]) == Double(kind) }),
                          let used = number(row[1]), (0...1).contains(used) else { continue }
                    var resetsAt: Date?
                    if row.count > 3, let reset = row[3] as? [[Any]], let timestamp = reset.first,
                       let secondsValue = timestamp.first, let seconds = number(secondsValue), seconds > 0 {
                        let nanos = timestamp.count > 1 ? number(timestamp[1]) : 0
                        if let nanos, (0..<1_000_000_000).contains(nanos) {
                            resetsAt = Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
                        }
                    }
                    metrics.append(UsageMetric(id: kind == 1 ? "five_hour" : "weekly",
                        label: kind == 1 ? "5 小时窗口" : "周窗口", usedPercent: used * 100,
                        resetsAt: resetsAt, pinned: metrics.isEmpty))
                }
                guard !metrics.isEmpty else { continue }
                let plan: String?
                switch number(root[0]) {
                case 2: plan = "Google AI Pro"
                case 3, 6: plan = "Google AI Ultra"
                case 4: plan = "Google AI Plus"
                default: plan = nil
                }
                return ProviderSnapshot(provider: .gemini, planName: plan, metrics: metrics, fetchedAt: now, status: .ok)
            }
        }
        return snapshot(now: now, status: .error("未获取到额度响应"))
    }

    private static func number(_ value: Any) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
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

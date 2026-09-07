import Foundation

/// 解析 Kiro 用量 JSON（planLimit / planUsed）。
/// 桌面端 `GetUsageLimits` 是 AWS 签名接口，不能从 WKWebView Cookie 伪造。
/// 接口目录见 `providers/kiro.md`。
public enum KiroParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let usage = results["usage"] else {
            return snapshot(now: now, status: .error("未获取到用量数据"))
        }
        guard usage.isOK else {
            return snapshot(now: now, status: usage.failureStatus)
        }
        guard let root = JSONHelp.object(usage.body) else {
            return snapshot(now: now, status: .error("用量数据异常"))
        }
        let node = (root["credit"] as? [String: Any]) ?? root
        guard let limit = JSONHelp.double(node["planLimit"]) ?? JSONHelp.double(node["plan_limit"]),
              let used = JSONHelp.double(node["planUsed"]) ?? JSONHelp.double(node["plan_used"]),
              limit.isFinite, used.isFinite, limit >= 0, used >= 0 else {
            return snapshot(now: now, status: .error("用量数据异常"))
        }
        let remaining = max(0, limit - used)
        let percent = limit > 0 ? clamp(used / limit * 100) : (used > 0 ? 100 : 0)
        let reset = JSONHelp.date(node["nextDateReset"]) ?? JSONHelp.date(node["next_date_reset"])
            ?? JSONHelp.date(root["nextDateReset"]) ?? JSONHelp.date(root["next_date_reset"])
        let metric = UsageMetric(
            id: "plan",
            label: "Plan",
            usedPercent: percent,
            remaining: remaining,
            total: limit,
            resetsAt: reset,
            pinned: true
        )
        return ProviderSnapshot(provider: .kiro, metrics: [metric], fetchedAt: now, status: .ok)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .kiro, fetchedAt: now, status: status)
    }
}

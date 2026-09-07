import Foundation

/// 解析 GitHub Copilot 的 budgets 探针。接口目录见 `providers/copilot.md`。
/// 同源 Cookie 路径：`GET /settings/billing/budgets?page=1&page_size=10&scope=customer`。
public enum CopilotParser {
    private static let copilotSKUs: Set<String> = [
        "copilot",
        "copilot_premium_request",
        "copilot_agent_premium_request",
        "spark_premium_request",
    ]

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let budgets = results["budgets"] else {
            return snapshot(now: now, status: .error("未获取到额度响应"))
        }
        guard budgets.isOK else {
            return snapshot(now: now, status: budgets.failureStatus)
        }
        guard let root = unwrapPayload(JSONHelp.object(budgets.body)),
              let rows = root["budgets"] as? [Any] else {
            return snapshot(now: now, status: .error("配额数据异常"))
        }

        var metrics: [UsageMetric] = []
        for (index, row) in rows.enumerated() {
            guard let item = row as? [String: Any] else {
                return snapshot(now: now, status: .error("配额数据异常"))
            }
            guard isCopilotBudget(item) else { continue }
            guard let amount = JSONHelp.double(item["budgetAmount"]) ?? JSONHelp.double(item["budget_amount"]),
                  let current = JSONHelp.double(item["currentAmount"]) ?? JSONHelp.double(item["current_amount"]),
                  amount.isFinite, current.isFinite, amount > 0, current >= 0 else {
                return snapshot(now: now, status: .error("配额数据异常"))
            }
            let percent = clamp(current / amount * 100)
            let name = JSONHelp.string(item["name"])
                ?? JSONHelp.string(item["displayName"])
                ?? JSONHelp.string(item["display_name"])
                ?? "Copilot"
            let id = JSONHelp.string(item["id"])
                ?? JSONHelp.string(item["uuid"])
                ?? "budget-\(index)"
            metrics.append(UsageMetric(
                id: id,
                label: name,
                usedPercent: percent,
                remaining: max(0, amount - current),
                total: amount,
                pinned: index == 0
            ))
        }
        guard !metrics.isEmpty else {
            return snapshot(now: now, status: .error("未获取到用量数据"))
        }
        return ProviderSnapshot(provider: .copilot, metrics: metrics, fetchedAt: now, status: .ok)
    }

    private static func unwrapPayload(_ root: [String: Any]?) -> [String: Any]? {
        guard let root else { return nil }
        if let payload = root["payload"] as? [String: Any] { return payload }
        return root
    }

    private static func isCopilotBudget(_ item: [String: Any]) -> Bool {
        let skus = stringArray(item["budgetProductSkus"]) + stringArray(item["budget_product_skus"])
        if !skus.isEmpty {
            return !Set(skus.map { $0.lowercased() }).isDisjoint(with: copilotSKUs)
        }
        let name = (JSONHelp.string(item["name"]) ?? "").lowercased()
        return name.contains("copilot")
    }

    private static func stringArray(_ any: Any?) -> [String] {
        if let values = any as? [String] { return values }
        if let values = any as? [Any] {
            return values.compactMap { JSONHelp.string($0) }
        }
        if let value = JSONHelp.string(any) { return [value] }
        return []
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .copilot, fetchedAt: now, status: status)
    }
}

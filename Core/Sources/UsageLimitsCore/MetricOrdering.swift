import Foundation

/// 用户自定义的计量条顺序：按 id 列表重排，列表外的（接口新增的）指标按原顺序排在最后，
/// 列表里已经不存在的 id 忽略。App 首页、小组件、手表都通过 `SharedStore` 读快照时套用，
/// 解析器本身不感知。
public enum MetricOrdering {
    public static func apply(_ metrics: [UsageMetric], order: [String]) -> [UsageMetric] {
        guard !order.isEmpty else { return metrics }
        var remaining = metrics
        var result: [UsageMetric] = []
        for id in order {
            guard let i = remaining.firstIndex(where: { $0.id == id }) else { continue }
            result.append(remaining.remove(at: i))
        }
        return result + remaining
    }
}

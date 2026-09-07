import Foundation

/// 「用量最高」自动选择（2×2 小组件可选项，参考 CodexBar 的 menuBarShowsHighestUsage）。
/// 永远按**已用百分比**比较，与展示口径（按已用 / 按剩余）解耦：显示模式只决定怎么画，不决定选谁。
public enum HighestUsagePicker {
    /// 一张快照的比较分：全部有效百分比指标里最大的一条；没有百分比指标返回 nil（不参与竞争）。
    public static func score(_ snapshot: ProviderSnapshot) -> Double? {
        guard snapshot.status.isOK else { return nil }
        // activeMetrics 会保留金额行、过滤 0% 行；只看它会让「有余额 + 0% 窗口」
        // 被误判成没有百分比。比较分必须从原始全部指标中独立提取。
        let fromMetrics = snapshot.metrics.compactMap { metric -> Double? in
            if let percent = UsagePresentation.validUsedPercent(metric.usedPercent) {
                return percent
            }
            if CustomUsageDisplay.fieldRole(metric) == .percent {
                return UsagePresentation.validUsedPercent(metric.amount)
            }
            return nil
        }
        if let best = fromMetrics.max() { return best }
        let numeric = CustomUsageDisplay.tiles(from: snapshot).filter { $0.role != .timestamp }
        let share = CustomUsageDisplay.sharePercent(from: snapshot.metrics)
        if let gauge = CustomUsageDisplay.gauge(tiles: numeric, share: share) {
            return UsagePresentation.validUsedPercent(gauge.riskPercent)
        }
        return share.flatMap(UsagePresentation.validUsedPercent)
    }

    /// 在候选里挑已用最高的一项。已经 100% 打满的候选排在后面（否则它会永远霸占小组件，
    /// 用户反而看不到其它正在消耗的额度）；全部打满时才回落到打满的那一个。并列取靠前者。
    public static func pick<T>(_ items: [T], snapshot: (T) -> ProviderSnapshot?) -> T? {
        var best: (item: T, score: Double)?
        var bestFull: (item: T, score: Double)?
        for item in items {
            guard let snap = snapshot(item), let score = score(snap) else { continue }
            if score >= 100 {
                if bestFull == nil || score > bestFull!.score { bestFull = (item, score) }
            } else if best == nil || score > best!.score {
                best = (item, score)
            }
        }
        return best?.item ?? bestFull?.item
    }
}

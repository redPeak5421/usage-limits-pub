import Foundation

/// 百分比类指标的展示口径：按已用画，还是按剩余画。
/// 解析器与提醒决策永远以「已用」（`UsageMetric.usedPercent`）为准；本口径只影响展示层
///（首页卡片、小组件、手表、分享图），不改快照、不改阈值判定。
public enum UsageDisplayMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 条 / 环随消耗增长，数值是已用百分比（历史默认）。
    case used
    /// 条 / 环随消耗缩短，数值是剩余百分比（CodexBar 默认口径）。
    case remaining

    public var id: String { rawValue }
}

/// 重置时间的展示口径：倒计时（「3 小时 12 分」）还是具体时刻（「14:30」/「明天 09:00」/「09-03 00:00」）。
public enum ResetTimeStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case countdown
    case absolute

    public var id: String { rawValue }
}

/// 百分比的风险色语义。`unknown` 必须显示中性颜色，不能把坏数据伪装成低风险绿色。
public enum UsageRiskLevel: Equatable, Sendable {
    case unknown
    case low
    case medium
    case high
}

/// 展示层换算。所有端共用同一套函数，保证首页 / 小组件 / 手表 / 分享图口径一致。
public enum UsagePresentation {
    /// 业务域内的已用百分比。通知、最高用量与风险色只接受 finite 0...100。
    public static func validUsedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    /// 通知文案专用安全整数；异常事件返回 nil，由投递层跳过。
    public static func roundedUsedPercent(_ value: Double?) -> Int? {
        guard let value = validUsedPercent(value) else { return nil }
        return JSONHelp.intRounded(value)
    }

    public static func riskLevel(for value: Double?) -> UsageRiskLevel {
        guard let value = validUsedPercent(value) else { return .unknown }
        if value >= 85 { return .high }
        if value >= 60 { return .medium }
        return .low
    }

    /// 要画到进度条 / 圆环上的百分比（0…100）。
    public static func barPercent(used: Double, mode: UsageDisplayMode) -> Double {
        // 非有限值不能参与 clamp（NaN 会一路传到 Int/CGFloat）；坏数据统一画空条，
        // 也避免「按剩余」把未知值误画成 100%。
        guard used.isFinite else { return 0 }
        let clamped = min(max(used, 0), 100)
        switch mode {
        case .used: return clamped
        case .remaining: return 100 - clamped
        }
    }

    /// 数值文本：`42%`。四舍五入到整数；未知的非有限值显示安全占位，不伪装成 0%。
    public static func percentText(used: Double, mode: UsageDisplayMode) -> String {
        guard used.isFinite else { return "—" }
        guard let percent = JSONHelp.intRounded(barPercent(used: used, mode: mode)) else { return "—" }
        return "\(percent)%"
    }

    /// 跨端统一的指标数值展示。只要解析器给了有效的已用百分比，显示口径就必须接管文本，
    /// 不能被官网百分比对或「剩余/总额」绕过；没有百分比时保留原有金额、次数与状态文本。
    public static func valueText(
        for metric: UsageMetric,
        language: AppLanguage,
        mode: UsageDisplayMode
    ) -> String {
        if let percent = validUsedPercent(metric.usedPercent) {
            return percentText(used: percent, mode: mode)
        }
        if let display = metric.displayValue, !display.isEmpty {
            return L10n.tr(display, language)
        }
        if metric.detail == "无限制" || metric.detail == "无上限" { return "∞" }
        if let remaining = safeNonnegativeInt(metric.remaining),
           let total = safeNonnegativeInt(metric.total) {
            return L10n.tr("metric.remaining", language, remaining, total)
        }
        if let amount = metric.amount, amount.isFinite {
            return MoneyFormat.string(amount, currency: metric.currency)
        }
        return "—"
    }

    private static func safeNonnegativeInt(_ value: Double?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return JSONHelp.intTruncating(value)
    }
}

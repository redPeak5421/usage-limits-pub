import Foundation

/// 与系统 locale 无关的相对时间，App 与小组件共用；语言由 App 设置决定。
public enum TimeFormat {
    private static let invalidPlaceholder = "—"

    /// Fixed Gregorian calendar date in the user's time zone, independent of display language.
    public static func yearMonthDay(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard JSONHelp.isSafeDate(date) else { return invalidPlaceholder }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func relative(_ date: Date, now: Date = Date(), language: AppLanguage = .zh) -> String {
        let interval = date.timeIntervalSince(now)
        guard let minutes = safeRoundedMinutes(interval) else { return invalidPlaceholder }
        if interval <= 0 { return L10n.tr("time.reset", language) }
        if minutes < 60 { return L10n.tr("time.min", language, minutes) }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m > 0 ? L10n.tr("time.hourMin", language, hours, m) : L10n.tr("time.hour", language, hours)
        }
        let days = hours / 24
        let h = hours % 24
        return h > 0 ? L10n.tr("time.dayHour", language, days, h) : L10n.tr("time.day", language, days)
    }

    /// 2×2 紧凑倒计时：只保留最大粒度（4 天后 / 3 小时后 / 25 分后）。
    public static func compactRelative(_ date: Date, now: Date = Date(), language: AppLanguage = .zh) -> String {
        let interval = date.timeIntervalSince(now)
        guard let minutes = safeRoundedMinutes(interval) else { return invalidPlaceholder }
        if interval <= 0 { return L10n.tr("time.reset", language) }
        if minutes < 60 { return L10n.tr("time.compactMin", language, minutes) }
        let hours = minutes / 60
        if hours < 24 { return L10n.tr("time.hour", language, hours) }
        return L10n.tr("time.day", language, hours / 24)
    }

    /// 重置 / 到期时间按展示口径输出：倒计时走 `relative`；具体时刻当天只给 `HH:mm`，
    /// 明天给「明天 HH:mm」，更远给 `MM-dd HH:mm`（CodexBar `resetDescription` 同一分档）。
    public static func reset(
        _ date: Date,
        now: Date = Date(),
        language: AppLanguage = .zh,
        style: ResetTimeStyle,
        calendar: Calendar = .current
    ) -> String {
        let interval = date.timeIntervalSince(now)
        guard safeRoundedMinutes(interval) != nil else { return invalidPlaceholder }
        switch style {
        case .countdown:
            return relative(date, now: now, language: language)
        case .absolute:
            if interval <= 0 { return L10n.tr("time.reset", language) }
            if calendar.isDate(date, inSameDayAs: now) { return hourMinute(date) }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(date, inSameDayAs: tomorrow) {
                let time = hourMinute(date)
                guard time != invalidPlaceholder else { return invalidPlaceholder }
                return L10n.tr("time.tomorrowAt", language, time)
            }
            return monthDayHourMinute(date)
        }
    }

    /// "HH:mm" 形式的本地时间（更新时间戳展示用）。
    public static func hourMinute(_ date: Date) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return invalidPlaceholder }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let text = f.string(from: date)
        return text.isEmpty ? invalidPlaceholder : text
    }

    /// 小组件「上次刷新」时间戳：当天只显示 `HH:mm`，跨天显示 `MM-dd HH:mm`，
    /// 避免昨天的 `22:21` 被误读成刚刷新过。
    public static func refreshStamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return invalidPlaceholder }
        return calendar.isDate(date, inSameDayAs: now) ? hourMinute(date) : monthDayHourMinute(date)
    }

    /// 即梦流水行：`08-23 22:21`。
    public static func monthDayHourMinute(_ date: Date) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return invalidPlaceholder }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        let text = formatter.string(from: date)
        return text.isEmpty ? invalidPlaceholder : text
    }

    /// `Double` 可以是有限值却远超 `Int`；所有相对时间整数运算统一经过这里。
    private static func safeRoundedMinutes(_ interval: TimeInterval) -> Int? {
        guard interval.isFinite else { return nil }
        let rounded = (interval / 60).rounded(.up)
        return JSONHelp.intExactly(rounded)
    }
}

/// 金额 / 大数字展示。DeepSeek 折叠两金额与展开数值共用。
public enum MoneyFormat {
    public static func string(_ amount: Double, currency: String?) -> String {
        if let currency, currency.uppercased() == "CNY" {
            return String(format: "¥%.2f", amount)
        }
        if let currency, currency.uppercased() == "USD" {
            return String(format: "$%.2f", amount)
        }
        if let currency, !currency.isEmpty {
            return String(format: "%.2f %@", amount, currency)
        }
        if amount >= 1_000_000_000 { return String(format: "%.2fB", amount / 1_000_000_000) }
        if amount >= 1_000_000 { return String(format: "%.2fM", amount / 1_000_000) }
        if amount >= 1_000 { return String(format: "%.1fK", amount / 1_000) }
        if amount == amount.rounded() { return String(format: "%.0f", amount) }
        return String(format: "%.2f", amount)
    }
}

/// 语义为整数的远端数量统一展示入口。先走带范围检查的取整，再生成文本，
/// 避免 `Int(Double)` 在有限但超出整数范围的输入上触发运行时 trap。
public enum IntegerFormat {
    public static func rounded(_ value: Double?) -> Int? {
        guard let value else { return nil }
        return JSONHelp.intRounded(value)
    }

    public static func truncating(_ value: Double?) -> Int? {
        guard let value else { return nil }
        return JSONHelp.intTruncating(value)
    }

    public static func string(_ value: Double?, placeholder: String = "—") -> String {
        guard let value = rounded(value) else { return placeholder }
        return String(value)
    }

    public static func signedString(_ value: Double?, placeholder: String = "—") -> String {
        guard let value = rounded(value) else { return placeholder }
        return String(format: "%+d", value)
    }
}

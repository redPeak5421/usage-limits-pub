import CoreFoundation
import Foundation

/// 解析 Notion AI 探针结果。接口目录见 `providers/notion.md`。
public enum NotionParser {
    private static let maximumSafeEpochSeconds = 253_402_300_799.0

    private enum SpacesSummary {
        case workspace(subscriptionTier: String?)
        case noWorkspace
        case invalid
    }

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let spacesResult = results["spaces"] else {
            return snapshot(now: now, status: .error("未获取到 Notion workspace 响应"))
        }
        guard spacesResult.isOK else {
            return snapshot(now: now, status: failureStatus(spacesResult))
        }

        let subscriptionTier: String?
        switch parseSpacesSummary(spacesResult.body) {
        case let .workspace(tier):
            subscriptionTier = tier
        case .noWorkspace:
            return snapshot(now: now, status: .error("未找到 Notion workspace"))
        case .invalid:
            return snapshot(now: now, status: .error("Notion workspace 摘要异常"))
        }

        guard let creditResult = results["credit_limit"] else {
            return snapshot(now: now, status: .error("未获取到 Notion AI 额度响应"))
        }
        guard creditResult.isOK else {
            return snapshot(now: now, status: failureStatus(creditResult))
        }
        guard let root = JSONHelp.object(creditResult.body) else {
            return snapshot(now: now, status: .error("Notion AI 额度数据异常"))
        }
        if normalizedString(root["status"])?.lowercased() == "not_applicable" {
            return snapshot(now: now, status: .error("当前 workspace 不适用 Notion AI 额度"))
        }

        var metrics: [UsageMetric] = []
        if let rolling = metric(
            root["window"],
            id: "rolling",
            label: rollingLabel,
            resetsAt: resetDate(secondsFromNow: root["resetsInSeconds"], now: now)
        ) {
            metrics.append(rolling)
        }
        if let billing = metric(
            root["billingPeriodWindow"],
            id: "billing_period",
            label: { _ in "Billing Period" },
            resetsAt: epochMillisecondsDate((root["billingPeriodWindow"] as? [String: Any])?["periodEndMs"])
        ) {
            metrics.append(billing)
        }
        guard !metrics.isEmpty else {
            return snapshot(now: now, status: .error("Notion AI 额度数据异常"))
        }

        return ProviderSnapshot(
            provider: .notion,
            planName: planName(subscriptionTier),
            metrics: metrics,
            fetchedAt: now,
            status: .ok
        )
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .notion, fetchedAt: now, status: status)
    }

    /// Notion 的 403 也可能是 workspace / 内部接口问题；只有 401 能确定登录失效。
    private static func failureStatus(_ result: ProbeResult) -> SnapshotStatus {
        if result.status == 401 { return .needsLogin }
        if result.status > 0 { return .error("HTTP \(result.status)") }
        if result.status == -3 { return .error("请求超时") }
        return .error("网络错误")
    }

    private static func parseSpacesSummary(_ body: String) -> SpacesSummary {
        guard let root = JSONHelp.object(body), !root.isEmpty else { return .invalid }
        let allowedKeys: Set<String> = ["hasWorkspace", "subscriptionTier"]
        guard Set(root.keys).isSubset(of: allowedKeys),
              let hasWorkspace = strictBool(root["hasWorkspace"])
        else { return .invalid }

        let subscriptionTier: String?
        if let rawTier = root["subscriptionTier"] {
            guard let tier = rawTier as? String,
                  tier == tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  ["free", "plus", "business", "enterprise"].contains(tier)
            else { return .invalid }
            subscriptionTier = tier
        } else {
            subscriptionTier = nil
        }
        guard hasWorkspace else {
            return subscriptionTier == nil ? .noWorkspace : .invalid
        }
        return .workspace(subscriptionTier: subscriptionTier)
    }

    private static func metric(
        _ raw: Any?,
        id: String,
        label: ([String: Any]) -> String,
        resetsAt: Date?
    ) -> UsageMetric? {
        guard let window = raw as? [String: Any],
              let used = finiteNumber(window["used"]), used >= 0,
              let limit = finiteNumber(window["limit"]), limit > 0
        else { return nil }

        let ratio = used / limit * 100
        let remaining = max(limit - used, 0)
        guard ratio.isFinite, remaining.isFinite else { return nil }
        return UsageMetric(
            id: id,
            label: label(window),
            usedPercent: clamp(ratio),
            remaining: remaining,
            total: limit,
            resetsAt: resetsAt,
            pinned: true
        )
    }

    private static func rollingLabel(_ window: [String: Any]) -> String {
        guard let minutes = windowMinutes(normalizedString(window["window"])) else { return "Rolling" }
        if minutes.isMultiple(of: 7 * 24 * 60) {
            return "Rolling（\(minutes / (7 * 24 * 60)) 周）"
        }
        if minutes.isMultiple(of: 24 * 60) {
            return "Rolling（\(minutes / (24 * 60)) 天）"
        }
        if minutes.isMultiple(of: 60) {
            return "Rolling（\(minutes / 60) 小时）"
        }
        return "Rolling（\(minutes) 分钟）"
    }

    private static func windowMinutes(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.count >= 2,
              let unit = raw.last,
              raw.dropLast().count <= 9,
              let value = Int(raw.dropLast()), value > 0
        else { return nil }
        let multiplier: Int
        switch unit {
        case "m": multiplier = 1
        case "h": multiplier = 60
        case "d": multiplier = 24 * 60
        case "w": multiplier = 7 * 24 * 60
        default: return nil
        }
        let (minutes, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : minutes
    }

    private static func resetDate(secondsFromNow raw: Any?, now: Date) -> Date? {
        guard let seconds = finiteNumber(raw), seconds >= 0 else { return nil }
        let epoch = now.timeIntervalSince1970 + seconds
        return safeDate(epochSeconds: epoch)
    }

    private static func epochMillisecondsDate(_ raw: Any?) -> Date? {
        guard let milliseconds = finiteNumber(raw), milliseconds > 0 else { return nil }
        return safeDate(epochSeconds: milliseconds / 1_000)
    }

    private static func safeDate(epochSeconds: Double) -> Date? {
        guard epochSeconds.isFinite,
              epochSeconds >= 0,
              epochSeconds <= maximumSafeEpochSeconds
        else { return nil }
        let date = Date(timeIntervalSince1970: epochSeconds)
        return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }

    private static func planName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let label = words.map { String($0).lowercased().capitalized }.joined(separator: " ")
        return "Notion AI \(label)"
    }

    private static func normalizedString(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func strictBool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

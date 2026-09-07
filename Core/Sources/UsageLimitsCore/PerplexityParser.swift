import Foundation
import CoreFoundation

/// 解析 Perplexity 探针结果。接口目录见 `providers/perplexity.md`。
public enum PerplexityParser {
    /// Unix epoch 秒上界：9999-12-31T23:59:59Z。更大的有限值无法安全展示。
    private static let maximumEpochSeconds = 253_402_300_799.0

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let credits = results["credits"] else {
            return snapshot(now: now, status: .error("未获取到额度响应"))
        }
        guard credits.isOK else {
            return snapshot(now: now, status: credits.failureStatus)
        }
        guard let root = JSONHelp.object(credits.body), let parsed = parsedCredits(root, now: now) else {
            return snapshot(now: now, status: .error("额度数据异常"))
        }

        var usageRemaining = parsed.totalUsage
        let recurringUsed = min(usageRemaining, parsed.recurringTotal)
        usageRemaining -= recurringUsed
        let purchasedUsed = min(usageRemaining, parsed.purchasedTotal)
        usageRemaining -= purchasedUsed
        let promotionalUsed = min(usageRemaining, parsed.promotionalTotal)

        var metrics: [UsageMetric] = []
        if parsed.recurringTotal > 0 {
            metrics.append(poolMetric(
                id: "monthly",
                label: "月度额度",
                used: recurringUsed,
                total: parsed.recurringTotal,
                resetsAt: parsed.renewalDate,
                pinned: true
            ))
        }
        if parsed.purchasedTotal > 0 {
            metrics.append(poolMetric(
                id: "purchased",
                label: "购买额度",
                used: purchasedUsed,
                total: parsed.purchasedTotal
            ))
        }
        if parsed.promotionalTotal > 0 {
            metrics.append(poolMetric(
                id: "promotional",
                label: "赠送额度",
                used: promotionalUsed,
                total: parsed.promotionalTotal,
                resetsAt: parsed.promotionalExpiry,
                expiryDetail: parsed.promotionalExpiry
            ))
        }
        metrics.append(UsageMetric(
            id: "balance",
            label: "余额",
            amount: parsed.balanceCents / 100,
            currency: "USD",
            pinned: true
        ))

        let planName: String?
        if parsed.recurringTotal <= 0 {
            planName = nil
        } else if parsed.recurringTotal < 5_000 {
            planName = "Perplexity Pro"
        } else {
            planName = "Perplexity Max"
        }

        return ProviderSnapshot(
            provider: .perplexity,
            planName: planName,
            metrics: metrics,
            fetchedAt: now,
            status: .ok
        )
    }

    private struct ParsedCredits {
        var balanceCents: Double
        var recurringTotal: Double
        var purchasedTotal: Double
        var promotionalTotal: Double
        var totalUsage: Double
        var renewalDate: Date?
        var promotionalExpiry: Date?
    }

    private static func parsedCredits(_ root: [String: Any], now: Date) -> ParsedCredits? {
        guard let balance = requiredNumber(root, key: "balance_cents"),
              let purchasedField = requiredNumber(root, key: "current_period_purchased_cents"),
              let totalUsage = requiredNumber(root, key: "total_usage_cents"),
              let grants = root["credit_grants"] as? [[String: Any]] else { return nil }

        var recurringTotal = 0.0
        var purchasedFromGrants = 0.0
        var promotionalTotal = 0.0
        var promotionalExpiries: [Date] = []
        let nowEpoch = now.timeIntervalSince1970

        for grant in grants {
            guard let rawType = JSONHelp.string(grant["type"]) else { continue }
            let type = rawType.lowercased()
            guard ["recurring", "purchased", "promotional"].contains(type) else { continue }
            guard let amount = requiredNumber(grant, key: "amount_cents") else { return nil }

            let expiry: Double?
            if grant.keys.contains("expires_at_ts") {
                // 过期时间只是单条 grant 的属性；漂移时丢 grant，不能把它当作永不过期。
                guard let rawExpiry = grant["expires_at_ts"], !(rawExpiry is NSNull),
                      let parsed = strictNumber(rawExpiry), isValidEpoch(parsed) else {
                    continue
                }
                expiry = parsed
            } else {
                expiry = nil
            }

            switch type {
            case "recurring":
                guard let sum = safeAdd(recurringTotal, amount) else { return nil }
                recurringTotal = sum
            case "purchased":
                guard let sum = safeAdd(purchasedFromGrants, amount) else { return nil }
                purchasedFromGrants = sum
            case "promotional":
                guard expiry == nil || expiry! > nowEpoch else { continue }
                guard let sum = safeAdd(promotionalTotal, amount) else { return nil }
                promotionalTotal = sum
                if let expiry, let date = dateFromEpochSeconds(expiry) {
                    promotionalExpiries.append(date)
                }
            default:
                break
            }
        }

        return ParsedCredits(
            balanceCents: balance,
            recurringTotal: recurringTotal,
            purchasedTotal: max(purchasedFromGrants, purchasedField),
            promotionalTotal: promotionalTotal,
            totalUsage: totalUsage,
            renewalDate: optionalDate(root["renewal_date_ts"]),
            promotionalExpiry: promotionalExpiries.min()
        )
    }

    private static func poolMetric(
        id: String,
        label: String,
        used: Double,
        total: Double,
        resetsAt: Date? = nil,
        pinned: Bool? = nil,
        expiryDetail: Date? = nil
    ) -> UsageMetric {
        let remaining = total - used
        var detail = "已用 \(MoneyFormat.string(used, currency: nil)) / \(MoneyFormat.string(total, currency: nil)) credits"
        if let expiryDetail {
            detail += " · 最近到期 \(expiryDateString(expiryDetail))"
        }
        return UsageMetric(
            id: id,
            label: label,
            usedPercent: min(max(used / total * 100, 0), 100),
            remaining: remaining,
            total: total,
            resetsAt: resetsAt,
            detail: detail,
            pinned: pinned
        )
    }

    private static func requiredNumber(_ root: [String: Any], key: String) -> Double? {
        guard nonNull(root[key]) != nil else { return nil }
        return finiteNonnegative(root[key])
    }

    private static func finiteNonnegative(_ value: Any?) -> Double? {
        guard let value, let number = strictNumber(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func safeAdd(_ lhs: Double, _ rhs: Double) -> Double? {
        let sum = lhs + rhs
        return sum.isFinite ? sum : nil
    }

    private static func optionalDate(_ value: Any?) -> Date? {
        guard let value = nonNull(value), let epoch = strictNumber(value),
              isValidEpoch(epoch) else { return nil }
        return dateFromEpochSeconds(epoch)
    }

    /// JSONSerialization bridges booleans through NSNumber; compare Core Foundation type IDs so
    /// `true` / `false` can never masquerade as 1 / 0 while ordinary JSON numbers remain accepted.
    private static func strictNumber(_ value: Any) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return JSONHelp.double(value)
    }

    private static func dateFromEpochSeconds(_ epoch: Double) -> Date? {
        guard isValidEpoch(epoch) else { return nil }
        let date = Date(timeIntervalSince1970: epoch)
        return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }

    private static func isValidEpoch(_ epoch: Double) -> Bool {
        epoch.isFinite && epoch > 0 && epoch <= maximumEpochSeconds
    }

    private static func expiryDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func nonNull(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .perplexity, fetchedAt: now, status: status)
    }
}

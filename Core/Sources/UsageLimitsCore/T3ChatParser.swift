import CoreFoundation
import Foundation

/// 解析 T3 Chat 的 tRPC JSONL 探针结果。接口目录见 `providers/t3chat.md`。
public enum T3ChatParser {
    private static let maximumEpochSeconds = 253_402_300_799.0
    private static let maximumSearchDepth = 48
    private static let maximumSearchNodes = 10_000

    private enum CustomerSearchResult {
        case valid([String: Any])
        case malformed
        case missing
    }

    private struct CustomerCandidate {
        let object: [String: Any]
        let score: Int
    }

    private struct CustomerSearchState {
        var nodeCount = 0
        var exceededBudget = false
        var sawCandidate = false
        var best: CustomerCandidate?
    }

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let customerProbe = results["customer"] else {
            return snapshot(now: now, status: .error("未获取到 T3 Chat 响应"))
        }
        guard customerProbe.isOK else {
            if customerProbe.status == 429, isVercelChallenge(customerProbe.headers) {
                return snapshot(now: now, status: .error("T3 Chat 遇到 Vercel 风控挑战"))
            }
            return snapshot(now: now, status: customerProbe.failureStatus)
        }
        let customer: [String: Any]
        switch customerSearch(inJSONLines: customerProbe.body) {
        case let .valid(found):
            customer = found
        case .malformed:
            return snapshot(now: now, status: .error("T3 Chat 主窗口数据异常"))
        case .missing:
            return snapshot(now: now, status: .error("未找到 T3 Chat 用量数据"))
        }
        // 搜索阶段只会选出主百分比为有限 JSON number 的候选；这里保留防御式 guard。
        guard let primaryPercent = finiteNumber(customer["usageFourHourPercentage"]) else {
            return snapshot(now: now, status: .error("T3 Chat 主窗口数据异常"))
        }

        let primaryReset = safeDate(customer["usageFourHourNextResetAt"])
            ?? safeDate(customer["usageWindowNextResetAt"])
        let usageBand = trimmedString(customer["usageBand"])
        let primaryDetail = usageBand.map { "Base - \($0)" } ?? "Base"

        var metrics = [UsageMetric(
            id: "four_hour",
            label: "Base（4 小时）",
            usedPercent: clamp(primaryPercent),
            resetsAt: primaryReset,
            detail: primaryDetail,
            pinned: true
        )]

        let secondaryPercent = finiteNumber(customer["usageMonthPercentage"])
            ?? finiteNumber(customer["usagePeriodPercentage"])
        let subscription = customer["subscription"] as? [String: Any]
        if let secondaryPercent {
            metrics.append(UsageMetric(
                id: "overage",
                label: "Overage",
                usedPercent: clamp(secondaryPercent),
                resetsAt: safeDate(subscription?["currentPeriodEnd"])
            ))
        }

        let rawPlan = trimmedString(subscription?["productName"])
            ?? trimmedString(customer["subTier"])
        return ProviderSnapshot(
            provider: .t3chat,
            planName: planLabel(rawPlan),
            metrics: metrics,
            fetchedAt: now,
            status: .ok
        )
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .t3chat, fetchedAt: now, status: status)
    }

    private static func customerSearch(inJSONLines text: String) -> CustomerSearchResult {
        var state = CustomerSearchState()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            collectCustomers(in: root, depth: 0, state: &state)
            if state.exceededBudget { break }
        }
        if state.exceededBudget { return .malformed }
        if let best = state.best { return .valid(best.object) }
        return state.sawCandidate ? .malformed : .missing
    }

    private static func collectCustomers(
        in value: Any,
        depth: Int,
        state: inout CustomerSearchState
    ) {
        guard !state.exceededBudget else { return }
        guard depth <= maximumSearchDepth, state.nodeCount < maximumSearchNodes else {
            state.exceededBudget = true
            return
        }
        state.nodeCount += 1

        if let dictionary = value as? [String: Any] {
            if isCustomerCandidate(dictionary) {
                state.sawCandidate = true
                if finiteNumber(dictionary["usageFourHourPercentage"]) != nil {
                    let candidate = CustomerCandidate(
                        object: dictionary,
                        score: customerScore(dictionary)
                    )
                    if let current = state.best {
                        if candidate.score > current.score { state.best = candidate }
                    } else {
                        state.best = candidate
                    }
                }
            }
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                collectCustomers(in: child, depth: depth + 1, state: &state)
                if state.exceededBudget { return }
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectCustomers(in: child, depth: depth + 1, state: &state)
                if state.exceededBudget { return }
            }
        }
    }

    private static func isCustomerCandidate(_ dictionary: [String: Any]) -> Bool {
        let usageKeys = [
            "usageFourHourPercentage", "usageMonthPercentage", "usagePeriodPercentage",
            "usageFourHourNextResetAt", "usageWindowNextResetAt",
        ]
        return usageKeys.contains(where: { dictionary[$0] != nil })
            || (dictionary["subscription"] != nil && dictionary["usageBand"] != nil)
    }

    private static func customerScore(_ dictionary: [String: Any]) -> Int {
        var score = 100
        if (safeDate(dictionary["usageFourHourNextResetAt"])
            ?? safeDate(dictionary["usageWindowNextResetAt"])) != nil {
            score += 4
        }
        if (finiteNumber(dictionary["usageMonthPercentage"])
            ?? finiteNumber(dictionary["usagePeriodPercentage"])) != nil {
            score += 4
        }
        if trimmedString(dictionary["usageBand"]) != nil { score += 2 }
        if trimmedString(dictionary["subTier"]) != nil { score += 1 }
        if let subscription = dictionary["subscription"] as? [String: Any] {
            score += 2
            if trimmedString(subscription["productName"]) != nil { score += 1 }
            if safeDate(subscription["currentPeriodEnd"]) != nil { score += 1 }
        }
        return score
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func safeDate(_ value: Any?) -> Date? {
        guard let raw = finiteNumber(value), raw > 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        guard seconds.isFinite, seconds > 0, seconds <= maximumEpochSeconds else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split { character in
            character.isWhitespace || character == "-" || character == "_"
        }
        guard !parts.isEmpty else { return nil }
        return parts.map { String($0).lowercased().capitalized }.joined(separator: " ")
    }

    private static func isVercelChallenge(_ headers: [String: String]?) -> Bool {
        guard let value = headers?.first(where: {
            $0.key.caseInsensitiveCompare("x-vercel-mitigated") == .orderedSame
        })?.value else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("challenge") == .orderedSame
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

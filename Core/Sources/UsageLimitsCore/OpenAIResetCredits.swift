import Foundation

/// Read-only reset summary. Never stores credit IDs, identity, or redemption credentials.
public struct OpenAIResetCredits: Codable, Equatable, Sendable {
    public var availableCount: Int?
    public var expiresAt: Date?
    public var usedCount: Int?
    public var windowStart: Date?
    public var asOf: Date?
    public var historyComplete: Bool
    public var availableExpirations: [Date]?
    public var usedDates: [Date]?

    public var isValid: Bool {
        (availableCount.map { $0 >= 0 } ?? true)
            && (usedCount.map { $0 >= 0 } ?? true)
            && [expiresAt, windowStart, asOf].compactMap { $0 }.allSatisfy(JSONHelp.isSafeDate)
            && (availableExpirations ?? []).allSatisfy(JSONHelp.isSafeDate)
            && (usedDates ?? []).allSatisfy(JSONHelp.isSafeDate)
            && (windowStart == nil || asOf == nil || windowStart! <= asOf!)
    }

    static func parse(results: [String: ProbeResult], now: Date) -> Self? {
        var summary = Self(historyComplete: false)
        if let probe = results["reset_credits"], probe.isOK,
           let root = JSONHelp.object(probe.body),
           let count = JSONHelp.intExactly(root["available_count"]), count >= 0 {
            summary.availableCount = count
            if count > 0, let credits = root["credits"] as? [[String: Any]] {
                var seen = Set<String>()
                let dates = credits.compactMap { credit -> Date? in
                    guard credit["reset_type"] as? String == "codex_rate_limits",
                          credit["status"] as? String == "available",
                          credit["is_supported_by_plan"] as? Bool == true,
                          let date = JSONHelp.date(credit["expires_at"]), date > now else { return nil }
                    if let id = credit["id"] as? String, !id.isEmpty,
                       !seen.insert(id).inserted { return nil }
                    return date
                }.sorted()
                summary.availableExpirations = dates
                summary.expiresAt = dates.first
            }
        }
        if let probe = results["reset_history"], probe.isOK,
           let root = JSONHelp.object(probe.body), let events = root["events"] as? [Any],
           let start = JSONHelp.date(root["window_start"]),
           let end = JSONHelp.date(root["as_of"]), start <= end {
            var seen = Set<String>()
            var count = 0
            var dates: [Date] = []
            var complete = root["next_cursor"] is NSNull || (root["next_cursor"] as? String) == ""
            for raw in events {
                guard let event = raw as? [String: Any],
                      let kind = event["kind"] as? String,
                      let id = event["id"] as? String, !id.isEmpty,
                      let date = JSONHelp.date(event["occurred_at"]) else {
                    complete = false
                    continue
                }
                guard date >= start, date <= end else { continue }
                if kind == "used", seen.insert(id).inserted {
                    count += 1
                    dates.append(date)
                }
            }
            summary.usedCount = count
            summary.usedDates = dates.sorted(by: >)
            summary.windowStart = start
            summary.asOf = end
            summary.historyComplete = complete
        }
        return summary.availableCount != nil || summary.usedCount != nil ? summary : nil
    }
}

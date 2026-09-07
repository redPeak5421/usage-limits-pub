import CoreFoundation
import Foundation

/// 解析 Ollama 安全摘要。接口目录见 `providers/ollama.md`。
public enum OllamaParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let settings = results["settings"] else {
            return snapshot(now: now, status: .error("未获取到 Ollama settings 响应"))
        }
        guard settings.isOK else {
            return snapshot(now: now, status: settings.failureStatus)
        }
        guard let root = JSONHelp.object(settings.body) else {
            return snapshot(now: now, status: .error("Ollama 用量数据异常"))
        }
        let allowedRootKeys: Set<String> = ["plan", "signedOut", "session", "hourly", "weekly"]
        guard Set(root.keys).isSubset(of: allowedRootKeys),
              windowsHaveAllowedStructure(root),
              let signedOut = strictBool(root["signedOut"])
        else {
            return snapshot(now: now, status: .error("Ollama 用量数据异常"))
        }
        if signedOut {
            guard Set(root.keys) == ["signedOut"] else {
                return snapshot(now: now, status: .error("Ollama 用量数据异常"))
            }
            return snapshot(now: now, status: .needsLogin)
        }

        let planName: String?
        if let rawPlan = root["plan"] {
            guard let plan = rawPlan as? String,
                  plan == plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  ["free", "pro", "max"].contains(plan)
            else {
                return snapshot(now: now, status: .error("Ollama 用量数据异常"))
            }
            planName = "Ollama " + plan.prefix(1).uppercased() + plan.dropFirst()
        } else {
            planName = nil
        }

        guard root["session"] == nil || root["hourly"] == nil else {
            return snapshot(now: now, status: .error("Ollama 用量数据异常"))
        }
        var metrics: [UsageMetric] = []
        if let session = metric(root["session"], id: "session", label: "Session usage") {
            metrics.append(session)
        } else if let hourly = metric(root["hourly"], id: "session", label: "Hourly usage") {
            metrics.append(hourly)
        }
        if let weekly = metric(root["weekly"], id: "weekly", label: "Weekly usage") {
            metrics.append(weekly)
        }
        guard !metrics.isEmpty else {
            return snapshot(now: now, status: .error("Ollama 用量数据异常"))
        }

        return ProviderSnapshot(
            provider: .ollama,
            planName: planName,
            metrics: metrics,
            fetchedAt: now,
            status: .ok
        )
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .ollama, fetchedAt: now, status: status)
    }

    private static func metric(_ raw: Any?, id: String, label: String) -> UsageMetric? {
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: ["usedPercent", "resetsAt"]),
              let percent = strictFiniteNumber(object["usedPercent"])
        else { return nil }
        let resetsAt: Date?
        if let string = object["resetsAt"] as? String {
            resetsAt = safeISODate(string)
        } else {
            resetsAt = nil
        }
        return UsageMetric(
            id: id,
            label: label,
            usedPercent: min(100, max(0, percent)),
            resetsAt: resetsAt,
            pinned: true
        )
    }

    private static func strictBool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    /// 先验证完整结构，再解析各已知字段。这样任一窗口夹带身份 / 未知键时整份拒绝，
    /// 不会因另一窗口仍有效而让敏感摘要被接受。
    private static func windowsHaveAllowedStructure(_ root: [String: Any]) -> Bool {
        let allowedWindowKeys: Set<String> = ["usedPercent", "resetsAt"]
        for key in ["session", "hourly", "weekly"] where root[key] != nil {
            guard let window = root[key] as? [String: Any],
                  Set(window.keys).isSubset(of: allowedWindowKeys)
            else { return false }
        }
        return true
    }

    private static func strictFiniteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func safeISODate(_ raw: String) -> Date? {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              strictISOComponentsAreValid(raw)
        else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else { return nil }
        return JSONHelp.isSafeDate(date) ? date : nil
    }

    private static func strictISOComponentsAreValid(_ raw: String) -> Bool {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(?:Z|[+-]([0-9]{2}):([0-9]{2}))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw)
              ),
              let year = captureInt(match, group: 1, in: raw),
              let month = captureInt(match, group: 2, in: raw),
              let day = captureInt(match, group: 3, in: raw),
              let hour = captureInt(match, group: 4, in: raw),
              let minute = captureInt(match, group: 5, in: raw),
              let second = captureInt(match, group: 6, in: raw)
        else { return false }
        guard (1...9999).contains(year), (1...12).contains(month),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return false }
        if let offsetHour = captureInt(match, group: 7, in: raw),
           let offsetMinute = captureInt(match, group: 8, in: raw),
           (!(0...23).contains(offsetHour) || !(0...59).contains(offsetMinute)) {
            return false
        }
        let monthDays = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...monthDays[month - 1]).contains(day)
    }

    private static func captureInt(_ match: NSTextCheckingResult, group: Int, in raw: String) -> Int? {
        let range = match.range(at: group)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: raw)
        else { return nil }
        return Int(raw[swiftRange])
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }
}

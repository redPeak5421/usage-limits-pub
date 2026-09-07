import Foundation
import CoreFoundation

/// 防御式 JSON 取值工具：接口形状漂移时返回 nil，绝不崩溃。
enum JSONHelp {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func array(_ text: String) -> [Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }

    static func double(_ any: Any?) -> Double? {
        let value: Double?
        switch any {
        case let n as NSNumber:
            // JSONSerialization 把 true/false 桥接成 CFBoolean，不能当 1/0 用量。
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            value = n.doubleValue
        case let s as String:
            value = Double(s)
        default:
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// 只接受整数值，且转成 Int 前先做 finite / 范围检查。
    static func intExactly(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value)
    }

    static func intExactly(_ any: Any?) -> Int? {
        double(any).flatMap(intExactly)
    }

    /// 保留 Swift `rounded()` 的默认契约（最近、中点远离 0），越界则返回 nil。
    static func intRounded(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    static func intRounded(_ any: Any?) -> Int? {
        double(any).flatMap(intRounded)
    }

    /// 保留 `Int(Double)` 原有的向 0 截断契约，但对非有限/越界值返回 nil。
    static func intTruncating(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    static func intTruncating(_ any: Any?) -> Int? {
        double(any).flatMap(intTruncating)
    }

    static func string(_ any: Any?) -> String? { any as? String }

    /// 兼容 ISO8601（带/不带毫秒、无时区、空格分隔、仅日期）与 epoch 秒/毫秒。
    /// 无时区与仅日期一律按 UTC，不猜设备本地时区。
    static func date(_ any: Any?) -> Date? {
        if let s = any as? String {
            if let d = dateFromISO(s) { return d }
            if let epoch = double(s) { return dateFromEpoch(epoch) }
            return nil
        }
        if let n = double(any) { return dateFromEpoch(n) }
        return nil
    }

    private static func dateFromISO(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s), isSafeDate(d) { return d }
        // ISO8601DateFormatter 只认毫秒级小数；claude.ai usage 的 resets_at
        // 是 6 位微秒（2026-08-16 真机报文），截到 3 位再试。
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let truncated = s.replacingCharacters(in: r, with: String(s[r].prefix(4)))
            if let d = f.date(from: truncated), isSafeDate(d) { return d }
        }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s), isSafeDate(d) { return d }
        return dateFromLenientISO(s)
    }

    private static func dateFromLenientISO(_ s: String) -> Date? {
        var t = s.replacingOccurrences(of: " ", with: "T")
        if t.count == 10, t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            t += "T00:00:00Z"
        } else {
            let hasTZ = t.hasSuffix("Z")
                || t.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
                || t.range(of: #"[+-]\d{4}$"#, options: .regularExpression) != nil
            guard t.contains("T"), !hasTZ else { return nil }
            t += "Z"
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t), isSafeDate(d) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t), isSafeDate(d) { return d }
        return nil
    }

    private static func dateFromEpoch(_ v: Double) -> Date? {
        guard v.isFinite, v >= 0 else { return nil }
        // 大于 10^12 视为毫秒时间戳
        let seconds = v > 1_000_000_000_000 ? v / 1000 : v
        let date = Date(timeIntervalSince1970: seconds)
        return isSafeDate(date) ? date : nil
    }

    /// 持久化与展示的统一日期边界：Unix epoch 到 9999-12-31T23:59:59Z。
    static func isSafeDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (0...253_402_300_799).contains(seconds)
    }

    static func date(byAdding interval: Double, to base: Date) -> Date? {
        guard interval.isFinite, isSafeDate(base) else { return nil }
        let date = base.addingTimeInterval(interval)
        return isSafeDate(date) ? date : nil
    }

    /// 用量百分比统一为 0...100：小于等于 1 的值按 0...1 口径换算。
    static func percent(_ any: Any?) -> Double? {
        guard var v = double(any) else { return nil }
        if v <= 1.0 { v *= 100 }
        return min(max(v, 0), 100)
    }

    /// 原生 0...100 字段：`1` / `0.5` 就是 1% / 0.5%，不再当 0...1 比例放大。
    static func percentAlreadyHundred(_ any: Any?) -> Double? {
        guard let v = double(any) else { return nil }
        return min(max(v, 0), 100)
    }

    /// 递归收集所有包含指定键的嵌套字典（含路径，便于区分同名窗口）。
    static func dictsContainingKey(_ key: String, in any: Any, path: String = "") -> [(path: String, dict: [String: Any])] {
        var found: [(String, [String: Any])] = []
        if let dict = any as? [String: Any] {
            if dict[key] != nil { found.append((path, dict)) }
            for (k, v) in dict {
                found.append(contentsOf: dictsContainingKey(key, in: v, path: path.isEmpty ? k : "\(path).\(k)"))
            }
        } else if let arr = any as? [Any] {
            for (i, v) in arr.enumerated() {
                found.append(contentsOf: dictsContainingKey(key, in: v, path: "\(path)[\(i)]"))
            }
        }
        return found
    }
}

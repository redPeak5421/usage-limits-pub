import Foundation

public enum AutoRefreshUnit: String, Equatable, CaseIterable, Sendable {
    case seconds
    case minutes
}

/// 界面上的整数 + 单位。禁止小数；超过 60 的分钟改单位为秒，不改用户正在输入的数字。
public struct AutoRefreshChoice: Equatable, Sendable {
    public var amount: Int
    public var unit: AutoRefreshUnit

    public init(amount: Int, unit: AutoRefreshUnit) {
        self.amount = amount
        self.unit = unit
    }

    public var storedSeconds: Double {
        switch unit {
        case .seconds: return Double(min(max(amount, 0), AutoRefreshInterval.maxSeconds))
        case .minutes: return Double(min(max(amount, 0), AutoRefreshInterval.maxMinutes) * 60)
        }
    }
}

/// 自动刷新间隔：滑杆档位（含 10s/30s）与手动输入共用同一份以秒计的持久化值。0 = 不自动刷新。
public enum AutoRefreshInterval {
    public static let minutes: ClosedRange<Int> = 0...60
    public static let maxMinutes = 60
    public static var maxSeconds: Int { maxMinutes * 60 }
    /// 滑块档位（秒）：关 / 10s / 30s / 1m / 5m / 10m / 15m / 30m / 45m / 60m。
    public static let sliderSteps: [Double] = [0, 10, 30, 60, 300, 600, 900, 1800, 2700, 3600]

    /// SwiftUI Slider 的绑定值仍可能被旧状态/非有限值污染；索引前统一安全钳制。
    public static func sliderStep(at rawIndex: Double) -> Double {
        let upper = Double(sliderSteps.count - 1)
        let index: Double
        if rawIndex.isNaN || rawIndex == -.infinity {
            index = 0
        } else if rawIndex == .infinity {
            index = upper
        } else {
            index = min(max(rawIndex, 0), upper)
        }
        guard let rounded = JSONHelp.intRounded(index), sliderSteps.indices.contains(rounded) else {
            return sliderSteps[0]
        }
        return sliderSteps[rounded]
    }

    public static func seconds(minutes: Int) -> Double {
        let n = min(max(minutes, Self.minutes.lowerBound), Self.minutes.upperBound)
        return Double(n) * 60
    }

    public static func minutes(seconds: Double) -> Int {
        let safe = clamped(seconds)
        guard safe > 0, let rounded = JSONHelp.intRounded(safe / 60) else { return 0 }
        return min(Self.minutes.upperBound, max(Self.minutes.lowerBound, rounded))
    }

    public static func unit(forStored seconds: Double) -> AutoRefreshUnit {
        let s = JSONHelp.intRounded(clamped(seconds)) ?? 0
        if s <= 0 { return .minutes }
        if s % 60 == 0 { return .minutes }
        return .seconds
    }

    public static func displayNumber(_ seconds: Double) -> Int {
        choice(fromStored: seconds).amount
    }

    public static func clamped(_ seconds: Double) -> Double {
        if seconds.isNaN || seconds == -.infinity { return 0 }
        if seconds == .infinity { return Double(maxSeconds) }
        return min(max(seconds, 0), Double(maxSeconds))
    }

    public static func choice(fromStored seconds: Double) -> AutoRefreshChoice {
        let s = JSONHelp.intRounded(clamped(seconds)) ?? 0
        if s <= 0 { return AutoRefreshChoice(amount: 0, unit: .minutes) }
        if s % 60 == 0 { return AutoRefreshChoice(amount: s / 60, unit: .minutes) }
        return AutoRefreshChoice(amount: s, unit: .seconds)
    }

    public static func choice(fromSliderStep seconds: Double) -> AutoRefreshChoice {
        choice(fromStored: seconds)
    }

    /// 手动输入：保留整数本身；分钟超过 60 则改单位为秒，不改成 1.5 分钟。禁止小数。
    public static func applyingTypedAmount(_ raw: String, currentUnit: AutoRefreshUnit) -> AutoRefreshChoice {
        fitting(amount: integerAmount(from: raw), preferredUnit: currentUnit)
    }

    public static func applyingUnitSwitch(amount: Int, to unit: AutoRefreshUnit) -> AutoRefreshChoice {
        fitting(amount: amount, preferredUnit: unit)
    }

    public static func fitting(amount: Int, preferredUnit: AutoRefreshUnit) -> AutoRefreshChoice {
        let n = max(amount, 0)
        if n > maxSeconds {
            return preferredUnit == .minutes
                ? AutoRefreshChoice(amount: maxMinutes, unit: .minutes)
                : AutoRefreshChoice(amount: maxSeconds, unit: .seconds)
        }
        switch preferredUnit {
        case .minutes:
            if n <= maxMinutes {
                return AutoRefreshChoice(amount: n, unit: .minutes)
            }
            return AutoRefreshChoice(amount: n, unit: .seconds)
        case .seconds:
            return AutoRefreshChoice(amount: n, unit: .seconds)
        }
    }

    /// 禁止小数：截到第一个小数点之前，再取数字。
    public static func integerAmount(from raw: String) -> Int {
        let cutoff = raw.firstIndex { $0 == "." || $0 == "．" || $0 == "," } ?? raw.endIndex
        let digits = raw[..<cutoff].filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

/// 把秒转换成 `Task.sleep` 的纳秒时先验证乘法与 UInt64 范围。
public enum SafeDuration {
    public static func nanoseconds(seconds: Double) -> UInt64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let product = seconds * 1_000_000_000
        guard product.isFinite, product >= 0 else { return nil }
        return UInt64(exactly: product.rounded(.towardZero))
    }
}

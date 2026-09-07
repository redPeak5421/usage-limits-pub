import CoreFoundation
import Foundation

/// 解析 StepFun 探针返回的严格安全摘要。接口目录见 `providers/stepfun.md`。
public enum StepFunParser {
    private static let maximumSafeEpochSeconds = 253_402_300_799.0
    private static let planNames: Set<String> = [
        "Free", "Mini", "Plus", "Pro", "Max", "Coding Plan", "Token Plan",
    ]

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        guard !results.isEmpty else {
            return snapshot(now: now, status: .error("未获取到任何响应"))
        }
        guard let rateResult = results["rate_limit"] else {
            return snapshot(now: now, status: .error("未获取到 StepFun 用量响应"))
        }
        guard rateResult.isOK else {
            return snapshot(now: now, status: failureStatus(rateResult))
        }
        guard let root = JSONHelp.object(rateResult.body),
              rootHasAllowedStructure(root),
              let apiSuccess = strictBool(root["apiSuccess"])
        else {
            return snapshot(now: now, status: .error("StepFun 用量数据异常"))
        }

        if !apiSuccess {
            guard Set(root.keys).isSubset(of: ["apiSuccess", "authError"]),
                  let authError = strictBool(root["authError"])
            else {
                return snapshot(now: now, status: .error("StepFun 用量数据异常"))
            }
            return snapshot(
                now: now,
                status: authError ? .needsLogin : .error("StepFun API 返回失败")
            )
        }
        guard root["authError"] == nil else {
            return snapshot(now: now, status: .error("StepFun 用量数据异常"))
        }

        let fiveHourReset = strictFiniteNumber(root["fiveHourResetTime"])
        let weeklyReset = strictFiniteNumber(root["weeklyResetTime"])
        let hasLiveWindow = (fiveHourReset ?? 0) > 0 || (weeklyReset ?? 0) > 0

        let metric: [UsageMetric]
        if hasLiveWindow {
            guard let windows = rateWindowMetrics(root) else {
                return snapshot(now: now, status: .error("StepFun 用量数据异常"))
            }
            metric = windows
        } else {
            let credit = root["credit"] as? [String: Any]
            let buckets = credit?["buckets"] as? [Any]
            let hasCreditPool = credit?["subscriptionLeftRate"] != nil
                || credit?["topupLeftRate"] != nil
                || !(buckets?.isEmpty ?? true)
            let familyIsCredit = strictFiniteNumber(root["planFamily"]) == 2
            guard hasCreditPool || familyIsCredit,
                  let credits = creditMetric(credit)
            else {
                return snapshot(now: now, status: .error("StepFun 用量数据异常"))
            }
            metric = [credits]
        }

        return ProviderSnapshot(
            provider: .stepfun,
            planName: planName(results["plan_status"]),
            metrics: metric,
            fetchedAt: now,
            status: .ok
        )
    }

    private static func snapshot(now: Date, status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .stepfun, fetchedAt: now, status: status)
    }

    /// 失败 body 已在 JS 侧脱敏；Swift 仍不用它拼错误文案，避免未来脚本漂移后回显原文。
    private static func failureStatus(_ result: ProbeResult) -> SnapshotStatus {
        if result.status == 401 || result.status == 403 { return .needsLogin }
        if result.status > 0 { return .error("HTTP \(result.status)") }
        if result.status == -3 { return .error("请求超时") }
        return .error("网络错误")
    }

    private static func rootHasAllowedStructure(_ root: [String: Any]) -> Bool {
        let allowedRoot: Set<String> = [
            "apiSuccess", "authError", "fiveHourLeftRate", "fiveHourResetTime",
            "weeklyLeftRate", "weeklyResetTime", "planFamily", "credit",
        ]
        guard Set(root.keys).isSubset(of: allowedRoot) else { return false }

        for key in [
            "fiveHourLeftRate", "fiveHourResetTime", "weeklyLeftRate",
            "weeklyResetTime", "planFamily",
        ] where root[key] != nil {
            guard strictFiniteNumber(root[key]) != nil else { return false }
        }

        guard let rawCredit = root["credit"] else { return true }
        guard let credit = rawCredit as? [String: Any] else { return false }
        let allowedCredit: Set<String> = [
            "subscriptionLeftRate", "subscriptionResetTime", "topupLeftRate", "buckets",
        ]
        guard Set(credit.keys).isSubset(of: allowedCredit) else { return false }
        for key in ["subscriptionLeftRate", "subscriptionResetTime", "topupLeftRate"]
            where credit[key] != nil
        {
            guard strictFiniteNumber(credit[key]) != nil else { return false }
        }

        guard let rawBuckets = credit["buckets"] else { return true }
        guard let buckets = rawBuckets as? [Any] else { return false }
        for rawBucket in buckets {
            guard let bucket = rawBucket as? [String: Any],
                  Set(bucket.keys).isSubset(of: ["total", "residual"])
            else { return false }
            for key in ["total", "residual"] where bucket[key] != nil {
                guard strictFiniteNumber(bucket[key]) != nil else { return false }
            }
        }
        return true
    }

    private static func rateWindowMetrics(_ root: [String: Any]) -> [UsageMetric]? {
        guard let fiveHourLeft = leftRate(root["fiveHourLeftRate"]),
              let weeklyLeft = leftRate(root["weeklyLeftRate"]),
              let fiveHourReset = safeDate(root["fiveHourResetTime"], requiresPositive: true),
              let weeklyReset = safeDate(root["weeklyResetTime"], requiresPositive: true)
        else { return nil }

        return [
            UsageMetric(
                id: "five_hour",
                label: "5 小时窗口",
                usedPercent: usedPercent(leftRate: fiveHourLeft),
                resetsAt: fiveHourReset,
                pinned: true
            ),
            UsageMetric(
                id: "weekly",
                label: "每周窗口",
                usedPercent: usedPercent(leftRate: weeklyLeft),
                resetsAt: weeklyReset,
                pinned: true
            ),
        ]
    }

    private static func creditMetric(_ credit: [String: Any]?) -> UsageMetric? {
        guard let credit else { return nil }

        let balance = combinedBucketBalance(credit["buckets"])
        let fallbackLeft = leftRate(credit["subscriptionLeftRate"])
            ?? leftRate(credit["topupLeftRate"])
        guard let left = balance?.leftRate ?? fallbackLeft else { return nil }

        let reset = safeDate(credit["subscriptionResetTime"], requiresPositive: true)
        return UsageMetric(
            id: "credits",
            label: "Credits",
            usedPercent: usedPercent(leftRate: left),
            remaining: balance?.remaining,
            total: balance?.total,
            resetsAt: reset,
            detail: reset == nil ? nil : "按月重置",
            pinned: true
        )
    }

    private static func combinedBucketBalance(
        _ raw: Any?
    ) -> (leftRate: Double, remaining: Double, total: Double)? {
        guard let buckets = raw as? [Any], !buckets.isEmpty else { return nil }
        var total = 0.0
        var remaining = 0.0
        for rawBucket in buckets {
            guard let bucket = rawBucket as? [String: Any],
                  let bucketTotal = strictFiniteNumber(bucket["total"]), bucketTotal > 0,
                  let bucketRemaining = strictFiniteNumber(bucket["residual"]),
                  bucketRemaining >= 0, bucketRemaining <= bucketTotal
            else { return nil }
            total += bucketTotal
            remaining += bucketRemaining
            guard total.isFinite, remaining.isFinite else { return nil }
        }
        guard total > 0 else { return nil }
        let left = remaining / total
        guard left.isFinite, (0...1).contains(left) else { return nil }
        return (left, remaining, total)
    }

    private static func planName(_ result: ProbeResult?) -> String? {
        guard let result, result.isOK,
              let root = JSONHelp.object(result.body),
              Set(root.keys).isSubset(of: ["apiSuccess", "authError", "plan"]),
              strictBool(root["apiSuccess"]) == true
        else { return nil }
        guard root["authError"] == nil else { return nil }
        guard let plan = root["plan"] as? String,
              plan == plan.trimmingCharacters(in: .whitespacesAndNewlines),
              planNames.contains(plan)
        else { return nil }
        return "StepFun \(plan)"
    }

    private static func leftRate(_ raw: Any?) -> Double? {
        guard let value = strictFiniteNumber(raw), (0...1).contains(value) else { return nil }
        return value
    }

    private static func usedPercent(leftRate: Double) -> Double {
        min(100, max(0, (1 - leftRate) * 100))
    }

    private static func safeDate(_ raw: Any?, requiresPositive: Bool) -> Date? {
        guard let seconds = strictFiniteNumber(raw),
              requiresPositive ? seconds > 0 : seconds >= 0,
              seconds <= maximumSafeEpochSeconds
        else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }

    private static func strictFiniteNumber(_ raw: Any?) -> Double? {
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
}

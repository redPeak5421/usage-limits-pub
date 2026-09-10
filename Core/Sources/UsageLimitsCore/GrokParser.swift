import Foundation

/// 解析 grok.com 探针结果（rate_limits 聚合 / subscriptions）。
public enum GrokParser {
    public static let browserVerificationError = "Grok 需要浏览器验证"

    /// REST 的 WKE 挑战不是普通会话过期。只认明确错误标记，不按任意 403 猜测。
    public static func requiresBrowserVerification(_ results: [String: ProbeResult]) -> Bool {
        func challenged(_ probe: ProbeResult) -> Bool {
            probe.status == 403 && probe.body.contains("WKE=unauthorized:second-factor-needed")
        }
        guard let rate = results["rate_limits"] else {
            return results["subscriptions"].map(challenged) ?? false
        }
        if challenged(rate) { return true }
        guard rate.isOK, let root = JSONHelp.object(rate.body),
              let rows = root["results"] as? [[String: Any]], !rows.isEmpty else { return false }
        return rows.allSatisfy { row in
            guard JSONHelp.intExactly(row["status"]) == 403 else { return false }
            if let body = row["body"] as? String {
                return challenged(ProbeResult(status: 403, body: body))
            }
            let body = row["body"] as? [String: Any]
            return (body?["message"] as? String)?.contains("WKE=unauthorized:second-factor-needed") == true
        }
    }

    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        var plan: String?
        var metrics: [UsageMetric] = []
        var loggedIn = false
        var parsedRateLimit = false

        if let rate = results["rate_limits"], rate.isOK,
           let dict = JSONHelp.object(rate.body),
           let list = dict["results"] as? [Any] {
            for item in list.compactMap({ $0 as? [String: Any] }) {
                guard let status = JSONHelp.intExactly(item["status"]), (200..<300).contains(status),
                      let body = item["body"] as? [String: Any],
                      let remaining = JSONHelp.double(body["remainingQueries"]), remaining >= 0 else { continue }
                let model = JSONHelp.string(item["modelName"]) ?? "grok"
                let kind = JSONHelp.string(item["requestKind"]) ?? "DEFAULT"
                let total = JSONHelp.double(body["totalQueries"])
                let window = JSONHelp.double(body["windowSizeSeconds"])
                guard total.map({ $0 >= 0 }) ?? true,
                      window.map({ $0 >= 0 }) ?? true else { continue }
                let resets = window.flatMap { JSONHelp.date(byAdding: $0, to: now) }
                var used: Double?
                if let total, total > 0 {
                    // 保留一位小数，避免浮点尾差（9.999... → 10.0），UI 展示也更干净
                    let raw = (1 - remaining / total) * 100
                    used = max(0, min(100, (raw * 10).rounded() / 10))
                }
                metrics.append(UsageMetric(
                    id: metricID(model: model, kind: kind),
                    label: metricLabel(model: model, kind: kind),
                    usedPercent: used,
                    remaining: remaining,
                    total: total,
                    resetsAt: resets,
                    detail: window.flatMap(formatWindow).map { "\($0)短期限流" }
                ))
                loggedIn = true
                parsedRateLimit = true
            }
        }

        if let subs = results["subscriptions"], subs.isOK {
            plan = planLabel(from: subs.body)
            if plan != nil { loggedIn = true }
        }
        if plan != nil, let inferred = inferPlan(from: metrics) {
            plan = mergePlan(subscription: plan, inferred: inferred)
        }
        if let creditsPlan = planFromCredits(results) {
            plan = creditsPlan
            loggedIn = true
        }

        // 官网 Settings → Usage 只展示共享周额度；付费套餐不再列出 /rest/rate-limits 的 2 小时次数。
        if let weekly = weeklyCredits(from: results, now: now) {
            loggedIn = true
            metrics = weeklyMetrics(weekly)
        } else if plan != nil {
            metrics = []
        }

        // 顶层 401，或全部 mode 都 401 且没有解析出任何档位：credits/weekly leftover 不得把卡片刷成已登录。
        // 部分 mode 200 + 部分 401 仍保留成功子结果。
        let rateLimitsUnauthorized = results["rate_limits"]?.isUnauthorized == true
            || (!parsedRateLimit && aggregateFailure(results["rate_limits"])?.isUnauthorized == true)
        let browserVerificationRequired = !parsedRateLimit && requiresBrowserVerification(results)
        if rateLimitsUnauthorized || browserVerificationRequired {
            metrics = []
            plan = nil
            loggedIn = false
        }

        let status: SnapshotStatus
        if browserVerificationRequired {
            status = .error(browserVerificationError)
        } else if rateLimitsUnauthorized {
            status = .needsLogin
        } else if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let nested = aggregateFailure(results["rate_limits"]) {
            status = nested.failureStatus
        } else if let key = results["rate_limits"] ?? results["subscriptions"], !key.isOK {
            // 401/403 → 重新登录；5xx / 超时 / 网络层不该催用户登录（weekly 的 gRPC 状态不参与判定）
            status = key.failureStatus
        } else {
            status = .needsLogin
        }

        // grok.com 对未登录访客也提供少量游客额度（rate-limits 照常返回），
        // 订阅信息为空时标注为游客数据，卡片上保留登录入口。
        var isAnonymous: Bool?
        var planName = plan
        if loggedIn, plan == nil {
            isAnonymous = true
            planName = "游客额度"
        }

        let cycle: BillingCycle? = (isAnonymous != true && PlanCatalog.hasListPrice(planName)) ? .monthly : nil
        var snapshot = ProviderSnapshot(
            provider: .grok,
            planName: planName,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            isAnonymous: isAnonymous,
            billingCycle: cycle
        )
        // 重置券只发给订阅账号；游客态和未登录都不查，免得把 leftover 次数说成现在还有。
        if loggedIn, isAnonymous != true {
            snapshot.grokUsageResets = GrokUsageResets.parse(results: results, now: now)
        }
        return snapshot
    }

    /// `rate_limits` 顶层是固定 200 的运输壳；只有逐 mode status 才是真实结果。
    /// 没有任何 mode 解析成功时，把内层 401/5xx/-3 还原成正常的状态分流。
    private static func aggregateFailure(_ probe: ProbeResult?) -> ProbeResult? {
        guard let probe, probe.isOK,
              let root = JSONHelp.object(probe.body),
              let rows = root["results"] as? [[String: Any]] else { return nil }
        let failures = rows.compactMap { row -> ProbeResult? in
            guard let status = JSONHelp.intExactly(row["status"]), !(200..<300).contains(status) else { return nil }
            let body: String
            if let string = row["body"] as? String {
                body = string
            } else if status > 0, let value = row["body"], JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = ""
            }
            return ProbeResult(status: status, body: body)
        }
        return preferredFailure(failures)
    }

    private static func preferredFailure(_ failures: [ProbeResult]) -> ProbeResult? {
        failures.first(where: \.isUnauthorized)
            ?? failures.first(where: { $0.status > 0 })
            ?? failures.first(where: { $0.status == -3 })
            ?? failures.first
    }

    private static func formatWindow(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if seconds >= 86400 {
            return JSONHelp.intTruncating(seconds / 86400).map { "\($0) 天" }
        }
        if seconds >= 3600 {
            return JSONHelp.intTruncating(seconds / 3600).map { "\($0) 小时" }
        }
        return JSONHelp.intTruncating(seconds / 60).map { "\($0) 分钟" }
    }

    /// grok.com 现行档位（2026）：Auto / Fast / Expert / Heavy，不再用 grok-4/grok-3 当展示名。
    private static let modeLabels: [String: String] = [
        "auto": "自动",
        "fast": "快速",
        "expert": "专家",
        "heavy": "Heavy",
    ]

    private static func metricID(model: String, kind: String) -> String {
        let key = model.lowercased()
        if modeLabels[key] != nil { return key }
        return "\(model)-\(kind)"
    }

    private static func metricLabel(model: String, kind: String) -> String {
        if let label = modeLabels[model.lowercased()] { return label }
        let kindLabel = kind.uppercased() == "REASONING" ? "推理" : "标准"
        return "\(model) \(kindLabel)"
    }

    private static func planLabel(from body: String) -> String? {
        guard let dict = JSONHelp.object(body) else { return nil }
        let tiers = JSONHelp.dictsContainingKey("tier", in: dict).compactMap { JSONHelp.string($0.dict["tier"]) }
        guard let raw = (tiers.first ?? JSONHelp.string(dict["tier"]))?.uppercased() else { return nil }
        if raw.contains("PREMIUM_PLUS") { return "X Premium+" }
        if raw.contains("SUPER_GROK_PRO") || raw.contains("HEAVY") { return "SuperGrok Heavy" }
        if raw.contains("SUPER_GROK_PLUS") || (raw.contains("PLUS") && raw.contains("SUPER")) { return "SuperGrok Plus" }
        if raw.contains("LITE") { return "SuperGrok Lite" }
        if raw.contains("SUPER_GROK") || raw.contains("GROK_PRO") { return "SuperGrok" }
        if raw.contains("PREMIUM") { return "X Premium+" }
        return raw.capitalized
    }

    /// 用 /rest/rate-limits 的总额度形态校准套餐（比内部枚举更接近官网档位）。
    private static func inferPlan(from metrics: [UsageMetric]) -> String? {
        let totals = Dictionary(uniqueKeysWithValues: metrics.compactMap { metric -> (String, Double)? in
            guard let total = metric.total else { return nil }
            return (metric.id, total)
        })
        if totals["heavy"] != nil || totals["auto"] == 150 || totals["fast"] == 400 {
            return "SuperGrok Heavy"
        }
        if totals["auto"] == 50 || totals["fast"] == 140 {
            return "SuperGrok"
        }
        return nil
    }

    private static func mergePlan(subscription: String?, inferred: String) -> String {
        if inferred == "SuperGrok Heavy" || subscription?.contains("Heavy") == true {
            return "SuperGrok Heavy"
        }
        return subscription ?? inferred
    }

    private static func planFromCredits(_ results: [String: ProbeResult]) -> String? {
        for key in ["credits", "weekly"] {
            guard let result = results[key], result.isOK,
                  let dict = JSONHelp.object(result.body) else { continue }
            if let raw = JSONHelp.string(dict["subscription_tier"])
                ?? JSONHelp.string(dict["subscriptionTier"]) {
                return displayPlan(raw)
            }
        }
        return nil
    }

    private static func displayPlan(_ raw: String) -> String {
        let upper = raw.uppercased()
        if upper.contains("HEAVY") { return "SuperGrok Heavy" }
        if upper.contains("SUPER") && upper.contains("PLUS") { return "SuperGrok Plus" }
        if upper.contains("LITE") { return "SuperGrok Lite" }
        if raw.localizedCaseInsensitiveContains("SuperGrok") { return raw }
        return planLabel(from: #"{"tier":"\#(raw)"}"#) ?? raw
    }

    /// weekly（gRPC-Web）探针的结果码。状态非 0 时不解析 payload，也**不**据此判未登录：
    /// 16/`no-credentials` 是端点要浏览器密钥（WKE），Cookie 登录本来就不够，
    /// 主用量走 `/rest/grok/credits`。返回值只用于诊断与测试。
    public static func weeklyGRPCStatus(results: [String: ProbeResult]) -> GrokGRPCStatus? {
        guard let weekly = results["weekly"], !weekly.body.isEmpty else { return nil }
        return GrokWeeklyParser.grpcStatus(headers: weekly.headers, base64Body: weekly.body)
    }

    private static func weeklyCredits(from results: [String: ProbeResult], now: Date) -> GrokWeeklyCredits? {
        for key in ["credits", "weekly"] {
            guard let weekly = results[key], weekly.isOK, !weekly.body.isEmpty else { continue }
            if key == "weekly", let grpc = weeklyGRPCStatus(results: results), grpc.blocksParsing {
                continue
            }
            if let parsed = GrokWeeklyParser.parse(json: weekly.body) { return parsed }
            if let data = GrokWeeklyParser.decodeBase64(weekly.body),
               let parsed = GrokWeeklyParser.parse(data: data, now: now) {
                return parsed
            }
        }
        return nil
    }

    private static func weeklyMetrics(_ weekly: GrokWeeklyCredits) -> [UsageMetric] {
        // 周限额是这张卡唯一的主指标，pinned 常显：0%（本周还没用）也要画出来，
        // JSON 路径真的缺百分比时 usedPercent 为 nil，行还在、只是不画百分比。
        var metrics = [
            UsageMetric(
                id: "weekly",
                label: weekly.period.metricLabel,
                usedPercent: weekly.usagePercent,
                resetsAt: weekly.resetsAt,
                detail: "已使用",
                pinned: true
            )
        ]
        for product in weekly.products where product.usagePercent > 0 {
            metrics.append(UsageMetric(
                id: "weekly.\(product.code)",
                label: product.label,
                usedPercent: product.usagePercent
            ))
        }
        return metrics
    }
}

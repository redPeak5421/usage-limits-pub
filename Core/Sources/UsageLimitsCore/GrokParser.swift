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

        // 订阅记录里会残留 INACTIVE / 已过账期的历史条目（2026-09-14 真机：过期账号仍列出两条），
        // 只有现行记录才能命名套餐；有记录但都失效 = 已登录的免费账号，不是游客。
        var hasSubscriptionRecords = false
        var subscriptionExpired = false
        if let subs = results["subscriptions"], subs.isOK {
            let records = subscriptionRecords(from: subs.body)
            hasSubscriptionRecords = !records.isEmpty
            let current = records.first(where: { isCurrentSubscription($0, now: now) })
            subscriptionExpired = hasSubscriptionRecords && current == nil
            plan = current.flatMap { planLabel(tier: JSONHelp.string($0["tier"])) }
            if hasSubscriptionRecords { loggedIn = true }
        }
        if plan != nil, let inferred = inferPlan(from: metrics) {
            plan = mergePlan(subscription: plan, inferred: inferred)
        }
        // 订阅接口有记录但全部失效 = 明确过期；credits / weekly 里残留的 subscription_tier 不能把套餐捞回来。
        if !subscriptionExpired, let creditsPlan = planFromCredits(results) {
            plan = creditsPlan
            loggedIn = true
        }

        // 官网 Settings → Usage 只展示共享周额度；付费套餐不再列出 /rest/rate-limits 的 2 小时次数。
        // 没有现行套餐时，周额度报文只剩周期（本地补出来的 0%）不能挤掉免费档 / 游客的短期次数；
        // 线上真给了百分比或非零产品占比才展示（渲染层也只画 > 0 的产品行）。
        if let weekly = weeklyCredits(from: results, now: now),
           plan != nil || !parsedRateLimit || weekly.percentIsWirePublished
            || weekly.products.contains(where: { $0.usagePercent > 0 }) {
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
        if loggedIn, plan == nil, !hasSubscriptionRecords {
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
        // 重置券只发给订阅账号；游客态、订阅已失效和未登录都不查，免得把 leftover 次数说成现在还有。
        if loggedIn, plan != nil {
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

    /// 响应里所有带 `tier` 的订阅记录（任意层级；数组内按出现顺序）。
    private static func subscriptionRecords(from body: String) -> [[String: Any]] {
        guard let dict = JSONHelp.object(body) else { return [] }
        return JSONHelp.dictsContainingKey("tier", in: dict).map(\.dict)
    }

    /// 现行订阅：`billingPeriodEnd` 未过，且 `status` 不含 INACTIVE / EXPIRED；
    /// CANCELED / CANCELLED 只在账期已过或没给账期时算失效（取消续费、期内仍可用）。
    /// 两个字段都没有的记录照旧采信（老 fixture / 形状漂移）。
    private static func isCurrentSubscription(_ record: [String: Any], now: Date) -> Bool {
        let end = JSONHelp.date(record["billingPeriodEnd"])
        if let end, end <= now { return false }
        guard let status = JSONHelp.string(record["status"])?.uppercased() else { return true }
        if status.contains("INACTIVE") || status.contains("EXPIRED") { return false }
        if status.contains("CANCELED") || status.contains("CANCELLED") {
            // 上面已排除过期账期：有账期即仍在期内；没给账期的取消记录按失效处理。
            if let end { return end > now }
            return false
        }
        return true
    }

    private static func planLabel(tier: String?) -> String? {
        guard let raw = tier?.uppercased() else { return nil }
        if raw.contains("PREMIUM_PLUS") { return "X Premium+" }
        if raw.contains("SUPER_GROK_PRO") || raw.contains("HEAVY") { return "SuperGrok Heavy" }
        if raw.contains("SUPER_GROK_PLUS") || (raw.contains("PLUS") && raw.contains("SUPER")) { return "SuperGrok Plus" }
        if raw.contains("LITE") { return "SuperGrok Lite" }
        if raw.contains("SUPER_GROK") || raw.contains("GROK_PRO") { return "SuperGrok" }
        if raw.contains("PREMIUM") { return "X Premium+" }
        return raw.capitalized
    }

    /// 用 /rest/rate-limits 的总额度形态校准套餐（比内部枚举更接近官网档位）。
    /// `heavy` 档如今游客和免费账号也有（20 次 / 2 小时），不再当 Heavy 的证据。
    private static func inferPlan(from metrics: [UsageMetric]) -> String? {
        let totals = Dictionary(uniqueKeysWithValues: metrics.compactMap { metric -> (String, Double)? in
            guard let total = metric.total else { return nil }
            return (metric.id, total)
        })
        if totals["auto"] == 150 || totals["fast"] == 400 {
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
        return planLabel(tier: raw) ?? raw
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

import Foundation

/// 解析 platform.deepseek.com 官网用量（预充值，无订阅套餐）。
/// 探针只 fetch，本文件只吃文本。形状漂移时跳过缺失键，不崩溃。
public enum DeepSeekParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        var loggedIn = false
        var currency = "CNY"
        var metrics: [UsageMetric] = []
        var timeBreakdowns: [UsageBreakdown] = []
        var keyBreakdowns: [UsageBreakdown] = []
        var modelBreakdowns: [UsageBreakdown] = []
        // 业务错误码（信封 code / biz_code 非 0）。40002 / 40003 是会话过期，其余进诊断文案。
        var bizError: (code: Int, msg: String)?

        if let current = results["current"] {
            if let root = JSONHelp.object(current.body) {
                if bizError == nil { bizError = businessError(root) }
                if current.isOK, let biz = bizData(root) {
                    if JSONHelp.string(biz["id"]) != nil || JSONHelp.string(biz["currency"]) != nil {
                        loggedIn = true
                    }
                    if let c = JSONHelp.string(biz["currency"]), !c.isEmpty { currency = c }
                }
            }
        }

        if let summary = results["summary"] {
            if let root = JSONHelp.object(summary.body) {
                if bizError == nil { bizError = businessError(root) }
                if summary.isOK, let biz = bizData(root) {
                    loggedIn = true
                    // 钱包按币种分组后再求和：同时持有 USD / CNY 钱包时不得横加成一个数。
                    let paid = groupByCurrency(biz["normal_wallets"], key: "balance", fallback: currency)
                    let granted = groupByCurrency(biz["bonus_wallets"], key: "balance", fallback: currency)
                    let costs = groupByCurrency(biz["total_costs"], key: "amount", fallback: currency)
                    let picked = chooseCurrency(paid: paid, granted: granted)
                        ?? costs.order.first
                    if let picked { currency = picked }
                    let paidAmount = paid[currency] ?? 0
                    let grantedAmount = granted[currency] ?? 0
                    let spent = costs[currency]
                        ?? (costs.order.count == 1 ? costs.totals[costs.order[0]] : nil)
                        ?? 0
                    metrics.append(UsageMetric(
                        id: "balance", label: "重置余额",
                        amount: paidAmount + grantedAmount, currency: currency
                    ))
                    metrics.append(UsageMetric(
                        id: "total_spent", label: "累计消费金额",
                        amount: spent, currency: currency
                    ))
                    if paidAmount > 0 {
                        metrics.append(UsageMetric(
                            id: "balance_paid", label: "充值余额",
                            amount: paidAmount, currency: currency
                        ))
                    }
                    if grantedAmount > 0 {
                        metrics.append(UsageMetric(
                            id: "balance_granted", label: "赠送余额",
                            amount: grantedAmount, currency: currency
                        ))
                    }
                }
            }
        }

        let periods = results["usage_periods"].flatMap { $0.isOK ? JSONHelp.object($0.body) : nil }
        let periodOrder = ["today", "yesterday", "last_7d", "last_30d", "this_month", "last_month"]
        let periodLabels = [
            "today": "今天", "yesterday": "昨天", "last_7d": "近 7 天",
            "last_30d": "近 30 天", "this_month": "本月", "last_month": "上月",
        ]
        if let periods {
            for id in periodOrder {
                guard let block = periods[id] as? [String: Any] else { continue }
                let costBody = probeBody(block["cost"])
                let amountBody = probeBody(block["amount"])
                let costAgg = aggregateCost(costBody)
                let amountAgg = aggregateAmount(amountBody)
                let hasData = costAgg.total != nil || amountAgg.requests != nil || amountAgg.tokens != nil
                    || !costAgg.series.isEmpty || !amountAgg.series.isEmpty
                guard hasData else { continue }
                timeBreakdowns.append(UsageBreakdown(
                    id: id,
                    label: periodLabels[id] ?? id,
                    cost: costAgg.total,
                    requests: amountAgg.requests,
                    tokens: amountAgg.tokens,
                    series: costAgg.series.isEmpty ? amountAgg.series : costAgg.series,
                    cacheHitTokens: amountAgg.cacheHit,
                    cacheMissTokens: amountAgg.cacheMiss,
                    outputTokens: amountAgg.output
                ))
                if keyBreakdowns.isEmpty {
                    keyBreakdowns = mergeKeyBreakdowns(cost: costAgg.byKey, amount: amountAgg.byKey)
                }
                if modelBreakdowns.isEmpty {
                    modelBreakdowns = mergeModelBreakdowns(cost: costAgg.byModel, amount: amountAgg.byModel)
                }
            }
        } else {
            let costAgg = aggregateCost(results["usage_cost"]?.isOK == true ? results["usage_cost"]?.body : nil)
            let amountAgg = aggregateAmount(results["usage_amount"]?.isOK == true ? results["usage_amount"]?.body : nil)
            if costAgg.total != nil || amountAgg.requests != nil || amountAgg.tokens != nil {
                timeBreakdowns.append(UsageBreakdown(
                    id: "this_month", label: "本月",
                    cost: costAgg.total, requests: amountAgg.requests,
                    tokens: amountAgg.tokens,
                    series: costAgg.series.isEmpty ? amountAgg.series : costAgg.series,
                    cacheHitTokens: amountAgg.cacheHit,
                    cacheMissTokens: amountAgg.cacheMiss,
                    outputTokens: amountAgg.output
                ))
                keyBreakdowns = mergeKeyBreakdowns(cost: costAgg.byKey, amount: amountAgg.byKey)
                modelBreakdowns = mergeModelBreakdowns(cost: costAgg.byModel, amount: amountAgg.byModel)
            }
        }

        if let keys = results["api_keys"], keys.isOK,
           let root = JSONHelp.object(keys.body),
           let biz = bizData(root),
           let list = biz["api_keys"] as? [[String: Any]] {
            var byID = Dictionary(uniqueKeysWithValues: keyBreakdowns.map { ($0.id, $0) })
            for item in list {
                let tid = JSONHelp.string(item["tracking_id"]) ?? ""
                let name = JSONHelp.string(item["name"]) ?? tid
                guard !tid.isEmpty || !name.isEmpty else { continue }
                let id = tid.isEmpty ? name : tid
                let lastUsed = unixDate(item["last_use"]) ?? unixDate(item["last_used"])
                if var existing = byID[id] {
                    if !name.isEmpty { existing.label = name }
                    existing.lastUsed = lastUsed ?? existing.lastUsed
                    byID[id] = existing
                }
            }
            keyBreakdowns = sortKeysByLastUsed(Array(byID.values))
        }

        let status: SnapshotStatus
        if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let bizError {
            // 40002 Missing Token / 40003 会话过期：官网仍 200，但需要重新登录。
            if bizError.code == 40002 || bizError.code == 40003 {
                status = .needsLogin
            } else {
                let suffix = bizError.msg.isEmpty ? "" : ": \(bizError.msg)"
                status = .error("DeepSeek code \(bizError.code)\(suffix)")
            }
        } else if let probe = results["current"] ?? results["summary"], !probe.isOK {
            // 401 / 403 → needsLogin；其它非 2xx / 网络层 → error，不误报"请重新登录"。
            status = probe.failureStatus
        } else if let probe = periodsFailure(results["usage_periods"]) {
            // usage_periods 顶层固定 200；全体子请求失败时仍要还原 timeout / HTTP 错误。
            status = probe.failureStatus
        } else {
            status = .needsLogin
        }

        return ProviderSnapshot(
            provider: .deepseek,
            planName: nil,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            currency: loggedIn ? currency : nil,
            timeBreakdowns: timeBreakdowns.isEmpty ? nil : timeBreakdowns,
            keyBreakdowns: keyBreakdowns.isEmpty ? nil : keyBreakdowns,
            modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns
        )
    }

    /// 信封业务码：`code`（或 `data.biz_code`）非 0 即错误，取出码与 msg 供诊断。
    private static func businessError(_ root: [String: Any]) -> (code: Int, msg: String)? {
        if let code = JSONHelp.intExactly(root["code"]), code != 0 {
            let msg = JSONHelp.string(root["msg"]) ?? JSONHelp.string(root["message"]) ?? ""
            return (code, msg)
        }
        if let data = root["data"] as? [String: Any],
           let biz = JSONHelp.intExactly(data["biz_code"]), biz != 0 {
            let msg = JSONHelp.string(data["biz_msg"]) ?? JSONHelp.string(root["msg"]) ?? ""
            return (biz, msg)
        }
        return nil
    }

    /// 币种 → 金额合计，并记住首次出现顺序（选币时"第一行"要稳定）。
    struct CurrencySums {
        var totals: [String: Double] = [:]
        var order: [String] = []

        mutating func add(_ currency: String, _ value: Double) {
            let key = currency.uppercased()
            if totals[key] == nil { order.append(key) }
            totals[key, default: 0] += value
        }

        subscript(_ currency: String) -> Double? { totals[currency.uppercased()] }
    }

    private static func groupByCurrency(_ any: Any?, key: String, fallback: String) -> CurrencySums {
        var sums = CurrencySums()
        for row in (any as? [[String: Any]]) ?? [] {
            let raw = JSONHelp.string(row["currency"]) ?? ""
            sums.add(raw.isEmpty ? fallback : raw, JSONHelp.double(row[key]) ?? 0)
        }
        return sums
    }

    /// 选币：有钱的 USD > 任意有钱的币种 > 空的 USD > 第一行。绝不把 USD 与 CNY 相加。
    static func chooseCurrency(paid: CurrencySums, granted: CurrencySums) -> String? {
        var combined = CurrencySums()
        for c in paid.order { combined.add(c, paid.totals[c] ?? 0) }
        for c in granted.order { combined.add(c, granted.totals[c] ?? 0) }
        if (combined.totals["USD"] ?? 0) > 0 { return "USD" }
        if let c = combined.order.first(where: { (combined.totals[$0] ?? 0) > 0 }) { return c }
        if combined.totals["USD"] != nil { return "USD" }
        return combined.order.first
    }

    private static func bizData(_ root: [String: Any]) -> [String: Any]? {
        let data = root["data"] as? [String: Any]
        return (data?["biz_data"] as? [String: Any]) ?? data
    }

    private static func probeBody(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let dict = any as? [String: Any] {
            if let status = JSONHelp.intExactly(dict["status"]), !(200..<300).contains(status) {
                return nil
            }
            if let body = dict["body"] as? String { return body }
            if JSONSerialization.isValidJSONObject(dict),
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func periodsFailure(_ probe: ProbeResult?) -> ProbeResult? {
        guard let probe, probe.isOK, let periods = JSONHelp.object(probe.body) else { return nil }
        var failures: [ProbeResult] = []
        var sawSuccess = false
        for value in periods.values {
            guard let block = value as? [String: Any] else { continue }
            for key in ["cost", "amount"] {
                guard let child = block[key] as? [String: Any],
                      let status = JSONHelp.intExactly(child["status"]) else { continue }
                if (200..<300).contains(status) {
                    sawSuccess = true
                } else {
                    failures.append(ProbeResult(
                        status: status,
                        body: JSONHelp.string(child["body"]) ?? ""
                    ))
                }
            }
        }
        // 任一真实 2xx 存在时保留部分结果；只有全失败才让壳贡献错误状态。
        guard !sawSuccess else { return nil }
        return failures.first(where: \.isUnauthorized)
            ?? failures.first(where: { $0.status > 0 })
            ?? failures.first(where: { $0.status == -3 })
            ?? failures.first
    }

    private struct CostAgg {
        var total: Double?
        var series: [UsagePoint] = []
        var byKey: [String: (label: String, cost: Double)] = [:]
        var byModel: [String: Double] = [:]
    }

    private struct AmountAgg {
        var requests: Double?
        var tokens: Double?
        /// `PROMPT_CACHE_HIT_TOKEN` / `PROMPT_CACHE_MISS_TOKEN` / `RESPONSE_TOKEN` 分类合计。
        var cacheHit: Double?
        var cacheMiss: Double?
        var output: Double?
        var series: [UsagePoint] = []
        var byKey: [String: (label: String, requests: Double, tokens: Double)] = [:]
        var byModel: [String: (requests: Double, tokens: Double)] = [:]
    }

    private static func aggregateCost(_ body: String?) -> CostAgg {
        var agg = CostAgg()
        guard let body, let root = JSONHelp.object(body), let biz = bizData(root) else { return agg }
        let blocks = (biz["data"] as? [[String: Any]]) ?? []
        var byTime: [Date: Double] = [:]
        var total: Double = 0
        var saw = false
        for block in blocks {
            for series in (block["series"] as? [[String: Any]]) ?? [] {
                let key = series["api_key"] as? [String: Any]
                let kid = JSONHelp.string(key?["tracking_id"]) ?? JSONHelp.string(key?["name"]) ?? "key"
                let kname = JSONHelp.string(key?["name"]) ?? kid
                let model = JSONHelp.string(series["model"]) ?? ""
                var keyCost = agg.byKey[kid]?.cost ?? 0
                var modelCost: Double = 0
                for bucket in (series["buckets"] as? [[String: Any]]) ?? [] {
                    let cost = JSONHelp.double(bucket["cost"]) ?? 0
                    total += cost
                    saw = true
                    keyCost += cost
                    modelCost += cost
                    if let t = JSONHelp.date(bucket["time"]) ?? unixDate(bucket["time"]) {
                        byTime[t, default: 0] += cost
                    }
                }
                agg.byKey[kid] = (kname, keyCost)
                if !model.isEmpty { agg.byModel[model, default: 0] += modelCost }
            }
        }
        if saw { agg.total = total }
        agg.series = byTime.keys.sorted().map { UsagePoint(at: $0, value: byTime[$0] ?? 0) }
        return agg
    }

    private static func aggregateAmount(_ body: String?) -> AmountAgg {
        var agg = AmountAgg()
        guard let body, let root = JSONHelp.object(body), let biz = bizData(root) else { return agg }
        let seriesList = (biz["series"] as? [[String: Any]]) ?? []
        var req: Double = 0
        var tok: Double = 0
        var cacheHit: Double = 0
        var cacheMiss: Double = 0
        var output: Double = 0
        var saw = false
        var byTime: [Date: Double] = [:]
        for series in seriesList {
            let key = series["api_key"] as? [String: Any]
            let kid = JSONHelp.string(key?["tracking_id"]) ?? JSONHelp.string(key?["name"]) ?? "key"
            let kname = JSONHelp.string(key?["name"]) ?? kid
            let model = JSONHelp.string(series["model"]) ?? ""
            var kr = agg.byKey[kid]?.requests ?? 0
            var kt = agg.byKey[kid]?.tokens ?? 0
            var mr = agg.byModel[model]?.requests ?? 0
            var mt = agg.byModel[model]?.tokens ?? 0
            var acceptedCount = false
            for bucket in (series["buckets"] as? [[String: Any]]) ?? [] {
                let usage = bucket["usage"] as? [String: Any] ?? [:]
                func addToken(_ any: Any?, category: inout Double) {
                    guard let n = semanticCount(any), let next = adding(n, to: category) else { return }
                    category = next
                    if let t = adding(n, to: tok) { tok = t }
                    if let t = adding(n, to: kt) { kt = t }
                    if !model.isEmpty, let t = adding(n, to: mt) { mt = t }
                    acceptedCount = true
                    saw = true
                }
                addToken(usage["PROMPT_CACHE_HIT_TOKEN"], category: &cacheHit)
                addToken(usage["PROMPT_CACHE_MISS_TOKEN"], category: &cacheMiss)
                addToken(usage["RESPONSE_TOKEN"], category: &output)
                if let n = semanticCount(usage["REQUEST"]), let next = adding(n, to: req) {
                    req = next
                    if let v = adding(n, to: kr) { kr = v }
                    if !model.isEmpty, let v = adding(n, to: mr) { mr = v }
                    acceptedCount = true
                    saw = true
                }
                var bucketTokens = 0
                for field in ["RESPONSE_TOKEN", "PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN"] {
                    bucketTokens += semanticCount(usage[field]) ?? 0
                }
                if bucketTokens > 0, let t = JSONHelp.date(bucket["time"]) ?? unixDate(bucket["time"]) {
                    byTime[t, default: 0] += Double(bucketTokens)
                }
            }
            if acceptedCount {
                agg.byKey[kid] = (kname, kr, kt)
                if !model.isEmpty { agg.byModel[model] = (mr, mt) }
            }
        }
        if saw {
            agg.requests = req
            agg.tokens = tok
            if cacheHit > 0 { agg.cacheHit = cacheHit }
            if cacheMiss > 0 { agg.cacheMiss = cacheMiss }
            if output > 0 { agg.output = output }
        }
        agg.series = byTime.keys.sorted().map { UsagePoint(at: $0, value: byTime[$0] ?? 0) }
        return agg
    }

    private static func semanticCount(_ any: Any?) -> Int? {
        guard let n = JSONHelp.intExactly(any), n >= 0 else { return nil }
        return n
    }

    private static func adding(_ value: Int, to current: Double) -> Double? {
        let next = current + Double(value)
        guard next.isFinite else { return nil }
        return next
    }

    private static func adding(_ value: Double, to current: Double) -> Double? {
        guard let value = JSONHelp.intExactly(value), value >= 0 else { return nil }
        return adding(value, to: current)
    }

    private static func mergeKeyBreakdowns(
        cost: [String: (label: String, cost: Double)],
        amount: [String: (label: String, requests: Double, tokens: Double)]
    ) -> [UsageBreakdown] {
        let ids = Set(cost.keys).union(amount.keys)
        return ids.sorted().map { id in
            UsageBreakdown(
                id: id,
                label: cost[id]?.label ?? amount[id]?.label ?? id,
                cost: cost[id]?.cost,
                requests: amount[id]?.requests,
                tokens: amount[id]?.tokens
            )
        }
    }

    /// 按模型合并金额 / 次数 / tokens：消耗金额多的在前，其次 tokens，再次名称。
    private static func mergeModelBreakdowns(
        cost: [String: Double],
        amount: [String: (requests: Double, tokens: Double)]
    ) -> [UsageBreakdown] {
        let ids = Set(cost.keys).union(amount.keys)
        return ids.map { id in
            UsageBreakdown(
                id: id,
                label: id,
                cost: cost[id],
                requests: amount[id]?.requests,
                tokens: amount[id]?.tokens
            )
        }.sorted { a, b in
            let ca = a.cost ?? 0, cb = b.cost ?? 0
            if ca != cb { return ca > cb }
            let ta = a.tokens ?? 0, tb = b.tokens ?? 0
            if ta != tb { return ta > tb }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    /// 最后使用时间新→旧；没有 last_use 的排后面。
    private static func sortKeysByLastUsed(_ keys: [UsageBreakdown]) -> [UsageBreakdown] {
        keys.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (la?, lb?): return la > lb
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
        }
    }

    private static func unixDate(_ any: Any?) -> Date? {
        guard let n = JSONHelp.double(any), n > 1_000_000_000 else { return nil }
        return JSONHelp.date(n)
    }
}

import Foundation

/// 解析 MiniMax TokenPlan（platform.minimaxi.com / platform.minimax.io/console/usage）。
/// 官网定义窗口：5 小时滚动额度 + 每周额度；页面另有视频赠送、积分、近 7/30 天调用、计费历史。
public enum MiniMaxParser {
    public static func parse(
        results: [String: ProbeResult],
        now: Date,
        provider: ProviderID = .minimax
    ) -> ProviderSnapshot {
        var plan: String?
        var planExpiresAt: Date?
        var billingCycle: BillingCycle?
        var metrics: [UsageMetric] = []
        var loggedIn = false
        var keySessionExpired = false
        var sessionExpired = false
        var apiError: String?
        var planFromRemains: String?
        var creditsFromRemains: Double?

        if let remains = results["remains"] {
            if remains.isUnauthorized {
                keySessionExpired = true
            } else if remains.isOK, let root = JSONHelp.object(remains.body) {
                let response = baseResp(root)
                switch response {
                case .needsLogin:
                    keySessionExpired = true
                case .failure(let message):
                    if apiError == nil { apiError = message }
                case .ok:
                    break
                }
                if case .ok = response {
                    let data = (root["data"] as? [String: Any]) ?? root
                    let models = (data["model_remains"] as? [[String: Any]])
                        ?? (root["model_remains"] as? [[String: Any]])
                    if models != nil { loggedIn = true }
                    metrics.append(contentsOf: modelMetrics(models ?? [], now: now))
                    planFromRemains = planTitle(in: data) ?? planTitle(in: root)
                    creditsFromRemains = creditsBalance(in: data) ?? creditsBalance(in: root)
                }
            }
        }

        if let combo = results["combo"], combo.isOK {
            if let root = JSONHelp.object(combo.body) {
                let response = comboBaseResp(root)
                switch response {
                case .needsLogin: sessionExpired = true
                case .failure(let message): if apiError == nil { apiError = message }
                case .ok: break
                }
                if case .ok = response {
                    planExpiresAt = comboExpiry(root)
                    if let picked = planFromCombo(combo.body) {
                        plan = picked.name
                        billingCycle = picked.cycle
                    }
                }
            }
        }

        if let credit = results["credit"], credit.isOK,
           let root = JSONHelp.object(credit.body) {
            let response = baseResp(root)
            switch response {
            case .needsLogin: sessionExpired = true
            case .failure(let message): if apiError == nil { apiError = message }
            case .ok: break
            }
            if case .ok = response {
                if root["total_credits"] != nil || root["remaining_credits"] != nil {
                    loggedIn = true
                }
                let remaining = JSONHelp.double(root["remaining_credits"])
                let total = JSONHelp.double(root["total_credits"])
                let used = JSONHelp.double(root["used_credits"])
                if remaining != nil || total != nil {
                    let percent: Double?
                    if let used, let total, total > 0 {
                        percent = min(max(used / total * 100, 0), 100)
                    } else if let remaining, let total, total > 0 {
                        percent = min(max((total - remaining) / total * 100, 0), 100)
                    } else {
                        percent = nil
                    }
                    metrics.append(UsageMetric(
                        id: "credits", label: "积分余额",
                        usedPercent: percent,
                        remaining: remaining, total: total
                    ))
                }
            }
        }

        if metrics.contains(where: { $0.id == "credits" }) == false, let balance = creditsFromRemains {
            metrics.append(UsageMetric(
                id: "credits", label: "积分余额",
                detail: "\(formatTokens(balance)) 积分",
                amount: balance
            ))
        }

        if let summary = results["usage_summary"], summary.isOK,
           let root = JSONHelp.object(summary.body) {
            let response = baseResp(root)
            switch response {
            case .needsLogin: sessionExpired = true
            case .failure(let message): if apiError == nil { apiError = message }
            case .ok: break
            }
            if case .ok = response {
                if root["total_token_consumed"] != nil || root["daily_token_usage"] != nil {
                    loggedIn = true
                }
                if let consumed = JSONHelp.string(root["total_token_consumed"]) ?? stringify(root["total_token_consumed"]) {
                    metrics.append(UsageMetric(
                        id: "lifetime_tokens", label: "累计调用量",
                        detail: consumed,
                        amount: parseCompact(consumed)
                    ))
                }
                if let days = JSONHelp.double(root["active_days"]), days > 0,
                   let dayCount = JSONHelp.intTruncating(days) {
                    metrics.append(UsageMetric(id: "active_days", label: "活跃天数",
                                               detail: "\(dayCount) 天", amount: days))
                }
                if let daily = root["daily_token_usage"] as? [Any] {
                    let last7 = daily.suffix(7).compactMap(JSONHelp.double)
                    let last30 = daily.suffix(30).compactMap(JSONHelp.double)
                    if !last7.isEmpty {
                        let sum = last7.reduce(0, +)
                        if sum.isFinite {
                            metrics.append(UsageMetric(
                                id: "last_7d_calls", label: "近 7 天调用量",
                                detail: formatTokens(sum), amount: sum
                            ))
                        }
                    }
                    if !last30.isEmpty {
                        let sum = last30.reduce(0, +)
                        if sum.isFinite {
                            metrics.append(UsageMetric(
                                id: "last_30d_calls", label: "近 30 天调用量",
                                detail: formatTokens(sum), amount: sum
                            ))
                        }
                    }
                }
            }
        }

        metrics.append(contentsOf: billingMetrics(results["billing"], provider: provider))

        if plan == nil, let raw = planFromRemains {
            plan = tierName(raw) ?? raw
        }
        if plan == nil, loggedIn {
            plan = "Token Plan"
        }

        let status: SnapshotStatus
        if keySessionExpired {
            metrics = []
            status = .needsLogin
        } else if loggedIn {
            status = .ok
        } else if sessionExpired {
            metrics = []
            status = .needsLogin
        } else if let apiError {
            status = .error(apiError)
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if let failed = failedProbe(results) {
            status = failed.failureStatus
        } else {
            status = .needsLogin
        }

        if billingCycle == nil, PlanCatalog.hasListPrice(plan, provider: provider) {
            billingCycle = .monthly
        }
        return ProviderSnapshot(
            provider: provider,
            planName: plan,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            billingCycle: billingCycle,
            planExpiresAt: planExpiresAt
        )
    }

    private enum BaseRespResult {
        case ok
        case needsLogin
        case failure(String)
    }

    private static func baseResp(_ root: [String: Any]) -> BaseRespResult {
        let node = (root["base_resp"] as? [String: Any])
            ?? ((root["data"] as? [String: Any])?["base_resp"] as? [String: Any])
        guard let node else { return .ok }
        guard node.keys.contains("status_code") else { return .ok }
        guard let rawCode = JSONHelp.double(node["status_code"]) else {
            return .failure("响应状态码异常")
        }
        guard rawCode != 0 else { return .ok }
        let message = JSONHelp.string(node["status_msg"]) ?? ""
        guard let code = JSONHelp.intExactly(rawCode) else {
            return .failure("响应状态码异常")
        }
        let lower = message.lowercased()
        if code == 1004 || lower.contains("cookie") || lower.contains("login") || lower.contains("log in") {
            return .needsLogin
        }
        return .failure("MiniMax \(code): \(message)")
    }

    private static func comboBaseResp(_ root: [String: Any]) -> BaseRespResult {
        for container in comboContainers(root) {
            let result = baseResp(container)
            if case .ok = result { continue }
            return result
        }
        return .ok
    }

    private static func comboContainers(_ root: [String: Any]) -> [[String: Any]] {
        var containers: [[String: Any]] = []
        for key in ["yearly", "monthly"] {
            guard let nested = root[key] as? [String: Any] else { continue }
            if let status = JSONHelp.intExactly(nested["status"]), nested.keys.contains("body") {
                guard (200..<300).contains(status),
                      let body = JSONHelp.string(nested["body"]),
                      let decoded = JSONHelp.object(body) else { continue }
                containers.append(decoded)
            } else {
                containers.append(nested)
            }
        }
        containers.append(root)
        return containers
    }

    private static func failedProbe(_ results: [String: ProbeResult]) -> ProbeResult? {
        for key in ["remains", "credit", "usage_summary", "combo", "billing"] {
            if let r = results[key] {
                if !r.isOK { return r }
                if key == "combo", let nested = comboFailure(r) { return nested }
            }
        }
        return results.keys.sorted().compactMap { results[$0] }.first { !$0.isOK }
    }

    private static func comboFailure(_ probe: ProbeResult) -> ProbeResult? {
        guard probe.isOK, let root = JSONHelp.object(probe.body) else { return nil }
        var failures: [ProbeResult] = []
        var sawSuccess = false
        for key in ["yearly", "monthly"] {
            guard let child = root[key] as? [String: Any],
                  child.keys.contains("body"),
                  let status = JSONHelp.intExactly(child["status"]) else { continue }
            if (200..<300).contains(status) {
                sawSuccess = true
            } else {
                failures.append(ProbeResult(status: status, body: JSONHelp.string(child["body"]) ?? ""))
            }
        }
        guard !sawSuccess else { return nil }
        return failures.first(where: \.isUnauthorized)
            ?? failures.first(where: { $0.status > 0 })
            ?? failures.first(where: { $0.status == -3 })
            ?? failures.first
    }

    private static func modelMetrics(_ models: [[String: Any]], now: Date) -> [UsageMetric] {
        var general: [UsageMetric] = []
        var video: [UsageMetric] = []
        var others: [UsageMetric] = []
        var used = Set<String>()

        func take(_ metric: UsageMetric?, into bucket: inout [UsageMetric]) {
            guard let metric, !used.contains(metric.id) else { return }
            used.insert(metric.id)
            bucket.append(metric)
        }

        for row in models {
            let name = (JSONHelp.string(row["model_name"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()

            if lower == "general" {
                take(windowMetric(id: "five_hour", label: "5h 限额", row: row, weekly: false, pinned: true, now: now), into: &general)
                take(windowMetric(id: "seven_day", label: "周限额", row: row, weekly: true, pinned: true, now: now), into: &general)
                continue
            }
            if lower == "video" || lower.hasPrefix("video") {
                take(windowMetric(id: "video_gift", label: "视频赠送", row: row, weekly: false, pinned: true, now: now), into: &video)
                continue
            }

            let service = serviceLabel(for: name)
            let slug = slugify(name)
            guard !slug.isEmpty else { continue }
            take(windowMetric(id: "model_\(slug)", label: service, row: row, weekly: false, pinned: false, now: now), into: &others)
            if shouldEmitWeekly(name: name, row: row) {
                take(windowMetric(id: "model_\(slug)_weekly", label: "\(service)（周）", row: row, weekly: true, pinned: false, now: now), into: &others)
            }
        }
        return general + video + others
    }

    private static func serviceLabel(for modelName: String) -> String {
        let lower = modelName.lowercased()
        if isTextGenerationModel(modelName) { return "文本生成" }
        if lower.contains("speech") { return "语音合成" }
        if lower.contains("hailuo"), lower.contains("fast") { return "图生视频" }
        if lower.contains("hailuo") { return "文生视频" }
        if lower.hasPrefix("image-") { return "图像生成" }
        if lower.contains("music") { return "音乐生成" }
        return modelName
    }

    private static func isTextGenerationModel(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        return lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2.")
    }

    private static func isNonTextChannel(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        return lower == "video" || lower.hasPrefix("video")
            || lower.contains("speech")
            || lower.hasPrefix("image-") || lower.contains("image")
            || lower.contains("music")
            || lower.contains("hailuo")
    }

    private static func hasWeeklyUsageFields(_ row: [String: Any]) -> Bool {
        let keys = [
            "current_weekly_used_percent", "current_weekly_remaining_percent",
            "current_weekly_total_count", "current_weekly_used_count",
            "current_weekly_remains_count", "current_weekly_usage_count",
            "current_weekly_status",
            "weekly_end_time", "weekly_remains_time",
        ]
        return keys.contains { key in
            guard let value = row[key], !(value is NSNull) else { return false }
            return true
        }
    }

    private static func shouldEmitWeekly(name: String, row: [String: Any]) -> Bool {
        if isNonTextChannel(name) { return false }
        return hasWeeklyUsageFields(row)
    }

    private static func slugify(_ raw: String) -> String {
        let mapped = raw.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "_"
        }
        return String(mapped).split(separator: "_").joined(separator: "_")
    }

    private static func windowMetric(
        id: String, label: String,
        row: [String: Any], weekly: Bool, pinned: Bool, now: Date
    ) -> UsageMetric? {
        let prefix = weekly ? "current_weekly_" : "current_interval_"
        let pin: Bool? = pinned ? true : nil

        let usedPercent = percentValue(row[prefix + "used_percent"])
        let remainingPercent = percentValue(row[prefix + "remaining_percent"])
        var percent = usedPercent
        if percent == nil, let remainingPercent {
            percent = min(max(100 - remainingPercent, 0), 100)
        }

        let totalCount = JSONHelp.double(row[prefix + "total_count"])
        let usedCount = JSONHelp.double(row[prefix + "used_count"])
        let remainingCount = JSONHelp.double(row[prefix + "remains_count"])
            ?? JSONHelp.double(row[prefix + "usage_count"])
        let status = JSONHelp.double(row[prefix + "status"])

        if status == 3 {
            let leftPercent = remainingPercent ?? usedPercent.map { 100 - $0 }
            if totalCount == 0, remainingCount == 0, (leftPercent ?? -1) >= 100 { return nil }
            return UsageMetric(
                id: id, label: label,
                usedPercent: nil,
                remaining: nil, total: nil,
                resetsAt: nil,
                detail: "无限制",
                pinned: pin
            )
        }

        if percent == nil, let totalCount, totalCount > 0 {
            if let usedCount, usedCount >= 0 {
                percent = min(max(usedCount / totalCount * 100, 0), 100)
            } else if let remainingCount, remainingCount >= 0 {
                percent = min(max((totalCount - remainingCount) / totalCount * 100, 0), 100)
            }
        }
        if percent == nil, usedCount == nil, remainingCount == nil { return nil }

        let boost = firstNumber(row, keys: weekly
            ? ["weekly_boost_permill", "weekly_boost_permille"]
            : ["interval_boost_permill", "interval_boost_permille"])
        let totalPercent: Double
        if let boost, boost > 0 {
            totalPercent = boost / 10
        } else {
            totalPercent = percentValue(row[prefix + "total_percent"]) ?? 100
        }

        let remainsMs = JSONHelp.double(row[weekly ? "weekly_remains_time" : "remains_time"])
        let end = JSONHelp.date(row[weekly ? "weekly_end_time" : "end_time"])
        let resets = end ?? remainsMs.flatMap { JSONHelp.date(byAdding: $0 / 1000, to: now) }

        let countsUsable = (totalCount ?? -1) > 0
        let usePair = percent != nil && (id == "five_hour" || id == "seven_day" || !countsUsable)
        return UsageMetric(
            id: id, label: label,
            usedPercent: percent,
            remaining: usePair ? nil : nonNegative(remainingCount),
            total: usePair ? nil : nonNegative(totalCount),
            resetsAt: resets,
            pinned: pin,
            displayValue: usePair ? percentPair(used: percent, total: totalPercent) : nil
        )
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func percentValue(_ any: Any?) -> Double? {
        let raw: Double?
        if let s = any as? String {
            raw = JSONHelp.double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        } else {
            raw = JSONHelp.double(any)
        }
        guard let raw, raw.isFinite, (0...100).contains(raw) else { return nil }
        return raw
    }

    private static func firstNumber(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = JSONHelp.double(dict[key]) { return value }
        }
        return nil
    }

    public static func percentPair(used: Double?, total: Double?) -> String {
        let safeUsed = used.flatMap { $0.isFinite ? $0 : nil }
        let safeTotal = total.flatMap { $0.isFinite ? $0 : nil }
        let u = JSONHelp.intRounded(safeUsed ?? 0) ?? 0
        let t = JSONHelp.intRounded(safeTotal ?? 100) ?? 100
        return "\(u)%/\(t)%"
    }

    private static func billingMetrics(_ probe: ProbeResult?, provider: ProviderID) -> [UsageMetric] {
        guard let probe, probe.isOK, let root = JSONHelp.object(probe.body) else { return [] }
        var out: [UsageMetric] = []
        if let today = JSONHelp.double(root["todayTokens"]), today > 0 {
            out.append(UsageMetric(id: "today_tokens", label: "今日 tokens",
                                   detail: formatTokens(today), amount: today))
        }
        if let last30 = JSONHelp.double(root["last30Tokens"]), last30 > 0 {
            let top = ((root["topModels"] as? [[String: Any]]) ?? []).prefix(3).compactMap { row -> String? in
                guard let name = JSONHelp.string(row["name"]), !name.isEmpty else { return nil }
                return "\(name) \(formatTokens(JSONHelp.double(row["tokens"]) ?? 0))"
            }
            out.append(UsageMetric(id: "last_30d_tokens", label: "近 30 天 tokens",
                                   detail: top.isEmpty ? formatTokens(last30) : top.joined(separator: " · "),
                                   amount: last30))
        }
        if let cash = JSONHelp.double(root["last30Cash"]), cash > 0 {
            out.append(UsageMetric(id: "last_30d_cash", label: "近 30 天消费",
                                   amount: cash, currency: billingCurrency(root, provider: provider)))
        }
        return out
    }

    private static func billingCurrency(_ root: [String: Any], provider: ProviderID) -> String {
        for key in ["currency", "cash_currency"] {
            if let raw = JSONHelp.string(root[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw.uppercased()
            }
        }
        return provider == .minimaxGlobal ? "USD" : "CNY"
    }

    private static func planFromCombo(_ body: String) -> (name: String, cycle: BillingCycle)? {
        guard let root = JSONHelp.object(body) else { return nil }
        if let picked = pickCurrentPlan(root) { return picked }
        for nested in comboContainers(root).dropLast() {
            if let picked = pickCurrentPlan(nested) { return picked }
        }
        return nil
    }

    private static func pickCurrentPlan(_ root: [String: Any]) -> (name: String, cycle: BillingCycle)? {
        let packs = (root["cycle_resource_packages"] as? [[String: Any]]) ?? []
        if let cur = root["current_subscribe"] as? [String: Any] {
            let title = firstString(cur, keys: [
                "current_subscribe_title", "subscribe_title", "title", "combo_name", "package_name"
            ])
            if let title, !title.isEmpty,
               let labeled = planLabel(title, cycle: JSONHelp.double(cur["current_subscribe_cycle_type"]) ?? JSONHelp.double(cur["cycle_type"])) {
                return labeled
            }
            let comboID = JSONHelp.string(cur["curr_subscribe_combo_id"]) ?? JSONHelp.string(cur["combo_id"])
            if let comboID, !comboID.isEmpty,
               let pack = packs.first(where: { JSONHelp.string($0["combo_id"]) == comboID }) {
                if let labeled = packLabel(pack) { return labeled }
            }
        }
        var best: (score: Int, picked: (name: String, cycle: BillingCycle))?
        for pack in packs {
            guard let labeled = packLabel(pack) else { continue }
            var score = 0
            let button = JSONHelp.string(pack["button_text"]) ?? ""
            let blob = packBlob(pack)
            if button.contains("续订") { score += 100 }
            if blob.contains("年度") || blob.contains("年付") || blob.contains("年会员") { score += 50 }
            if labeled.cycle == .yearly { score += 20 }
            if JSONHelp.double(pack["cycle_type"]) == 3 { score += 10 }
            if score > (best?.score ?? 0) { best = (score, labeled) }
        }
        return best?.picked
    }

    private static func packLabel(_ pack: [String: Any]) -> (name: String, cycle: BillingCycle)? {
        let title = firstString(pack, keys: ["title", "combo_name", "package_name", "name", "price_desc"])
        return planLabel(title, cycle: JSONHelp.double(pack["cycle_type"]))
    }

    private static func packBlob(_ pack: [String: Any]) -> String {
        [pack["title"], pack["combo_name"], pack["package_name"], pack["name"],
         pack["button_text"], pack["price_desc"]]
            .compactMap { JSONHelp.string($0) }
            .joined(separator: " ")
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = JSONHelp.string(dict[key]), !s.isEmpty { return s }
        }
        return nil
    }

    private static func planLabel(_ raw: String?, cycle: Double?) -> (name: String, cycle: BillingCycle)? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let fromText = BillingCycle.parse(raw)
        let billing: BillingCycle
        if cycle == 3 { billing = .yearly }
        else { billing = fromText ?? .monthly }
        let tier: String
        if lower.contains("ultra") { tier = "Token Plan Ultra" }
        else if lower.contains("max") { tier = "Token Plan Max" }
        else if lower.contains("plus") { tier = "Token Plan Plus" }
        else { return nil }
        return (tier, billing)
    }

    private static func tierName(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("ultra") { return "Token Plan Ultra" }
        if lower.contains("max") { return "Token Plan Max" }
        if lower.contains("plus") { return "Token Plan Plus" }
        return nil
    }

    private static func planTitle(in root: [String: Any]) -> String? {
        if let nested = root["current_combo_card"] as? [String: Any],
           let title = firstString(nested, keys: ["title", "name"]) {
            return title
        }
        return firstString(root, keys: [
            "current_subscribe_title", "plan_name", "planName",
            "combo_title", "comboTitle", "current_plan_title", "currentPlanTitle"
        ])
    }

    private static func creditsBalance(in root: [String: Any]) -> Double? {
        firstNumber(root, keys: [
            "points_balance", "point_balance", "credits_balance", "credit_balance", "balance"
        ])
    }

    private static func comboExpiry(_ root: [String: Any]) -> Date? {
        let keys = [
            "current_subscribe_end_time_ts", "current_subscribe_end_time",
            "renewal_trigger_time_ts", "renewal_date",
        ]
        for container in comboContainers(root) {
            for found in JSONHelp.dictsContainingKey("current_subscribe_end_time_ts", in: container)
                + JSONHelp.dictsContainingKey("current_subscribe_end_time", in: container)
                + JSONHelp.dictsContainingKey("renewal_trigger_time_ts", in: container)
                + JSONHelp.dictsContainingKey("renewal_date", in: container) {
                for key in keys {
                    if let date = parseComboDate(found.dict[key]) { return date }
                }
            }
            for key in keys {
                if let date = parseComboDate(container[key]) { return date }
            }
        }
        return nil
    }

    private static func parseComboDate(_ any: Any?) -> Date? {
        if let date = JSONHelp.date(any) { return date }
        guard let raw = JSONHelp.string(any)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd/yyyy"
        if let date = formatter.date(from: raw), JSONHelp.isSafeDate(date) { return date }
        return nil
    }

    private static func stringify(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = JSONHelp.double(any) { return String(format: "%.0f", n) }
        return nil
    }

    private static func parseCompact(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.hasSuffix("B"), let n = Double(t.dropLast()) { return n * 1_000_000_000 }
        if t.hasSuffix("M"), let n = Double(t.dropLast()) { return n * 1_000_000 }
        if t.hasSuffix("K"), let n = Double(t.dropLast()) { return n * 1_000 }
        return Double(t)
    }

    private static func formatTokens(_ n: Double) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.2fK", n / 1_000) }
        return String(format: "%.0f", n)
    }
}

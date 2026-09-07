import Foundation

/// 解析即梦官网积分（jimeng.jianying.com）。
/// 卡片四条数字：剩余可用订阅+充值+赠送校验；充值必须用 `purchase_credit` 原值。
/// 积分已是整数，禁止走 `JSONHelp.percent`。流水进 `creditHistory`，不进指标行。
public enum JimengParser {
    public static func parse(results: [String: ProbeResult], now: Date) -> ProviderSnapshot {
        var loggedIn = false
        var vip: Double?
        var purchase: Double?
        var gift: Double?
        var remaining: Double?
        var creditHistory: [CreditLedgerEntry] = []

        if let credit = results["credit"], credit.isOK,
           let root = JSONHelp.object(credit.body) {
            if isSuccess(root), let bag = creditBag(root) {
                loggedIn = true
                vip = intAmount(bag["vip_credit"] ?? bag["subscription_credit"])
                // 充值积分是原值，禁止 remaining − vip − gift
                purchase = intAmount(bag["purchase_credit"] ?? bag["recharge_credit"])
                gift = intAmount(bag["gift_credit"] ?? bag["bonus_credit"])
                if let total = intAmount(bag["total_credit"]) {
                    remaining = total
                }
            } else if isSystemBusy(root) {
                // 1014 系统繁忙，不是未登录
            } else if isAuthFailure(root) {
                loggedIn = false
            }
        }

        let creditBusy = results["credit"].map { isSystemBusyBody($0.body) } ?? false
        if !creditBusy, let history = results["history"], history.isOK,
           let root = JSONHelp.object(history.body) {
            if isSuccess(root), let data = payload(root) {
                if let total = intAmount(data["total_credit"]) {
                    loggedIn = true
                    if remaining == nil { remaining = total }
                }
                creditHistory = parseRecords(data["records"])
            }
        }

        // 官网公式：剩余 = 订阅 + 充值 + 赠送。三者齐全时用和做校验/展示。
        if let vip, let purchase, let gift {
            let sum = vip + purchase + gift
            if sum.isFinite { remaining = sum }
        } else if remaining == nil {
            let parts = [vip, purchase, gift].compactMap { $0 }
            if !parts.isEmpty {
                let sum = parts.reduce(0, +)
                if sum.isFinite { remaining = sum }
            }
        }

        if let user = results["user"], user.isOK,
           let root = JSONHelp.object(user.body),
           boolFlag(root["loggedIn"]) || discoveredID(root) != nil {
            // 过桥只回 {loggedIn}；旧 fixture 仍可能带 sec_uid / user_id。
            // 不能再跟积分字段做与，否则额度探针失败时登录页永远识别不到。
            loggedIn = true
        }

        if let page = results["page"], page.isOK, let root = JSONHelp.object(page.body) {
            let isLogined = boolFlag(root["isLogined"])
            let hasUserInfo = boolFlag(root["hasUserInfo"])
            if JimengSession.pageIndicatesLogin(isLogined: isLogined, hasUserInfo: hasUserInfo) {
                loggedIn = true
            }
        }

        if let session = results["session"], session.isOK,
           let root = JSONHelp.object(session.body),
           boolFlag(root["hasSession"]) {
            // 离屏页可能仍是匿名 SSR，但本机会话 Cookie 已在。
            // 额度 1014 时也要认已登录，不能落成「系统繁忙」。
            loggedIn = true
        }

        var metrics: [UsageMetric] = []
        if let remaining {
            metrics.append(UsageMetric(
                id: "remaining", label: "剩余积分",
                amount: remaining, pinned: true
            ))
        }
        if let vip {
            metrics.append(UsageMetric(id: "subscription", label: "订阅积分", amount: vip, pinned: true))
        }
        if let purchase {
            metrics.append(UsageMetric(id: "recharge", label: "充值积分", amount: purchase, pinned: true))
        }
        if let gift {
            metrics.append(UsageMetric(id: "gift", label: "赠送积分", amount: gift, pinned: true))
        }

        if !metrics.isEmpty { loggedIn = true }

        // 会话在、额度却是 1014：仍算已登录，但不能交一份空白 ok。
        // 钉住剩余积分占位，卡片才不会只剩「更新于」。
        if loggedIn, metrics.isEmpty {
            let historyBusy = results["history"].map { isSystemBusyBody($0.body) } ?? false
            if creditBusy || historyBusy {
                metrics.append(UsageMetric(
                    id: "remaining",
                    label: "剩余积分",
                    detail: Self.unavailableDetail,
                    pinned: true,
                    displayValue: "—"
                ))
            }
        }

        let status: SnapshotStatus
        if creditRejectedLogin(results) {
            // 额度探针明确未登录时，通行证 / 流水不得把 leftover 数字写成 .ok。
            // 通行证单独成功且没有 credit 401 仍是已登录空卡。
            metrics = []
            creditHistory = []
            status = .needsLogin
        } else if loggedIn {
            status = .ok
        } else if results.isEmpty {
            status = .error("未获取到任何响应")
        } else if results.values.contains(where: { isSystemBusyBody($0.body) }) {
            status = .error("系统繁忙")
        } else if results.values.contains(where: { $0.status == 401 || $0.status == 403 }) {
            status = .needsLogin
        } else if let failed = results["credit"], !failed.isOK {
            status = failed.failureStatus
        } else if let failed = results.values.first(where: { !$0.isOK }) {
            status = failed.failureStatus
        } else {
            status = .needsLogin
        }

        return ProviderSnapshot(
            provider: .jimeng,
            planName: nil,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            creditHistory: creditHistory.isEmpty ? nil : creditHistory
        )
    }

    /// 卡片用的稳定占位标记，界面再本地化成「积分暂未获取到 / 系统繁忙」。
    public static let unavailableDetail = "system_busy"

    /// 额度 HTTP 401/403 或信封写未登录。1014 繁忙不是未登录。
    static func creditRejectedLogin(_ results: [String: ProbeResult]) -> Bool {
        guard let credit = results["credit"] else { return false }
        if credit.isUnauthorized { return true }
        guard credit.isOK, let root = JSONHelp.object(credit.body), !isSystemBusy(root) else { return false }
        let msg = (JSONHelp.string(root["errmsg"]) ?? JSONHelp.string(root["message"]) ?? "").lowercased()
        return msg.contains("login") || msg.contains("auth") || msg.contains("未登录")
    }

    /// 积分整数。已是绝对数量，不得当 0…1 百分比放大。
    static func intAmount(_ any: Any?) -> Double? {
        guard let value = JSONHelp.intRounded(any) else { return nil }
        return Double(value)
    }

    static func parseRecords(_ any: Any?) -> [CreditLedgerEntry] {
        guard let rows = any as? [[String: Any]] else { return [] }
        var entries: [CreditLedgerEntry] = []
        for row in rows {
            guard let title = JSONHelp.string(row["title"]), !title.isEmpty else { continue }
            guard let amount = intAmount(row["amount"]) else { continue }
            guard let historyType = JSONHelp.intRounded(row["history_type"]) else { continue }
            guard historyType == 1 || historyType == 2 else { continue }
            guard let created = unixDate(row["create_time"]) else { continue }
            let id = stringID(row["history_id"]) ?? stringID(row["submit_id"]) ?? "\(created.timeIntervalSince1970)"
            let extra = JSONHelp.string(row["extra_content"])
            entries.append(CreditLedgerEntry(
                id: id,
                title: title,
                amount: amount,
                historyType: historyType,
                createdAt: created,
                extraContent: (extra?.isEmpty == false) ? extra : nil
            ))
        }
        return entries
    }

    static func unixDate(_ any: Any?) -> Date? {
        JSONHelp.date(any)
    }

    static func isSuccess(_ root: [String: Any]) -> Bool {
        if let ret = JSONHelp.string(root["ret"]), ret == "0" { return true }
        if let ret = JSONHelp.double(root["ret"]), ret == 0 { return true }
        if JSONHelp.string(root["errmsg"])?.lowercased() == "success" { return true }
        return creditBag(root) != nil
    }

    static func isSystemBusy(_ root: [String: Any]) -> Bool {
        if let ret = JSONHelp.string(root["ret"]), ret == "1014" { return true }
        if let ret = JSONHelp.double(root["ret"]), ret == 1014 { return true }
        let msg = (JSONHelp.string(root["errmsg"]) ?? "").lowercased()
        return msg.contains("system busy")
    }

    static func isSystemBusyBody(_ body: String) -> Bool {
        guard let root = JSONHelp.object(body) else { return false }
        return isSystemBusy(root)
    }

    static func isAuthFailure(_ root: [String: Any]) -> Bool {
        if isSystemBusy(root) { return false }
        let msg = (JSONHelp.string(root["errmsg"]) ?? JSONHelp.string(root["message"]) ?? "").lowercased()
        if msg.contains("login") || msg.contains("auth") || msg.contains("未登录") { return true }
        if let ret = JSONHelp.string(root["ret"]), ret != "0" { return true }
        if let ret = JSONHelp.double(root["ret"]), ret != 0 { return true }
        return false
    }

    static func payload(_ root: [String: Any]) -> [String: Any]? {
        if let data = root["data"] as? [String: Any] { return data }
        if let response = JSONHelp.string(root["response"]),
           let nested = JSONHelp.object(response) {
            return nested
        }
        return root
    }

    static func creditBag(_ root: [String: Any]) -> [String: Any]? {
        let data = payload(root) ?? root
        if let credit = data["credit"] as? [String: Any] { return credit }
        if data["gift_credit"] != nil || data["vip_credit"] != nil || data["purchase_credit"] != nil {
            return data
        }
        if root["gift_credit"] != nil { return root }
        return nil
    }

    static func discoveredID(_ root: [String: Any]) -> String? {
        let data = (root["data"] as? [String: Any]) ?? root
        let discovered = (root["discovered"] as? [String: Any]) ?? (data["discovered"] as? [String: Any])
        let keys = ["sec_uid", "secUid", "sec_user_id", "secUserId", "user_id", "userId", "uid"]
        for key in keys {
            if let value = stringID(data[key]) { return value }
            if let value = stringID(discovered?[key]) { return value }
        }
        return nil
    }

    static func stringID(_ any: Any?) -> String? {
        if let value = JSONHelp.string(any), !value.isEmpty { return value }
        if let number = JSONHelp.double(any), let id = JSONHelp.intTruncating(number) { return String(id) }
        return nil
    }

    static func boolFlag(_ any: Any?) -> Bool {
        if let value = any as? Bool { return value }
        if let value = JSONHelp.string(any)?.lowercased() { return value == "true" || value == "1" }
        if let value = JSONHelp.double(any) { return value != 0 }
        return false
    }
}

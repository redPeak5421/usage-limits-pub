import Foundation
import CoreFoundation

/// 诊断日志脱敏：把探针响应压成可贴给开发者分析的一行 JSON 预览，
/// 凭据 / 身份 / 长随机串一律打码。Release 构建也记录，用户交日志即可定位接口漂移。
public enum DiagnosticRedactor {
    /// 命中即整值打码的键（大小写、下划线、连字符无关）。
    static let sensitiveKeyFragments: [String] = [
        "token", "secret", "password", "passwd", "cookie", "authorization", "auth",
        "session", "sessionid", "sid", "sub", "email", "phone", "mobile", "uid", "userid", "user_id",
        "secuid", "sec_uid", "uifid", "mstoken", "csrf", "apikey", "api_key", "key", "credential",
        "signature", "sign", "ticket", "device", "fingerprint", "log_id", "logid", "trace",
        // OpenCode billing.get 带 Stripe customerID / paymentMethodID / 卡尾号
        "customer", "payment",
        "nickname", "displayname", "workspace", "organization", "orgid", "accountid", "account",
        "sensitive_id",
        "trackingid",
        // OpenCode billing.get 还有 Stripe subscriptionID / liteSubscriptionID
        "subscriptionid",
    ]
    /// 保留原值的键（虽然命中上面片段，但只是业务字段）。
    static let allowKeys: Set<String> = [
        "history_type", "trade_source", "window_minutes", "limit_window_seconds", "reset_after_seconds",
        "resets_in_seconds", "resets_at", "reset_at", "expires_at", "plan_type", "subscription_plan",
        "has_active_subscription", "used_percent", "usage", "remaining", "total", "limit", "amount",
        "isLogined", "hasUserInfo", "hasUifid", "hasSigner", "hasNativeSign", "hasSession", "hasSub",
        // LongCat token_packs / token_usage 用量字段含 Token 后缀，不能被 token 片段误伤
        "totalToken", "consumedToken", "usedToken", "availableToken", "freeAvailableToken", "consumedRatio",
    ]
    public static let defaultLimit = 700

    /// 含账号名 / 手机 / token 的探针只记 HTTP 与字节数，不预览 body。
    public static func shouldOmitBody(providerRaw: String, probeName: String) -> Bool {
        if providerRaw == ProviderID.longcat.rawValue && probeName == "user" { return true }
        if providerRaw == ProviderID.openai.rawValue && probeName == "session" { return true }
        if providerRaw == ProviderID.deepseek.rawValue && probeName == "current" { return true }
        if providerRaw == ProviderID.deepseek.rawValue && probeName == "api_keys" { return true }
        if providerRaw == ProviderID.kimi.rawValue && probeName == "user" { return true }
        if providerRaw == ProviderID.zhipu.rawValue && probeName == "customer" { return true }
        if providerRaw == ProviderID.claude.rawValue && probeName == "account" { return true }
        if providerRaw == ProviderID.opencode.rawValue && probeName == "status" { return true }
        if providerRaw == ProviderID.augment.rawValue && probeName == "subscription" { return true }
        if providerRaw == ProviderID.t3chat.rawValue && probeName == "customer" { return true }
        if providerRaw == ProviderID.copilot.rawValue && probeName == "budgets" { return true }
        if providerRaw == ProviderID.gemini.rawValue && probeName == "quota" { return true }
        if providerRaw == ProviderID.antigravity.rawValue && probeName == "quota" { return true }
        if providerRaw == ProviderID.kiro.rawValue && probeName == "usage" { return true }
        return false
    }

    /// 诊断一行：`prefix.name: HTTP s，n 字节`，默认再跟脱敏 body。
    public static func probeLine(prefix: String, name: String, status: Int, body: String) -> String {
        let providerRaw = prefix.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? prefix
        let head = "\(prefix).\(name): HTTP \(status)，\(body.utf8.count) 字节"
        if shouldOmitBody(providerRaw: providerRaw, probeName: name) {
            return head
        }
        return head + " body= " + preview(body)
    }

    /// 一行预览：JSON 走脱敏序列化；非 JSON 截前缀（HTML 只留标签摘要）。
    public static func preview(_ body: String, limit: Int = defaultLimit) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "<空>" }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            let redacted = redact(json, key: "")
            if let out = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
               let text = String(data: out, encoding: .utf8) {
                return truncate(text, limit: limit)
            }
        }
        if trimmed.lowercased().hasPrefix("<!doctype") || trimmed.lowercased().hasPrefix("<html") {
            return "<HTML \(body.utf8.count) 字节>"
        }
        return truncate(redactFreeText(trimmed), limit: limit)
    }

    /// 快照解析结果一行摘要：状态 / 套餐 / 每条指标的 id、标签、数值、重置。
    public static func summary(of snap: ProviderSnapshot, now: Date = Date()) -> String {
        var parts: [String] = ["status=\(statusText(snap.status))"]
        if let plan = snap.planName { parts.append("plan=\(plan)") }
        if let cycle = snap.billingCycle { parts.append("cycle=\(cycle.rawValue)") }
        let metrics = snap.metrics.map { m -> String in
            var v: [String] = []
            if let p = m.usedPercent {
                v.append(p.isFinite && (0...100).contains(p)
                    ? String(format: "%.1f%%", p)
                    : "percent=<invalid-number>")
            }
            if let a = m.amount { v.append("amount=\(trimNumber(a))") }
            if let r = m.remaining, let t = m.total { v.append("\(trimNumber(r))/\(trimNumber(t))") }
            if let d = m.displayValue { v.append("display=\(d)") }
            if let r = m.resetsAt {
                if JSONHelp.isSafeDate(r), JSONHelp.isSafeDate(now),
                   let mins = JSONHelp.intTruncating(r.timeIntervalSince(now) / 60) {
                    v.append("resets=\(mins)min")
                } else {
                    v.append("resets=<invalid-date>")
                }
            }
            if let k = m.kind { v.append("kind=\(k)") }
            return "\(m.id)「\(m.label)」\(v.joined(separator: " "))"
        }
        parts.append("metrics[\(metrics.count)]=[\(metrics.joined(separator: "; "))]")
        if let h = snap.creditHistory { parts.append("history=\(h.count)") }
        return parts.joined(separator: " ")
    }

    // MARK: - 内部

    static func redact(_ any: Any, key: String) -> Any {
        if let dict = any as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if isSensitiveKey(k) {
                    out[k] = mask(v)
                } else {
                    out[k] = redact(v, key: k)
                }
            }
            return out
        }
        if let arr = any as? [Any] {
            // 长数组只留前 5 项，避免流水把预览撑满
            let head = arr.prefix(5).map { redact($0, key: key) }
            return arr.count > 5 ? head + ["<…还有 \(arr.count - 5) 项>"] : head
        }
        if let s = any as? String {
            return redactString(s)
        }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : "<invalid-number>"
        }
        return any
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        if allowKeys.contains(key) { return false }
        let norm = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        // 精确键 name：账号名。不能用 name 片段，否则 plan_name / model_name 会被误伤。
        if norm == "name" { return true }
        let words = Set(CustomFieldSemantics.tokens(of: key))
        for fragment in sensitiveKeyFragments {
            let f = fragment.replacingOccurrences(of: "_", with: "")
            // 短片段（key / sid / sign / auth / uid）要求整词（snake / camel 分词后精确匹配），避免误伤 monkey / signal
            if f.count <= 4 {
                if norm == f || words.contains(f) { return true }
            } else if norm.contains(f) {
                return true
            }
        }
        return false
    }

    static func mask(_ value: Any) -> Any {
        if let s = value as? String { return s.isEmpty ? "" : "<redacted:\(s.count)>" }
        if value is NSNull { return value }
        if let dict = value as? [String: Any] { return "<redacted:object \(dict.count) keys>" }
        if let arr = value as? [Any] { return "<redacted:array \(arr.count)>" }
        return "<redacted>"
    }

    /// 长随机串（无空格、≥ 40 字符）与邮箱、URL query 里的 token 一律打码。
    static func redactString(_ s: String) -> String {
        if s.count >= 40, !s.contains(" ") { return "<str:\(s.count)>" }
        if s.contains("@"), s.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil {
            return "<email>"
        }
        if s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
            return "<uuid>"
        }
        return redactFreeText(s)
    }

    static func redactFreeText(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: #"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            with: "<email>",
            options: .regularExpression
        )
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9\-_\.=]+"#,
            #"(?i)([?&](token|access_token|msToken|uifid|sessionid|sid|key)=)[^&\s]+"#,
            #"[A-Za-z0-9\-_]{40,}"#,
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "$1<redacted>", options: .regularExpression)
        }
        return out
    }

    static func truncate(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…<共 \(s.count) 字符>"
    }

    static func statusText(_ status: SnapshotStatus) -> String {
        switch status {
        case .ok: return "ok"
        case .needsLogin: return "needsLogin"
        case .error(let m): return "error(\(m))"
        }
    }

    static func trimNumber(_ d: Double) -> String {
        guard d.isFinite, JSONHelp.intTruncating(d) != nil else { return "<invalid-number>" }
        if let integer = JSONHelp.intExactly(d) { return String(integer) }
        return String(format: "%.2f", d)
    }
}

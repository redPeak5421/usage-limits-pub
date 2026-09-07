import Foundation
import CoreFoundation

/// 向导勾选的一条数字字段：只存路径与展示名，不猜已用/余额角色。
public struct CustomUsageField: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var displayName: String
    /// 向导推断（或用户改选）的语义角色；旧模板无此键 → nil，展示层按普通数字处理。
    public var role: CustomFieldRole?
    /// 币种（USD / CNY …），由原始文本 / 键名 / 兄弟 `currency` 字段推断；可空。
    public var currency: String?
    public var id: String { path }

    public init(path: String, displayName: String, role: CustomFieldRole? = nil, currency: String? = nil) {
        self.path = path
        self.displayName = displayName
        self.role = role
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case path, displayName, role, currency }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        displayName = try c.decode(String.self, forKey: .displayName)
        // 未知角色字符串（未来新增）不让整份模板解码失败
        role = (try? c.decodeIfPresent(String.self, forKey: .role)).flatMap { $0 }.flatMap(CustomFieldRole.init(rawValue:))
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(role?.rawValue, forKey: .role)
        try c.encodeIfPresent(currency, forKey: .currency)
    }
}

/// 已有图标（自动解析或手动上传）则测试连接不再抓 favicon。
public enum CustomUsageLogoPolicy {
    public static func shouldResolveOnTest(hasExistingLogo: Bool) -> Bool {
        !hasExistingLogo
    }
}

/// 用户配置的自定义用量模板。只存 URL 与选中字段（path + 展示名），不含 token。
public struct CustomUsageTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// scheme + host + path，不含 query。
    public var requestURL: String
    public var fields: [CustomUsageField]
    public var createdAt: Date
    /// App Group 相对路径（`custom-logos/<uuid>.<ext>`）。无图时用链环占位。
    public var logoRelativePath: String?
    /// 用户手动选过图后，测试连接不再自动覆盖。
    public var logoIsManual: Bool
    /// 模板默认色；账号自己的 tint 仍优先。
    public var tint: BrandTint?

    public var requestHost: String {
        URL(string: requestURL)?.host ?? ""
    }

    public init?(
        id: UUID = UUID(),
        name: String,
        requestURL: String,
        fields: [CustomUsageField],
        createdAt: Date = Date(),
        logoRelativePath: String? = nil,
        logoIsManual: Bool = false,
        tint: BrandTint? = nil
    ) {
        let normalized = Self.normalizedFields(fields)
        guard !normalized.isEmpty else { return nil }
        guard let sanitized = Self.sanitizedURLString(requestURL) else { return nil }
        self.id = id
        self.name = name
        self.requestURL = sanitized
        self.fields = normalized
        self.createdAt = createdAt
        self.logoRelativePath = logoRelativePath
        self.logoIsManual = logoIsManual
        self.tint = tint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawURL = try container.decode(String.self, forKey: .requestURL)
        requestURL = Self.sanitizedURLString(rawURL) ?? rawURL
        let decodedFields = try container.decodeIfPresent([CustomUsageField].self, forKey: .fields) ?? []
        let used = Self.normalizedPath(try container.decodeIfPresent(String.self, forKey: .usedPath))
        let balance = Self.normalizedPath(try container.decodeIfPresent(String.self, forKey: .balancePath))
        let usedLabel = try container.decodeIfPresent(String.self, forKey: .usedLabel) ?? "已用"
        let balanceLabel = try container.decodeIfPresent(String.self, forKey: .balanceLabel) ?? "余额"
        let fromList = Self.normalizedFields(decodedFields)
        fields = fromList.isEmpty
            ? Self.fieldsFromLegacy(
                usedPath: used,
                balancePath: balance,
                usedLabel: usedLabel,
                balanceLabel: balanceLabel
            )
            : fromList
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        logoRelativePath = try container.decodeIfPresent(String.self, forKey: .logoRelativePath)
        logoIsManual = try container.decodeIfPresent(Bool.self, forKey: .logoIsManual) ?? false
        tint = try container.decodeIfPresent(BrandTint.self, forKey: .tint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(requestURL, forKey: .requestURL)
        try container.encode(fields, forKey: .fields)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(logoRelativePath, forKey: .logoRelativePath)
        if logoIsManual {
            try container.encode(true, forKey: .logoIsManual)
        }
        try container.encodeIfPresent(tint, forKey: .tint)
    }

    public static func sanitizedURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = url.path.isEmpty ? "/" : url.path
        return components.url?.absoluteString
    }

    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 路径最后一段，供向导默认展示名（`data.remain` → `remain`）。
    public static func defaultDisplayName(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let dot = trimmed.lastIndex(of: ".") {
            let tail = String(trimmed[trimmed.index(after: dot)...])
            return tail.isEmpty ? trimmed : tail
        }
        return trimmed
    }

    public static func normalizedFields(_ fields: [CustomUsageField]) -> [CustomUsageField] {
        var seen = Set<String>()
        var result: [CustomUsageField] = []
        for field in fields {
            guard let path = normalizedPath(field.path), !seen.contains(path) else { continue }
            seen.insert(path)
            let name = field.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(CustomUsageField(
                path: path,
                displayName: name.isEmpty ? defaultDisplayName(for: path) : name,
                role: field.role,
                currency: field.currency
            ))
        }
        return result
    }

    public static func fieldsFromLegacy(
        usedPath: String?,
        balancePath: String?,
        usedLabel: String = "已用",
        balanceLabel: String = "余额"
    ) -> [CustomUsageField] {
        var fields: [CustomUsageField] = []
        if let usedPath {
            fields.append(CustomUsageField(path: usedPath, displayName: usedLabel, role: .used))
        }
        if let balancePath, balancePath != usedPath {
            fields.append(CustomUsageField(path: balancePath, displayName: balanceLabel, role: .remaining))
        }
        return normalizedFields(fields)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, requestURL, fields, usedPath, balancePath, usedLabel, balanceLabel, createdAt
        case logoRelativePath, logoIsManual, tint
    }
}

public struct JSONNumberLeaf: Equatable, Sendable {
    public var path: String
    public var value: Double
    public var rawDisplay: String
    /// 语义推断（角色 / 币种 / 推荐分）。
    public var hint: CustomFieldHint

    public init(path: String, value: Double, rawDisplay: String, hint: CustomFieldHint? = nil) {
        self.path = path
        self.value = value
        self.rawDisplay = rawDisplay
        self.hint = hint ?? CustomFieldSemantics.infer(path: path, value: value, rawText: rawDisplay)
    }
}

public struct CustomJSONPreviewResult: Equatable, Sendable {
    public var leaves: [JSONNumberLeaf]
    public var truncated: Bool
    public var error: String?

    public init(leaves: [JSONNumberLeaf], truncated: Bool, error: String? = nil) {
        self.leaves = leaves
        self.truncated = truncated
        self.error = error
    }
}

/// 把 JSON 拍扁成可选数字叶子，供向导勾选路径。
public enum CustomJSONPreview {
    public static let maxDepth = 8
    public static let maxLeaves = 200
    public static let maxBodyBytes = 1_048_576

    public static func preview(body: String) -> CustomJSONPreviewResult {
        if body.utf8.count > maxBodyBytes {
            return CustomJSONPreviewResult(leaves: [], truncated: true, error: "custom.error.tooLarge")
        }
        guard let json = parseJSON(body) else {
            return CustomJSONPreviewResult(leaves: [], truncated: false, error: "custom.error.notJSON")
        }
        var leaves: [JSONNumberLeaf] = []
        var truncated = false
        walk(json, path: "", depth: 0, leaves: &leaves, truncated: &truncated)
        return CustomJSONPreviewResult(leaves: leaves, truncated: truncated)
    }

    public static func parseJSON(_ body: String) -> Any? {
        if let object = JSONHelp.object(body) { return object }
        if let array = JSONHelp.array(body) { return array }
        return nil
    }

    public static func value(at path: String, in json: Any) -> Any? {
        guard let tokens = tokenize(path) else { return nil }
        var current: Any = json
        for token in tokens {
            switch token {
            case .key(let key):
                guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    private enum PathToken {
        case key(String)
        case index(Int)
    }

    private static func tokenize(_ path: String) -> [PathToken]? {
        var tokens: [PathToken] = []
        var index = path.startIndex
        while index < path.endIndex {
            if path[index] == "[" {
                guard let close = path[index...].firstIndex(of: "]") else { return nil }
                let inner = path[path.index(after: index)..<close]
                guard let arrayIndex = Int(inner) else { return nil }
                tokens.append(.index(arrayIndex))
                index = path.index(after: close)
                if index < path.endIndex, path[index] == "." {
                    index = path.index(after: index)
                }
            } else {
                let rest = path[index...]
                let end = rest.firstIndex(where: { $0 == "." || $0 == "[" }) ?? path.endIndex
                let key = String(path[index..<end])
                guard !key.isEmpty else { return nil }
                tokens.append(.key(key))
                index = end
                if index < path.endIndex, path[index] == "." {
                    index = path.index(after: index)
                }
            }
        }
        return tokens
    }

    private static func walk(
        _ any: Any,
        path: String,
        depth: Int,
        leaves: inout [JSONNumberLeaf],
        truncated: inout Bool
    ) {
        if leaves.count >= maxLeaves {
            truncated = true
            return
        }
        if depth > maxDepth {
            truncated = true
            return
        }
        if isBooleanLeaf(any) { return }

        if let dict = any as? [String: Any] {
            for key in dict.keys.sorted() {
                guard let value = dict[key] else { continue }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if isNumberLeaf(value) {
                    appendLeaf(value, path: childPath, siblings: dict, leaves: &leaves, truncated: &truncated)
                } else {
                    walk(value, path: childPath, depth: depth + 1, leaves: &leaves, truncated: &truncated)
                }
            }
        } else if let array = any as? [Any] {
            for (offset, value) in array.enumerated() {
                let childPath = "\(path)[\(offset)]"
                if isNumberLeaf(value) {
                    appendLeaf(value, path: childPath, leaves: &leaves, truncated: &truncated)
                } else {
                    walk(value, path: childPath, depth: depth + 1, leaves: &leaves, truncated: &truncated)
                }
            }
        }
    }

    private static func appendLeaf(
        _ value: Any,
        path: String,
        siblings: [String: Any]? = nil,
        leaves: inout [JSONNumberLeaf],
        truncated: inout Bool
    ) {
        if leaves.count >= maxLeaves {
            truncated = true
            return
        }
        guard let number = leafNumber(value) else { return }
        let raw = rawDisplay(value, number: number)
        let hint = CustomFieldSemantics.infer(path: path, value: number, rawText: raw, siblings: siblings)
        leaves.append(JSONNumberLeaf(path: path, value: number, rawDisplay: raw, hint: hint))
    }

    /// 数字、宽松数字字符串，或能被 `JSONHelp.date` 认下的 ISO 时间（值写成 epoch 秒）。
    /// ISO 不得走 `lenientNumber`，避免 `"2026-09-01T…"` 收成 2026。
    public static func leafNumber(_ value: Any) -> Double? {
        if let number = JSONHelp.double(value) { return number }
        if let text = value as? String {
            if CustomFieldSemantics.lenientNumber(text) == nil,
               let date = JSONHelp.date(text) {
                return date.timeIntervalSince1970
            }
            return CustomFieldSemantics.lenientNumber(text)
        }
        return nil
    }

    private static func rawDisplay(_ value: Any, number: Double) -> String {
        if let text = value as? String { return text }
        if let intValue = value as? Int { return String(intValue) }
        if let exact = JSONHelp.intExactly(number) {
            return String(exact)
        }
        return String(number)
    }

    private static func isNumberLeaf(_ any: Any) -> Bool {
        if isBooleanLeaf(any) { return false }
        if any is [String: Any] || any is [Any] { return false }
        return leafNumber(any) != nil
    }

    private static func isBooleanLeaf(_ any: Any) -> Bool {
        if any is Bool { return true }
        if let number = any as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return false
    }
}

/// 自定义用量解析。401/403 只标 needsLogin、metrics 为空；保留旧数字在刷新层合成。
public enum CustomUsageParser {
    public static func parse(
        status: Int,
        body: String,
        template: CustomUsageTemplate,
        now: Date = Date()
    ) -> ProviderSnapshot {
        if status == 401 || status == 403 {
            return snapshot(status: .needsLogin, metrics: [], now: now)
        }
        if !(200..<300).contains(status) {
            return snapshot(status: .error(httpErrorMessage(status, body: body)), metrics: [], now: now)
        }
        guard let json = CustomJSONPreview.parseJSON(body) else {
            return snapshot(status: .error("custom.error.notJSON"), metrics: [], now: now)
        }
        var metrics: [UsageMetric] = []
        for field in template.fields {
            if field.role == .timestamp {
                guard let raw = CustomJSONPreview.value(at: field.path, in: json) else { continue }
                if let date = JSONHelp.date(raw) {
                    metrics.append(timestampMetric(for: field, date: date, in: template.fields))
                } else if let kept = keptTimestampMetric(for: field, raw: raw, in: template.fields) {
                    metrics.append(kept)
                }
                continue
            }
            guard let amount = amount(at: field.path, in: json) else { continue }
            metrics.append(metric(for: field, amount: amount, in: template.fields, json: json))
        }
        if metrics.isEmpty {
            return snapshot(status: .error("custom.error.unreadable"), metrics: [], now: now)
        }
        return snapshot(status: .ok, metrics: metrics, now: now)
    }

    /// 按角色产出指标：百分比 → `displayValue: "42%"`；时间戳 → `resetsAt`；
    /// 金额带币种。`usedPercent` 恒 nil（不触发阈值提醒）。
    static func metric(for field: CustomUsageField, amount: Double, in fields: [CustomUsageField], json: Any) -> UsageMetric {
        let role = field.role ?? .other
        var currency = field.currency
        if currency == nil, let raw = CustomJSONPreview.value(at: field.path, in: json) as? String {
            currency = CustomFieldSemantics.currencyFromText(raw)
        }
        switch role {
        case .percent:
            return UsageMetric(
                id: metricID(for: field, in: fields), label: field.displayName,
                amount: amount, pinned: true,
                displayValue: CustomUsageDisplay.percentText(amount), kind: role.rawValue
            )
        case .remaining where isRemainingPercent(field: field, amount: amount, json: json):
            return UsageMetric(
                id: metricID(for: field, in: fields), label: field.displayName,
                amount: amount, pinned: true,
                displayValue: CustomUsageDisplay.percentText(amount), kind: role.rawValue
            )
        case .timestamp:
            if let raw = CustomJSONPreview.value(at: field.path, in: json) {
                if let date = JSONHelp.date(raw) {
                    return timestampMetric(for: field, date: date, amount: amount, in: fields)
                }
                return keptTimestampMetric(for: field, raw: raw, in: fields)
                    ?? UsageMetric(
                        id: metricID(for: field, in: fields), label: field.displayName,
                        amount: amount, pinned: true, kind: role.rawValue
                    )
            }
            return UsageMetric(
                id: metricID(for: field, in: fields), label: field.displayName,
                amount: amount, pinned: true, kind: role.rawValue
            )
        default:
            return UsageMetric(
                id: metricID(for: field, in: fields), label: field.displayName,
                amount: amount, currency: currency, pinned: true,
                kind: field.role?.rawValue
            )
        }
    }

    private static func timestampMetric(
        for field: CustomUsageField,
        date: Date,
        amount: Double? = nil,
        in fields: [CustomUsageField]
    ) -> UsageMetric {
        UsageMetric(
            id: metricID(for: field, in: fields),
            label: field.displayName,
            resetsAt: date,
            amount: amount ?? date.timeIntervalSince1970,
            pinned: true,
            kind: CustomFieldRole.timestamp.rawValue
        )
    }

    /// 越界 / 无法解析的 timestamp：保留原值，不写 `resetsAt`。
    private static func keptTimestampMetric(
        for field: CustomUsageField,
        raw: Any,
        in fields: [CustomUsageField]
    ) -> UsageMetric? {
        let amount = CustomJSONPreview.leafNumber(raw)
        let display = raw as? String
        if amount == nil && (display == nil || display?.isEmpty == true) {
            return nil
        }
        return UsageMetric(
            id: metricID(for: field, in: fields),
            label: field.displayName,
            amount: amount,
            pinned: true,
            displayValue: display,
            kind: CustomFieldRole.timestamp.rawValue
        )
    }

    /// 默认用 path。只有展示名就是「余额」/ 各语言余额默认名时才写成 `balance`。
    /// 唯一 `remaining` 但名叫「剩余请求」不得冒充预充值余额。
    private static func metricID(for field: CustomUsageField, in fields: [CustomUsageField]) -> String {
        let name = field.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CustomUsageDisplay.matchesPrepaidLabel(name) else { return field.path }
        let remaining = fields.filter { $0.role == .remaining }
        if fields.count == 1 { return "balance" }
        if field.role == .remaining, remaining.count == 1 { return "balance" }
        return field.path
    }

    /// 路径或原文是剩余占比时，按百分比展示，不能当剩余次数去和上限配对。
    private static func isRemainingPercent(field: CustomUsageField, amount: Double, json: Any) -> Bool {
        let raw = CustomJSONPreview.value(at: field.path, in: json) as? String
        let hint = CustomFieldSemantics.infer(path: field.path, value: amount, rawText: raw)
        return hint.role == .remaining && hint.isPercentString
    }

    private static func amount(at path: String, in json: Any) -> Double? {
        guard let value = CustomJSONPreview.value(at: path, in: json) else { return nil }
        return CustomJSONPreview.leafNumber(value)
    }

    private static func httpErrorMessage(_ status: Int, body: String = "") -> String {
        if status <= 0 {
            switch body.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "证书不受信任", "明文被拦", "超时", "无网络":
                return body.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                return "custom.error.requestFailed"
            }
        }
        return "HTTP \(status)"
    }

    private static func snapshot(
        status: SnapshotStatus,
        metrics: [UsageMetric],
        now: Date
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .claude,
            metrics: metrics,
            fetchedAt: now,
            status: status,
            isCustom: true
        )
    }
}

/// 自定义刷新提交：RefreshPolicy + 401/403 合成旧数字（D5）。
public enum CustomUsageRefresh {
    public static let resultKey = "usage"

    public static func results(from probe: ProbeResult) -> [String: ProbeResult] {
        [resultKey: probe]
    }

    public static func synthesizedNeedsLogin(old: ProviderSnapshot?, now: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .claude,
            planName: old?.planName,
            metrics: old?.metrics ?? [],
            fetchedAt: old?.fetchedAt ?? now,
            status: .needsLogin,
            currency: old?.currency,
            isCustom: true
        )
    }

    public static func commit(
        old: ProviderSnapshot?,
        parsed: ProviderSnapshot,
        results: [String: ProbeResult],
        now: Date = Date()
    ) -> ProviderSnapshot? {
        guard RefreshPolicy.shouldCommit(old: old, new: parsed, results: results) else {
            return nil
        }
        if parsed.status.isNeedsLogin {
            return synthesizedNeedsLogin(old: old, now: now)
        }
        return parsed
    }

    public static func diagnosticLine(templateName: String, host: String, status: Int, bytes: Int) -> String {
        "custom.\(templateName): HTTP \(status)，\(bytes) 字节 host=\(host)"
    }

    /// 取 token、发 GET、解析并按 D5 决定是否提交。不写 store。
    public static func perform(
        template: CustomUsageTemplate,
        token: String?,
        old: ProviderSnapshot?,
        client: CustomUsageClient,
        now: Date = Date()
    ) async -> (snapshot: ProviderSnapshot, didCommit: Bool, diagnostic: String) {
        let host = URL(string: template.requestURL).map(CustomUsageClient.diagnosticHost(from:)) ?? template.requestHost
        guard let token, !token.isEmpty, let url = URL(string: template.requestURL) else {
            let parsed = ProviderSnapshot(
                provider: .claude, fetchedAt: now, status: .needsLogin, isCustom: true
            )
            let results = results(from: ProbeResult(status: 401, body: ""))
            let committed = commit(old: old, parsed: parsed, results: results, now: now) ?? parsed
            return (
                committed,
                true,
                diagnosticLine(templateName: template.name, host: host, status: 401, bytes: 0)
            )
        }
        let probe = await client.fetch(url: url, token: token)
        let parsed = CustomUsageParser.parse(
            status: probe.status, body: probe.body, template: template, now: now
        )
        let line = diagnosticLine(
            templateName: template.name,
            host: host,
            status: probe.status,
            bytes: probe.body.utf8.count
        )
        if let next = commit(old: old, parsed: parsed, results: results(from: probe), now: now) {
            return (next, true, line)
        }
        return (old ?? parsed, false, line)
    }
}

import Foundation

/// grok.com 用量周期类型（`currentPeriod.type`）。指标标签跟着它走，不再写死「本周限额」。
public enum GrokUsagePeriod: String, Equatable, Sendable {
    case daily
    case weekly
    case monthly

    public var metricLabel: String {
        switch self {
        case .daily: return "今日限额"
        case .weekly: return "本周限额"
        case .monthly: return "本月限额"
        }
    }

    /// `USAGE_PERIOD_TYPE_WEEKLY` 这类枚举名，只做大写子串匹配。
    /// 不认 `DAY`（`SEVEN_DAY` 之类会被误判成日额度），只认 `DAILY`。
    static func parse(_ raw: String?) -> GrokUsagePeriod? {
        guard let raw, !raw.isEmpty else { return nil }
        let key = raw.uppercased()
        if key.contains("DAILY") { return .daily }
        if key.contains("WEEK") { return .weekly }
        if key.contains("MONTH") { return .monthly }
        return nil
    }

    /// 没有 type 字段时按周期长度推断：4–12 天算周，20–45 天算月，其余不下结论。
    static func infer(start: Date?, end: Date?) -> GrokUsagePeriod? {
        guard let start, let end else { return nil }
        let days = end.timeIntervalSince(start) / 86400
        if days >= 4, days <= 12 { return .weekly }
        if days >= 20, days <= 45 { return .monthly }
        return nil
    }
}

/// weekly（gRPC-Web）探针的结果码判定。gRPC 的错误不体现在 HTTP 状态上，
/// HTTP 200 也可能整条失败，真正的结果码在响应头或 trailer 帧里。
public enum GrokGRPCOutcome: Equatable, Sendable {
    /// 状态 0 / 无状态字段。
    case ok
    /// 16 + `no-credentials`：端点要求浏览器密钥交换（WKE），裸 fetch 带不上。**不判未登录**。
    case needsBrowserKey
    /// 7 + `bad-credentials` / `unauthenticated` / `could not be validated`：
    /// 只作为 weekly 探针自身的未登录证据，卡片登录态仍以 `/rest/*` 为准。
    case needsLogin
    /// 9 + `no personal team`：团队账号没有个人计费主体，周额度不可用。
    case noPersonalTeam
    /// 其它非 0 状态。
    case failed
}

/// weekly 探针的 gRPC 状态与人读诊断文案。UI 不消费，只进探针诊断日志与测试。
public struct GrokGRPCStatus: Equatable, Sendable {
    public var code: Int
    public var message: String
    public var outcome: GrokGRPCOutcome
    public var note: String

    public init(code: Int, message: String, outcome: GrokGRPCOutcome, note: String) {
        self.code = code
        self.message = message
        self.outcome = outcome
        self.note = note
    }

    /// 状态非 0 时都不该继续解析 payload：trailer-only 的响应里没有可用数据。
    public var blocksParsing: Bool { outcome != .ok }
}

/// grok.com Settings → Usage 的共享周额度（GetGrokCreditsConfig / gRPC-Web protobuf）。
public struct GrokWeeklyCredits: Equatable, Sendable {
    /// 已用百分比。**报文里没有就是 nil，绝不用 0 顶替**（0% 和「还没用」在 UI 上分不开）。
    public var usagePercent: Double?
    public var resetsAt: Date?
    public var products: [GrokWeeklyProduct]
    /// 百分比是否真的在报文里出现过。false = 只有周期、没有百分比。
    public var percentIsWirePublished: Bool
    /// 周期类型：`currentPeriod.type` → 长度推断 → 默认按周。
    public var period: GrokUsagePeriod
    /// 周期起点，用于推断周期类型。
    public var periodStart: Date?

    public init(
        usagePercent: Double?,
        resetsAt: Date? = nil,
        products: [GrokWeeklyProduct] = [],
        percentIsWirePublished: Bool? = nil,
        period: GrokUsagePeriod = .weekly,
        periodStart: Date? = nil
    ) {
        self.usagePercent = usagePercent
        self.resetsAt = resetsAt
        self.products = products
        self.percentIsWirePublished = percentIsWirePublished ?? (usagePercent != nil)
        self.period = period
        self.periodStart = periodStart
    }
}

public struct GrokWeeklyProduct: Equatable, Sendable {
    public var code: Int
    public var usagePercent: Double
    public var rawName: String?

    public init(code: Int, usagePercent: Double, rawName: String? = nil) {
        self.code = code
        self.usagePercent = usagePercent
        self.rawName = rawName
    }

    /// 与 grok.com Settings → Usage 一致：Grok Build / Imagine / Chat 等官网用词。
    public var label: String {
        if let rawName, let mapped = Self.label(forName: rawName) {
            return mapped
        }
        return Self.label(forCode: code)
    }

    static func label(forCode code: Int) -> String {
        switch code {
        case 0: return "第三方"
        case 1: return "API"
        case 2: return "Grok Build"
        case 3: return "插件"
        case 4: return "Chat"
        case 5: return "Imagine"
        case 6: return "Voice"
        // 网页 Usage 页 "App Builder"（iOS 端本地化为「应用构建器」），与 code 2 的 Grok Build（编码 agent）是两个产品
        case 7: return "App Builder"
        default: return "分类 \(code)"
        }
    }

    static func label(forName name: String) -> String? {
        let key = name.uppercased().replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if key.contains("IMAGINE") { return "Imagine" }
        if key.contains("VOICE") || key.contains("语音") { return "Voice" }
        if key.contains("CHAT") || key.contains("聊天") { return "Chat" }
        // 先判 App Builder，否则 "APPBUILDER" 会被下面的 BUILD 吃掉
        if key.contains("APPBUILDER") || key.contains("应用构建") { return "App Builder" }
        if key.contains("BUILD") { return "Grok Build" }
        if key.contains("PLUGIN") || key.contains("插件") { return "插件" }
        if key.contains("API") { return "API" }
        return nil
    }

    static func code(forName name: String) -> Int {
        let key = name.uppercased().replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if key.contains("IMAGINE") { return 5 }
        if key.contains("VOICE") || key.contains("语音") { return 6 }
        if key.contains("CHAT") || key.contains("聊天") { return 4 }
        if key.contains("APPBUILDER") || key.contains("应用构建") { return 7 }
        if key.contains("BUILD") { return 2 }
        if key.contains("PLUGIN") || key.contains("插件") { return 3 }
        if key.contains("API") { return 1 }
        return 0
    }
}

public enum GrokWeeklyParser {
    // MARK: - gRPC 状态

    /// 合并响应头与 trailer 帧里的 `grpc-*` 字段（trailer 优先），给出结果码判定。
    /// 返回 nil 表示没有状态字段或状态为 0（正常）。
    public static func grpcStatus(headers: [String: String]?, data: Data?) -> GrokGRPCStatus? {
        var fields: [String: String] = [:]
        for (key, value) in headers ?? [:] {
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name.hasPrefix("grpc-") else { continue }
            fields[name] = decode(value)
        }
        if let data {
            for (key, value) in trailerFields(in: data) { fields[key] = value }
        }
        guard let raw = fields["grpc-status"], let code = Int(raw.trimmingCharacters(in: .whitespaces)),
              code != 0 else { return nil }
        let message = fields["grpc-message"] ?? ""
        let lower = message.lowercased()
        if code == 16, lower.contains("no-credentials") || lower.contains("no credentials") {
            return GrokGRPCStatus(code: code, message: message, outcome: .needsBrowserKey,
                                  note: "该端点需要浏览器密钥（WKE），Cookie 登录不够")
        }
        if code == 7, lower.contains("bad-credentials") || lower.contains("unauthenticated")
            || lower.contains("could not be validated") {
            return GrokGRPCStatus(code: code, message: message, outcome: .needsLogin,
                                  note: "grok.com 凭据失效，weekly 探针需要重新登录")
        }
        if code == 9, lower.contains("no personal team") {
            return GrokGRPCStatus(code: code, message: message, outcome: .noPersonalTeam,
                                  note: "该账号无个人计费主体（team 账号），周额度不可用")
        }
        let tail = message.isEmpty ? "" : "：\(message)"
        return GrokGRPCStatus(code: code, message: message, outcome: .failed,
                              note: "gRPC 状态 \(code)\(tail)")
    }

    /// 探针 body 是 base64（weekly 走 arrayBuffer），解不出来就当没有 trailer。
    public static func grpcStatus(headers: [String: String]?, base64Body: String) -> GrokGRPCStatus? {
        grpcStatus(headers: headers, data: decodeBase64(base64Body))
    }

    static func decodeBase64(_ body: String) -> Data? {
        let compact = body.replacingOccurrences(of: "\n", with: "")
        return Data(base64Encoded: compact) ?? Data(base64Encoded: body)
    }

    private static func decode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.removingPercentEncoding ?? trimmed
    }

    /// trailer 帧（flag 字节 `0x80`）里是 `key: value` 的文本行。
    private static func trailerFields(in data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        var index = data.startIndex
        while index + 5 <= data.endIndex {
            let flags = data[index]
            let length = Int(data[index + 1]) << 24
                | Int(data[index + 2]) << 16
                | Int(data[index + 3]) << 8
                | Int(data[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= data.endIndex else { break }
            if flags & 0x80 != 0, let text = String(data: data[start..<end], encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    fields[key] = decode(String(line[line.index(after: separator)...]))
                }
            }
            index = end
        }
        return fields
    }

    // MARK: - protobuf / JSON

    public static func parse(data: Data, now: Date = Date()) -> GrokWeeklyCredits? {
        let payloads = grpcWebPayloads(in: data)
        let candidates = payloads.isEmpty ? [data] : payloads
        var exact: GrokWeeklyCredits?
        for payload in candidates {
            if let credits = parseMessage(payload) { exact = credits; break }
        }
        if let exact, exact.usagePercent != nil { return exact }

        // 精确解析没拿到百分比：字段号可能漂了，按 CodexBar 的通用扫描再兜一层。
        let scan = genericScan(candidates, now: now)
        guard scan.percent != nil || scan.reset != nil else { return exact }
        var merged = exact ?? GrokWeeklyCredits(usagePercent: nil)
        if merged.usagePercent == nil, let percent = scan.percent {
            merged.usagePercent = percent
            merged.percentIsWirePublished = true
        }
        if merged.resetsAt == nil { merged.resetsAt = scan.reset }
        if merged.usagePercent == nil, merged.resetsAt == nil { return exact }
        // proto3 不上线默认值：报文里有周期、精确解析和通用扫描都找不到百分比，就是官网的 0%（真机：
        // 本周还没用过时报文只剩 currentPeriod，之前当「未知」隐藏，卡片看起来像没加载）。
        if merged.usagePercent == nil, merged.resetsAt != nil {
            merged.usagePercent = 0
            merged.percentIsWirePublished = false
        }
        merged.period = GrokUsagePeriod.infer(start: merged.periodStart, end: merged.resetsAt) ?? merged.period
        return merged
    }

    public static func parse(json body: String) -> GrokWeeklyCredits? {
        guard let dict = JSONHelp.object(body) else { return nil }
        let config = (dict["config"] as? [String: Any]) ?? dict
        let percent = percent(config["creditUsagePercent"])
            ?? percent(config["usagePercent"])
        let period = config["currentPeriod"] as? [String: Any]
        let resets = JSONHelp.date(config["resetsAt"])
            ?? JSONHelp.date(config["billingPeriodEnd"])
            ?? JSONHelp.date(period?["end"])
        let periodStart = JSONHelp.date(config["billingPeriodStart"])
            ?? JSONHelp.date(period?["start"])
        var products: [GrokWeeklyProduct] = []
        let rawProducts = (config["productUsage"] as? [Any]) ?? (config["products"] as? [Any]) ?? []
        for item in rawProducts.compactMap({ $0 as? [String: Any] }) {
            if let product = parseProductJSON(item) {
                products.append(product)
            }
        }
        guard percent != nil || resets != nil else { return nil }
        let kind = GrokUsagePeriod.parse(JSONHelp.string(period?["type"]))
            ?? GrokUsagePeriod.parse(JSONHelp.string(config["periodType"]))
            ?? GrokUsagePeriod.infer(start: periodStart, end: resets)
            ?? .weekly
        // 只有周期没有百分比：usagePercent 保持 nil，由展示层按 hasUsage 隐藏，绝不落成 0%。
        return GrokWeeklyCredits(
            usagePercent: percent,
            resetsAt: resets,
            products: products,
            percentIsWirePublished: percent != nil,
            period: kind,
            periodStart: periodStart
        )
    }

    private static func parseProductJSON(_ item: [String: Any]) -> GrokWeeklyProduct? {
        let productPercent: Double
        if item.keys.contains("usagePercent") {
            guard let value = percent(item["usagePercent"]) else { return nil }
            productPercent = value
        } else {
            productPercent = 0
        }
        if let name = JSONHelp.string(item["product"]) ?? JSONHelp.string(item["name"]),
           name.rangeOfCharacter(from: .decimalDigits) == nil || name.contains("PRODUCT") || name.contains("Grok") {
            return GrokWeeklyProduct(code: GrokWeeklyProduct.code(forName: name), usagePercent: productPercent, rawName: name)
        }
        if let code = JSONHelp.double(item["code"]) ?? JSONHelp.double(item["product"]) {
            guard let code = JSONHelp.intExactly(code) else { return nil }
            return GrokWeeklyProduct(code: code, usagePercent: productPercent)
        }
        return nil
    }

    private static func percent(_ raw: Any?) -> Double? {
        guard let value = JSONHelp.double(raw), (0...100).contains(value) else { return nil }
        return value
    }

    private static func grpcWebPayloads(in data: Data) -> [Data] {
        var payloads: [Data] = []
        var index = data.startIndex
        while index + 5 <= data.endIndex {
            let flags = data[index]
            let length = Int(data[index + 1]) << 24
                | Int(data[index + 2]) << 16
                | Int(data[index + 3]) << 8
                | Int(data[index + 4])
            let start = index + 5
            let end = start + length
            guard end <= data.endIndex, length >= 0 else { break }
            if flags & 0x80 == 0 {
                payloads.append(data[start..<end])
            }
            index = end
        }
        return payloads
    }

    private static func parseMessage(_ data: Data) -> GrokWeeklyCredits? {
        let fields = readFields(data)
        if let nested = fields.first(where: { $0.number == 1 && $0.wire == 2 })?.bytes,
           let credits = parseConfig(nested) {
            return credits
        }
        return parseConfig(data)
    }

    private static func parseConfig(_ data: Data) -> GrokWeeklyCredits? {
        let fields = readFields(data)
        var used: Double?
        var reset: Date?
        var periodStart: Date?
        var products: [GrokWeeklyProduct] = []
        for field in fields {
            switch (field.number, field.wire) {
            case (1, 5):
                if let value = field.float, value.isFinite, (0...100).contains(value) {
                    used = Double(value)
                }
            case (5, 2):
                reset = parseTimestamp(field.bytes ?? Data())
            case (7, 2):
                if let product = parseProduct(field.bytes ?? Data()) {
                    products.append(product)
                }
            case (8, 2):
                let period = parseCurrentPeriod(field.bytes ?? Data())
                if periodStart == nil { periodStart = period.start }
                if reset == nil { reset = period.end }
            default:
                break
            }
        }
        // 缺百分比但有周期：返回 nil 百分比 + percentIsWirePublished = false，不当 0。
        guard used != nil || reset != nil else { return nil }
        return GrokWeeklyCredits(
            usagePercent: used,
            resetsAt: reset,
            products: products,
            percentIsWirePublished: used != nil,
            period: GrokUsagePeriod.infer(start: periodStart, end: reset) ?? .weekly,
            periodStart: periodStart
        )
    }

    private static func parseProduct(_ data: Data) -> GrokWeeklyProduct? {
        let fields = readFields(data)
        var code: Int?
        var percent: Double?
        for field in fields {
            if field.number == 1, let value = field.varint {
                code = Int(exactly: value)
            }
            if field.number == 2, field.wire == 5, let value = field.float, (0...100).contains(value) {
                percent = Double(value)
            }
        }
        guard let code, let percent else { return nil }
        return GrokWeeklyProduct(code: code, usagePercent: percent)
    }

    static func parseTimestamp(_ data: Data) -> Date? {
        let fields = readFields(data)
        guard let seconds = fields.first(where: { $0.number == 1 })?.varint, seconds > 0 else { return nil }
        let nanos = fields.first(where: { $0.number == 2 })?.varint ?? 0
        return JSONHelp.date(Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    /// currentPeriod：field 1 = 类型枚举（数值语义未确认，不用它猜周/月）、
    /// field 2 = 起点 Timestamp、field 3 = 结束 Timestamp。
    private static func parseCurrentPeriod(_ data: Data) -> (start: Date?, end: Date?) {
        let fields = readFields(data)
        let start = fields.first(where: { $0.number == 2 && $0.wire == 2 })?.bytes.flatMap(parseTimestamp)
        let end = fields.first(where: { $0.number == 3 && $0.wire == 2 })?.bytes.flatMap(parseTimestamp)
        return (start, end)
    }

    // MARK: - 通用扫描回退

    private struct ScanFloat {
        var path: [UInt64]
        var value: Float
        var order: Int
    }

    private struct ScanVarint {
        var path: [UInt64]
        var value: UInt64
    }

    private struct Scan {
        var floats: [ScanFloat] = []
        var varints: [ScanVarint] = []

        mutating func merge(_ other: Scan) {
            floats.append(contentsOf: other.floats)
            varints.append(contentsOf: other.varints)
        }
    }

    /// 不认字段号，整棵报文里找「像百分比的 fixed32」与「像 Unix 秒的 varint」。
    private static func genericScan(_ payloads: [Data], now: Date) -> (percent: Double?, reset: Date?) {
        var scan = Scan()
        for payload in payloads {
            scan.merge(scanProtobuf(payload, depth: 0, path: [], order: 0).scan)
        }
        let percent = scan.floats
            .filter { $0.path.last == 1 && $0.value.isFinite && $0.value >= 0 && $0.value <= 100 }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }
        let stamps = scan.varints.compactMap { field -> (path: [UInt64], date: Date)? in
            guard field.value >= 1_700_000_000, field.value <= 2_100_000_000 else { return nil }
            guard let date = JSONHelp.date(Double(field.value)) else { return nil }
            return (field.path, date)
        }
        let future = stamps.filter { $0.date > now }
        let reset = future.filter { $0.path == [1, 5, 1] }.map(\.date).min()
            ?? future.map(\.date).min()
        return (percent, reset)
    }

    private static func scanProtobuf(
        _ data: Data, depth: Int, path: [UInt64], order: Int
    ) -> (scan: Scan, order: Int) {
        var scan = Scan()
        var index = data.startIndex
        var nextOrder = order
        while index < data.endIndex {
            let fieldStart = index
            guard let key = readVarint(data, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let number = key >> 3
            let wire = key & 0x07
            let fieldPath = path + [number]
            switch wire {
            case 0:
                if let value = readVarint(data, index: &index) {
                    scan.varints.append(ScanVarint(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= data.endIndex else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = readVarint(data, index: &index),
                      length <= UInt64(data.endIndex - index) else {
                    index = fieldStart + 1
                    continue
                }
                guard let count = Int(exactly: length) else {
                    index = fieldStart + 1
                    continue
                }
                let end = index + count
                if depth < 4 {
                    let nested = scanProtobuf(data[index..<end], depth: depth + 1, path: fieldPath, order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= data.endIndex else { return (scan, nextOrder) }
                let bits = UInt32(data[index])
                    | UInt32(data[index + 1]) << 8
                    | UInt32(data[index + 2]) << 16
                    | UInt32(data[index + 3]) << 24
                scan.floats.append(ScanFloat(path: fieldPath, value: Float(bitPattern: bits), order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }
        return (scan, nextOrder)
    }

    struct ProtoField {
        var number: UInt64
        var wire: UInt64
        var varint: UInt64?
        var float: Float?
        var bytes: Data?
    }

    static func readFields(_ data: Data) -> [ProtoField] {
        var fields: [ProtoField] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = readVarint(data, index: &index) else { break }
            let number = key >> 3
            let wire = key & 0x07
            var field = ProtoField(number: number, wire: wire)
            switch wire {
            case 0:
                field.varint = readVarint(data, index: &index)
            case 1:
                guard index + 8 <= data.endIndex else { return fields }
                index += 8
            case 2:
                guard let length = readVarint(data, index: &index),
                      let count = Int(exactly: length) else { return fields }
                let end = index + count
                guard end <= data.endIndex else { return fields }
                field.bytes = data[index..<end]
                index = end
            case 5:
                guard index + 4 <= data.endIndex else { return fields }
                let bits = UInt32(data[index])
                    | UInt32(data[index + 1]) << 8
                    | UInt32(data[index + 2]) << 16
                    | UInt32(data[index + 3]) << 24
                field.float = Float(bitPattern: bits)
                index += 4
            default:
                return fields
            }
            fields.append(field)
        }
        return fields
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

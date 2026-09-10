import Foundation

/// grok.com「Usage Limit Reset」的只读摘要：一次性重置券的可用张数与到期时间。
///
/// **绝不保存 `token_id`** —— 它是 `RedeemReset` 的兑换凭据，快照里只留数字与日期。
/// 探针同样只读，不兑换、不购买。
public struct GrokUsageResets: Codable, Equatable, Sendable {
    /// 未过期的重置券张数。0 也是有效结论（官网照样显示「Reset Available」区块的总数）。
    public var availableCount: Int?
    /// 最近一张的到期时间，与官网 "the next expires on {date}" 同口径。
    public var expiresAt: Date?
    /// 全部到期时间，正序。缺失或无效的日期不编造，宁可少一行。
    public var availableExpirations: [Date]?

    public init(availableCount: Int? = nil, expiresAt: Date? = nil, availableExpirations: [Date]? = nil) {
        self.availableCount = availableCount
        self.expiresAt = expiresAt
        self.availableExpirations = availableExpirations
    }

    public var isValid: Bool {
        (availableCount.map { $0 >= 0 } ?? true)
            && (expiresAt.map(JSONHelp.isSafeDate) ?? true)
            && (availableExpirations ?? []).allSatisfy(JSONHelp.isSafeDate)
    }

    /// 两条服务的字段号（取自 grok.com 自带的 proto 描述符，不是猜测）。
    /// 官网按 `ENABLE_BILLING_FACADE` 二选一，标志值看不到，所以两条都打、谁给出 token 用谁。
    private struct Schema {
        /// 响应里 `tokens` 的字段号。
        var list: UInt64
        /// `ResetToken.token_id`。
        var id: UInt64
        /// `ResetToken.validity_end`。
        var end: UInt64
    }

    /// `resets` = `prod_mc_billing.ConsumerUiSvc`（默认分支），`resets_facade` = `grok_api_v2.GrokBuildBilling`。
    private static let schemas: [(probe: String, schema: Schema)] = [
        ("resets", Schema(list: 10, id: 10, end: 30)),
        ("resets_facade", Schema(list: 1, id: 1, end: 3)),
    ]

    static func parse(results: [String: ProbeResult], now: Date) -> Self? {
        for (name, schema) in schemas {
            guard let probe = results[name], probe.isOK, !probe.body.isEmpty else { continue }
            // gRPC 的错误不体现在 HTTP 状态上；非 0 状态的响应里没有可用数据，硬解会产出垃圾次数。
            if let status = GrokWeeklyParser.grpcStatus(headers: probe.headers, base64Body: probe.body),
               status.blocksParsing { continue }
            guard let data = GrokWeeklyParser.decodeBase64(probe.body),
                  let payload = completePayload(in: data),
                  let fields = completeFields(in: payload) else { continue }
            // 空 protobuf 消息明确表示空列表；非空却没有已知列表字段是形状漂移。
            guard payload.isEmpty || fields.contains(where: { $0.number == schema.list && $0.wire == 2 }) else { continue }
            let dates = expirations(in: fields, schema: schema, now: now).sorted()
            return Self(
                availableCount: dates.count,
                expiresAt: dates.first,
                availableExpirations: dates.isEmpty ? nil : dates
            )
        }
        return nil
    }

    /// 与官网前端同一套过滤：丢掉空 `token_id`、缺 `validity_end`、已过期的条目，同 id 只算一次。
    private static func expirations(in response: [GrokWeeklyParser.ProtoField], schema: Schema, now: Date) -> [Date] {
        var seen = Set<String>()
        var dates: [Date] = []
        for field in response
        where field.number == schema.list && field.wire == 2 {
            guard let token = field.bytes, let fields = completeFields(in: token) else { continue }
            guard let idBytes = fields.first(where: { $0.number == schema.id && $0.wire == 2 })?.bytes,
                  let id = String(data: idBytes, encoding: .utf8), !id.isEmpty else { continue }
            guard let endBytes = fields.first(where: { $0.number == schema.end && $0.wire == 2 })?.bytes,
                  completeFields(in: endBytes) != nil,
                  let end = GrokWeeklyParser.parseTimestamp(endBytes), end > now else { continue }
            guard seen.insert(id).inserted else { continue }
            dates.append(end)
        }
        return dates
    }

    /// Unary gRPC 必须只有一个完整、未压缩的数据帧；不把半包或压缩字节当成空列表。
    private static func completePayload(in data: Data) -> Data? {
        var index = data.startIndex
        var payload: Data?
        while index < data.endIndex {
            guard data.endIndex - index >= 5 else { return nil }
            let flag = data[index]
            guard flag == 0 || flag == 0x80 else { return nil }
            let length = Int(data[index + 1]) << 24 | Int(data[index + 2]) << 16
                | Int(data[index + 3]) << 8 | Int(data[index + 4])
            index += 5
            guard length <= data.endIndex - index else { return nil }
            if flag == 0 {
                guard payload == nil else { return nil }
                payload = Data(data[index..<(index + length)])
            }
            index += length
        }
        return payload
    }

    /// 周额度解析器允许保留已读字段；重置次数须先验证整条消息，避免截断后误报零。
    private static func completeFields(in data: Data) -> [GrokWeeklyParser.ProtoField]? {
        var index = data.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < data.endIndex else { return nil }
                let byte = data[index]
                index += 1
                guard shift < 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        while index < data.endIndex {
            guard let key = varint(), key >> 3 > 0 else { return nil }
            let count: Int
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
                continue
            case 1: count = 8
            case 2:
                guard let length = varint(), let exact = Int(exactly: length) else { return nil }
                count = exact
            case 5: count = 4
            default: return nil
            }
            guard count <= data.endIndex - index else { return nil }
            index += count
        }
        return GrokWeeklyParser.readFields(data)
    }
}

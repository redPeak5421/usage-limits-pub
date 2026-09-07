import Foundation

/// Gemini 同源占位探针：打登录后的 `/app`。没有已确认的 Cookie 配额 JSON。
/// 解析器只接受 remainingFraction 形状；HTML / CORS 失败不得编数字。
public enum GeminiProbeScript {
    public static let body = #"""
    const probes = {};
    probes.quota = await __probe('/app', {
        headers: { 'Accept': 'application/json' },
        noAuth: true,
        timeoutMs: 12000
    });
    return { probes: probes };
    """#
}

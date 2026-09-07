import Foundation

/// Kiro 同源占位探针：打 `app.kiro.dev` 根。`GetUsageLimits` 不能用 Cookie 伪造。
public enum KiroProbeScript {
    public static let body = #"""
    const probes = {};
    probes.usage = await __probe('/', {
        headers: { 'Accept': 'application/json' },
        noAuth: true,
        timeoutMs: 12000
    });
    return { probes: probes };
    """#
}

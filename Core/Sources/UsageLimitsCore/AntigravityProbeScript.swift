import Foundation

/// Antigravity 同源占位探针：打站点根。桌面 OAuth / 本地 agy 不能搬到 iOS。
public enum AntigravityProbeScript {
    public static let body = #"""
    const probes = {};
    probes.quota = await __probe('/', {
        headers: { 'Accept': 'application/json' },
        noAuth: true,
        timeoutMs: 12000
    });
    return { probes: probes };
    """#
}

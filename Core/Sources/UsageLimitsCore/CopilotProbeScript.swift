import Foundation

/// GitHub Copilot 同源 budgets Cookie 探针。保持在 Core 以便测试读到生产脚本。
public enum CopilotProbeScript {
    public static let body = #"""
    const probes = {};
    probes.budgets = await __probe('/settings/billing/budgets?page=1&page_size=10&scope=customer', {
        headers: {
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'GitHub-Verified-Fetch': 'true'
        },
        noAuth: true,
        timeoutMs: 12000
    });
    return { probes: probes };
    """#
}

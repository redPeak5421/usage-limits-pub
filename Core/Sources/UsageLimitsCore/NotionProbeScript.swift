import Foundation

/// Notion 专属探针函数体。保持在 Core 以便用 JavaScriptCore 对实际生产脚本做运行时契约测试；
/// Core 本身仍只依赖 Foundation，JavaScriptCore 仅由 macOS 测试目标导入。
public enum NotionProbeScript {
    public static let body = #"""
    const probes = {};
    const h = { 'Accept': '*/*', 'Content-Type': 'application/json' };
    function __notionObject(value) {
        return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
    }
    function __notionUnwrap(raw) {
        const outer = __notionObject(raw);
        if (!outer) { return null; }
        const value = __notionObject(outer.value);
        if (!value) { return outer; }
        return __notionObject(value.value) || value;
    }
    function __notionResolveUserKey(root) {
        const keys = Object.keys(root).sort();
        const identified = keys.filter(function (key) {
            const container = __notionObject(root[key]);
            const users = container && __notionObject(container.notion_user);
            const record = users && __notionUnwrap(users[key]);
            return !!(record && typeof record.id === 'string' && record.id.trim() === key);
        });
        if (identified.length === 1) { return identified[0]; }
        if (identified.length === 0 && keys.length === 1) { return keys[0]; }
        return null;
    }
    function __notionSafeTier(raw) {
        if (typeof raw !== 'string') { return ''; }
        const tier = raw.trim().toLowerCase();
        return ['free', 'plus', 'business', 'enterprise'].indexOf(tier) >= 0 ? tier : '';
    }
    function __notionSelectWorkspace(root) {
        const userKey = __notionResolveUserKey(root);
        const container = userKey && __notionObject(root[userKey]);
        const spaces = container && __notionObject(container.space);
        if (!spaces) { return null; }
        const candidates = Object.keys(spaces).sort().map(function (key) {
            const record = __notionUnwrap(spaces[key]);
            if (!record) { return null; }
            const recordID = (typeof record.id === 'string') ? record.id.trim() : '';
            const id = recordID || key.trim();
            if (!id) { return null; }
            const tier = __notionSafeTier(record.subscription_tier);
            return { id: id, tier: tier };
        }).filter(Boolean);
        return candidates.find(function (item) {
            const tier = item.tier;
            return tier === 'business' || tier === 'enterprise';
        }) || candidates[0] || null;
    }
    function __notionSafeNumber(raw) {
        return (typeof raw === 'number' && Number.isFinite(raw)) ? raw : null;
    }
    function __notionSafeWindowToken(raw) {
        if (typeof raw !== 'string') { return ''; }
        const token = raw.trim().toLowerCase();
        return /^[1-9][0-9]{0,8}[mhdw]$/.test(token) ? token : '';
    }
    function __notionSafeStatus(raw) {
        if (typeof raw !== 'string') { return ''; }
        const status = raw.trim().toLowerCase();
        return ['within_limit', 'over_limit', 'not_applicable'].indexOf(status) >= 0 ? status : '';
    }
    function __notionSafeCreditWindow(raw, includeWindowToken) {
        const source = __notionObject(raw);
        if (!source) { return null; }
        const safe = {};
        const used = __notionSafeNumber(source.used);
        const limit = __notionSafeNumber(source.limit);
        if (used !== null) { safe.used = used; }
        if (limit !== null) { safe.limit = limit; }
        if (includeWindowToken) {
            const token = __notionSafeWindowToken(source.window);
            if (token) { safe.window = token; }
        }
        const periodEndMs = __notionSafeNumber(source.periodEndMs);
        if (periodEndMs !== null) { safe.periodEndMs = periodEndMs; }
        return Object.keys(safe).length ? safe : null;
    }
    function __notionSafeCredit(raw) {
        const source = __notionObject(raw);
        if (!source) { return {}; }
        const safe = {};
        const status = __notionSafeStatus(source.status);
        if (status) { safe.status = status; }
        const window = __notionSafeCreditWindow(source.window, true);
        if (window) { safe.window = window; }
        const resets = __notionSafeNumber(source.resetsInSeconds);
        if (resets !== null) { safe.resetsInSeconds = resets; }
        const billing = __notionSafeCreditWindow(source.billingPeriodWindow, false);
        if (billing) { safe.billingPeriodWindow = billing; }
        return safe;
    }
    const rawSpaces = await __probe('/api/v3/getSpaces', {
        method: 'POST', headers: h, body: '{}', noAuth: true, timeoutMs: 7000, retry: true
    });
    if (rawSpaces.status < 200 || rawSpaces.status >= 300) {
        probes.spaces = { status: rawSpaces.status, body: '{}' };
        return { probes: probes };
    }
    let selected = null;
    try {
        const root = JSON.parse(rawSpaces.body);
        if (__notionObject(root)) { selected = __notionSelectWorkspace(root); }
    } catch (e) {}
    if (!selected) {
        probes.spaces = { status: rawSpaces.status, body: JSON.stringify({ hasWorkspace: false }) };
        return { probes: probes };
    }
    const spacesSummary = { hasWorkspace: true };
    if (selected.tier) { spacesSummary.subscriptionTier = selected.tier; }
    probes.spaces = { status: rawSpaces.status, body: JSON.stringify(spacesSummary) };
    const rawCredit = await __probe('/api/v3/getCreditRateLimitStatus', {
        method: 'POST', headers: h, body: JSON.stringify({ spaceId: selected.id }),
        noAuth: true, timeoutMs: 8000, retry: false
    });
    if (rawCredit.status < 200 || rawCredit.status >= 300) {
        probes.credit_limit = { status: rawCredit.status, body: '{}' };
        return { probes: probes };
    }
    let safeCredit = {};
    try {
        safeCredit = __notionSafeCredit(JSON.parse(rawCredit.body));
    } catch (e) {}
    probes.credit_limit = { status: rawCredit.status, body: JSON.stringify(safeCredit) };
    return { probes: probes };
    """#
}

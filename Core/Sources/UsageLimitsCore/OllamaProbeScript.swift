import Foundation

/// Ollama `/settings` 会返回可能含邮箱、姓名和 WorkOS 参数的 SSR HTML。
/// 生产脚本只在 WebView 内存里解析原文，跨桥只返回严格白名单摘要。
/// 放在 Core 是为了让 macOS 测试用 JavaScriptCore 真正执行这段生产脚本；
/// Core 生产目标本身仍只依赖 Foundation。
public enum OllamaProbeScript {
    public static let body = #"""
    const probes = {};
    function __ollamaSafeFinalURLIsSignIn(raw) {
        if (typeof raw !== 'string') { return false; }
        const match = raw.trim().toLowerCase().match(/^https:\/\/([^\/?#]+)(\/[^?#]*)?/);
        if (!match) { return false; }
        const host = match[1];
        const path = match[2] || '/';
        if ((host === 'ollama.com' || host === 'www.ollama.com')
            && (path === '/signin' || path.indexOf('/signin/') === 0)) { return true; }
        if (host === 'signin.ollama.com') { return true; }
        return host.endsWith('.workos.com')
            && (path === '/user_management/authorize' || path.indexOf('/user_management/authorize/') === 0);
    }
    function __ollamaLooksSignedOut(html) {
        if (typeof html !== 'string') { return false; }
        const lower = html.toLowerCase();
        const hasForm = lower.indexOf('<form') >= 0;
        if (!hasForm) { return false; }
        const heading = lower.indexOf('sign in to ollama') >= 0 || lower.indexOf('log in to ollama') >= 0;
        const email = /(?:type|name)\s*=\s*["']email["']/.test(lower);
        const password = /(?:type|name)\s*=\s*["']password["']/.test(lower);
        const authRoute = lower.indexOf('/api/auth/signin') >= 0 || lower.indexOf('/auth/signin') >= 0;
        const loginRoute = /(?:action|href)\s*=\s*["']\/(?:login|signin)(?:[\/?#][^"']*)?["']/.test(lower);
        const endpoint = authRoute || loginRoute;
        return (heading && (email || password || endpoint)) || endpoint || (email && password);
    }
    function __ollamaBlock(label, html) {
        const labelRegex = new RegExp(label.replace(/\s+/g, '\\s+'), 'i');
        const match = labelRegex.exec(html);
        if (!match) { return ''; }
        const tail = html.slice(match.index + match[0].length);
        const next = /(?:Session|Hourly|Weekly)\s+usage/i.exec(tail);
        const end = Math.min(4000, next ? next.index : tail.length);
        return tail.slice(0, end);
    }
    function __ollamaSafePercent(block) {
        let match = /(?:^|[^0-9A-Za-z.+-])([0-9]+(?:\.[0-9]+)?)\s*%\s*used(?![0-9A-Za-z.])/i.exec(block);
        if (!match) {
            match = /(?:^|[^0-9A-Za-z_-])width\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*%(?![0-9A-Za-z.])/i.exec(block);
        }
        if (!match) { return null; }
        const value = Number(match[1]);
        if (!Number.isFinite(value)) { return null; }
        return Math.max(0, Math.min(100, value));
    }
    function __ollamaLeapYear(year) {
        return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    }
    function __ollamaStrictISO(raw) {
        const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$/.exec(raw);
        if (!match) { return false; }
        const year = Number(match[1]);
        const month = Number(match[2]);
        const day = Number(match[3]);
        const hour = Number(match[4]);
        const minute = Number(match[5]);
        const second = Number(match[6]);
        const offsetHour = match[7] === undefined ? 0 : Number(match[7]);
        const offsetMinute = match[8] === undefined ? 0 : Number(match[8]);
        if (year < 1 || year > 9999 || month < 1 || month > 12
            || hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59
            || offsetHour < 0 || offsetHour > 23 || offsetMinute < 0 || offsetMinute > 59) { return false; }
        const monthDays = [31, __ollamaLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        return day >= 1 && day <= monthDays[month - 1];
    }
    function __ollamaSafeReset(block) {
        const match = /data-time\s*=\s*"([^"]+)"/i.exec(block);
        if (!match) { return ''; }
        const raw = match[1].trim();
        if (!__ollamaStrictISO(raw)) { return ''; }
        const milliseconds = Date.parse(raw);
        if (!Number.isFinite(milliseconds)
            || milliseconds < -62135596800000
            || milliseconds > 253402300799000) { return ''; }
        return raw;
    }
    function __ollamaUsage(label, html) {
        const block = __ollamaBlock(label, html);
        if (!block) { return null; }
        const usedPercent = __ollamaSafePercent(block);
        if (usedPercent === null) { return null; }
        const safe = { usedPercent: usedPercent };
        const resetsAt = __ollamaSafeReset(block);
        if (resetsAt) { safe.resetsAt = resetsAt; }
        return safe;
    }
    function __ollamaPlan(html) {
        const match = /Cloud\s+Usage\s*<\/span>\s*<span[^>]*>([^<]+)<\/span>/i.exec(html);
        if (!match) { return ''; }
        const tier = match[1].trim().toLowerCase();
        return ['free', 'pro', 'max'].indexOf(tier) >= 0 ? tier : '';
    }
    const rawSettings = await __probe('/settings', {
        headers: { 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' },
        noAuth: true,
        timeoutMs: 12000,
        retry: true
    });
    if (rawSettings.status < 200 || rawSettings.status >= 300) {
        probes.settings = { status: rawSettings.status, body: '{}' };
        return { probes: probes };
    }
    const rawHTML = (typeof rawSettings.body === 'string') ? rawSettings.body : '';
    if (__ollamaSafeFinalURLIsSignIn(rawSettings.finalURL) || __ollamaLooksSignedOut(rawHTML)) {
        probes.settings = { status: rawSettings.status, body: JSON.stringify({ signedOut: true }) };
        return { probes: probes };
    }
    const summary = { signedOut: false };
    const plan = __ollamaPlan(rawHTML);
    if (plan) { summary.plan = plan; }
    const session = __ollamaUsage('Session usage', rawHTML);
    const hourly = session ? null : __ollamaUsage('Hourly usage', rawHTML);
    const weekly = __ollamaUsage('Weekly usage', rawHTML);
    if (session) { summary.session = session; }
    else if (hourly) { summary.hourly = hourly; }
    if (weekly) { summary.weekly = weekly; }
    probes.settings = { status: rawSettings.status, body: JSON.stringify(summary) };
    return { probes: probes };
    """#
}

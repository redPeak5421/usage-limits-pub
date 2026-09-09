import Foundation

/// 官网 GetUsageInfo；引导 HTML 只取会话参数，用量只取已验证的 RPC。
public enum GeminiProbeScript {
    public static let body = #"""
    const probes = {};
    const routeKey = 'usage-limits.gemini.account-path';
    const match = location.pathname.match(/^\/u\/\d+(?=\/|$)/);
    const currentRoute = match ? match[0] : '';
    let savedRoute = null;
    try { savedRoute = localStorage.getItem(routeKey); } catch (_) {}
    if (savedRoute !== '' && !/^\/u\/\d+$/.test(savedRoute || '')) { savedRoute = null; }
    const useCurrent = typeof geminiUseCurrentAccount === 'undefined' || geminiUseCurrentAccount;
    const route = useCurrent ? currentRoute : (savedRoute === null ? currentRoute : savedRoute);
    const bootstrap = await __probe(route + '/usage', { noAuth: true, retry: false });
    if (bootstrap.status !== 200) {
        probes.quota = { status: bootstrap.status, body: '' };
        return { probes: probes };
    }
    // .defaultClient 看不到网页 JS 全局变量；只 JSON.parse 具名引导数据，不 eval。
    const initial = bootstrap.body.match(/<script\b[^>]*>\s*window\.WIZ_global_data\s*=\s*(\{[\s\S]*?\});?\s*<\/script>/);
    let wiz = null;
    try { if (initial) { wiz = JSON.parse(initial[1]); } } catch (_) {}
    if (!wiz || typeof wiz.SNlM0e !== 'string' || !wiz.SNlM0e ||
        typeof wiz.S06Grb !== 'string' || !/^\d+$/.test(wiz.S06Grb)) {
        probes.quota = { status: 200, body: '<html>Gemini usage session unavailable</html>' };
        return { probes: probes };
    }
    const query = new URLSearchParams({ rpcids: 'jSf9Qc', 'source-path': route + '/usage', rt: 'c' });
    if (typeof wiz.cfb2h === 'string') { query.set('bl', wiz.cfb2h); }
    if (typeof wiz.FdrFJe === 'string') { query.set('f.sid', wiz.FdrFJe); }
    const form = new URLSearchParams({
        'f.req': JSON.stringify([[['jSf9Qc', '[]', null, 'generic']]]), at: wiz.SNlM0e
    });
    probes.quota = await __probe(route + '/_/BardChatUi/data/batchexecute?' + query.toString(), {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
        body: form.toString(), noAuth: true, retry: false
    });
    let validUsage = false;
    if (probes.quota.status === 200) {
        for (const line of probes.quota.body.split('\n')) {
            try {
                const frames = JSON.parse(line);
                if (!Array.isArray(frames)) { continue; }
                for (const frame of frames) {
                    if (!Array.isArray(frame) || frame[0] !== 'wrb.fr' || frame[1] !== 'jSf9Qc') { continue; }
                    const data = JSON.parse(frame[2]);
                    validUsage = Array.isArray(data) && Array.isArray(data[1]) && data[1].some(row =>
                        Array.isArray(row) && (row[2] === 1 || row[2] === 2) &&
                        typeof row[1] === 'number' && Number.isFinite(row[1]) && row[1] >= 0 && row[1] <= 1);
                    if (validUsage) { break; }
                }
            } catch (_) {}
            if (validUsage) { break; }
        }
    }
    if (validUsage) {
        try {
            const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(
                'aiusage-identity-v1|gemini|sub|' + wiz.S06Grb));
            const fingerprint = Array.from(new Uint8Array(hash)).map(x => x.toString(16).padStart(2, '0')).join('');
            probes.identity = { status: 200, body: JSON.stringify({ identityFingerprint: fingerprint }) };
        } catch (_) {
            // 无法校验身份时不返回其他 Google 账号的数字。
            probes.quota = { status: 0, body: '' };
            return { probes: probes };
        }
        try { localStorage.setItem(routeKey, route); } catch (_) {}
    }
    return { probes: probes };
    """#
}

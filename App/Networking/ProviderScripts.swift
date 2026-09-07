import Foundation
import UsageLimitsCore

/// 各服务商的探针 JS。脚本在对应站点源内执行（callAsyncJavaScript 包装成 async 函数体），
/// 统一返回 `{ probes: { 探针名: { status: Number, body: String } } }`。
/// 请求全部发往站点自身域名，凭据由 WebKit Cookie 自动携带，绝不外发。
enum ProviderScripts {
    static func script(for provider: ProviderID) -> String {
        switch provider {
        case .claude: return claude
        case .openai: return openai
        case .grok: return grok
        case .cursor: return cursor
        case .deepseek: return deepseek
        case .zhipu: return zhipu
        case .kimi: return kimi
        case .minimax: return minimax
        case .jimeng: return jimeng
        case .opencode: return opencode
        case .longcat: return longcat
        case .mimo: return mimo
        case .qoder: return qoder
        case .perplexity: return perplexity
        case .augment: return augment
        case .abacus: return abacus
        case .t3chat: return t3chat
        case .notion: return notion
        case .ollama: return ollama
        case .stepfun: return stepfun
        case .copilot: return copilot
        case .gemini: return gemini
        case .antigravity: return antigravity
        case .kiro: return kiro
        // 国际站：脚本按 location.hostname 推导 www 主机，同一份脚本两站通用。
        case .minimaxGlobal: return minimax
        }
    }

    /// 通用探针函数（拼接进各脚本头部）。
    /// 智谱 / DeepSeek / Kimi 官网用量接口要 Authorization，Token 存在
    /// 同源 localStorage 或可读 Cookie 里（Cookie-only fetch 会 200 Missing Token / 1001 / 401）。
    private static let probeHelper = ProviderProbeScript.helper

    // claude.ai 纯 Cookie 鉴权：全部探针带 noAuth，避免通用助手把同源 token 拼成
    // 意料外的 Authorization 头（CodexBar 的 web 链路也只发 Cookie + Accept）。
    // account / overage / prepaid 是尽力而为的补充项：排在两个核心探针之后、
    // 4 秒超时、不重试，失败只是少一项数据，绝不拖累 organizations / usage。
    static let claude = probeHelper + #"""
    const JSON_HEADERS = { 'Accept': 'application/json' };
    const CORE = { headers: JSON_HEADERS, noAuth: true };
    const SIDE = { headers: JSON_HEADERS, noAuth: true, timeoutMs: 4000, retry: false };
    const probes = {};
    probes.organizations = await __probe('/api/organizations', CORE);
    let orgId = null;
    try {
        const orgs = JSON.parse(probes.organizations.body);
        const caps = o => (o.capabilities || []).map(c => String(c).toLowerCase());
        // chat 能力 → 第一个「非纯 API」org → 第一个 org（顺序须与 ClaudeParser 一致）
        const pick = orgs.find(o => caps(o).indexOf('chat') >= 0)
            || orgs.find(o => { const c = caps(o); return !(c.length === 1 && c[0] === 'api'); })
            || orgs[0];
        orgId = pick && pick.uuid;
    } catch (e) {}
    if (orgId) {
        probes.usage = await __probe('/api/organizations/' + orgId + '/usage', CORE);
    }
    // extra_usage 已随 usage 内联返回时不必再问 overage_spend_limit
    let hasExtraUsage = false;
    try {
        const u = JSON.parse(probes.usage.body);
        hasExtraUsage = !!(u && u.extra_usage);
    } catch (e) {}
    const sideNames = ['account'];
    const sideJobs = [__probe('/api/account', SIDE)];
    if (orgId && !hasExtraUsage) {
        sideNames.push('overage');
        sideJobs.push(__probe('/api/organizations/' + orgId + '/overage_spend_limit', SIDE));
    }
    if (orgId) {
        sideNames.push('prepaid');
        sideJobs.push(__probe('/api/organizations/' + orgId + '/prepaid/credits', SIDE));
    }
    const sideValues = await Promise.all(sideJobs);
    sideNames.forEach(function (name, index) { probes[name] = sideValues[index]; });
    return { probes: probes };
    """#
    // session 下发 token 后，accounts / wham 与尽力而为的 subscriptions 并发；
    // spend_monthly 只依赖 wham 的门控。bootstrap 不发请求，只回传 authStatus 与「有没有邮箱」的布尔。
    // session 与 backend-api 都 noAuth：禁止 helper 注入 leftover localStorage Bearer；
    // backend-api 仍可由脚本自己把 session.accessToken 写成 Authorization。
    static let openai = probeHelper + #"""
    const probes = {};
    probes.session = await __probe('/api/auth/session', { headers: { 'Accept': 'application/json' }, noAuth: true });
    let token = null;
    try { token = JSON.parse(probes.session.body).accessToken || null; } catch (e) {}
    const headers = { 'Accept': 'application/json' };
    if (token) { headers['Authorization'] = 'Bearer ' + token; }
    const accountsPromise = __probe('/backend-api/accounts/check/v4-2023-04-27', { headers: headers, noAuth: true });
    const whamPromise = __probe('/backend-api/wham/usage', { headers: headers, noAuth: true });
    const subscriptionsPromise = __probe('/backend-api/subscriptions', {
        headers: headers, noAuth: true, timeoutMs: 4000, retry: false
    });

    // 页内内嵌 JSON：session 接口漂移时的登录态第二证据。不发请求。
    probes.bootstrap = (function () {
        function readJSON(text) {
            if (!text) { return null; }
            try { return JSON.parse(text); } catch (e) { return null; }
        }
        function hasEmailIn(node, depth) {
            if (!node || depth > 6) { return false; }
            if (typeof node === 'string') { return node.indexOf('@') > 0; }
            if (typeof node !== 'object') { return false; }
            const keys = Object.keys(node).slice(0, 60);
            for (let i = 0; i < keys.length; i++) {
                const k = keys[i];
                if (k.toLowerCase() === 'email' && typeof node[k] === 'string' && node[k].indexOf('@') > 0) { return true; }
                if (hasEmailIn(node[k], depth + 1)) { return true; }
            }
            return false;
        }
        try {
            const el = document.getElementById('client-bootstrap');
            const sources = [];
            if (el) { const b = readJSON(el.textContent); if (b) { sources.push(b); } }
            if (typeof window !== 'undefined' && window.__NEXT_DATA__) { sources.push(window.__NEXT_DATA__); }
            let authStatus = null;
            let hasEmail = false;
            for (let i = 0; i < sources.length; i++) {
                const s = sources[i];
                if (!authStatus && typeof s.authStatus === 'string') { authStatus = s.authStatus; }
                if (!hasEmail && hasEmailIn(s, 0)) { hasEmail = true; }
            }
            if (!sources.length) { return { status: 204, body: '{}' }; }
            return { status: 200, body: JSON.stringify({ authStatus: authStatus, hasEmail: hasEmail }) };
        } catch (e) {
            return { status: -1, body: String(e) };
        }
    })();

    // 月度美元额度池：照抄 CodexBar 的门控，个人档（guest/free/go/plus/pro）一律不发。
    const spendPromise = (async function () {
        const whamResult = await whamPromise;
        try {
            const wham = JSON.parse(whamResult.body) || {};
            const accountId = wham.account_id || wham.accountId || '';
            const pool = wham.individual_limit || wham.individualLimit
                || (wham.rate_limit && wham.rate_limit.individual_limit)
                || (wham.spend_control && wham.spend_control.individual_limit);
            const poolResolved = !!(pool && Number(pool.limit) > 0);
            const spendPresent = Object.prototype.hasOwnProperty.call(wham, 'spend_control');
            const plan = String(wham.plan_type || '').toLowerCase();
            const skip = ['guest', 'free', 'go', 'plus', 'pro'];
            if (accountId && !poolResolved && spendPresent && skip.indexOf(plan) < 0) {
                return await __probe(
                    '/backend-api/accounts/' + encodeURIComponent(accountId)
                        + '/spend-controls/current-user/monthly-usage',
                    { headers: headers, noAuth: true, timeoutMs: 4000, retry: false }
                );
            }
        } catch (e) {}
        return null;
    })();
    const openAIValues = await Promise.all([accountsPromise, whamPromise, subscriptionsPromise, spendPromise]);
    probes.accounts_check = openAIValues[0];
    probes.wham_usage = openAIValues[1];
    probes.subscriptions = openAIValues[2];
    if (openAIValues[3]) { probes.spend_monthly = openAIValues[3]; }
    probes.identity = await (async function () {
        function firstEmail(node, depth) {
            if (!node || depth > 6) { return null; }
            if (typeof node === 'string') { return node.indexOf('@') > 0 ? node : null; }
            if (typeof node !== 'object') { return null; }
            const keys = Object.keys(node).slice(0, 60);
            for (let i = 0; i < keys.length; i++) {
                const k = keys[i];
                const v = node[k];
                if (k.toLowerCase() === 'email' && typeof v === 'string' && v.indexOf('@') > 0) { return v; }
                const found = firstEmail(v, depth + 1);
                if (found) { return found; }
            }
            return null;
        }
        async function sha256hex(text) {
            if (!crypto || !crypto.subtle) { return null; }
            const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
            return Array.from(new Uint8Array(buf)).map(function (b) {
                return ('0' + b.toString(16)).slice(-2);
            }).join('');
        }
        try {
            const acc = openAIValues[0];
            if (!acc || acc.status < 200 || acc.status >= 300) {
                return { status: 204, body: '{}' };
            }
            const root = JSON.parse(acc.body);
            const email = firstEmail(root, 0);
            if (!email) { return { status: 204, body: '{}' }; }
            const fp = await sha256hex('aiusage-identity-v1|openai|email|' + email.trim().toLowerCase());
            if (!fp) { return { status: 204, body: '{}' }; }
            return { status: 200, body: JSON.stringify({ identityFingerprint: fp }) };
        } catch (e) {
            return { status: 204, body: '{}' };
        }
    })();
    return { probes: probes };
    """#
    static let cursor = probeHelper + #"""
    const probes = {};
    const usagePromise = __probe('/api/usage-summary', { headers: { 'Accept': 'application/json' }, noAuth: true });
    const sandPromise = __probe('/api/dashboard/get-sand-usage-status', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: '{}',
        noAuth: true
    });
    // 尽力而为：拿稳定账号 ID sub 去查旧版「按请求数」计费套餐的用量。
    // 失败 / 超时 / 404 都不影响主用量；email、name 等身份字段解析层一概不取。
    const authPromise = __probe('/api/auth/me', {
        headers: { 'Accept': 'application/json' },
        timeoutMs: 4000,
        noAuth: true
    });
    const requestPromise = (async function () {
        const authResult = await authPromise;
        let cursorSub = null;
        try {
            const me = JSON.parse(authResult.body);
            if (me && typeof me.sub === 'string' && me.sub) { cursorSub = me.sub; }
        } catch (e) {}
        if (!cursorSub) {
            // 回退：Cookie WorkosCursorSessionToken 形如 <userID>::<JWT>，JWT payload 的 sub 取 | 之后一段。
            // 该 Cookie 通常是 httpOnly，这条多半读不到，属正常。
            try {
                const raw = __cookie('WorkosCursorSessionToken');
                const jwt = raw && raw.indexOf('::') >= 0 ? raw.split('::')[1] : '';
                const payload = jwt ? jwt.split('.')[1] : '';
                if (payload) {
                    const pad = payload.replace(/-/g, '+').replace(/_/g, '/');
                    const claims = JSON.parse(atob(pad + '==='.slice((pad.length + 3) % 4)));
                    if (claims && typeof claims.sub === 'string' && claims.sub) {
                        const parts = claims.sub.split('|');
                        cursorSub = parts[parts.length - 1];
                    }
                }
            } catch (e) {}
        }
        if (cursorSub) {
            return await __probe('/api/usage?user=' + encodeURIComponent(cursorSub), {
                headers: { 'Accept': 'application/json' },
                timeoutMs: 6000,
                noAuth: true
            });
        }
        return null;
    })();
    const cursorValues = await Promise.all([usagePromise, sandPromise, authPromise, requestPromise]);
    probes.usage_summary = cursorValues[0];
    probes.sand_usage_status = cursorValues[1];
    // auth_me 原包含 email / name / picture / sub。sub 只留在上面 request_usage 的 JS 闭包里；
    // 过桥只回 hasSub + SHA-256 指纹，原文不得进 Swift / 诊断 / 落盘。
    probes.auth_me = await (async function () {
        const raw = cursorValues[2];
        if (!raw) { return { status: -1, body: '' }; }
        let sub = null;
        try {
            const me = JSON.parse(raw.body);
            if (me && typeof me.sub === 'string' && me.sub) { sub = me.sub; }
        } catch (e) {}
        if (!sub) {
            return { status: raw.status, body: JSON.stringify({ hasSub: false }) };
        }
        let fp = null;
        try {
            if (crypto && crypto.subtle) {
                const buf = await crypto.subtle.digest(
                    'SHA-256',
                    new TextEncoder().encode('aiusage-identity-v1|cursor|sub|' + String(sub).trim())
                );
                fp = Array.from(new Uint8Array(buf)).map(function (b) {
                    return ('0' + b.toString(16)).slice(-2);
                }).join('');
            }
        } catch (e) {}
        return { status: raw.status, body: JSON.stringify({ hasSub: true, identityFingerprint: fp }) };
    })();
    if (cursorValues[3]) { probes.request_usage = cursorValues[3]; }
    return { probes: probes };
    """#
    // grok.com 纯 Cookie。REST 与 weekly 一律 noAuth，禁止 helper 注入 leftover Bearer。
    static let grok = probeHelper + #"""
    const probes = {};
    // 只请求官网四个固定 mode。没有已证实的动态发现接口，不发明第五个 mode；
    // 解析器对未知 modelName 仍会并入聚合。
    const modes = ['auto', 'fast', 'expert', 'heavy'];
    const modePromise = Promise.all(modes.map(async function (mode) {
        const r = await __probe('/rest/rate-limits', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
            noAuth: true,
            body: JSON.stringify({ modelName: mode })
        });
        let body = r.body;
        if (r.status >= 200 && r.status < 300) {
            try { body = JSON.parse(r.body); } catch (e) { body = {}; }
        }
        return { modelName: mode, requestKind: 'DEFAULT', status: r.status, body: body };
    }));
    const SIDE = { headers: { 'Accept': 'application/json' }, noAuth: true, timeoutMs: 6000, retry: false };
    const subscriptionsPromise = __probe('/rest/subscriptions', SIDE);
    const creditsPromise = __probe('/rest/grok/credits', SIDE);
    const weeklyPromise = __probeBinary('/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig', {
        method: 'POST', noAuth: true, timeoutMs: 6000, retry: false,
        headers: { 'content-type': 'application/grpc-web+proto', 'x-grpc-web': '1' },
        body: new Uint8Array([0, 0, 0, 0, 0])
    });
    const grokValues = await Promise.all([modePromise, subscriptionsPromise, creditsPromise, weeklyPromise]);
    const results = grokValues[0];
    probes.rate_limits = {
        // 合成壳固定 200；每个 mode 的真实 status/body 留在 results，避免一条 503
        // 把另一条已完成的 200 整体挡在 Swift 解析器外。
        status: 200,
        body: JSON.stringify({ results: results })
    };
    probes.subscriptions = grokValues[1];
    probes.credits = grokValues[2];
    probes.weekly = grokValues[3];
    return { probes: probes };
    """#
    static let deepseek = probeHelper + #"""
    const probes = {};
    const dsHeaders = { 'Accept': 'application/json', 'x-client-platform': 'web', 'x-client-version': '1.0.0' };
    const tz = 28800;
    const now = new Date();
    const utc8 = new Date(now.getTime() + tz * 1000);
    function dayStart(d) {
        return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) / 1000 - tz;
    }
    const today0 = dayStart(utc8);
    const tomorrow0 = today0 + 86400;
    const yday0 = today0 - 86400;
    const month0 = Date.UTC(utc8.getUTCFullYear(), utc8.getUTCMonth(), 1) / 1000 - tz;
    const nextMonth0 = Date.UTC(utc8.getUTCFullYear(), utc8.getUTCMonth() + 1, 1) / 1000 - tz;
    const lastMonth0 = Date.UTC(utc8.getUTCFullYear(), utc8.getUTCMonth() - 1, 1) / 1000 - tz;
    const presets = {
        today: [today0, tomorrow0],
        yesterday: [yday0, today0],
        last_7d: [today0 - 6 * 86400, tomorrow0],
        last_30d: [today0 - 29 * 86400, tomorrow0],
        this_month: [month0, nextMonth0],
        last_month: [lastMonth0, month0]
    };
    const currentP = __probe('/auth-api/v0/users/current', { headers: dsHeaders });
    const summaryP = __probe('/api/v0/users/get_user_summary', { headers: dsHeaders });
    const keysP = __probe('/api/v0/users/get_api_keys', { headers: dsHeaders });
    const periodJobs = [];
    const periodMeta = [];
    Object.entries(presets).forEach(function (entry) {
        const id = entry[0];
        const range = entry[1];
        const q = 'start=' + range[0] + '&end=' + range[1] + '&tz=' + tz;
        periodMeta.push({ id: id, start: range[0], end: range[1] });
        periodJobs.push(__probe('/api/v0/usage/by_api_key/cost?' + q, { headers: dsHeaders }));
        periodJobs.push(__probe('/api/v0/usage/by_api_key/amount?' + q, { headers: dsHeaders }));
    });
    const deepseekValues = await Promise.all([currentP, summaryP, keysP].concat(periodJobs));
    probes.current = deepseekValues[0];
    probes.summary = deepseekValues[1];
    probes.api_keys = deepseekValues[2];
    const periods = {};
    periodMeta.forEach(function (meta, index) {
        periods[meta.id] = {
            start: meta.start,
            end: meta.end,
            cost: deepseekValues[3 + index * 2],
            amount: deepseekValues[4 + index * 2]
        };
    });
    probes.usage_periods = {
        status: 200,
        body: JSON.stringify(periods)
    };
    return { probes: probes };
    """#
    static let zhipu = probeHelper + #"""
    const probes = {};
    const headers = { 'Accept': 'application/json' };
    const end = new Date();
    const start = new Date(end.getTime() - 6 * 86400000);
    function fmt(d) {
        const p = n => String(n).padStart(2, '0');
        return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
    }
    const q = 'startTime=' + encodeURIComponent(fmt(start) + ' 00:00:00') + '&endTime=' + encodeURIComponent(fmt(end) + ' 23:59:59');
    const zhipuValues = await Promise.all([
        __probe('/api/biz/customer/getCustomerInfo', { headers: headers }),
        __probe('/api/biz/subscription/list?pageSize=9999&pageNum=1', { headers: headers }),
        __probe('/api/monitor/usage/quota/limit', { headers: headers }),
        __probe('/api/monitor/usage/model-usage?' + q, { headers: headers })
    ]);
    probes.customer = zhipuValues[0];
    probes.subscription = zhipuValues[1];
    probes.quota = zhipuValues[2];
    probes.model_usage = zhipuValues[3];
    return { probes: probes };
    """#
    static let kimi = probeHelper + #"""
    const probes = {};
    const headers = {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'x-msh-platform': 'web',
        'connect-protocol-version': '1',
        'x-language': 'en-US'
    };
    try {
        const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
        if (tz) headers['r-timezone'] = tz;
    } catch (e) {}
    const kimiAuth = __cookie('kimi-auth');
    if (kimiAuth) {
        headers.Authorization = kimiAuth.indexOf(' ') >= 0 ? kimiAuth : ('Bearer ' + kimiAuth);
        try {
            const parts = kimiAuth.split('.');
            if (parts.length >= 2) {
                let payload = parts[1].replace(/-/g, '+').replace(/_/g, '/');
                while (payload.length % 4) payload += '=';
                const json = JSON.parse(atob(payload));
                if (json && json.device_id) headers['x-msh-device-id'] = String(json.device_id);
                if (json && json.ssid) headers['x-msh-session-id'] = String(json.ssid);
                if (json && json.sub) headers['x-traffic-id'] = String(json.sub);
            }
        } catch (e) {}
    }
    const kimiValues = await Promise.all([
        __probe('/apiv2/kimi.gateway.account.v1.UserService/GetCurrentUser', { method: 'POST', headers: headers, body: '{}' }),
        __probe('/apiv2/kimi.gateway.membership.v2.MembershipService/ListSubscriptions', { method: 'POST', headers: headers, body: '{}' }),
        __probe('/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription', { method: 'POST', headers: headers, body: '{}' }),
        __probe('/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages', { method: 'POST', headers: headers, body: JSON.stringify({ scope: ['FEATURE_CODING'] }) }),
        __probe('/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats', { method: 'POST', headers: headers, body: '{}' })
    ]);
    probes.user = kimiValues[0];
    probes.subscriptions = kimiValues[1];
    probes.subscription = kimiValues[2];
    probes.usages = kimiValues[3];
    probes.stats = kimiValues[4];
    return { probes: probes };
    """#
    static let minimax = probeHelper + #"""
    const probes = {};
    function __mmHosts() {
        let hostname = '';
        try { hostname = String(location.hostname || ''); } catch (e) { hostname = ''; }
        const intl = /minimax\.io$/i.test(hostname);
        const host = intl ? 'https://www.minimax.io' : 'https://www.minimaxi.com';
        let platform = intl ? 'https://platform.minimax.io' : 'https://platform.minimaxi.com';
        try {
            if (hostname.indexOf('platform.') === 0 && typeof location.origin === 'string' && location.origin) {
                platform = location.origin;
            }
        } catch (e) {}
        return { host: host, platform: platform };
    }
    function __mmGroupID() {
        const fromLS = __ls('minimax_current_group_id');
        if (fromLS) { return fromLS; }
        const fromCookie = __cookie('minimax_group_id_v2');
        if (fromCookie) { return fromCookie; }
        const tokens = [__ls('access_token'), __ls('accessToken'), __ls('id_token')];
        for (let i = 0; i < tokens.length; i++) {
            const raw = tokens[i];
            if (!raw) { continue; }
            try {
                const parts = String(raw).split('.');
                if (parts.length < 2) { continue; }
                const pad = parts[1].replace(/-/g, '+').replace(/_/g, '/');
                const claims = JSON.parse(atob(pad + '==='.slice((pad.length + 3) % 4)));
                const gid = claims && (claims.GroupID || claims.group_id || claims.groupId);
                if (gid) { return String(gid); }
            } catch (e) {}
        }
        return '';
    }
    function __mmRecordTime(rec) {
        if (!rec || typeof rec !== 'object') { return null; }
        if (rec.created_at != null) {
            const n = Number(rec.created_at);
            if (Number.isFinite(n) && n > 0) { return n < 1e12 ? n * 1000 : n; }
        }
        const ymd = rec.ymd != null ? String(rec.ymd) : '';
        if (ymd) {
            const compact = ymd.replace(/[^\d]/g, '');
            if (compact.length >= 8) {
                const y = Number(compact.slice(0, 4));
                const m = Number(compact.slice(4, 6));
                const d = Number(compact.slice(6, 8));
                if (y >= 1970 && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
                    return Date.UTC(y, m - 1, d) - 8 * 3600000;
                }
            }
        }
        if (rec.consume_time != null) {
            const n = Number(rec.consume_time);
            if (Number.isFinite(n) && n > 0) { return n < 1e12 ? n * 1000 : n; }
        }
        return null;
    }
    function __mmIsSuccess(rec) {
        const raw = rec && (rec.result != null ? rec.result : rec.status);
        if (typeof raw !== 'string') { return true; }
        return String(raw).toUpperCase() === 'SUCCESS';
    }
    async function __mmBilling(platform, headers) {
        const BILLING = { headers: headers, timeoutMs: 8000, retry: false, noAuth: true };
        const records = [];
        const cutoff = Date.now() - 30 * 86400000;
        let first = null;
        let stop = false;
        for (let page = 1; page <= 2 && !stop; page++) {
            const r = await __probe(platform + '/account/amount?page=' + page + '&limit=100&aggregate=false', BILLING);
            if (!first) { first = r; }
            if (!r || r.status < 200 || r.status >= 300) { break; }
            let rows = [];
            try {
                const root = JSON.parse(r.body) || {};
                const data = root.data || root;
                rows = data.charge_records || data.records || data.list || [];
                if (!Array.isArray(rows)) { rows = []; }
            } catch (e) { rows = []; }
            if (!rows.length) { break; }
            for (let i = 0; i < rows.length; i++) {
                const rec = rows[i];
                const at = __mmRecordTime(rec);
                if (at != null && at < cutoff) { stop = true; }
                records.push(rec);
            }
        }
        const shNow = Date.now() + 8 * 3600000;
        const sh = new Date(shNow);
        const today0 = Date.UTC(sh.getUTCFullYear(), sh.getUTCMonth(), sh.getUTCDate()) - 8 * 3600000;
        let todayTokens = 0, last30Tokens = 0, todayCash = 0, last30Cash = 0;
        const byModel = {};
        for (let i = 0; i < records.length; i++) {
            const rec = records[i];
            if (!__mmIsSuccess(rec)) { continue; }
            const at = __mmRecordTime(rec);
            let tokens = Number(rec.consume_token);
            if (!(tokens > 0)) {
                tokens = (Number(rec.consume_input_token) || 0) + (Number(rec.consume_output_token) || 0);
            }
            if (!Number.isFinite(tokens) || tokens < 0) { tokens = 0; }
            let cash = Number(rec.consume_cash_after_voucher);
            if (!Number.isFinite(cash)) { cash = Number(rec.consume_cash); }
            if (!Number.isFinite(cash) || cash < 0) { cash = 0; }
            last30Tokens += tokens;
            last30Cash += cash;
            if (at != null && at >= today0) {
                todayTokens += tokens;
                todayCash += cash;
            }
            const name = rec.model_name || rec.model || rec.modelName;
            if (name && tokens > 0) {
                const key = String(name);
                byModel[key] = (byModel[key] || 0) + tokens;
            }
        }
        const topModels = Object.keys(byModel).map(function (name) {
            return { name: name, tokens: byModel[name] };
        }).sort(function (a, b) { return b.tokens - a.tokens; }).slice(0, 3);
        return {
            status: first ? first.status : -1,
            body: JSON.stringify({
                todayTokens: todayTokens,
                last30Tokens: last30Tokens,
                todayCash: todayCash,
                last30Cash: last30Cash,
                topModels: topModels
            })
        };
    }
    const hosts = __mmHosts();
    probes.region = { status: 200, body: JSON.stringify({ host: hosts.host, platform: hosts.platform }) };
    const headers = { 'Accept': 'application/json' };
    const gid = __mmGroupID();
    if (gid) { headers['x-group-id'] = gid; }
    const MM = { headers: headers, noAuth: true };
    const remainsP = __probe(hosts.host + '/backend/account/token_plan/remains_percent', MM);
    const creditP = __probe(hosts.host + '/backend/account/token_plan_credit', MM);
    const usageP = __probe(hosts.host + '/backend/account/token_plan/usage_summary', MM);
    const yearlyP = __probe(hosts.host + '/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7', MM);
    const monthlyP = __probe(hosts.host + '/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=1&resource_package_type=7', MM);
    const billingP = __mmBilling(hosts.platform, headers);
    const mmValues = await Promise.all([remainsP, creditP, usageP, yearlyP, monthlyP, billingP]);
    probes.remains = mmValues[0];
    probes.credit = mmValues[1];
    probes.usage_summary = mmValues[2];
    probes.combo = {
        status: 200,
        body: JSON.stringify({ yearly: mmValues[3], monthly: mmValues[4] })
    };
    probes.billing = mmValues[5];
    return { probes: probes };
    """#
    static let jimeng = probeHelper + #"""
    function __jimengHeaders() {
        const headers = {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/json',
            'Appid': '513695',
            'Appvr': '5.8.0',
            'Pf': '7'
        };
        const token = (typeof csrf === 'string' && csrf)
            || __cookie('passport_csrf_token')
            || __cookie('passport_csrf_token_default')
            || '';
        if (token) { headers['x-tt-passport-csrf-token'] = token; }
        return headers;
    }
    function __jimengRuntimeUifid() {
        try {
            if (typeof window._secsdk_uifid === 'string' && window._secsdk_uifid) {
                return window._secsdk_uifid;
            }
        } catch (e) {}
        try {
            const odin = window.SSR_RENDER_DATA && window.SSR_RENDER_DATA.app && window.SSR_RENDER_DATA.app.odin;
            if (odin && odin.user_id) { return String(odin.user_id); }
        } catch (e) {}
        try {
            const info = window.__STORE__ && window.__STORE__.userStore && window.__STORE__.userStore.userInfo;
            if (info && (info.id_str || info.user_id || info.uid)) {
                return String(info.id_str || info.user_id || info.uid);
            }
        } catch (e) {}
        if (typeof uifid === 'string' && uifid) { return uifid; }
        const fromCookie = __cookie('uifid');
        if (fromCookie) { return fromCookie; }
        return '';
    }
    function __jimengSigner() {
        try {
            if (typeof window.use !== 'function') { return null; }
            let fn = window.use('webSignBody');
            if (!fn) {
                try { window.use('webSign')(); } catch (e) {}
                fn = window.use('webSignBody');
            }
            return typeof fn === 'function' ? fn : null;
        } catch (e) {
            return null;
        }
    }
    async function __jimengWaitSigner() {
        for (let i = 0; i < 32; i++) {
            if (__jimengSigner()) { return; }
            if (!(await __probeBackoff(250))) { return; }
        }
    }
    function __jimengOfficialCredit() {
        try {
            const store = window.__STORE__;
            if (!store) { return null; }
            const bags = [];
            try { bags.push(store.userStore && store.userStore.credit); } catch (e) {}
            try { bags.push(store.userStore && store.userStore.userCredit); } catch (e) {}
            try {
                const info = store.userStore && store.userStore.userInfo;
                if (info && info.credit) { bags.push(info.credit); }
            } catch (e) {}
            try { bags.push(store.creditStore && store.creditStore.credit); } catch (e) {}
            try { bags.push(store.creditStore && store.creditStore.userCredit); } catch (e) {}
            for (let i = 0; i < bags.length; i++) {
                const bag = bags[i];
                if (bag && typeof bag === 'object' && (
                    bag.vip_credit != null || bag.purchase_credit != null
                    || bag.gift_credit != null || bag.total_credit != null
                )) {
                    return bag;
                }
            }
        } catch (e) {}
        return null;
    }
    function __jimengNativeSign(url) {
        try {
            if (typeof deviceTime !== 'string' || !deviceTime) { return null; }
            const path = String(url).split('?')[0];
            let sign = '';
            if (path.indexOf('user_credit_history') !== -1) { sign = signHistory; }
            else if (path.indexOf('user_credit') !== -1) { sign = signCredit; }
            if (typeof sign !== 'string' || !sign) { return null; }
            return { 'Device-Time': deviceTime, 'Sign': sign, 'Sign-Ver': '1' };
        } catch (e) {
            return null;
        }
    }
    async function __jimengWaitHomeReady() {
        const quick = !!__jimengNativeSign('/commerce/v1/benefits/user_credit');
        const rounds = quick ? 8 : 40;
        for (let i = 0; i < rounds; i++) {
            if (window.__isLogined === true && (__jimengSigner() || __jimengOfficialCredit())) {
                return;
            }
            if (!(await __probeBackoff(250))) { return; }
        }
        if (!quick) { await __jimengWaitSigner(); }
    }
    function __jimengSign(url, body) {
        const signer = __jimengSigner();
        if (signer) {
            try {
                const signed = signer(url, typeof body === 'string' ? body : '');
                if (signed && signed.url) {
                    return { url: signed.url, headers: signed.headers || {} };
                }
            } catch (e) {}
        }
        const native = __jimengNativeSign(url);
        if (native) { return { url: url, headers: native }; }
        return { url: url, headers: {} };
    }
    async function __jimengProbeOnce(url, options) {
        const merged = Object.assign({}, options || {});
        const signed = __jimengSign(url, merged.body);
        merged.headers = Object.assign(__jimengHeaders(), signed.headers || {}, merged.headers || {});
        merged.noAuth = true;
        merged.retry = false;
        return await __probe(signed.url, merged);
    }
    async function __jimengProbe(url, options) {
        let result = await __jimengProbeOnce(url, options);
        if (result.status === 200 && result.body.indexOf('"ret":"1014"') !== -1) {
            if (await __probeBackoff(400)) {
                result = await __jimengProbeOnce(url, options);
            }
        }
        return result;
    }
    function __jimengSanitizeUser(raw) {
        if (!raw) { return { status: -1, body: JSON.stringify({ loggedIn: false }) }; }
        let loggedIn = false;
        try {
            const root = JSON.parse(raw.body) || {};
            const data = (root && typeof root.data === 'object' && root.data) ? root.data : root;
            loggedIn = !!(data && (
                data.sec_uid || data.secUid || data.sec_user_id || data.secUserId
                || data.user_id || data.userId || data.uid || data.name
            ));
        } catch (e) {}
        return { status: raw.status, body: JSON.stringify({ loggedIn: loggedIn }) };
    }
    const probes = {};
    probes.user = __jimengSanitizeUser(
        await __jimengProbe('/passport/web/account/info/v2/?aid=513695&account_sdk_source=web')
    );
    await __jimengWaitHomeReady();
    const pageUser = (typeof window !== 'undefined' && window.__userInfo) || null;
    probes.page = {
        status: 200,
        body: JSON.stringify({
            isLogined: (typeof window !== 'undefined' && window.__isLogined === true),
            hasUserInfo: !!(pageUser && (pageUser.sec_uid || pageUser.sec_user_id || pageUser.secUid || pageUser.user_id || pageUser.userId || pageUser.uid)),
            hasUifid: !!__jimengRuntimeUifid(),
            hasSigner: !!__jimengSigner(),
            hasNativeSign: !!__jimengNativeSign('/commerce/v1/benefits/user_credit')
        })
    };
    const timestamp = Math.floor(Date.now() / 1000);
    const ms = (typeof msToken === 'string' && msToken) || __cookie('msToken') || '';
    let creditQuery = 'aid=513695&device_platform=web&region=CN&timestamp=' + timestamp;
    const uid = __jimengRuntimeUifid();
    if (uid) {
        try { window._secsdk_uifid = uid; } catch (e) {}
        creditQuery += '&uifid=' + encodeURIComponent(uid);
    }
    if (ms) { creditQuery += '&msToken=' + encodeURIComponent(ms); }
    const officialCredit = __jimengOfficialCredit();
    const creditURL = '/commerce/v1/benefits/user_credit?' + creditQuery;
    const historyURL = '/commerce/v1/benefits/user_credit_history?' + creditQuery;
    if (officialCredit) {
        probes.credit = {
            status: 200,
            body: JSON.stringify({ ret: '0', errmsg: 'success', data: { credit: officialCredit } })
        };
    } else {
        probes.credit = await __jimengProbe(creditURL, {
            method: 'POST',
            body: '{}'
        });
    }
    probes.history = await __jimengProbe(historyURL, {
        method: 'POST',
        body: JSON.stringify({ count: 20, cursor: '', history_type: 0 })
    });
    return { probes: probes };
    """#
    static let opencode = probeHelper + #"""
    const probes = {};
    const ORIGIN = 'https://opencode.ai';
    const BILLING_ID_FALLBACK = 'c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d';
    const LITE_ID_FALLBACK = 'c7389bd0e731f80f49593e5ee53835475f4e28594dd6bd83eb229bab753498cd';
    const WORKSPACES_ID = 'def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f';
    const OC_BOUNDARY = '(?:^|[^A-Za-z0-9_$])';
    const OC_NUMBER = '(-?[0-9]+(?:\\.[0-9]+)?)';
    const OC_BOOL = '(!0|!1|true|false)';
    const OC_STRING = '(?:new\\s+Date\\(\\s*)?"([^"]*)"';
    function __ocOnSite() {
        try { return location.hostname === 'opencode.ai'; } catch (e) { return false; }
    }
    function __ocWorkspace() {
        try {
            const m = String(location.pathname).match(/wrk_[A-Za-z0-9]+/);
            return m ? m[0] : '';
        } catch (e) { return ''; }
    }
    function __ocMatch(text, re) {
        const m = String(text || '').match(re);
        return m ? m[1] : '';
    }
    function __ocUUID() {
        try {
            if (crypto && typeof crypto.randomUUID === 'function') { return crypto.randomUUID(); }
        } catch (e) {}
        return '00000000-0000-4000-8000-000000000000';
    }
    function __ocFieldRe(field, value) {
        return new RegExp(OC_BOUNDARY + '(?:"' + field + '"|' + field + ')\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?' + value);
    }
    function __ocFirst(re, text) {
        const m = String(text || '').match(re);
        return m ? m[1] : null;
    }
    function __ocNum(text, field) {
        const v = __ocFirst(__ocFieldRe(field, OC_NUMBER), text);
        return v == null ? null : Number(v);
    }
    function __ocStr(text, field) {
        return __ocFirst(__ocFieldRe(field, OC_STRING), text);
    }
    function __ocBool(text, field) {
        const v = __ocFirst(__ocFieldRe(field, OC_BOOL), text);
        if (v == null) { return null; }
        return v === '!0' || v === 'true';
    }
    function __ocExplicitNull(text) {
        const t = String(text || '').trim();
        if (t.toLowerCase() === 'null') { return true; }
        return /\]\s*=\s*\[\s*\]\s*,\s*null\s*\)\s*$/.test(t);
    }
    function __ocWindow(text, key) {
        const scoped = new RegExp(OC_BOUNDARY + key + '[^}]*?' + OC_BOUNDARY + '(?:"usagePercent"|usagePercent)\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?' + OC_NUMBER);
        const percentRaw = __ocFirst(scoped, text);
        if (percentRaw == null) { return null; }
        const out = { usagePercent: Number(percentRaw) };
        const secRe = new RegExp(OC_BOUNDARY + key + '[^}]*?' + OC_BOUNDARY + '(?:"resetInSec"|resetInSec)\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?' + OC_NUMBER);
        const sec = __ocFirst(secRe, text);
        if (sec != null) { out.resetInSec = Number(sec); }
        const statusRe = new RegExp(OC_BOUNDARY + key + '[^}]*?' + OC_BOUNDARY + '(?:"status"|status)\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?' + OC_STRING);
        const status = __ocFirst(statusRe, text);
        if (status) { out.status = status; }
        const resetsRe = new RegExp(OC_BOUNDARY + key + '[^}]*?' + OC_BOUNDARY + '(?:"resetsAt"|resetsAt)\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?' + OC_STRING);
        const resetsAt = __ocFirst(resetsRe, text);
        if (resetsAt) { out.resetsAt = resetsAt; }
        return out;
    }
    function __ocBillingJSON(text) {
        if (__ocExplicitNull(text)) { return 'null'; }
        const customer = __ocStr(text, 'customerID');
        if (!customer) { return null; }
        const out = {};
        ['balance', 'monthlyLimit', 'monthlyUsage'].forEach(function (field) {
            const n = __ocNum(text, field);
            if (n != null && Number.isFinite(n)) { out[field] = n; }
        });
        ['timeMonthlyUsageUpdated', 'subscriptionID', 'timeSubscriptionBooked', 'liteSubscriptionID'].forEach(function (field) {
            const s = __ocStr(text, field);
            if (s) { out[field] = s; }
        });
        return JSON.stringify(out);
    }
    function __ocWindowsJSON(text, source) {
        if (__ocExplicitNull(text)) { return 'null'; }
        const out = {};
        let produced = 0;
        ['rollingUsage', 'weeklyUsage', 'monthlyUsage'].forEach(function (key) {
            const win = __ocWindow(text, key);
            if (win) { out[key] = win; produced += 1; }
        });
        if (!produced) { return null; }
        const mine = __ocBool(text, 'mine');
        out.mine = mine == null ? true : mine;
        const useBalance = __ocBool(text, 'useBalance');
        if (useBalance != null) { out.useBalance = useBalance; }
        const renew = __ocStr(text, 'renewAt') || __ocStr(text, 'renew_at');
        if (renew) { out.renewAt = renew; }
        if (source) { out.source = source; }
        return JSON.stringify(out);
    }
    function __ocSSRWindows(text) {
        function take(key) {
            const block = String(text || '').match(new RegExp(key + '[^}]{0,400}'));
            const chunk = block ? block[0] : '';
            const percent = __ocMatch(chunk, /usagePercent\s*:\s*([0-9.]+)/);
            if (!percent) { return null; }
            const out = { usagePercent: Number(percent) };
            const sec = __ocMatch(chunk, /resetInSec\s*:\s*([0-9]+)/);
            if (sec) { out.resetInSec = Number(sec); }
            return out;
        }
        const out = {};
        let produced = 0;
        ['rollingUsage', 'weeklyUsage', 'monthlyUsage'].forEach(function (key) {
            const win = take(key);
            if (win) { out[key] = win; produced += 1; }
        });
        if (!produced) { return null; }
        out.mine = true;
        out.source = 'ssr-html';
        return JSON.stringify(out);
    }
    async function __ocText(url) {
        const r = await __probe(url, { headers: { 'Accept': 'text/html, application/javascript, */*' }, noAuth: true });
        return r.status >= 200 && r.status < 300 ? r.body : '';
    }
    async function __ocRuntime(html) {
        const chunk = __ocMatch(html, /(\/_build\/assets\/server-runtime-[\w-]+\.js)/);
        if (!chunk) { return null; }
        const mod = await __deadlineRace(function () { return import(ORIGIN + chunk); }, 5000, null);
        if (!mod) { return null; }
        const keys = Object.keys(mod);
        for (let i = 0; i < keys.length; i++) {
            const fn = mod[keys[i]];
            if (typeof fn === 'function' && String(fn).indexOf('_server') >= 0) { return fn; }
        }
        return null;
    }
    async function __ocServerID(text, fnName, fallback) {
        const re = new RegExp('createServerReference\\("([0-9a-f]{64})"\\);\\s*const \\w+ = query\\(\\w+, "' + fnName + '"\\)');
        return __ocMatch(text, re) || fallback;
    }
    async function __ocCall(makeRef, id, args) {
        const OC_TIMEOUT = { __ocTimeout: true };
        try {
            const ref = makeRef(id);
            const value = await __deadlineRace(function () { return ref.apply(null, args); }, 8000, OC_TIMEOUT);
            if (value && value.__ocTimeout) {
                return { status: -3, body: 'timeout after 8000ms' };
            }
            return { status: 200, body: JSON.stringify(value === undefined ? null : value) };
        } catch (e) {
            const st = (e && typeof e.status === 'number') ? e.status : 500;
            let msg = '';
            try { msg = (e && e.message) ? String(e.message) : JSON.stringify(e); } catch (x) { msg = String(e); }
            return { status: st, body: (msg || '').slice(0, 2000) };
        }
    }
    async function __ocServerGET(id, args) {
        const uuid = __ocUUID();
        const url = ORIGIN + '/_server?id=' + encodeURIComponent(id) + '&args=' + encodeURIComponent(JSON.stringify(args));
        return await __probe(url, {
            headers: {
                'X-Server-Id': id,
                'X-Server-Instance': 'server-fn:' + uuid,
                'Accept': 'text/javascript, application/json;q=0.9, */*;q=0.8'
            },
            noAuth: true
        });
    }
    function __ocDecodeBilling(result) {
        if (!result) { return { status: -1, body: '' }; }
        if (result.status < 200 || result.status >= 300) { return result; }
        const text = String(result.body || '');
        try {
            const parsed = JSON.parse(text);
            if (parsed && typeof parsed === 'object') { return { status: 200, body: JSON.stringify(parsed) }; }
            if (parsed === null) { return { status: 200, body: 'null' }; }
        } catch (e) {}
        const decoded = __ocBillingJSON(text);
        if (decoded != null) { return { status: 200, body: decoded }; }
        return { status: -2, body: 'seroval billing unavailable' };
    }
    function __ocDecodeLite(result) {
        if (!result) { return { status: -1, body: '' }; }
        if (result.status < 200 || result.status >= 300) { return result; }
        const text = String(result.body || '');
        if (__ocExplicitNull(text)) { return { status: 200, body: 'null' }; }
        try {
            const parsed = JSON.parse(text);
            if (parsed && typeof parsed === 'object') { return { status: 200, body: JSON.stringify(parsed) }; }
            if (parsed === null) { return { status: 200, body: 'null' }; }
        } catch (e) {}
        const decoded = __ocWindowsJSON(text);
        if (decoded != null) { return { status: 200, body: decoded }; }
        return { status: -2, body: 'seroval lite unavailable' };
    }
    function __ocUsable(result) {
        return !!(result && result.status >= 200 && result.status < 300 && result.body !== undefined);
    }
    if (!__ocOnSite()) {
        probes.status = { status: 401, body: '{}' };
        probes.billing = { status: 401, body: 'off-site: ' + String(location.hostname) };
        probes.lite = { status: 401, body: 'off-site' };
        return { probes: probes };
    }
    probes.status = await __probe(ORIGIN + '/auth/status', { headers: { 'Accept': 'application/json' }, noAuth: true });
    let wid = __ocWorkspace();
    if (!wid) {
        const ws = await __ocServerGET(WORKSPACES_ID, []);
        const blob = (ws && ws.body) ? String(ws.body) : '';
        wid = __ocMatch(blob, /id"?\s*:\s*"(wrk_[^"]+)"/) || __ocMatch(blob, /(wrk_[A-Za-z0-9]+)/);
    }
    if (!wid) {
        probes.billing = { status: -2, body: 'no workspace' };
        probes.lite = { status: -2, body: 'no workspace' };
        return { probes: probes };
    }
    const html = await __ocText(ORIGIN + '/workspace/' + wid);
    let makeRef = null;
    try { makeRef = await __ocRuntime(html); } catch (e) { makeRef = null; }
    let billingID = BILLING_ID_FALLBACK;
    let liteID = LITE_ID_FALLBACK;
    const commonChunk = __ocMatch(html, /(\/_build\/assets\/common-[\w-]+\.js)/);
    const entryChunk = __ocMatch(html, /(\/_build\/assets\/entry-client-[\w-]+\.js)/);
    async function __ocResolveIDs() {
        if (commonChunk) {
            billingID = await __ocServerID(await __ocText(ORIGIN + commonChunk), 'billing\\.get', BILLING_ID_FALLBACK);
        }
        if (entryChunk) {
            const entry = await __ocText(ORIGIN + entryChunk);
            const goChunk = __ocMatch(entry, /routes\/workspace\/\[id\]\/go\/index\.tsx[\s\S]{0,400}?import\(\s*(?:\/\*[^*]*\*\/\s*)?"\.\/(index-[\w-]+\.js)"/);
            if (goChunk) {
                liteID = await __ocServerID(await __ocText(ORIGIN + '/_build/assets/' + goChunk), 'lite\\.subscription\\.get', LITE_ID_FALLBACK);
            }
        }
    }
    await __ocResolveIDs();
    async function __ocBillingFallbacks() {
        if (makeRef) {
            const runtime = await __ocCall(makeRef, billingID, [wid]);
            if (__ocUsable(runtime) && runtime.status === 200) { return runtime; }
        }
        return __ocDecodeBilling(await __ocServerGET(billingID, [wid]));
    }
    async function __ocLiteFallbacks() {
        if (makeRef) {
            const runtime = await __ocCall(makeRef, liteID, [wid]);
            if (__ocUsable(runtime) && runtime.status === 200) { return runtime; }
        }
        const getLeg = __ocDecodeLite(await __ocServerGET(liteID, [wid]));
        if (__ocUsable(getLeg) && getLeg.status === 200 && getLeg.body !== 'seroval lite unavailable') {
            return getLeg;
        }
        const htmlGo = await __ocText(ORIGIN + '/workspace/' + wid + '/go');
        const ssr = __ocSSRWindows(htmlGo);
        if (ssr) { return { status: 200, body: ssr }; }
        return getLeg.status >= 100 ? getLeg : { status: -2, body: 'lite unavailable' };
    }
    const ocValues = await Promise.all([__ocBillingFallbacks(), __ocLiteFallbacks()]);
    probes.billing = ocValues[0];
    probes.lite = ocValues[1];
    return { probes: probes };
    """#
    static let longcat = probeHelper + #"""
    const probes = {};
    const headers = { 'Accept': 'application/json, text/plain, */*' };
    const CORE = { headers: headers, noAuth: true };
    const SIDE = { headers: headers, noAuth: true, timeoutMs: 8000 };
    const longcatValues = await Promise.all([
        __probe('/api/v1/user-current', CORE),
        __probe('/api/pay/quota/metering/token-packs/summary', {
            method: 'POST',
            headers: { 'Accept': 'application/json, text/plain, */*', 'Content-Type': 'application/json' },
            body: '{}',
            noAuth: true,
            timeoutMs: 8000
        }),
        __probe('/api/lc-platform/v1/tokenUsage', SIDE),
        __probe('/api/lc-platform/v1/pending-fuel-packages', SIDE)
    ]);
    probes.user = longcatValues[0];
    probes.token_packs = longcatValues[1];
    probes.token_usage = longcatValues[2];
    probes.fuel = longcatValues[3];
    return { probes: probes };
    """#
    static let mimo = probeHelper + #"""
    const probes = {};
    const headers = { 'Accept': 'application/json, text/plain, */*', 'x-timeZone': 'UTC+01:00' };
    const CORE = { headers: headers, timeoutMs: 12000, noAuth: true };
    const SIDE = { headers: headers, timeoutMs: 8000, retry: false, noAuth: true };
    const mimoValues = await Promise.all([
        __probe('/api/v1/balance', CORE),
        __probe('/api/v1/tokenPlan/detail', SIDE),
        __probe('/api/v1/tokenPlan/usage', SIDE)
    ]);
    probes.balance = mimoValues[0];
    probes.plan_detail = mimoValues[1];
    probes.plan_usage = mimoValues[2];
    return { probes: probes };
    """#
    /// Qoder
    static let qoder = probeHelper + #"""
    const probes = {};
    probes.credits = await __probe('/api/v2/me/usages/big_model_credits', {
        headers: {
            'Accept': 'application/json, text/plain, */*',
            'X-Requested-With': 'XMLHttpRequest',
            'Bx-V': '2.5.35'
        },
        noAuth: true
    });
    return { probes: probes };
    """#
    /// Perplexity
    // 纯 Cookie / AuthJS session，禁止 helper 注入 Bearer。
    static let perplexity = probeHelper + #"""
    const probes = {};
    probes.credits = await __probe('/rest/billing/credits?version=2.18&source=default', {
        headers: { 'Accept': 'application/json' },
        noAuth: true
    });
    return { probes: probes };
    """#
    static let augment = probeHelper + #"""
    const probes = {};
    const CORE = { headers: { 'Accept': 'application/json' }, noAuth: true };
    const SIDE = { headers: { 'Accept': 'application/json' }, noAuth: true, timeoutMs: 8000, retry: false };
    const augmentValues = await Promise.all([
        __probe('/api/credits', CORE),
        __probe('/api/subscription', SIDE)
    ]);
    probes.credits = augmentValues[0];
    probes.subscription = augmentValues[1];
    return { probes: probes };
    """#
    static let abacus = probeHelper + #"""
    const probes = {};
    const headers = { 'Accept': 'application/json', 'Content-Type': 'application/json' };
    const abacusValues = await Promise.all([
        __probe('/api/_getOrganizationComputePoints', {
            headers: headers, noAuth: true, timeoutMs: 12000
        }),
        __probe('/api/_getBillingInfo', {
            method: 'POST', headers: headers, body: '{}', noAuth: true, timeoutMs: 5000, retry: false
        })
    ]);
    probes.compute_points = abacusValues[0];
    probes.billing = abacusValues[1];
    return { probes: probes };
    """#
    /// T3 Chat
    static let t3chat = probeHelper + #"""
    const probes = {};
    const input = encodeURIComponent('{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}');
    probes.customer = await __probe('/api/trpc/getCustomerData?batch=1&input=' + input, {
        headers: {
            'Accept': '*/*',
            'trpc-accept': 'application/jsonl',
            'x-trpc-source': 'web-client',
            'x-trpc-batch': 'true'
        },
        noAuth: true,
        timeoutMs: 12000,
        retry: true
    });
    return { probes: probes };
    """#
    /// Notion AI
    static let notion = probeHelper + NotionProbeScript.body
    static let ollama = probeHelper + OllamaProbeScript.body
    static let stepfun = probeHelper + StepFunProbeScript.body
    static let copilot = probeHelper + CopilotProbeScript.body
    static let gemini = probeHelper + GeminiProbeScript.body
    static let antigravity = probeHelper + AntigravityProbeScript.body
    static let kiro = probeHelper + KiroProbeScript.body
}

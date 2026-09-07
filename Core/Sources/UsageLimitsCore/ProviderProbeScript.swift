import Foundation

/// 所有站内用量探针共用的 JavaScript 请求助手。
///
/// 保持在 Core 作为唯一源码，App 直接拼接此字符串；macOS 测试可用 JavaScriptCore
/// 执行同一份生产 helper，而 Core 生产目标本身仍只依赖 Foundation。
public enum ProviderProbeScript {
    public static let helper = #"""
    function __ls(key) {
        try { return localStorage.getItem(key); } catch (e) { return null; }
    }
    function __cookie(name) {
        try {
            const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            const m = document.cookie.match(new RegExp('(?:^|; )' + esc + '=([^;]*)'));
            return m ? decodeURIComponent(m[1]) : '';
        } catch (e) { return ''; }
    }
    function __unwrapToken(raw) {
        if (!raw) return '';
        try {
            const o = JSON.parse(raw);
            if (o && typeof o === 'object') {
                return o.value || o.token || o.accessToken || o.access_token || o.authorization || '';
            }
        } catch (e) {}
        return raw;
    }
    function __officialToken() {
        return __unwrapToken(__ls('userToken'))
            || __ls('access_token')
            || __cookie('bigmodel_token_production')
            || __cookie('token')
            || '';
    }
    function __authHeaders(extra) {
        const headers = Object.assign({}, extra || {});
        const token = __officialToken();
        if (token && !headers.Authorization && !headers.authorization) {
            headers.Authorization = token.indexOf(' ') >= 0 ? token : ('Bearer ' + token);
        }
        return headers;
    }
    const __PROBE_DEFAULT_TIMEOUT_MS = 12000;
    const __PROBE_DEADLINE_AT = Date.now() + 27000;
    // 1 MB：Gemini quota 单次超过 200 KB，被截断后 JSON 解析失败（真机「配额数据异常」）
    const __PROBE_TEXT_LIMIT_BYTES = 1000000;
    // 150,000 raw bytes encode to exactly 200,000 base64 bytes.
    const __PROBE_BINARY_LIMIT_BYTES = 150000;
    function __probeRemainingMs() {
        return Math.max(0, __PROBE_DEADLINE_AT - Date.now());
    }
    function __probeTimeout(timeoutMs) {
        return { status: -3, body: 'timeout after ' + Math.max(0, Math.floor(timeoutMs || 0)) + 'ms' };
    }
    // 给 dynamic import / 页面 runtime promise 等不可 Abort 的任务使用。task 必须是闭包，
    // deadline 已耗尽时不会启动；timeoutMs 会自动夹到本轮共享的 27 秒预算内。
    async function __deadlineRace(task, timeoutMs, fallback, onTimeout) {
        const remaining = __probeRemainingMs();
        if (!(remaining > 0)) { return fallback; }
        const requested = (typeof timeoutMs === 'number' && timeoutMs > 0) ? timeoutMs : remaining;
        const budget = Math.min(requested, remaining);
        return await new Promise(function (resolve, reject) {
            let settled = false;
            let timer = null;
            function finish(value, isError) {
                if (settled) { return; }
                settled = true;
                if (timer !== null) { clearTimeout(timer); }
                if (isError) { reject(value); } else { resolve(value); }
            }
            let work;
            try { work = task(); } catch (e) {
                finish(e, true);
                return;
            }
            Promise.resolve(work).then(function (value) {
                finish(value, false);
            }, function (error) {
                if (settled) { return; }
                finish(error, true);
            });
            timer = setTimeout(function () {
                if (settled) { return; }
                settled = true;
                try { if (typeof onTimeout === 'function') { onTimeout(); } } catch (e) {}
                resolve(fallback);
            }, budget);
            if (settled && timer !== null) { clearTimeout(timer); }
        });
    }
    async function __probeBackoff(delayMs) {
        if (__probeRemainingMs() <= delayMs) { return false; }
        await new Promise(function (resolve) { setTimeout(resolve, delayMs); });
        return __probeRemainingMs() > 0;
    }
    function __probeResponseHeaders(response, out) {
        try {
            const grpc = response.headers && response.headers.get ? response.headers.get('grpc-status') : null;
            if (grpc !== null && grpc !== undefined) {
                out.grpcStatus = grpc;
                out.grpcMessage = response.headers.get('grpc-message') || '';
            }
            const vercel = response.headers && response.headers.get ? response.headers.get('x-vercel-mitigated') : null;
            if (vercel !== null && vercel !== undefined) { out.vercelMitigated = vercel; }
        } catch (e) {}
    }
    function __probeFinalURL(response, out) {
        try {
            // 仅供重定向登录判定；query/hash 可能含 OAuth token，绝不越桥。
            const final = new URL(response.url);
            out.finalURL = final.origin + final.pathname;
        } catch (e) {}
    }
    function __probeContentLength(response) {
        try {
            const raw = response.headers && response.headers.get ? response.headers.get('content-length') : null;
            if (raw === null || raw === undefined || !/^\d+$/.test(String(raw).trim())) { return null; }
            const value = Number(raw);
            return Number.isSafeInteger(value) && value >= 0 ? value : null;
        } catch (e) { return null; }
    }
    function __utf8Truncate(text, limit) {
        const source = String(text || '');
        let used = 0;
        let out = '';
        for (let i = 0; i < source.length; i++) {
            const first = source.charCodeAt(i);
            let chars = 1;
            let bytes = 3;
            if (first <= 0x7f) { bytes = 1; }
            else if (first <= 0x7ff) { bytes = 2; }
            else if (first >= 0xd800 && first <= 0xdbff && i + 1 < source.length) {
                const second = source.charCodeAt(i + 1);
                if (second >= 0xdc00 && second <= 0xdfff) { chars = 2; bytes = 4; }
            }
            if (used + bytes > limit) { break; }
            out += source.slice(i, i + chars);
            used += bytes;
            i += chars - 1;
        }
        return out;
    }
    function __utf8Decode(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length;) {
            const a = bytes[i];
            if (a <= 0x7f) { out += String.fromCharCode(a); i++; continue; }
            if (a >= 0xc2 && a <= 0xdf && i + 1 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80) {
                out += String.fromCharCode(((a & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
                i += 2; continue;
            }
            if (a >= 0xe0 && a <= 0xef && i + 2 < bytes.length
                && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
                const code = ((a & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
                if (code >= 0x800 && !(code >= 0xd800 && code <= 0xdfff)) {
                    out += String.fromCharCode(code); i += 3; continue;
                }
            }
            if (a >= 0xf0 && a <= 0xf4 && i + 3 < bytes.length
                && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80
                && (bytes[i + 3] & 0xc0) === 0x80) {
                const code = ((a & 7) << 18) | ((bytes[i + 1] & 0x3f) << 12)
                    | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
                if (code >= 0x10000 && code <= 0x10ffff) {
                    const value = code - 0x10000;
                    out += String.fromCharCode(0xd800 + (value >> 10), 0xdc00 + (value & 0x3ff));
                    i += 4; continue;
                }
            }
            // Invalid/interrupted UTF-8: replacement is re-truncated below so it cannot expand past the cap.
            out += '\ufffd';
            i++;
        }
        return __utf8Truncate(out, __PROBE_TEXT_LIMIT_BYTES);
    }
    function __probeBase64(bytes) {
        let raw = '';
        for (let i = 0; i < bytes.length; i += 32768) {
            const end = Math.min(bytes.length, i + 32768);
            let part = '';
            for (let j = i; j < end; j++) { part += String.fromCharCode(bytes[j]); }
            raw += part;
        }
        return btoa(raw);
    }
    async function __probeStreamBody(response, binary, setReader) {
        const limit = binary ? __PROBE_BINARY_LIMIT_BYTES : __PROBE_TEXT_LIMIT_BYTES;
        const reader = response.body.getReader();
        setReader(reader);
        const chunks = [];
        let total = 0;
        while (total < limit) {
            const step = await reader.read();
            if (!step || step.done) { break; }
            const bytes = step.value instanceof Uint8Array ? step.value : new Uint8Array(step.value || []);
            const take = Math.min(bytes.length, limit - total);
            if (take > 0) { chunks.push(bytes.subarray(0, take)); total += take; }
            if (take < bytes.length || total >= limit) {
                try {
                    const pending = reader.cancel();
                    Promise.resolve(pending).then(function () {}, function () {});
                } catch (e) {}
                break;
            }
        }
        const joined = new Uint8Array(total);
        let offset = 0;
        for (let i = 0; i < chunks.length; i++) { joined.set(chunks[i], offset); offset += chunks[i].length; }
        return binary ? __probeBase64(joined) : __utf8Decode(joined);
    }
    // 单次请求：options 额外支持
    //   timeoutMs  超时（AbortController），默认 12000；超时返回 status -3
    //   noAuth     不自动附加 Authorization（纯 Cookie 鉴权的站点，如 claude.ai）
    //   retry      对 408 / 502 / 503 / 504 或网络层失败再试一次（默认 true）
    // 全脚本共享 27 秒 deadline，给 Swift callAsyncJavaScript 的 30 秒外层留出编码/回桥余量。
    async function __probeOnce(url, options, binary) {
        const opts = options || {};
        const remaining = __probeRemainingMs();
        if (!(remaining > 0)) { return __probeTimeout(0); }
        const controller = (typeof AbortController === 'function') ? new AbortController() : null;
        const requested = (typeof opts.timeoutMs === 'number' && opts.timeoutMs > 0)
            ? opts.timeoutMs : __PROBE_DEFAULT_TIMEOUT_MS;
        const timeoutMs = Math.min(requested, remaining);
        let activeReader = null;
        try {
            const merged = Object.assign({ credentials: 'include' }, opts);
            delete merged.timeoutMs; delete merged.noAuth; delete merged.retry;
            merged.headers = opts.noAuth ? Object.assign({}, opts.headers || {}) : __authHeaders(opts.headers || {});
            if (controller) { merged.signal = controller.signal; }
            const operation = async function () {
                const r = await fetch(url, merged);
                let body = '';
                const limit = binary ? __PROBE_BINARY_LIMIT_BYTES : __PROBE_TEXT_LIMIT_BYTES;
                const canStream = !!(r.body && typeof r.body.getReader === 'function');
                const contentLength = __probeContentLength(r);
                if (contentLength !== null && contentLength > limit && !canStream) {
                    const tooLarge = {
                        status: (r.status >= 200 && r.status < 300) ? -2 : r.status,
                        body: 'response exceeds ' + limit + '-byte limit'
                    };
                    __probeFinalURL(r, tooLarge);
                    __probeResponseHeaders(r, tooLarge);
                    return tooLarge;
                }
                if (canStream) {
                    body = await __probeStreamBody(r, binary, function (reader) { activeReader = reader; });
                } else if (binary) {
                    const all = new Uint8Array(await r.arrayBuffer());
                    body = __probeBase64(all.subarray(0, Math.min(all.length, limit)));
                } else {
                    body = __utf8Truncate(await r.text(), limit);
                }
                const out = { status: r.status, body: body };
                __probeFinalURL(r, out);
                __probeResponseHeaders(r, out);
                return out;
            };
            return await __deadlineRace(operation, timeoutMs, __probeTimeout(timeoutMs), function () {
                if (controller) { controller.abort(); }
                if (activeReader && typeof activeReader.cancel === 'function') {
                    try {
                        const pending = activeReader.cancel();
                        Promise.resolve(pending).then(function () {}, function () {});
                    } catch (e) {}
                }
            });
        } catch (e) {
            const aborted = e && (e.name === 'AbortError' || String(e).indexOf('abort') >= 0);
            return { status: aborted ? -3 : -1, body: aborted ? ('timeout after ' + timeoutMs + 'ms') : String(e) };
        }
    }
    function __transient(result) {
        return result.status < 0 || result.status === 408 || result.status === 502
            || result.status === 503 || result.status === 504;
    }
    async function __probeWithMode(url, options, binary) {
        const opts = options || {};
        let result = await __probeOnce(url, opts, binary);
        if (opts.retry !== false && __transient(result)) {
            if (await __probeBackoff(300)) { result = await __probeOnce(url, opts, binary); }
        }
        return result;
    }
    async function __probe(url, options) { return await __probeWithMode(url, options, false); }
    async function __probeBinary(url, options) { return await __probeWithMode(url, options, true); }
    """#
}

import Foundation

/// StepFun 原始 Dashboard JSON 的安全摘要探针函数体。
/// 保持在 Core 以便 macOS 测试执行 App 实际使用的生产脚本；Core 仍只依赖 Foundation。
public enum StepFunProbeScript {
    public static let body = #"""
    const probes = {};
    function __stepObject(value) {
        return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
    }
    function __stepNumber(raw) {
        if (typeof raw === 'number') { return Number.isFinite(raw) ? raw : null; }
        if (typeof raw !== 'string'
            || !/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/.test(raw)) { return null; }
        const value = Number(raw);
        return Number.isFinite(value) ? value : null;
    }
    function __stepCopyNumber(target, key, source, sourceKey) {
        const value = __stepNumber(source[sourceKey]);
        if (value !== null) { target[key] = value; }
    }
    function __stepAuthError(root) {
        const parts = [];
        ['code', 'message', 'desc'].forEach(function (key) {
            const value = root[key];
            if (typeof value === 'string' || typeof value === 'number') { parts.push(String(value)); }
        });
        const text = parts.join(' ').toLowerCase();
        return /(?:^|[^0-9])(?:401|403)(?:[^0-9]|$)/.test(text)
            || /unauthori[sz]ed|unauthenticated|token\s+expired|auth(?:entication)?\s+failed|login(?:\s+required)?|sign\s*in/.test(text);
    }
    function __stepFailure(root) {
        return { apiSuccess: false, authError: __stepAuthError(root) };
    }
    function __stepParseObject(body) {
        if (typeof body !== 'string') { return null; }
        try { return __stepObject(JSON.parse(body)); } catch (e) { return null; }
    }
    function __stepRateSummary(body) {
        const root = __stepParseObject(body);
        if (!root) { return {}; }
        const status = __stepNumber(root.status);
        if (status === null) { return {}; }
        if (status !== 1) { return __stepFailure(root); }

        const safe = { apiSuccess: true };
        __stepCopyNumber(safe, 'fiveHourLeftRate', root, 'five_hour_usage_left_rate');
        __stepCopyNumber(safe, 'fiveHourResetTime', root, 'five_hour_usage_reset_time');
        __stepCopyNumber(safe, 'weeklyLeftRate', root, 'weekly_usage_left_rate');
        __stepCopyNumber(safe, 'weeklyResetTime', root, 'weekly_usage_reset_time');
        __stepCopyNumber(safe, 'planFamily', root, 'plan_family');

        const rawCredit = __stepObject(root.plan_credit_rate_limit);
        if (rawCredit) {
            const credit = {};
            __stepCopyNumber(credit, 'subscriptionLeftRate', rawCredit, 'subscription_credit_left_rate');
            __stepCopyNumber(credit, 'subscriptionResetTime', rawCredit, 'subscription_credit_reset_time');
            __stepCopyNumber(credit, 'topupLeftRate', rawCredit, 'topup_credit_left_rate');
            if (Array.isArray(rawCredit.credit_buckets) && rawCredit.credit_buckets.length) {
                credit.buckets = rawCredit.credit_buckets.map(function (rawBucket) {
                    const bucket = {};
                    const source = __stepObject(rawBucket);
                    if (source) {
                        __stepCopyNumber(bucket, 'total', source, 'credit_total');
                        __stepCopyNumber(bucket, 'residual', source, 'credit_residual');
                    }
                    return bucket;
                });
            }
            if (Object.keys(credit).length) { safe.credit = credit; }
        }
        return safe;
    }
    function __stepPlanSummary(body) {
        const root = __stepParseObject(body);
        if (!root) { return {}; }
        const status = __stepNumber(root.status);
        if (status === null) { return {}; }
        if (status !== 1) { return __stepFailure(root); }
        const safe = { apiSuccess: true };
        const subscription = __stepObject(root.subscription);
        const rawName = subscription && subscription.name;
        if (typeof rawName === 'string') {
            const normalized = rawName.trim().toLowerCase().replace(/\s+/g, ' ');
            const plans = {
                'free': 'Free', 'mini': 'Mini', 'plus': 'Plus', 'pro': 'Pro', 'max': 'Max',
                'coding plan': 'Coding Plan', 'token plan': 'Token Plan'
            };
            if (plans[normalized]) { safe.plan = plans[normalized]; }
        }
        return safe;
    }
    function __stepSafeResult(raw, summary) {
        if (!raw || typeof raw.status !== 'number') { return { status: -2, body: '{}' }; }
        if (raw.status < 200 || raw.status >= 300) { return { status: raw.status, body: '{}' }; }
        return { status: raw.status, body: JSON.stringify(summary(raw.body)) };
    }

    const webid = __cookie('Oasis-Webid').trim();
    if (!webid) {
        probes.rate_limit = {
            status: 401,
            body: JSON.stringify({ apiSuccess: false, authError: true })
        };
        return { probes: probes };
    }

    const headers = {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'oasis-appid': '10300',
        'oasis-platform': 'web',
        'oasis-webid': webid
    };
    const values = await Promise.all([
        __probe('/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit', {
            method: 'POST', headers: headers, body: '{}', noAuth: true,
            timeoutMs: 12000, retry: true
        }),
        __probe('/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus', {
            method: 'POST', headers: headers, body: '{}', noAuth: true,
            timeoutMs: 8000, retry: false
        })
    ]);
    probes.rate_limit = __stepSafeResult(values[0], __stepRateSummary);
    probes.plan_status = __stepSafeResult(values[1], __stepPlanSummary);
    return { probes: probes };
    """#
}

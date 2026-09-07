# Ollama Cloud（ollama.com）用量接口目录

- **官网控制台 / 用量页**：`https://ollama.com/settings`；登录入口 `https://ollama.com/signin`。
- **鉴权**：本机 WebKit Cookie。探针在 `ollama.com` 页面源内执行 `fetch('/settings', { credentials: 'include' })`，只用 Cookie，**无 Bearer、无 localStorage token**，`noAuth: true`。
- **登录入口 / 探针页**：`loginURL` = `https://ollama.com/signin`，`probeURL` = `https://ollama.com/settings`。两者与用量请求同源；WorkOS 登录跳转只用于用户交互，不作为探针源。
- **Cookie 域**：`ollama.com`。CodexBar 识别过 `session`、`__Secure-session`、`ollama_session`、`__Host-ollama_session`、`wos-session`、NextAuth session（含分片）；iOS 不读 Cookie 内容，只让 WebKit 自动携带。
- **标价**：只确认接口页面可能返回 Free / Pro / Max 档位名，本轮没有可信官方金额，因此 **不改 `PlanCatalog.swift`**，卡片不显示金额和周期标签。
- **接入范围**：Cloud 的 Session（或旧版 Hourly）和 Weekly 两个速率窗口。API key 的 `/api/web_search` / `/api/tags` 只能验活、没有用量，**不接入**。
- **代码**：安全摘要探针 `OllamaProbeScript.body`（由 `ProviderScripts.ollama` 组合）、解析 `OllamaParser`，脱敏原始 HTML fixture `ollama_settings_*.html`，测试 `OllamaParserTests`。
- **观测**：2026-08-28 **按 CodexBar 的 Ollama fetcher / parser / tests 整理，待真机确认**。HTML 结构、WorkOS 跳转和档位白名单尚无我们自己的真机诊断样本。

## 接口与预算

| 地址 | 方法 · 鉴权 | 返回 | App |
|---|---|---|---|
| `GET /settings` | Cookie 自动带；`Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` | SSR 原始 HTML | 唯一网络请求；12s 超时，瞬态失败重试一次，间隔 300ms，总预算 24.3s，小于 WebView 外层 30s |

- 生产脚本必须用 `fetch` 返回的**原始 HTML 文本**做正则，不能读取 hydrate 后的 DOM。
- 通用 `__probeOnce` 会把响应的最终 URL 规整为 `origin + pathname` 后放进临时 `finalURL`；必须丢掉 query / hash，避免 WorkOS token 越桥。Ollama 脚本只在局部读取该字段做登录判定，最终 `probes.settings` **不回传 `finalURL`**。
- `401` / `403` 直接映射未登录；其它非 2xx 保留状态，但 body 固定为 `{}`，禁止把服务端 HTML / 错误页带回 Swift。
- `200` 最终落到以下任一地址，也按退出登录处理：
  - `https://ollama.com/signin`
  - `https://www.ollama.com/signin`
  - `https://signin.ollama.com/...`
  - `https://*.workos.com/user_management/authorize...`
- 上述判定在 `WebViewFetcher` 的通用 origin gate **之前**执行：离屏 WebView 初始加载 `/settings` 已经跳到登录页时，直接合成 `settings` 401 安全结果，不在登录子域误发相对请求，也不落成 `origin_drift` 网络错误。
- `200` 页面包含强认证表单信号时也按退出：含 `<form`，并同时满足「Ollama 登录标题 + email/password/auth 路由」或「登录 action/href」或「email 与 password 字段」。普通正文里出现 `sign in` 字样不能误判。

## 隐私边界：HTML 只在 WebView 内存里存在

`/settings` 的 SSR HTML 可能包含账号邮箱、姓名、WorkOS 参数或其他身份字段。它是**高敏原始响应**：

1. `rawSettings.body` 只许在生产 JavaScript 的局部变量中短暂存在；
2. 正则只能从该原始字符串抽取下面的白名单摘要；
3. `ProbeResult.body` 只许是白名单 JSON，禁止原 HTML、邮箱、姓名、账号 ID、Cookie、最终 URL 或 URL query；
4. 失败 body 固定为 `{}`（登录态可返回只含 `signedOut: true` 的 JSON）；禁止把异常字符串、响应正文或 URL 拼进诊断；
5. Swift 解析器再次执行严格 allowlist，出现额外键（尤其 email / name / identity）整份拒绝。

安全摘要唯一允许的形状：

```json
{
  "plan": "pro",
  "signedOut": false,
  "session": { "usedPercent": 12.5, "resetsAt": "2026-08-29T02:00:00Z" },
  "weekly": { "usedPercent": 34, "resetsAt": "2026-09-01T00:00:00Z" }
}
```

- `plan` 只允许小写 `free` / `pro` / `max`；未知值丢掉。
- 主窗口优先键 `session`；只有 Session block 无有效百分比时才回落 `hourly`。两者不能同时输出。
- 每个窗口只允许 `usedPercent` 和可选 `resetsAt` 两个已知键。根或任一窗口出现未知键（尤其 `email` / `name` / `id` 等身份键）时，Swift 必须**整份拒绝**，不能只丢违规窗口后继续用另一个窗口。
- `usedPercent` 必须是有限数值；Bool、字符串、NaN / Infinity 或缺失时只丢该窗口，另一条结构安全的窗口仍可用。
- `resetsAt` 是可选 ISO8601；该已知键的值类型错误、日期坏、早于 1970 或晚于 9999-12-31 时只丢重置时间，保留同窗口的有效百分比。落盘与 `JSONHelp.isSafeDate` 同一边界。
- `signedOut` 必须是 Bool。正常摘要显式 `false`；明确登录页为 `true`，此时不带其它字段。

## 原始 HTML 解析口径

页面定位和正则来自 CodexBar，所有匹配都在**原始 HTML 文本**上完成：

- 套餐：`Cloud Usage ... 下一个 span`，去掉标签后只认 Free / Pro / Max（大小写不敏感）。展示为 `Ollama Free` / `Ollama Pro` / `Ollama Max`。
- 主窗口：先找 `Session usage`，找不到有效百分比才找 `Hourly usage`。
- 周窗口：找 `Weekly usage`。
- 百分比：block 内优先完整 token `digits[.digits]% used`（大小写不敏感），fallback `width: digits[.digits]%`；左右字符边界必须安全，不能从 `-5%`、`+5%`、`.5%`、`1e2%`、`width:-5%` 中截尾抽出一个伪正数。语义已经是**已用 0–100**，不是 0–1。
- 重置：只取同一 block 内 `data-time="ISO8601"`；带 / 不带小数秒都接受。JS 与 Swift 都须先严格校验公历年月日、时分秒和时区分量（year 1...9999），禁止把非闰年 `2/29`、`2/31`、月 13、hour 24 等交给宽松日期库规范化成另一天。
- block 从标签末尾开始，到下一个 usage label 或最多 4000 字符为止，先到者截断，避免把周百分比串给 Session。超过边界的百分比 / 日期不属于该窗口。
- 百分比只接受有限数值，并钳在 0–100；日期只接受 ISO8601 且落在 Unix epoch 到 9999-12-31。坏日期只丢重置时间，不丢整条有效窗口。
- 至少有一个窗口才成功；Session / Hourly 与 Weekly 都允许单独存在。没有窗口且不是明确登录页 → 解析错误。

## `OllamaParser` 展示口径

- `session` 摘要 → `UsageMetric(id: "session", label: "Session usage", windowMinutes: 300 的语义由本目录记录，模型本身没有该字段, usedPercent:, resetsAt:, pinned: true)`。
- `hourly` 摘要 → 同一个稳定 id `session`，label = `Hourly usage`；页面没有可证实的固定窗口长度，App 不虚构。
- `weekly` 摘要 → `UsageMetric(id: "weekly", label: "Weekly usage", usedPercent:, resetsAt:, pinned: true)`；周窗口是 10080 分钟的语义口径。
- 当前 `UsageMetric` 没有 `windowMinutes` 字段，因此 300 / 10080 分钟只用于标签和目录校准，不写入快照。
- plan 只做白名单映射，不改 `billingCycle`（无可信价格与账期字段）。
- 状态分档：
  - 空 `results` → `.error("未获取到任何响应")`；
  - `settings` 401 / 403，或安全摘要 `signedOut: true` → `.needsLogin`；
  - 其它非 2xx / 网络错误 → `ProbeResult.failureStatus`；
  - 200 但不是严格安全 JSON、根 / 窗口包含未知键或额外身份字段、或没有任何窗口 → `.error("Ollama 用量数据异常")`；
  - 至少一个有效窗口 → `.ok`；另一个窗口缺失 / 百分比无效不抑制有效窗口，已知 `resetsAt` 字段的坏值只丢日期。

## 漂移复核

Ollama 的用量没有稳定 JSON API，HTML class / span 层级可能随前端发布漂移。出现「Ollama 用量数据异常」时，先用真机诊断确认原始页面形状，但**不要把原 HTML 加进诊断日志**；只在本地临时调试中核对以下内容后立即删除：usage label、百分比文案 / style、`data-time` 与最终跳转路径。确认后同一轮更新本文件、脱敏 fixture、`OllamaProbeScript` 和 `OllamaParser`。

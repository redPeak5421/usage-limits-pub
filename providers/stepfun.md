# StepFun（platform.stepfun.com）用量接口目录

- **官网 / 登录入口 / 用量页**：`https://platform.stepfun.com/plan-usage`。登录页、探针页和两条 Dashboard API 同源。
- **鉴权**：仅使用本机 WKWebView 已有的 Cookie。正常网页登录会写入 `Oasis-Token` 与 `Oasis-Webid`；`fetch(..., { credentials: 'include' })` 自动携带 `Oasis-Token`，脚本只读取可见的 `Oasis-Webid` 作为同值请求头，**绝不读取、返回或持久化 `Oasis-Token`**。
- **Cookie 域**：`stepfun.com`。退出登录清该域 WebKit 数据。
- **iOS 简化边界**：不复刻 CodexBar 的 `RegisterDevice` → `SignInByPassword` → `RefreshToken` 账密流程，也不解析 token JWT。若 `document.cookie` 没有可见、非空的 `Oasis-Webid`，本轮不发 Dashboard 请求，直接生成安全 401；用户需在内置 WebView 重新完成正常网页登录。该假设 **待真机确认**。
- **接入范围**：旧 Coding Plan 的 5 小时 / 每周滚动窗口，以及 Token / Credit Plan 的积分池。套餐状态接口只用于 best-effort 白名单套餐名。
- **标价**：本轮没有可信官方标价，不改 `PlanCatalog.swift`，`billingCycle` 恒为 `nil`。
- **代码**：Foundation-only 生产脚本体 `StepFunProbeScript.body`，App 组合为 `ProviderScripts.stepfun = probeHelper + StepFunProbeScript.body`；解析 `StepFunParser`；脱敏 fixture `stepfun_*.json`；测试 `StepFunParserTests`（macOS 下用 JavaScriptCore 执行完整生产 helper + body）。
- **观测**：2026-08-29 **按 CodexBar 的 `StepFunUsageFetcher.swift` 与对应测试整理，待 iOS 真机确认**。Dashboard API 是未公开接口，字段和 Cookie 可见性可能漂移。

## 请求与时间预算

有 `Oasis-Webid` 时两条请求用 `Promise.all` 同时发出；可选套餐请求不能阻塞或压掉核心额度：

| 探针名 | 请求 | 预算 / 重试 | 必需性 |
|---|---|---|---|
| `rate_limit` | `POST /api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit`，body `{}` | 12 秒；瞬态失败重试一次，含 300ms backoff 的最坏预算 24.3 秒 | 必需 |
| `plan_status` | `POST /api/step.openapi.devcenter.Dashboard/GetStepPlanStatus`，body `{}` | 8 秒；`retry: false` | 可选 |

两条请求都只用相对路径，并带：

```text
Accept: application/json
Content-Type: application/json
oasis-appid: 10300
oasis-platform: web
oasis-webid: <document.cookie 中的 Oasis-Webid>
credentials: include
noAuth: true
```

`Origin` / `Referer` / `User-Agent` 由 WKWebView 自动处理。两条请求并发后的总网络预算仍小于 `WebViewFetcher` 外层 30 秒。`Oasis-Token` 只由 Cookie 自动携带，禁止把它拼成 header、读取到 JavaScript 变量或越过 `callAsyncJavaScript` 边界。

## 原始响应与安全摘要

Dashboard 原始 JSON 可能带账号字段、token 回显或任意 `message` / `desc`。**原始 body 只许在 JavaScript 局部变量短暂存在**；返回 Swift 的 `ProbeResult.body` 必须按 allowlist 新建，禁止透传、合并原对象或返回未知字段。

### 核心额度原始形状

```json
{
  "status": 1,
  "five_hour_usage_left_rate": 1,
  "five_hour_usage_reset_time": "1777528800",
  "weekly_usage_left_rate": 0.99781543,
  "weekly_usage_reset_time": "1777899600",
  "plan_family": 2,
  "plan_credit_rate_limit": {
    "subscription_credit_left_rate": 0.75,
    "subscription_credit_reset_time": "1786288293",
    "topup_credit_left_rate": 0,
    "credit_buckets": [
      { "credit_total": "1000", "credit_residual": "750", "expire_at": "1792416128", "next_reset_at": "1786288293" }
    ]
  }
}
```

原始数值允许 JSON number，或不带空白、符号 `+`、指数的严格十进制字符串；实际接口的 timestamp / credit total 常为字符串。JavaScript 只接受有限值并转换成 JSON number，拒绝 Bool、空串、`NaN` / `Infinity`、`1e3` 一类数值字符串。Swift 再次只接受有限 JSON number，严格拒绝 Bool 与任何字符串。

核心成功时允许越桥的唯一形状为：

```json
{
  "apiSuccess": true,
  "fiveHourLeftRate": 1,
  "fiveHourResetTime": 1777528800,
  "weeklyLeftRate": 0.99781543,
  "weeklyResetTime": 1777899600,
  "planFamily": 2,
  "credit": {
    "subscriptionLeftRate": 0.75,
    "subscriptionResetTime": 1786288293,
    "topupLeftRate": 0,
    "buckets": [
      { "total": 1000, "residual": 750 }
    ]
  }
}
```

- 根只允许上述键；`credit` 只允许四个已知键；bucket 只允许 `total` / `residual`。Swift 发现任何额外键、身份键或类型漂移时整份拒绝。
- `expire_at` / `next_reset_at` 不参与 CodexBar 的 credit reset 口径，本轮不回传、不据此臆造重置时间。credit reset 只认 `subscription_credit_reset_time > 0`。
- HTTP 非 2xx 只保留原状态，body 固定 `{}`。
- `status != 1` 时，JavaScript 可在局部检查原始 `message` / `desc` / `code` 是否含 `401`、`403`、`unauthorized`、`unauthenticated`、`token expired`、`auth failed`、`login` / `sign in`；越桥只返回 `{"apiSuccess":false,"authError":true|false}`，禁止返回原文。
- HTTP 401 / 403 或 `authError: true` → `.needsLogin`；其它 API 失败 → 明确错误。

### 可选套餐状态

原始成功形状是 `{"status":1,"subscription":{"name":"Plus"}}`。脚本只允许以下精确套餐名（忽略首尾空白和大小写）并按此规范化：`Free`、`Mini`、`Plus`、`Pro`、`Max`、`Coding Plan`、`Token Plan`。成功摘要只有：

```json
{ "apiSuccess": true, "plan": "Plus" }
```

未知套餐名省略；失败只返回 `apiSuccess` / `authError` 布尔，不返回原 `message`、`desc`、账号或 subscription 对象。Swift 只在 HTTP 2xx、`apiSuccess == true` 且 `plan` 在同一白名单时展示 `StepFun <plan>`；套餐请求缺失、超时、401/403、失败信封或坏 JSON 均不影响核心用量。

## 计费形状分类（shape first）

先按实际 payload 结构分类，`plan_family` 只在结构模糊时兜底：

1. **任一** `fiveHourResetTime` / `weeklyResetTime > 0` 就判为 Coding / rate-window，哪怕 `planFamily == 2` 或同时存在 credit。
2. 没有 live reset，且 credit 内存在 `subscriptionLeftRate`、`topupLeftRate` 或非空 `buckets`，判为 Token / credit plan。
3. 两种结构都没有时，只有 `planFamily == 2` 才兜底判为 credit；其它形状无有效额度，报错。滚动字段的 reset 为 0 表示**没有窗口**，不能渲染成 100% used。

### Coding / rate-window

一旦判为滚动窗口，以下四个字段必须全部有效：

- `fiveHourLeftRate`、`weeklyLeftRate`：有限数值且在 `0...1`；
- `fiveHourResetTime`、`weeklyResetTime`：epoch 秒，必须 `> 0` 且不超过 `253402300799`（year 9999）。

指标顺序固定：

```text
id: five_hour     label: 5 小时窗口   usedPercent: (1 - left) × 100   resetsAt: fiveHourResetTime   pinned: true
id: weekly        label: 每周窗口     usedPercent: (1 - left) × 100   resetsAt: weeklyResetTime     pinned: true
```

5 小时 / 每周分别对应 300 / 10080 分钟；当前 `UsageMetric` 没有 `windowMinutes` 字段，因此该语义只由稳定 id、标签和目录记录。left 为 0 / 1 分别显示 100% / 0% used。字段缺失、越界、Bool、字符串、非有限数或不安全时间都使核心形状失败，不能只画半条窗口。

### Token / credit plan

只生成一个 `UsageMetric(id: "credits", label: "Credits", pinned: true)`：

1. `credit.buckets` 非空且**每个** bucket 都有有限 `total > 0`、`residual` 位于 `0...total`，并且两项求和均不溢出时，按 `Σ residual / Σ total` 加权；同时写入 `remaining = Σ residual`、`total = Σ total`。
2. bucket 为空、任一 bucket 不完整 / 越界、或求和非有限时，不用部分 bucket；回退合法的 `subscriptionLeftRate`，再无则回退合法的 `topupLeftRate`。两个独立百分比**不能相加**。
3. 所有 left rate 都必须在 `0...1`。credit plan 没有任何可用 left rate时返回错误，不能显示假 0%。
4. `usedPercent = (1 - left) × 100`；reset 只认合法且 `> 0` 的 `subscriptionResetTime`。reset 为 0 / 缺失时 `resetsAt = nil`。

credit reset 有值时 `detail = "按月重置"`；模型没有 monthly sentinel / `windowMinutes` 字段，不另外伪造周期。`billingCycle` 仍为 `nil`，因为套餐状态没有可信账期或价格。

## 状态分档

| 情况 | 快照状态 |
|---|---|
| `results` 为空 | `.error("未获取到任何响应")` |
| `rate_limit` 缺失 | `.error("未获取到 StepFun 用量响应")` |
| 核心 HTTP 401 / 403，或安全失败摘要 `authError: true` | `.needsLogin` |
| 核心其它非 2xx / 网络错误 | HTTP / 超时 / 网络错误；不读取脱敏 body 作错误文案 |
| 核心安全摘要 JSON / allowlist / 数字类型异常 | `.error("StepFun 用量数据异常")` |
| 已判定形状却缺核心字段，或 credit 无可用 left rate | `.error("StepFun 用量数据异常")` |
| 至少生成一条有效核心 metric | `.ok`；可选 `plan_status` 任何失败均不压掉 |

## 隐私与漂移复核

- `Oasis-Token`、完整 `Oasis-Webid`、原始 API body、`message` / `desc`、未知 subscription 字段不进入 `ProbeResult`、诊断日志、fixture 输出或 `ProviderSnapshot`。
- fixture 只用明显虚构的敏感占位值证明生产脚本会删除它们，不放真实 Cookie、token、设备 ID、邮箱或账号 ID。
- 真机若发现 `Oasis-Webid` 为 HttpOnly / 名称变化、Dashboard 改成跨源、字段形状或 plan 名变化，先本地诊断确认；随后同一轮更新本文、`StepFunProbeScript`、`StepFunParser` 与 fixture，不能只放宽 parser。

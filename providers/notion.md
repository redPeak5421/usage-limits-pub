# Notion AI（app.notion.com）用量接口目录

- **官网 / 登录入口 / 探针页**：`https://app.notion.com/`。登录页与两条用量请求同源。
- **鉴权**：仅使用本机 WKWebView 的 Notion Cookie。`fetch(..., { credentials: 'include' })` 会自动携带包括 HttpOnly `token_v2` 在内的 Cookie；脚本不读取 `document.cookie`，不要求可见 `token_v2`，不添加 Bearer，所有请求都设 `noAuth: true`。
- **Cookie 域**：`notion.com`、`notion.so`。退出登录清这些域的 WebKit 数据。
- **接入范围**：Notion AI 的滚动额度与计费周期额度，以及所选 workspace 的 `subscription_tier`。不接 Custom Agents / Workers 的 Notion credits。
- **标价**：**无**。本轮没有可信官方价格，`PlanCatalog` 不收录 Notion AI，`billingCycle` 恒为 `nil`。
- **代码**：Foundation-only 的生产脚本体 `NotionProbeScript.body`，App 侧组合为 `ProviderScripts.notion = probeHelper + NotionProbeScript.body`；解析 `NotionParser`，fixture `notion_spaces_*.json` / `notion_credit_limit*.json`，测试 `NotionParserTests`。JavaScriptCore 只由 macOS 测试目标导入，用 stub `__probe` 执行这份实际生产脚本；Core 产品 target 不依赖 JavaScriptCore。
- **观测**：2026-08-28 **按 CodexBar 实现整理，待真机确认**。契约来自 `reference/CodexBar/Sources/CodexBarCore/Providers/Notion/NotionUsageFetcher.swift`、`NotionUsageSnapshot.swift`、`Tests/CodexBarTests/NotionUsageFetcherTests.swift` 及其 fixture；Notion `/api/v3` 是未公开接口，可能漂移。

## 请求链与时间预算

每次刷新严格串行两步，并且只查一个 workspace：

| 探针名 | 请求 | body | 预算 / 重试 |
|---|---|---|---|
| `spaces` | `POST /api/v3/getSpaces` | `{}` | 7 秒；保留通用助手的一次瞬态重试，最坏 `7s × 2 + 300ms = 14.3s` |
| `credit_limit` | `POST /api/v3/getCreditRateLimitStatus` | `{"spaceId":"<选定 workspace id>"}` | 8 秒；`retry: false` |

总理论预算不超过 22.3 秒，给 `WebViewFetcher` 外层 30 秒留出解析与回传余量。禁止把响应正文用 UUID 正则扫一遍后最多串行请求五个 workspace；那会误把 user id 当 space id，并可能超过外层预算。

两条请求都带：

```text
Accept: */*
Content-Type: application/json
credentials: include
noAuth: true
```

`Origin`、`Referer`、`User-Agent` 由真实 WKWebView / `fetch` 自动处理。脚本只请求相对路径，Cookie 不离开 Notion 官方域名。

## `getSpaces` 选择契约

顶层是以 user id 为 key 的 record map。每条 Notion record 可能是单层 `{"value": {...}}`，也可能是双层 `{"value":{"value": {...}}}`。原始 `getSpaces` 正文只允许留在 JavaScript 局部变量中完成以下选择：

1. 在每个顶层容器的 `notion_user` map 中寻找与顶层 key 同名的 record；解包后 `id == 顶层 key` 才算“自识别用户”。
2. 恰好一个自识别用户时选它；没有自识别用户但顶层只有一个 key 时，兼容旧形状并选唯一 key；其它多用户歧义一律拒绝，不按字典顺序猜。
3. 读取该容器的 `space` map，按 map key 排序。每个 workspace 的 id 优先用 record 内非空 `id`，否则回退 map key。
4. 在排序结果中优先选择 `subscription_tier` 为 `business` / `enterprise`（忽略大小写）的第一项；没有时回退第一项。
5. 没有任何可用 workspace 时返回明确错误，不发第二条请求。

示意形状（全部 ID 均为测试占位值，不是用户数据）：

```json
{
  "user-placeholder": {
    "notion_user": {
      "user-placeholder": { "value": { "value": { "id": "user-placeholder" } } }
    },
    "space": {
      "workspace-free": {
        "value": { "id": "workspace-free", "subscription_tier": "free" }
      },
      "workspace-business": {
        "value": { "value": { "id": "workspace-business", "subscription_tier": "business" } }
      }
    }
  }
}
```

脚本只用选中的 workspace id 构造第二条请求。该 id 与原始 `getSpaces` 正文都**不得**赋给 `probes.spaces`、不得越过 `callAsyncJavaScript` 边界，也不得进入诊断日志。返回 Swift 的 `spaces` 是新建的最小摘要：

```json
{ "hasWorkspace": true, "subscriptionTier": "business" }
```

- `ProbeResult.status` 只复制原请求 HTTP / 网络状态。
- `hasWorkspace` 必须是 JSON Bool。
- `subscriptionTier` 先去空白、转小写，只允许 `free` / `plus` / `business` / `enterprise`；其它值直接省略，不能回传任意原文。
- 无 workspace / 多用户歧义 / 解析异常统一返回 `{"hasWorkspace":false}`；非 2xx / 网络失败正文固定为 `{}`，绝不回显服务端原文。
- Swift 只读取这个安全摘要，不再接触 record map；Bool / 字符串类型漂移、未知 tier 或额外字段一律拒绝。

email、name、user id、workspace id / name 都不进入 `ProbeResult`、诊断日志或 `ProviderSnapshot`。含身份形状的 fixture 也只使用明显虚构的占位值。

## `getCreditRateLimitStatus` 响应

```json
{
  "status": "within_limit",
  "window": {
    "creditType": "basic_ai_credits",
    "scope": "per_user",
    "window": "6h",
    "used": 25,
    "limit": 50
  },
  "resetsInSeconds": 0,
  "billingPeriodWindow": {
    "cadence": "billing_period",
    "used": 18,
    "limit": 100,
    "periodEndMs": 1788000000000
  },
  "enforcement": "preview"
}
```

`status == "not_applicable"` 表示所选 workspace 没有可跟踪的 AI allowance，必须返回明确错误；不能显示 0%，也不能提示重新登录。

原始额度响应同样只在 JavaScript 局部解析。返回的 `credit_limit` body 由脚本按 allowlist 重建，只保留 `status`、滚动窗口的安全 `window` token 与数值、`resetsInSeconds`、计费周期窗口的数值 / `periodEndMs`。不回传未知字段、身份字段或任意字符串；失败与非法 JSON 固定返回 `{}`。因此诊断持久化的只是额度数字 / 状态，不是服务端原文。

### 滚动窗口

```text
id:          rolling
label:       Rolling（按 window token 显示，如 6 小时）
usedPercent: clamp(used / limit × 100, 0...100)
remaining:   max(limit - used, 0)
total:       limit
resetsAt:    now + resetsInSeconds
pinned:      true
```

- `used` / `limit` 必须是有限、非负 JSON 数字，拒绝 Bool 与数字字符串，且 `limit > 0`。
- 百分比按接口返回的 `limit` 计算，不能假设总额恒为 100；App 的 `UsageMetric` 约束为 0...100，因此超额时钳到 100。
- `window` 支持 **1–9 位**正整数加 `m` / `h` / `d` / `w`。JS allowlist 与 Swift 解析器使用同一明文上限；10 位或更长 token 一律丢弃并回退通用 `Rolling` 标签。换算分钟仍须防 `Int` 乘法溢出。
- `resetsInSeconds == 0` 合法，表示当前时刻重置；负数、非有限数或相加后超出安全 epoch（0...`253402300799` 秒）时丢弃重置时间。

### 计费周期窗口

```text
id:          billing_period
label:       Billing Period
usedPercent: clamp(used / limit × 100, 0...100)
remaining:   max(limit - used, 0)
total:       limit
resetsAt:    periodEndMs / 1000（epoch 毫秒）
pinned:      true
```

数值约束与滚动窗口一致。`periodEndMs` 必须是有限正 JSON 数字，换算后的 epoch 秒须位于 0...`253402300799`；坏日期只丢弃 `resetsAt`。`cadence` 不改变稳定 id。

两个窗口独立：缺失或不可测的一项可以跳过；至少一个窗口有效才返回 `.ok`，两者都不可测则返回解析错误。指标顺序固定为 `rolling`、`billing_period`。安全摘要不保留服务端任意字符串，`detail` 因而为空。

套餐名来自安全摘要中 allowlist 后的 `subscriptionTier`，例如 `business` → `Notion AI Business`、`enterprise` → `Notion AI Enterprise`。不据此猜价格或计费周期。

## 状态分档

Notion 的 403 也可能代表 workspace / 内部接口问题，只有服务端 HTTP 401 能证明会话失效：

| 情况 | 状态 |
|---|---|
| `results` 为空 | `.error("未获取到任何响应")` |
| `spaces` 缺失 | `.error("未获取到 Notion workspace 响应")` |
| 任一必需请求 HTTP 401 | `.needsLogin` |
| HTTP 403 或其它非 2xx | `.error("HTTP <status>")`；禁止走把 403 映射成登录的通用 `failureStatus` |
| `status == -3` | 固定 `.error("请求超时")`，不读取脱敏后的 `{}` body |
| 其它 `status < 0` | 固定 `.error("网络错误")`，不把脱敏 body 当错误文案 |
| `spaces` 安全摘要类型漂移 / 未知字段 | `.error("Notion workspace 摘要异常")` |
| 多用户歧义、无 workspace、原始 JSON 无法选择 | `.error("未找到 Notion workspace")`（脚本只返回安全 `hasWorkspace:false`，不泄漏原始原因 / 身份） |
| `credit_limit` 缺失 | `.error("未获取到 Notion AI 额度响应")` |
| `status == not_applicable` | `.error("当前 workspace 不适用 Notion AI 额度")` |
| 额度 JSON 非对象、全 nil、两个窗口均不可测 | 明确解析错误 |
| 至少一个窗口有效 | `.ok` |

## 隐私与漂移

- HttpOnly `token_v2` 只由 WebKit 随同源请求自动发送；脚本和解析器都不读取或保存它。
- 原始 workspace 与额度正文只在 JS 局部使用；诊断日志只会拿到重建后的安全摘要。不得把原始 body 赋给任何 `probes.*`。
- 不解析、不落盘 email、name、user id、workspace id / name。快照只含 allowlist tier、额度数字和时间。
- fixture 只使用 `user-placeholder` / `workspace-*` 等占位 ID 与虚构额度；不放真实 Cookie、token、账号或组织资料。
- 真机若出现新 record 包装、字段或状态码，先看诊断日志确认，再同步修改本文、探针、解析器与 fixture。

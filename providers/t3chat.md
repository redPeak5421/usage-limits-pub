# T3 Chat（t3.chat）用量接口目录

- **官网 / Usage 页**：`https://t3.chat/settings/subscription`。
- **登录入口 / 探针页**：`loginURL` 与 `probeURL` 都是 `https://t3.chat/settings/subscription`，探针只打同源相对路径。
- **鉴权**：本机 `t3.chat` WebKit Cookie jar；没有单一固定 Cookie 名，也无 Bearer / API key / localStorage token。站内 `fetch(..., { credentials: 'include' })` 自动携带，探针 `noAuth: true`。
- **Cookie 域**：`t3.chat`。退出登录清该域 WebKit 数据。
- **接入范围**：4 小时 Base 主窗口、Overage 次窗口、套餐名。不读账号、邮箱、余额或 Cookie 内容。
- **标价**：**无**。接口可返回 Free / Pro / Team 等套餐名，但本轮没有核对可信官方标价；`PlanCatalog` 不收录 T3 Chat，`billingCycle` 恒为 `nil`。
- **代码**：探针 `ProviderScripts.t3chat`，解析 `T3ChatParser`，fixture `t3chat_customer.jsonl` / `t3chat_customer_fallback.jsonl`，测试 `T3ChatParserTests`。
- **观测**：2026-08-28 **按 CodexBar 实现整理，待真机确认**。契约来自 `reference/CodexBar/Sources/CodexBarCore/Providers/T3Chat/T3ChatUsageFetcher.swift`、`T3ChatUsageSnapshot.swift` 与 `Tests/CodexBarTests/T3ChatUsageFetcherTests.swift`；尚未在 iOS 真机登录态核对报文。

## 请求

每次刷新只发一条同源 tRPC batch GET：

```text
GET /api/trpc/getCustomerData?batch=1&input=<URL encoded>
```

`input` 编码前的**精确原文**：

```json
{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}
```

请求头：

```text
Accept:        */*
trpc-accept:   application/jsonl
x-trpc-source: web-client
x-trpc-batch:  true
```

`Sec-Fetch-*`、`Origin`、`Referer`、`User-Agent` 由真实 WKWebView / `fetch` 自动补，禁止手写桌面端指纹头。
子请求显式使用 12 秒预算，并允许通用助手对网络错误 / 408 / 502 / 503 / 504 **重试一次**；最坏为 `12s × 2 + 300ms`，严格小于 `WebViewFetcher` 外层 30 秒。

## JSONL 响应与查找规则

响应不是普通单对象 JSON，而是**逐行 JSON**。每行独立解析；垃圾行 / 空行跳过，再递归扫描字典和数组，找到包含 T3 customer 用量字段的对象：

```jsonl
{"json":{"0":[[0],[null,0,0]]}}
not-json
{"json":[2,0,[[{"subTier":"pro","usageBand":"max","usageFourHourPercentage":12.5,"usageMonthPercentage":34.25,"usageFourHourNextResetAt":1779366216920,"subscription":{"productName":"pro","currentPeriodEnd":1780763009000}}]]]}
```

找到 customer 对象后，**主窗口 `usageFourHourPercentage` 必须是有限 JSON 数字**才算核心成功；字符串、Bool、只含 `subscription` 或次窗口的对象都不是有效核心。
解析器会遍历全部 JSONL 行、按数组原顺序和字典排序键递归收集候选，再优先选择主百分比有效且字段最完整的 customer。前一行或同一行出现的坏候选不能遮住后面的有效结果；整份响应都没有有效主候选时才报告形状错误。

递归设有 48 层 / 10,000 节点的防御预算。超过任一上限即停止并安全返回形状错误，避免异常深或异常宽的非公开 tRPC 响应造成栈溢出或长时间占用。

## 字段映射

| 字段 | 用途 |
|---|---|
| `usageFourHourPercentage` | 主窗口已用百分比，原始口径 0–100 |
| `usageFourHourNextResetAt` | 主窗口重置；优先 |
| `usageWindowNextResetAt` | 主窗口重置 fallback |
| `usageMonthPercentage` | Overage 百分比；优先 |
| `usagePeriodPercentage` | Overage 百分比 fallback |
| `subscription.currentPeriodEnd` | Overage 唯一允许的重置时间 |
| `billingNextResetAt` | **不用于 Overage**；它是用量窗口重置，避免误标账期 |
| `usageBand` | 拼到主窗口 detail（如 `Base - max`） |
| `subscription.productName` | 套餐名；优先 |
| `subTier` | 套餐名 fallback |

### 数值与日期安全

- 百分比字段必须是 JSON 数字，拒绝 Bool、字符串、NaN、Infinity；有效有限值按 CodexBar 口径钳到 0–100。
- 时间戳必须是有限正数：`> 1e10` 按 epoch 毫秒，否则按秒；换算后的 epoch 秒不得超过 `253402300799`（9999-12-31 23:59:59 UTC），否则丢弃。
- 优先字段缺失或非法时才尝试 fallback。非法可选字段只让该字段 / 次窗口缺失，不能压掉有效主窗口。
- 所有成功快照必须能被 `JSONEncoder` 编码，不允许非有限 Double / Date 落盘。

## 指标口径

### 主窗口

```text
id:          four_hour
label:       Base（4 小时）
usedPercent: clamp(usageFourHourPercentage, 0...100)
resetsAt:    usageFourHourNextResetAt ?? usageWindowNextResetAt
detail:      usageBand 非空 ? "Base - <usageBand>" : "Base"
pinned:      true
```

主窗口有效是 `.ok` 的必要条件；即使 0% 也要展示。

### 次窗口

```text
id:          overage
label:       Overage
usedPercent: usageMonthPercentage ?? usagePeriodPercentage（再钳 0...100）
resetsAt:    subscription.currentPeriodEnd
```

次窗口没有有效百分比时不产出。`billingNextResetAt` 永远不拿来补 Overage 重置。

### 套餐名

原值优先 `subscription.productName`，缺失 / 空白时回落 `subTier`。去首尾空白，再按空格、连字符、下划线分词并标题化（如 `pro` → `Pro`、`team-plan` → `Team Plan`）；不补造 T3 前缀，不据此造标价。

## 登录与风控状态

| 情况 | 状态 |
|---|---|
| `results` 为空 | `.error("未获取到任何响应")` |
| `customer` 缺失 | `.error("未获取到 T3 Chat 响应")` |
| HTTP 401 / 403 | `.needsLogin` |
| HTTP 429 且响应头 `x-vercel-mitigated: challenge`（值忽略大小写） | `.error("T3 Chat 遇到 Vercel 风控挑战")` |
| 普通 HTTP 429 | `.error("HTTP 429")` |
| 其它非 2xx / 网络错误 | `ProbeResult.failureStatus` |
| 2xx 但无 customer / 主窗口非法 | 明确的解析错误 |
| 主窗口有效，次窗口 / 套餐 / 重置缺失或非法 | `.ok` |

通用探针只透传最小必要响应头：既有 gRPC 的 `grpc-status` / `grpc-message` 保持不变，另为 T3 Chat 透传 `x-vercel-mitigated`；不把 Cookie 或其它响应头写入 `ProbeResult`。

## 隐私与漂移

- customer 未来若出现邮箱、账号 ID、支付信息，一律不解析、不落盘。
- fixture 只放虚构套餐与数值，不放真实 Cookie、用户 ID、token 或支付信息。
- 这是 T3 Chat 未公开的站内 tRPC；若接口路径、input 或 JSONL 形状漂移，先用真机诊断日志确认，再同步修改本文件、探针和 fixture。

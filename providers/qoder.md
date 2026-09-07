# Qoder（qoder.com）用量接口目录

- **官网控制台**：`https://qoder.com/account/usage`（国内站 `https://qoder.com.cn/account/usage`）
- **鉴权**：本机 WebKit Cookie（站点会话 Cookie，HttpOnly）。站内 `fetch(..., { credentials: 'include' })` 自动携带；无 Bearer / API key、无 CSRF、无 token 派生。
- **登录入口 / 探针页**：`loginURL` 与 `probeURL` 都是 `https://qoder.com/account/usage`。
- **Cookie 域**：`qoder.com` / `qoder.com.cn`（`ProviderID.qoder.cookieDomains` 两个都清）。退出登录清这两个域的 WebKit 数据。
- **标价**：`reference/CodexBar/docs/qoder.md` **未记录任何档位标价**，官网价目也未在本轮核对 → `PlanCatalog` 不收录 Qoder，卡片不画周期标签。接口本身也不返回套餐名，`planName` 恒为 `nil`。
- **接入范围**：大模型积分（big model credits）单窗口。不接 token 花费历史（CodexBar 也明确不支持）。
- **代码**：探针 `ProviderScripts.qoder`，解析 `QoderParser`，fixture `qoder_credits.json` / `qoder_credits_snake.json` / `qoder_credits_shared.json` / `qoder_credits_shared_zero.json` / `qoder_credits_zero.json` / `qoder_credits_epoch_millis.json`，测试 `QoderParserTests`。
- **观测**：2026-08-28 **按 CodexBar 实现整理，待真机确认**。形状来自 `reference/CodexBar/Sources/CodexBarCore/Providers/Qoder/QoderUsageFetcher.swift` 与 `Tests/CodexBarTests/QoderUsageFetcherTests.swift`（其 fixture 注明来自 steipete/CodexBar#1590 的浏览器实抓）。我们这边**尚未有真机诊断日志**。

## 接口表

地址一律**路径相对**（`/api/v2/...`），不写死 host —— 探针跑在哪个站点源里就打哪个站点，国际站与国内站因此共用同一份脚本。

| 地址 | 方法 · 鉴权 | 返回 | App |
|---|---|---|---|
| `/api/v2/me/usages/big_model_credits` | GET · Cookie 自动带 | `{ totalQuota: { quotaSummary: {…} }, sharedQuota?, nextResetAt }` | 探针 `credits`（唯一探针，`keyProbe`） |
| `/account/usage` | GET · Cookie | 用量页 HTML | `loginURL` / `probeURL` |

请求头（`ProviderScripts.qoder`，与 CodexBar 逐字对齐）：

```
Accept:           application/json, text/plain, */*
X-Requested-With: XMLHttpRequest
Bx-V:             2.5.35
credentials: include        // Origin / Referer / Accept-Language / UA 由 WebView 自动补，禁止手写
```

- **`Bx-V` 是硬编码的前端版本 / 指纹头**，取自 CodexBar 2026-08 的观测值。Qoder 前端换版本时它是第一个要重抓的头：接口开始返回 4xx 或空包，先看这里。
- `noAuth: true`（不附加任何自定义鉴权），`retry` 走探针默认。

### 国内站（`qoder.com.cn`）

`qoder.com.cn` 与 `qoder.com` 各自**完全同源**，没有单独的网关 host，路径、请求头、响应形状全部一致。因为探针脚本是路径相对的，只要 WebView 停在 `qoder.com.cn` 上，同一份脚本就直接可用。

但当前 `ProviderID.qoder` 的 `loginURL` / `probeURL` 写死的是**国际站** `qoder.com`，所以：

- **国内站账号目前必须先在国际站登录入口里手动改地址栏（或从国际站跳转）落到 `qoder.com.cn` 才能被探到**，不是开箱可用。
- 是否为国内站单开一个 `ProviderID`（如 `qoder_cn`，比照 `minimax` / `minimax_global` 的双站模式）**待定** —— 需要先有国内站真机账号确认响应形状与 `Bx-V` 是否同值。在那之前不擅自加 id。

## 形状示例

### `GET /api/v2/me/usages/big_model_credits`（camelCase，按 CodexBar 实现整理，待真机确认）

```json
{
  "userId": "<redacted>",
  "quotaKey": "big_model_credits",
  "nextResetAt": "2024-09-01T00:00:00Z",
  "status": "active",
  "totalQuota": {
    "quotaSummary": {
      "usedValue": 125,
      "limitValue": 500,
      "remainingValue": 375,
      "usagePercentage": 25,
      "unit": "credit"
    },
    "quotaDetail": []
  }
}
```

同一接口也出现过**全 snake_case** 的形态（`total_quota` / `quota_summary` / `used_value` / `limit_value` / `remaining_value` / `usage_percentage` / `next_reset_at`），两套 key **必须都认**，逐字段独立回落（camelCase 优先）。

### 团队共享额度（`sharedQuota`）

套餐额度用尽后，团队共享包（resource pack）是**另一个池子**，与 `totalQuota` 并列返回：

```json
{
  "totalQuota":  { "quotaSummary": { "usedValue": 1500, "limitValue": 1500, "remainingValue": 0,   "usagePercentage": 100, "unit": "credit" } },
  "sharedQuota": { "quotaSummary": { "usedValue": 200,  "limitValue": 1000, "remainingValue": 800, "usagePercentage": 20,  "unit": "credit" } }
}
```

→ 合并成 used 1700 / total 2500 / remaining 800 / 68%。**只出一条指标，不拆两条**（与 CodexBar 展示口径一致）。

### 字段说明

| 字段 | 含义 |
|---|---|
| `totalQuota.quotaSummary` \| `total_quota.quota_summary` | 主额度池。缺失即视为形状漂移 |
| `usedValue` \| `used_value` | 已用积分（**计数，不是百分比**） |
| `limitValue` \| `limit_value` | 总额度 |
| `remainingValue` \| `remaining_value` | 剩余；缺失时算 `max(0, limit - used)` |
| `usagePercentage` \| `usage_percentage` | **已经是 0–100**。缺失时算 `used / total × 100` |
| `unit` | 单位文本（如 `"credit"`）；可空 |
| `sharedQuota` \| `shared_quota` | 团队共享包，形状同上；存在时与主池**逐项相加** |
| `nextResetAt` \| `next_reset_at` | ISO8601 字符串，或 epoch 数值（`> 1e10` 判毫秒）；可空 |

**百分比口径警告**：`usagePercentage` 已是 0–100，**禁止走 `JSONHelp.percent`**（它会把 ≤1 的值再乘 100，「0.5%」会变成「50%」）。解析器直接取值后钳 0–100。

单一窗口，接口不给窗口长度（无 5h / 周 / 月拆分）。

## 解析口径（`QoderParser`）

- **登录判定**：`credits` 探针 401 / 403 → `.needsLogin`；其它非 2xx / 网络层错误 → `ProbeResult.failureStatus`（`HTTP n` / `请求超时` / 网络错误文本）；`results` 为空 → `.error("未获取到任何响应")`。
- **合并**：`totalQuota` 与 `sharedQuota` 逐项相加（used / limit / remaining 各自求和），`unit` 取主池、主池没有再取共享池。合并后百分比**一律重算** `used / total × 100`，不采信任一边的 `usagePercentage`（两个池子的百分比无法相加）。
- **只有主池时**：百分比优先用接口给的 `usagePercentage`，缺失才算 `used / total × 100`。
- **严格性（照搬 CodexBar，不做静默 clamp）**：下列情形一律判成解析失败 `.error("配额数据异常")`，而不是钳到 0 或造一条假指标 ——
  - `usedValue` / `limitValue` / `remainingValue` 任一为负；
  - 接口给的 `usagePercentage` 为负；
  - `limitValue == 0` 但 `usedValue != 0` 或 `remainingValue != 0`（总额为 0 就必须处处为 0）。
  - 任一数值为 NaN / Infinity，或主池与共享池相加后溢出为非有限值；
  - `limitValue == 0` 且 used / remaining 都为 0 时是**合法的「额度耗尽 / 未分配」态**：百分比取接口值，缺失按 `100`。
- **缺 `totalQuota.quotaSummary`、body 不是 JSON 对象**：同样 `.error("配额数据异常")`，不崩、不产指标。
- `nextResetAt` 的非有限 epoch 或 1970–9999 范围外日期直接丢弃；任何成功快照都必须能被 `JSONEncoder` 正常编码。
- **产出**（成功时 `.ok`，恒一条）：

  ```
  UsageMetric(id: "credits", label: "Credits",
              usedPercent: <0–100 钳位>, remaining: <剩余>, total: <总额>,
              resetsAt: nextResetAt, pinned: true,
              detail: "已用 125 / 500 credit")
  ```

  `detail` 里数值为整数时不带小数点；`unit` 为空时退化成 `"已用 125 / 500"`。
- `pinned: true`：0% 也要露出来（这是该账号唯一的额度窗口，藏了卡片就空了）。
- `planName` / `billingCycle` / `planExpiresAt` 恒为 `nil` —— 接口不返回套餐信息，也没有可用的标价表。

## 登录与页面复用规则

- 探针页与登录页同为 `/account/usage`，同源，无需专门的就绪判定。
- 未登录时该页会跳登录流程；接口会返回 401 / 403，解析器据此判 `.needsLogin`。
- 多账号走独立 `WKWebsiteDataStore`，与其它服务商一致。

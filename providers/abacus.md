# Abacus AI（apps.abacus.ai）用量接口目录

- **官网 / 登录入口**：`https://apps.abacus.ai/`。登录页与探针页同源，`loginURL` / `probeURL` 都落在 `apps.abacus.ai`。
- **鉴权**：本机 WebKit Cookie。站内 `fetch(..., { credentials: 'include' })` 自动携带；无 Bearer、API key、CSRF 或 localStorage token，探针一律 `noAuth: true`。
- **Cookie 域**：`abacus.ai`（同时覆盖 `apps.abacus.ai`）。退出登录清该域 WebKit 数据。
- **接入范围**：组织 Compute Points 总额 / 剩余量，以及 best-effort 的套餐名、下次账单日。不读取账号、组织名或任何 Cookie 内容。
- **标价**：**无**。CodexBar 仅观测到 `Basic` / `Pro` 等套餐名，未记录可信官方价格；`PlanCatalog` 不收录 Abacus AI，`billingCycle` 恒为 `nil`。
- **代码**：探针 `ProviderScripts.abacus`，解析 `AbacusParser`，fixture `abacus_compute_points.json` / `abacus_billing.json`，测试 `AbacusParserTests`。
- **观测**：2026-08-28 **按 CodexBar 实现整理，待真机确认**。契约来自 `reference/CodexBar/Sources/CodexBarCore/Providers/Abacus/AbacusUsageFetcher.swift`、`AbacusUsageSnapshot.swift` 与 `Tests/CodexBarTests/AbacusProviderTests.swift`；尚未在 iOS 真机登录态核对报文。

## 接口表

两条请求从 `https://apps.abacus.ai` 页面源内**并发**发出，总体仍受 `WebViewFetcher` 外层 30 秒限制：

| 探针名 | 请求 | 预算 / 重试 | 用途 |
|---|---|---|---|
| `compute_points` | `GET /api/_getOrganizationComputePoints` | 12 秒；保留通用助手的一次瞬态重试（理论上限 24.3 秒） | **必需**。总额与剩余额度。 |
| `billing` | `POST /api/_getBillingInfo`，body 必须为 `{}` | 5 秒；`retry: false` | 可选。套餐名与下次账单日；失败不能压掉主额度。 |

两条都带：

```text
Accept: application/json
Content-Type: application/json
credentials: include
```

`Origin` / `Referer` / `User-Agent` 由 WKWebView 自动补，禁止手写。探针只请求相对路径，凭据不会离开 Abacus 官方域名。

## 统一响应信封

成功响应必须同时满足 `success` 是 JSON 布尔值 `true`、`result` 是对象：

```json
{
  "success": true,
  "result": {
    "totalComputePoints": 1000,
    "computePointsLeft": 750
  }
}
```

`success: 1`、字符串 `"true"`、缺 `result` 或 `result` 不是对象都不是成功信封。失败形状：

```json
{ "success": false, "error": "session expired" }
```

- HTTP 401 / 403 → `.needsLogin`。
- `success != true` 且 `error`（忽略大小写）含 `expired` / `session` / `login` / `authenticate` / `unauthorized` / `unauthenticated` / `forbidden` → `.needsLogin`。
- 其它失败信封、非对象顶层、非法 JSON → 明确的解析错误，不伪装成未登录。
- 上述登录判定以必需的 `compute_points` 为准；可选 `billing` 的任何失败都只让套餐 / 重置时间缺失。

## 字段与解析口径

### `compute_points.result`

| 字段 | 含义 |
|---|---|
| `totalComputePoints` | 总 Compute Points |
| `computePointsLeft` | 剩余 Compute Points |

两个字段都必须是 JSON 数字（拒绝 Bool / 数字字符串），且有限、非负，并满足 `computePointsLeft <= totalComputePoints`。否则核心数据无效，返回解析错误；不得 clamp、不得让 NaN / Infinity 进入快照。

单一指标：

```text
id:          compute_points
label:       Compute Points
used:        totalComputePoints - computePointsLeft
usedPercent: total > 0 ? used / total × 100 : 0
remaining:   computePointsLeft
total:       totalComputePoints
pinned:      true
detail:      已用 <used> / <total> points
```

百分比现算后钳在 0–100，不走 `JSONHelp.percent`。`total == 0 && left == 0` 是合法零额度，仍因 `pinned` 展示。

### `billing.result`

```json
{
  "success": true,
  "result": {
    "nextBillingDate": "2026-09-28T08:30:00.123Z",
    "currentTier": "pro"
  }
}
```

- `nextBillingDate` 只接 ISO8601；兼容带小数秒与不带小数秒两种。非法值、早于 1970 或晚于 9999-12-31 的日期直接丢弃 `resetsAt`，不影响额度，也不让可选账单日把整张快照判成不可落盘。
- `currentTier` 去首尾空白；已知 `free` / `basic` / `pro` / `team` / `enterprise` 按英文标题格式展示（如 `pro` → `Pro`），未知非空值保留原文。不补造「Abacus」前缀，也不据此造标价。
- `resetsAt = nextBillingDate`；`planName = currentTier`；`billingCycle` / `planExpiresAt` 恒为 `nil`。

## 状态分档

| 情况 | 状态 |
|---|---|
| `results` 为空 | `.error("未获取到任何响应")` |
| `compute_points` 缺失 | `.error("未获取到算力点响应")` |
| 核心 HTTP 401 / 403 或认证失败信封 | `.needsLogin` |
| 核心其它非 2xx / 网络错误 | `ProbeResult.failureStatus` |
| 核心成功但信封 / 字段非法 | 解析错误 |
| 核心有效，不论 `billing` 成功、失败或缺失 | `.ok` |

## 隐私与漂移

- 响应中未来若出现账号、组织、邮箱等身份字段，一律不读、不存、不进快照。
- fixture 只放虚构数字与套餐名；不放真实 Cookie、用户 ID 或 token。
- Abacus 使用内部接口；真机若出现新字段、信封或状态码，先用诊断日志核对，再同步修改本文件、探针与 fixture。

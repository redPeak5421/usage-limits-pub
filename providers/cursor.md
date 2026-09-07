# Cursor（cursor.com）用量接口目录

- **官网 Usage 页**：https://cursor.com/dashboard/usage（Spending 页 https://cursor.com/dashboard/spending 是计量名的对齐来源）
- **鉴权**：本机 WebKit Cookie（httpOnly `WorkosCursorSessionToken`，域 `cursor.com`）。探针在 cursor.com 源内以 `fetch(..., credentials: 'include')` 执行，不带 Authorization。Cookie 域：`cursor.com`、`cursor.sh`。
- **登录入口**：`https://cursor.com/dashboard`——未登录会被引去 WorkOS 授权（Google / GitHub / 邮箱），完成后回到 cursor.com 同源。
- **探针执行页**：`https://cursor.com/dashboard`；登录检测优先复用已进入 Dashboard 的可见主页面或 OAuth 弹窗。
- **接口性质**：社区逆向的仪表盘端点（无官方文档，随时可能漂移），解析全程防御式。

## 已解析 API（探针名 → 代码）

### 2026-09-05 登录验证回归

真机日志连续 7 轮 `auth_me=204/hasSub=false`，两条用量接口均为 401。仅凭此日志不能证明官网登录失败，也不能反推新的响应字段。登录检测改为等待 Dashboard 文档并在当前文档执行新探针，不用离屏首页或历史快照判定成功；官网认证域 `cursor.sh` 与 `cursor.com` 之间的 OAuth 弹窗导航保留。诊断只增加检测页面 host、是否加载中、会话 Cookie 是否存在等信息，不输出 Cookie 值或回跳 query。接口、Parser 的 401 判定与账号隔离保持原契约，修复后仍需在真机完成实际登录复验。

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `usage_summary` | `GET /api/usage-summary`，`Accept: application/json` | 登录判定 + 套餐 + 计费周期 + Cursor Models / Other Models / On-demand | `CursorParser` |
| `sand_usage_status` | `POST /api/dashboard/get-sand-usage-status`，`Content-Type: application/json`，body `{}` | Grok Bot 周额度（SAND 是站内代号） | `CursorParser` |
| `auth_me` | `GET /api/auth/me`，`Accept: application/json`，独立超时 4s | JS 内用 `sub` 拼 `request_usage`；过桥只回 `{hasSub, identityFingerprint}`，`sub` / email / name 原文不越桥 | `CursorParser` |
| `request_usage` | `GET /api/usage?user=<sub>`，`Accept: application/json`；仅在拿到 `sub` 时发 | 旧版**按请求数**计费套餐的用量 | `CursorParser` |

`auth_me` / `request_usage` 两行按 CodexBar 实现整理（`CursorStatusProbe.swift:1547-1586`），**待真机确认**。两者都是尽力而为：失败、超时、404 都不影响 `usage_summary` 的主用量与登录判定。

编排：`usage_summary`、`sand_usage_status`、`auth_me` 同时发出；`request_usage` 只等待 `auth_me`（或 Cookie payload）得到 `sub`，不等待两条主探针。所有腿共用目录 README 定义的 27 秒 deadline。

`sub` 的取法：优先 `auth_me` 响应里的 `sub`；拿不到时退回 Cookie `WorkosCursorSessionToken`，其值形如 `<userID>%3A%3A<JWT>`，解码后按 `::` 切开取 JWT，base64url 解 payload 拿 `sub`，再取 `|` 之后的一段。该 Cookie 通常是 httpOnly（`document.cookie` 读不到），所以这条回退多半落空，属正常。两条都拿不到就不发 `request_usage`。

**隐私**：`auth_me` 还会返回 `email` / `name` / `picture`，**一律不解析、不落盘、不展示**，只取 `sub` 拼 URL，并哈希为 `identityFingerprint`（`aiusage-identity-v1|cursor|sub|<sub>`），`sub` 原文不落盘。

**usage-summary 响应形状**（fixture `cursor_usage_summary.json`）：

```json
{
  "billingCycleStart": "2026-08-03T00:00:00.000Z", "billingCycleEnd": "2026-09-03T00:00:00.000Z",
  "membershipType": "ultra", "limitType": "user", "isUnlimited": false,
  "autoModelSelectedDisplayMessage": "You've used 1% of your included total usage",
  "namedModelSelectedDisplayMessage": "You've used 2% of your included API usage",
  "individualUsage": {
    "plan": {
      "enabled": true, "used": 249, "limit": 20000, "remaining": 19751,
      "breakdown": { "included": 20000, "bonus": 0, "total": 20000 },
      "autoPercentUsed": 1, "apiPercentUsed": 2, "totalPercentUsed": 1
    },
    "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
  },
  "teamUsage": { "onDemand": { "enabled": false, "used": 0, "limit": 0, "remaining": 0 } }
}
```

企业 / 团队号还会多出两块（fixture `cursor_usage_summary_team.json`）：

```json
{
  "individualUsage": {
    "overall":  { "enabled": true, "used": 1250, "limit": 5000,  "remaining": 3750 },
    "onDemand": { "enabled": true, "used": 640,  "limit": null,  "remaining": null }
  },
  "teamUsage": {
    "pooled":   { "enabled": true, "used": 12000, "limit": 100000, "remaining": 88000 },
    "onDemand": { "enabled": true, "used": 320,   "limit": 0,      "remaining": null }
  }
}
```

- `individualUsage.overall`：Enterprise / Team 成员的**个人上限**。
- `teamUsage.pooled`：团队**共享池**。
- `teamUsage.onDemand`：团队的按需超额池。
- 上面这些以及 `plan.used/limit`、`onDemand.used/limit`，单位全部是**分（cent）**，÷100 才是美元。这与 `PlanCatalog.swift` 的套餐月标价是两回事：前者是本周期实际额度 / 消费，后者是静态标价。

**`/api/usage?user=<sub>` 响应形状**（fixture `cursor_request_usage.json`）：

```json
{ "gpt-4": { "numRequests": 320, "numRequestsTotal": 320, "numTokens": 0,
             "maxRequestUsage": 500, "maxTokenUsage": null },
  "startOfMonth": "2026-08-03T00:00:00.000Z" }
```

**`/api/auth/me` 响应形状**（fixture `cursor_auth_me.json`，已脱敏）：生产过桥是 `{hasSub, identityFingerprint}`；解析器与身份绑定仍兼容旧 fixture 里的 `sub` 原文，但新日志不得再出现 email / name / sub。

**get-sand-usage-status 响应形状**（fixture `cursor_sand_usage_status.json`）：

```json
{
  "currentPeriodStart": "2026-08-20T18:27:53.116Z",
  "nextResetTimestampUtc": "2026-08-27T18:27:53.116Z",
  "usagePercent": 10.324473,
  "hasAvailableUsage": true,
  "hasNonZeroIncludedLimit": true
}
```

## 解析口径

- **套餐**：`membershipType` 映射 `free`→Cursor Free、`free_trial`/`trial`→Cursor Free Trial、`hobby`→Cursor Hobby、`express`→Cursor Start、`pro`→Cursor Pro、`pro_student`→Cursor Pro（学生优惠不单列档位，标价沿用 Pro）、`pro_plus`/`pro-plus`/`proplus`→Cursor Pro+、`ultra`→Cursor Ultra、`team`/`teams`/`business`→Cursor Teams、`enterprise`→Cursor Enterprise；其他值显示为 `Cursor（原值）`。
- **计费周期**：由 `billingCycleStart` / `billingCycleEnd` 推算；缺失且套餐有标价时按月。重置时间 = `billingCycleEnd`。
- **Total**（`total`，`pinned`）：`plan.totalPercentUsed` 存在**且**两个池字段在场时产出，排在**第一条**，重置时间 `billingCycleEnd`。它和 `cursor_models` / `other_models` 共用同一个重置时间，靠「排第一」让 `longestWindowMetric` 在并列时选中它当折叠摘要。池字段缺失时不产 `total`（那种形状下 `included` 就是总量，两条会重复）。
- **Cursor Models**（`cursor_models`）：`individualUsage.plan.autoPercentUsed`；**Other Models**（`other_models`）：`individualUsage.plan.apiPercentUsed`。两者只要有一个**非 null 在场**就同时产出两条；`NSNull` 不算在场，回落到 `included`。百分比是 0–100 整数，只做区间钳制，不走 `JSONHelp.percent`。
- **Included**（回退）：两个池字段都缺失时，依次用 `plan.totalPercentUsed` → `plan.used / plan.limit` → `individualUsage.overall.used / limit` → `teamUsage.pooled.used / limit`。
- **美元 detail**：`cursor_models` / `other_models` / `included` 三条在 `plan.used` / `plan.limit`（缺则 `overall`，再缺则 `pooled`）存在时补 detail「已用 $x.xx / $y.yy」（分 ÷100，两位小数）。**不给这三条设 `amount`**——它们是百分比条，设了会改折叠卡的摘要形状。
- **Team pooled**（`team_pooled`）：`teamUsage.pooled.enabled == true` 且 `limit > 0` 时**总是**产出：百分比 `used / limit`，`amount = used / 100`（USD），detail「上限 $y.yy」。
- **plan.enabled == false**：`individualUsage.plan` 整段丢掉（与 on-demand 相同）。不产出 `total` / `cursor_models` / `other_models`，也不用 plan 的 used/limit 做 Included 或美元 detail；回落到 `overall` / `pooled`。缺省或非 false 保持现行行为。
- **On-demand**（`on_demand`）：`individualUsage.onDemand`。`enabled == false` 整条丢弃。`limit > 0` → 百分比 `used / limit` + `amount = used / 100`（USD）；`limit` 为 null / 0 但 `used > 0` → 不画百分比，只出 `amount` + detail「无上限」（这是很常见的形态，丢掉等于丢信息）；`used` 也是 0 → 不入列。
- **Team on-demand**（`team_on_demand`）：`teamUsage.onDemand`，规则同上，标签 `Team on-demand`。
- **旧版请求制套餐**（`request_usage` 的 `gpt-4.maxRequestUsage` 非 null）：整卡切换口径，产出 `requests`（`pinned`，标签 `Requests`，百分比 `numRequests / maxRequestUsage`，剩余 = `max - used`，总量 = `max`，detail「N / M requests」，重置 `billingCycleEnd`），并**隐藏** `total` / `cursor_models` / `other_models` / `grok_bot` —— 那四条是 token 计费口径，和请求配额并列会误导。金额类（`on_demand` / `team_on_demand` / `team_pooled`）与 `included` 仍照常展示。
- **Grok Bot**（`grok_bot`）：优先在 `usage-summary` 里递归找键名含 `grok` 的子对象（深度 ≤4）；没有则取 `sand_usage_status` 整段。`currentPeriodStart` 与重置时间都在时补 detail「N 天窗口」（不足一天按小时写）。百分比字段依次取 `percentUsed` / `totalPercentUsed` / `usedPercent` / `usagePercent` / `percent` / `percentageUsed` / `used÷limit` / `utilization`；重置时间取键名含 `reset` / `periodEnd` / `endMs` / 后缀 `AtMs` 的日期字段，或含 `remaining` / `until` / `left` 的毫秒数换算。`hasNonZeroIncludedLimit == false` 或 `hasAvailableUsage == false`（未开通）时跳过，不画 0% 空行；百分比为 0 且无重置时间也跳过。
- **登录判定**：`membershipType` 非空、或 `plan` 池字段可解析、或 Grok Bot 可解析、或 `auth_me` 给出 `sub` → 已登录。都不成立时按 `usage_summary` 的状态分流：

| 情况 | 快照状态 |
|---|---|
| 无任何探针结果 | `error("未获取到任何响应")` |
| `usage_summary` 401 / 403 | `needsLogin` |
| `usage_summary` 其它非 2xx | `error("HTTP n")`；网络层 -3 → `error("请求超时")`、-1 → 错误描述 |
| `usage_summary` 2xx 但解析不出任何东西（非 JSON / 形状漂移） | `needsLogin` |

## 标价（`PlanCatalog.swift`）

| 套餐 | 月付 | 年付 |
|---|---|---|
| Cursor Pro | $20 | $192 |
| Cursor Pro+ | $60 | — |
| Cursor Ultra | $200 | — |
| Cursor Teams | $40 | — |

Free / Free Trial / Enterprise 不显示价格。

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。旧版请求数口径的 `numRequests` / `maxRequestUsage` 只有在可安全转成 Int 时才启用；越界则保留现行 token 口径。重置时间只接受 1970–9999。

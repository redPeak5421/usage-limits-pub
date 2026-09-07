# Kimi Code Plan（www.kimi.com/code/console）用量接口目录

- **官网控制台**：https://www.kimi.com/code/console
- **登录入口**：`https://www.kimi.com/code`（控制台 `/code/console` 不展示扫码登录，首页 `/code` 才有二维码）
- **探针执行页**：`https://www.kimi.com/code/console`（`probeURL`；探针必须停在 `www.kimi.com`，登录跳到 `auth.kimi.com` 时 Cookie 域匹配但 token 不在那）
- **鉴权**：`apiv2` 要 `Authorization: Bearer <token>` 以及 `x-msh-platform: web`。只带 Cookie 会 401 `REASON_INVALID_AUTH_TOKEN`。token 取值顺序：
  1. Cookie `kimi-auth`（JWT 原文，直接当 Bearer 用）——**按 CodexBar 实现整理，待真机确认**；
  2. 探针公共 `__officialToken()`：`localStorage.userToken` → `localStorage.access_token` → Cookie `bigmodel_token_production` → Cookie `token`。

  探针在自己的块里显式写 `Authorization`，优先级高于 `__authHeaders` 的自动注入。诊断日志与任何落盘都**不许出现 token 原文**。
- **Cookie 域**：`kimi.com`、`moonshot.cn`
- **范围**：Kimi Code Plan 订阅额度。Extra Usage / 加油包购买流不接。

## 官网定义窗口

- **每 7 天额度**（控制台「本周用量」，指标 `seven_day`）
- **每 5 小时滚动频限**（控制台「频限明细」，指标 `five_hour`；窗口 300 分钟，解析时 240–360 分钟都归为 5h）

页面另有会员档位、API Key 列表、登录设备、使用记录；Key / 设备明细不进卡片。

## 已解析 API

全部 `POST`，未注明 body 即 `{}`。统一请求头：

| Header | 值 | 说明 |
|---|---|---|
| `Accept` | `application/json` | |
| `Content-Type` | `application/json` | |
| `x-msh-platform` | `web` | |
| `connect-protocol-version` | `1` | `apiv2` 是 Connect-RPC，缺这条服务端可能按 gRPC-web 处理 |
| `x-language` | `en-US` | |
| `r-timezone` | `Intl.DateTimeFormat().resolvedOptions().timeZone` | 运行时取，禁止写死 |
| `Authorization` | `Bearer <kimi-auth>` | Cookie `kimi-auth` 存在时显式带上 |
| `x-msh-device-id` | JWT payload `device_id` | 有才带 |
| `x-msh-session-id` | JWT payload `ssid` | 有才带 |
| `x-traffic-id` | JWT payload `sub` | 有才带 |

后三条由 `kimi-auth` 的 base64url payload 解出（纯字符串运算，脚本内完成）。**`Origin` / `Referer` 不许手写**——同源 fetch 由 WebKit 自动补，手写会被忽略或报错。

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `user` | `/apiv2/kimi.gateway.account.v1.UserService/GetCurrentUser` | 登录判定（`keyProbe`） | `KimiParser` |
| `subscription` | `/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription` | 套餐名 + 到期 + 计费周期 | `KimiParser` |
| `subscriptions` | `/apiv2/kimi.gateway.membership.v2.MembershipService/ListSubscriptions` | `subscription` 没给套餐时取列表第一条 | `KimiParser` |
| `usages` | `/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` body `{"scope":["FEATURE_CODING"]}` | 周额度 + 5 小时频限 | `KimiParser` |
| `stats` | `/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats` | 月度总用量池（`subscriptionBalance`）+ `ratelimitCode7d` + `ratelimitCode5h` 兜底 | `KimiParser` |

五条 POST 在 token / 身份头准备好后同时发出，默认单次 12 秒、瞬态最多重试一次；它们共享 27 秒 deadline。任一补充请求永不 resolve 时，已经完成的 `user` / `usages` 仍会越桥，不能被串行等待拖丢。

**GetUsages 形状**（fixture `kimi_usages.json`）：

```json
{ "usages": [{
  "scope": "FEATURE_CODING",
  "detail": { "limit": "100", "used": "1", "remaining": "99", "resetTime": "2026-08-22T13:36:55Z" },
  "limits": [{
    "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
    "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-08-16T16:36:55Z" }
  }]
}] }
```

**GetSubscriptionStats 形状**（fixture `kimi_stats.json` / `kimi_stats_balance.json`）：

```json
{
  "subscriptionBalance": {
    "feature": "FEATURE_OMNI", "type": "SUBSCRIPTION",
    "amountUsedRatio": 0.0579, "kimiCodeUsedRatio": 0.0579,
    "expireTime": "2026-08-21T13:36:55.168888Z"
  },
  "ratelimitCode7d": { "ratio": 0.0075, "enabled": true, "resetTime": "2026-08-22T13:36:54Z" },
  "ratelimitCode5h": { "enabled": true, "resetTime": "2026-08-16T16:36:54Z" }
}
```

## 解析口径

- 取 `usages[]` 中 `scope` 含 `CODING` 的一条（没有则第一条）。`detail` → `seven_day`；`limits[]` 按 `window.duration` / `timeUnit` 折算分钟，240–360 分钟 → `five_hour`，其它 → `window_<分钟>`。
- 百分比 = `used / limit`，缺 `used` 时用 `(limit − remaining) / limit`；`remaining` / `limit` 原样进 `remaining` / `total`。

### 月度总用量池（`subscriptionBalance`）

`stats` 的 `subscriptionBalance` **无条件解析**（不再只当窗口兜底），条件满足时产出 `monthly`「总用量」，`pinned`，排在所有窗口之前：

- 只在 `feature ∈ {缺失, FEATURE_OMNI}` 且 `type ∈ {缺失, SUBSCRIPTION}` 时采用。额度池跨功能共享，官网「Total usage」那条就是它。
- 百分比用 **`amountUsedRatio`**（不是 `kimiCodeUsedRatio`），0–1 小数走 `JSONHelp.percent` 换算成 0–100。
- `expireTime` → `resetsAt`。

### 两条 7 天窗口的去重

`ratelimitCode7d` 也**无条件解析**成 `code_7d`「Code 7 天」（`enabled == false` 直接丢弃），但与 `GetUsages` 的 `seven_day` **确有分歧时才展示**：

| 判据 | 结果 |
|---|---|
| 两边百分比都在、差 ≤ 1，且两边重置时间都在、差 ≤ 5 分钟 | 同一份配额 → 隐藏 `code_7d` |
| 任一条件不成立（含 `seven_day` 缺失、缺百分比、缺重置时间） | 视为不同配额 → 展示 `code_7d` |

`ratelimitCode5h` 只在 `usages` 没产出 `five_hour` **且 `enabled != false`** 时兜底。缺 `ratio` 不得编成 0%。`ratio` 一律是 0–1 小数，走 `JSONHelp.percent`。

### 计数可信度（`used` / `remaining` / `limit`）

`used` 是权威值，`remaining` 只在自洽时才采信：

| 情形 | 处理 |
|---|---|
| `used` 在、`limit > 0` | `used / limit`；**允许 `used > limit`**（超额），进度条 clamp 到 100%，`detail` 写「已用 N / M（超额）」 |
| 只有 `remaining`，且 `0 ≤ remaining ≤ limit` | `(limit − remaining) / limit` |
| `remaining < 0` | 共享 / 无限额度哨兵：`usedPercent` 置空，`displayValue` 写 `∞`，不画满格 |
| `remaining > limit`，或没有可用数字 | 计数不可信：**不按窗口分钟数猜标签**，退成 `window_<序号>`「配额」，避免把一条读不懂的额度冒充成 5 小时频限 |

### 键名别名与单位

- `resetTime` 认 4 个别名：`resetTime` / `resetAt` / `reset_time` / `reset_at`；数字字段一律 数字 / 数字字符串 / 浮点 三态解码（`JSONHelp.double` / `JSONHelp.date`）。
- `window.timeUnit` 认 `TIME_UNIT_MINUTE` / `HOUR` / `DAY` / `WEEK`。**未知单位返回空窗口**，不再当成分钟——否则 `TIME_UNIT_WEEK: 1` 会被算成 1 分钟。

### 状态

- 任一探针 401 / 403 → `needsLogin`。
- 未判定为已登录且有非 2xx 探针 → 走 `ProbeResult.failureStatus`（`HTTP n` / 请求超时 / 网络错误）。
- 套餐：`subscription.goods.title`（或 `membershipLevel`，`LEVEL_INTERMEDIATE` 视为 Allegretto）映射 Moderato / Allegretto / Allegro / Vivace → `Kimi Code …`。到期取 `currentEndTime`，缺则 `nextBillingTime`。`goods.billingCycle.timeUnit` 为 `TIME_UNIT_YEAR` → `yearly`，否则有标价即 `monthly`。

## 标价（`PlanCatalog.swift`）

> **待核对**：CodexBar 的 `docs/kimi.md` 记的是另一套档位与价格（Andante ¥49 / 1024 周请求、Moderato ¥99 / 2048、Allegretto ¥199 / 7168，统一 200 请求每 5 小时），与下表完全对不上。两边至少一边过期，**未真机核对前不动价格**。


| 套餐 | 月付 | 年付 |
|---|---|---|
| Kimi Code Moderato | ¥19 | ¥228 |
| Kimi Code Allegretto | ¥159 | ¥1,908 |
| Kimi Code Allegro | ¥99 | ¥1,188 |
| Kimi Code Vivace | ¥199 | ¥2,388 |

## 登录判定

满足任一即已登录：`GetCurrentUser` 能解析 `user.id` 或 `user.nickname`；`subscription` 有 `subscription` / `purchaseSubscription` 节点；`subscriptions` 列表非空；`usages[]` 非空。全无响应 → error，否则 → `needsLogin`。

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。`window.duration × timeUnit` 必须得到可安全转 Int 的有限分钟数；溢出时保留该额度的数字，但标签回落为不猜窗口的「配额」。时间只接受 1970–9999。

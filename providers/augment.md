# Augment（app.augmentcode.com）用量接口目录

- **官网控制台**：`https://app.augmentcode.com/account/subscription`（Credits 与订阅信息同页）。
- **鉴权**：本机 WebKit Cookie。站内 `fetch(..., { credentials: 'include' })` 自动携带；**无 Bearer、无 localStorage token**，探针一律 `noAuth: true`。CodexBar 认过的会话 Cookie 名（仅作参考，iOS 不做名字校验，直接让服务端判 401）：`session`、`_session`、`web_rpc_proxy_session`、`auth0`、`auth0.is.authenticated`、`a0.spajs.txs`、`__Secure-next-auth.session-token`、`next-auth.session-token`、`__Secure-authjs.session-token`、`authjs.session-token`、`__Host-authjs.csrf-token`。
- **登录入口 / 探针页**：`loginURL` = `https://app.augmentcode.com`，`probeURL` = `https://app.augmentcode.com/account/subscription`。认证子域是 `auth.augmentcode.com`；**未登录会被弹到该子域**，探针停在那里时不发请求（同源判定见下）。
- **Cookie 域**：`augmentcode.com`（含 `app.` 与 `auth.` 子域）。退出登录清该域 WebKit 数据。
- **标价**：`reference/CodexBar/docs/augment.md` **未记录任何金额**，官网档位只有名字（`free` / `community` / `indie` / `pro` / `team` / `enterprise`）。因此 **`PlanCatalog.swift` 不收录 Augment**，卡片不显示价格与「月 / 年」标签。真机确认标价后再补。
- **接入范围**：Credits 一条百分比（含剩余 / 总量 / 账期重置）+ 套餐名。**不接** `auggie` CLI（CodexBar 的 macOS 专属路径），不接会话保活（见「保活（待评估）」）。
- **代码**：探针 `ProviderScripts.augment`，解析 `AugmentParser`，fixture `augment_credits.json` / `augment_subscription.json` / `augment_credits_available.json`，测试 `AugmentParserTests`。
- **观测**：**按 CodexBar 实现整理（`Sources/CodexBarCore/Providers/Augment/AugmentStatusProbe.swift`），待真机确认**。字段名、状态码语义均来自该实现，尚无我们自己的诊断日志样本。

## 接口表

两条地址都同源 `https://app.augmentcode.com`，都是 `Accept: application/json` 的普通 JSON。

| 地址 | 方法 · 鉴权 | 返回 | App |
|---|---|---|---|
| `GET /api/credits` | Cookie 自动带 | `usageUnitsRemaining` / `usageUnitsConsumedThisBillingCycle` / `usageUnitsAvailable` / `usageBalanceStatus` | 探针 `credits`，**必需**（失败即整卡失败） |
| `GET /api/subscription` | Cookie 自动带 | `planName` / `billingPeriodEnd` / `email` / `organization` | 探针 `subscription`，**可选**（8s、不重试，失败只丢套餐与重置时间） |
| `GET /api/auth/session` | Cookie | 会话保活（CodexBar macOS 每 30 分钟 ping 一次） | **不调用**，见下 |

`credits` 与可选 `subscription` 同时发出并共享 27 秒 deadline；可选腿挂住最多占 8 秒，不能串行拖住已经完成的 Credits 核心结果。
| `https://status.augmentcode.com` | — | 官方状态页 | 未接 |

**隐私**：`/api/subscription` 会带回 `email` 与 `organization`。解析器**必须完全不读这两个键**，快照里只许有数字、套餐名与时间。fixture 里的邮箱一律写成占位符。

## 形状示例

「按 CodexBar 实现整理，待真机确认」。

### `GET /api/credits`

```json
{ "usageUnitsRemaining": 380, "usageUnitsConsumedThisBillingCycle": 620,
  "usageUnitsAvailable": 1000, "usageBalanceStatus": "active" }
```

- 单位是无量纲 credits（不是钱、不是 token）。
- `usageUnitsAvailable` **大于 0 时就是本账期总量**；缺失或 ≤ 0 时用 `usageUnitsRemaining + usageUnitsConsumedThisBillingCycle` 合成。
- `usageBalanceStatus` 是文本状态（如 `active`），非空时拼进该条指标的 `detail`，不据此隐藏指标。
- 这里**没有任何百分比字段**，百分比全部由 App 算，不许走 `JSONHelp.percent`。

### `GET /api/subscription`

```json
{ "planName": "Developer", "billingPeriodEnd": "2026-09-15T00:00:00Z",
  "email": "user@example.com", "organization": "Example Inc" }
```

- `billingPeriodEnd` 是 ISO8601（带 / 不带小数秒都要能解），作为 Credits 条的 `resetsAt`。
- `planName` 是裸档位名，展示时统一前缀成 `Augment <planName>`（原值已含 `Augment` 时不重复加）。

## 解析口径（`AugmentParser`）

- **总量**：`usageUnitsAvailable > 0` → 它就是 `total`；否则 `usageUnitsRemaining + usageUnitsConsumedThisBillingCycle`；两者都缺 → `total` 为 nil。
- **百分比**：`total > 0` 时优先 `consumed / total × 100`，`consumed` 缺失则 `(total − remaining) / total × 100`；结果钳 0–100。`total` 为 0 / nil 时不出百分比。
- **指标**：`UsageMetric(id: "credits", label: "Credits", usedPercent:, remaining: usageUnitsRemaining, total:, resetsAt: billingPeriodEnd, detail: usageBalanceStatus（非空时）, pinned: true)`。`pinned` 保证 0% 也露出来。
- **套餐**：`planName` → `Augment <planName>`；常见小写档位（`free` / `community` / `indie` / `pro` / `team` / `enterprise`）规范成首字母大写。`billingCycle` 留空（无标价，标签无意义）。
- **状态分档**：
  - 产出了 Credits 指标 → `.ok`（此时 `/api/subscription` 401/403/超时都只丢套餐，不降级）。
  - `results` 为空 → `.error("未获取到任何响应")`。
  - 没产出指标且 `credits` 非 2xx → `credits.failureStatus`（401 / 403 → `.needsLogin` 会话过期；5xx / 超时 → `.error("HTTP n")` / `.error("请求超时")`）。
  - 没产出指标、`credits` 是 2xx，但 `subscription` 非 2xx → `subscription.failureStatus`（403 = 未登录 → `.needsLogin`）。
  - 其余（2xx 但形状不认识 / 非 JSON） → `.needsLogin`。
- **漂移防御**：Credits 的三个数值只接受有限且非负的值，任一为负、NaN / Infinity，或 fallback 相加溢出时都不产指标；非有限 `billingPeriodEnd` 当缺失处理，保证快照可编码。
- 键缺失、`null`、非 JSON：跳过并记诊断，不崩。

## 登录与页面复用规则

- 探针在 `app.augmentcode.com` 源内跑。未登录时站点会 302 到 `auth.augmentcode.com`；此时两条探针都会拿到跨源失败或 401/403，按上面的状态分档落到 `.needsLogin`。
- **不要**因为 `auth.augmentcode.com` 与 `app.augmentcode.com` 同后缀就认为「已在源上」——那是 OpenCode 踩过的坑（`providers/opencode.md`「离站判定」）。Augment 目前没有自定义就绪判定，靠服务端状态码兜底；真机若出现「停在 auth 子域被判已就绪」的现象，再补一条与 `OpenCodeSession` 同款的 host 精确匹配。

## 保活（待评估，当前不实现）

CodexBar 在 macOS 上每 1 分钟检查一次 Cookie 过期时间，并对**无 TTL 的会话 Cookie 每 30 分钟 ping 一次 `GET /api/auth/session`**，以免服务端静默失效。

我们的形态不同：iOS 上 Cookie 由 `WKWebsiteDataStore` 持有，通常能跨启动保活，而且我们没有常驻后台轮询。**当前不实现**。若真机出现「几小时后必掉登录」，最低成本的对齐手段是在 `ProviderScripts.augment` 开头加一条同源 `GET /api/auth/session`（`noAuth: true`，短超时，结果不参与解析）。真机确认前不要加——多一条请求就多一次被风控的机会。

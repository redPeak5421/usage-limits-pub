# ChatGPT（chatgpt.com）用量接口目录

- **官网 Usage 页**：https://chatgpt.com/#settings → Subscription（网页版没有稳定公开的数值额度页面；数值额度来自 Codex 的 wham 接口）
- **登录入口**（`loginURL`）：`https://chatgpt.com/auth/login`
- **探针执行页**（`probeURL`）：`https://chatgpt.com/`
- **鉴权**：本机 WebKit Cookie（`cookieDomains = ["chatgpt.com", "openai.com"]`）+ 站内 `accessToken`（由 `session` 接口下发，探针脚本内存中转成 `Authorization: Bearer <token>`，不落盘）。`session` 与全部 `backend-api` 探针都带 `noAuth: true`，禁止 helper 把 leftover localStorage / Cookie `token` 拼成 Authorization；脚本只在 `session.accessToken` 存在时自己写 Bearer。CodexBar 的实测结论是这些 `backend-api` 端点**只认 Cookie**，Bearer 只是锦上添花，拿不到 token 照发。
- **关键探针**（`keyProbe`）：`session`。

## 已解析 API（探针名 → 代码）

| 探针名 | 请求 | 超时 / 重试 | 性质 | 用途 | 解析器 |
|---|---|---|---|---|---|
| `session` | `GET https://chatgpt.com/api/auth/session` | 12s，可重试 | 核心 | 登录判定 + 取 accessToken | `OpenAIParser` |
| `accounts_check` | `GET https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`（Bearer） | 12s，可重试 | 核心 | 套餐 + 订阅到期 | `OpenAIParser` |
| `identity` | 脚本内从 `accounts_check` 就地取邮箱并 **SHA-256** | — | 核心（身份） | 只回传 `{identityFingerprint}`，永不回传邮箱原文 | `AccountIdentity` |
| `wham_usage` | `GET https://chatgpt.com/backend-api/wham/usage`（Bearer） | 12s，可重试 | 核心 | Codex 额度窗口 + credits + 美元额度池 | `OpenAIParser` |
| `bootstrap` | 读页内 `#client-bootstrap` / `window.__NEXT_DATA__`，**不发请求** | — | 尽力而为（按 CodexBar 实现整理，待真机确认） | 登录态第二证据 | `OpenAIParser` |
| `subscriptions` | `GET https://chatgpt.com/backend-api/subscriptions`（Bearer） | 4s，不重试 | 尽力而为（按 CodexBar 实现整理，待真机确认） | `active_until` + `will_renew`，区分「续费日」与「到期日」 | `OpenAIParser` |
| `spend_monthly` | `GET https://chatgpt.com/backend-api/accounts/{account_id}/spend-controls/current-user/monthly-usage`（Bearer） | 4s，不重试 | 尽力而为 + **门控**（按 CodexBar 实现整理，待真机确认） | 团队 / 企业账号的月度美元额度池 | `OpenAIParser` |

所有请求都带 `Accept: application/json`；`session` 未返回 `accessToken` 时后续请求不带 Authorization 照发。`session` 是 token 依赖；它结束后 `accounts_check`、`wham_usage`、`subscriptions` 并发，`spend_monthly` 只等待 `wham_usage` 完成门控，不等待慢的 `accounts_check`。`subscriptions` / `spend_monthly` 各 4 秒、不重试；`bootstrap` 只同步读页内 JSON、不发网络。任一补充挂住不会压掉已完成核心结果，整轮受共享 27 秒 deadline 限制。

**`spend_monthly` 的门控**（照抄 CodexBar 的 `CodexSpendControlsMonthlyUsageGate`，在探针脚本里解析完 wham 后判定，免得给绝大多数个人账号白打一次请求）——四条同时成立才发：

1. wham 里有非空 `account_id`；
2. wham 里**没有**已解析出的美元额度池（`individual_limit` / `rate_limit.individual_limit` / `spend_control.individual_limit` 都拿不到 `limit > 0`）；
3. wham 里存在 `spend_control` 键；
4. `plan_type` 不属于 `guest` / `free` / `go` / `plus` / `pro`（**精确相等**，`prolite` / `chatgptplusplan` 会发；即 team / business / education / edu / quorum / k12 / enterprise / free_workspace / 未知 / 缺失才发）。

### session 响应形状

`{ user: { email, name, id }, accessToken, expires }`。

诊断日志里 `session` 只记 HTTP 状态与响应长度，不预览 `user.name` / email / accessToken。解析仍在内存里读 `user.email` 作登录证据。

chatgpt.com 对匿名访客也返回 200 的 session，甚至带游客 accessToken，且游客 token 能让部分 backend-api 返回 200。因此 **session 2xx 在场时，`user.email` 非空是主要登录证据**；`bootstrap.authStatus == "logged_in"`（`authStatus` 缺失时 `hasEmail == true` 同级）是并列的第二证据（见「登录判定」）。`session` 401 / 403 赢整轮并清 leftover，不走兜底；`accounts_check` / `wham_usage` 只在 session 缺失或 5xx / 超时时才作兜底证据。

### bootstrap 探针返回形状

不是网络请求，是页内内嵌 JSON。脚本按序读 `document.getElementById('client-bootstrap')?.textContent`，再读 `window.__NEXT_DATA__`，产出：

```json
{ "authStatus": "logged_in", "hasEmail": true }
```

`authStatus` 取值 `logged_in` / `logged_out`（读不到则缺省）。**只回传「有没有邮箱」这个布尔，绝不回传邮箱本身**——隐私约定要求快照里只有数字与诊断文本。

### identity 指纹

`accounts_check` 2xx 后，探针用 `crypto.subtle` 计算 `SHA-256("aiusage-identity-v1|openai|email|<lowercase email>")`，只把 64 位 hex 放进 `identity` / `accounts_check.identityFingerprint`。Swift 侧**禁止**再对邮箱原文做哈希。首次成功解析写入账号 `identityFingerprint`；之后不一致标 `needsLogin` 且不覆盖已存快照。

### accounts_check 响应形状

```json
{ "accounts": { "default": {
  "account": { "plan_type": "plus", "account_id": "…" },
  "entitlement": { "subscription_plan": "chatgptplusplan", "has_active_subscription": true, "expires_at": "2026-09-01T00:00:00Z" }
} } }
```

解析口径：递归找所有含 `subscription_plan` 的字典，取第一条 `has_active_subscription != false` 且 `expires_at` 未过期（或缺失）的记录作现行套餐，`expires_at` 写入 `planExpiresAt`（到期提醒用）。没有现行记录（如免费账号残留已到期的历史订阅）则回落到第一个含 `plan_type` 的字典。

### subscriptions 响应形状（按 CodexBar 实现整理，待真机确认）

```json
{ "active_until": "2026-09-01T00:00:00Z", "will_renew": true }
```

`will_renew` 缺失或形状漂移就当整条不可用。顶层没有 `will_renew` 时递归找第一个含该键的字典。

**到期时间的最终口径**（覆盖 `accounts_check` 的 `expires_at`）：

| `will_renew` | `planExpiresAt` |
|---|---|
| `true` | **置空**——会自动续费的订阅不该触发到期提醒 |
| `false` 且有 `active_until` | `active_until` |
| 探针缺失 / 非 2xx / 解析失败 | 保持 `accounts_check` 的 `expires_at` 不变 |

### plan 映射

`subscription_plan` / `plan_type` 映射（小写子串，按顺序命中；先匹配 lite / 5x，再匹配 plain pro；先匹配 free workspace，再匹配 free）：

| 值含 | 展示名 | 月标价 |
|---|---|---|
| `pro` + `lite`（现网 `chatgptprolite` / `pro_lite` / `prolite`）或 `pro` + `5x` | ChatGPT Pro 5x | $100 |
| `pro`（如 `chatgptproplan`） | ChatGPT Pro | $200 |
| `plus` | ChatGPT Plus | $20（年付 $200） |
| `team` | ChatGPT Team | $30（年付 $300） |
| `enterprise` | ChatGPT Enterprise | （无标价） |
| `business` | ChatGPT Business | （无标价） |
| `edu` / `education` | ChatGPT Edu | （无标价） |
| `k12` | ChatGPT K12 | （无标价） |
| `quorum` | ChatGPT Quorum | （无标价） |
| `free_workspace`（或同时含 free 与 workspace） | ChatGPT Free Workspace | （无标价） |
| `free` | ChatGPT Free | （无标价） |
| 词元含 `go`，或含 `chatgptgo` | ChatGPT Go | （无标价，分地区定价，故不进 `PlanCatalog`） |
| 其它 | `ChatGPT（<原值>）` | （无标价） |

`go` 用**词元**匹配（按非字母数字切词）而不是裸子串，免得将来出现 `gov` 一类档位被误判。官方 Pro 分两档：**Pro $100 = 5x Plus**（chatgpt.com 内部命名 Pro Lite），**Pro $200 = 20x Plus**。已登录但拿不到套餐名时展示名为 `ChatGPT`。有标价的套餐 `billingCycle` 固定为 `monthly`。

### wham_usage 响应形状（$100 Pro，脱敏）

```json
{"plan_type":"prolite","email":"…","account_id":"",
 "rate_limit":{"allowed":true,"limit_reached":false,
   "primary_window":{"used_percent":99,"limit_window_seconds":18000,"reset_after_seconds":12000,"reset_at":1787767642},
   "secondary_window":{"used_percent":99,"limit_window_seconds":604800,"reset_after_seconds":500000,"reset_at":1788354442}},
 "code_review_rate_limit":null,
 "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox",
   "rate_limit":{"primary_window":{…},"secondary_window":{…}}}],
 "credits":{"balance":"0","has_credits":false,"unlimited":false,"overage_limit_reached":false},
 "individual_limit":{"limit":500,"used":123.45,"remaining_percent":75.31,"resets_at":1790000000}}
```

解析顺序与命名（各分组 id 互不相同，主额度不会被附加限额顶掉）：

| 顶层键 | 展示前缀 | id |
|---|---|---|
| `rate_limits` / `rate_limit` / `usage`（主额度） | Codex | `<窗口键>`（如 `primary_window`） |
| `code_review_rate_limits` / `code_review_rate_limit` | Codex 代码审查 | `code_review.<窗口键>` |
| `additional_rate_limits[]` | `limit_name`（缺则 `metered_feature`，再缺「附加 N」） | `additional.<name>.<窗口键>` |
| 其它含窗口的未知分组（对象或数组） | Codex <分组键人类化：去掉 `_rate_limits` 等后缀、下划线转空格> | `<分组键>.<窗口键>` |

- 窗口对象在各分组内按 `used_percent` 递归搜寻；上述分组一个窗口都没有时才对整个响应递归兜底（前缀 Codex）。
- **`credits` / `individual_limit` / `spend_control` 三个键不参与窗口递归**：它们是金额池，字段是 `remaining_percent` 而不是 `used_percent`，绝不能被当成额度窗口重复列一行。
- `used_percent` 是原生 0…100 字段，走 `JSONHelp.percentAlreadyHundred`：`1` / `0.5` 就是 1% / 0.5%，**不得**再按 0…1 放大。
- 时长：`window_minutes` / `window_duration_minutes` / `limit_window_minutes`（分钟）或 `limit_window_seconds` / `window_seconds` / `window_duration_seconds`（秒）。
- 重置：`resets_at` / `reset_at`（ISO8601 或 epoch），否则 `resets_in_seconds` / `reset_after_seconds` 相对当前时间。
- **窗口标签只按时长判定**：≥ 1 天按天数（7 天 → 「周窗口」，其它 「N 天窗口」），否则「N 小时窗口」。时长缺失时按路径名含 `week` / `7d` / `daily` → 周窗口、含 `hour` / `5h` → 5 小时窗口；再缺则按距重置时间推断（> 6 小时视为周窗口，否则 5 小时窗口）。**不按 primary / secondary 名字硬猜**，也不写死窗口数量。
- 去重：同 id 只留第一条；标签、百分比相同且重置时间相差 < 60 秒的也只留第一条。
- 0% 的附加限额靠 `hasUsage` 默认不露出（展开后可显示）。

### credits（Codex 余额）

`credits` 对象产出单独一行计量，排在窗口之后：

| 条件 | 产出 |
|---|---|
| `unlimited == true` | `id=credits`、`label=Codex credits`、`displayValue="∞"`、`pinned=true`（无限额度要一直露出来） |
| 否则 `has_credits == true` 或 `balance > 0` | `id=credits`、`label=Codex credits`、`amount=balance`、`currency=USD`（不 pin；余额 0 靠 `hasUsage` 自动隐藏） |
| 否则 | 不产出 |

`balance` 现网可能是数字也可能是字符串（`"0"`），两种都认。单位就是**美元 credits**，不是分。

### 美元额度池（spend controls）

先在 wham 里按序找池子：`individual_limit` → `individualLimit` → `rate_limit.individual_limit` → `spend_control.individual_limit`。都没有再用 `spend_monthly` 探针。

| 来源 | 形状 |
|---|---|
| wham 池 | `{ limit, used, remaining_percent \| remainingPercent, resets_at \| resetsAt \| reset_at }`，数值可能是字符串 |
| `spend_monthly` | `{ current_month_usage, effective_monthly_limit: { limit, enforcement_mode, limit_mode } }`，单位美元 |

产出统一为一行：`id=spend_limit`、`label=Monthly spend limit`、`usedPercent = 100 - remaining_percent`（缺则 `used / limit * 100`）、`amount = used`、`currency=USD`、`detail = 「上限 $<limit>」`、`resetsAt` 取池子里的重置时间（`spend_monthly` 没有重置时间）。`limit <= 0` 不产出；`spend_monthly` 的 `enforcement_mode` 属于 `none` / `off` / `disabled` / `no_limit` 时视为未启用，同样不产出。

## 登录判定

按优先级短路：

1. `session` 401 / 403 → `needsLogin`，清掉已解析的 accounts / wham 指标（游客或过期 session 也能让部分 backend-api 回 200）；
2. `session` 2xx 且 `user.email` 非空 → `ok`；
3. 否则 `bootstrap.authStatus == "logged_out"` → `needsLogin`，清掉已解析的 accounts / wham 指标（页面自己说没登录，最硬的反证）；
4. 否则 `bootstrap.authStatus == "logged_in"`，或 `authStatus` 缺失 / 非 logged_in·logged_out 且 `hasEmail == true` → `ok`（session 接口漂移时的第二证据，消除「session 一变整卡失联」的单点）；
5. 否则 session 2xx 在场（但无邮箱、无 bootstrap 证据）→ `needsLogin`，清掉 accounts / wham leftover（不看它们判登录，游客 token 能让它们返回 200）；
6. session 缺失或 5xx / 超时：`accounts_check` 解析出套餐名，或 `wham_usage` 解析出至少一个窗口 / credits / 美元池 → `ok`。`session` 401 / 403 已在第 1 步短路，不进入本条。

都不成立时：探针结果为空 → `error("未获取到任何响应")`；否则按 `session`、`wham_usage` 的状态码分级——401 / 403 → `needsLogin`，其它非 2xx → `error("HTTP <n>")`，超时 → `error("请求超时")`；都是 2xx 只是解析不出东西 → `needsLogin`。

已登录但 `accounts_check` / `wham_usage` 非 2xx 时，卡片显示已登录、套餐名 `ChatGPT`、无数值额度。

## Codex 完全重置（2026-09-10 用户提供现网响应）

补充探针 `reset_credits`：GET `/backend-api/wham/rate-limit-reset-credits`；
`reset_history`：GET `/backend-api/wham/rate-limit-reset-credits/history`。
沿用 session 后的同源 Cookie / Bearer、`noAuth: true`，并发、各 4 秒且不重试。
只读，不兑换、不购买。失败不影响已有登录证据或额度窗口。

`available_count` 是可用次数；`credits[]` 中仅 `reset_type=codex_rate_limits`、
`status=available`、`is_supported_by_plan=true` 且未过期的记录用于到期日期。
到期使用最早的 `expires_at`，缺失日期不编造；不保存 credit id、头像、标题或用户信息。
历史只统计 `events[].kind=used`，按事件 id 去重，限定 `window_start…as_of`。
仅读取首页；`next_cursor` 非空或事件形状不完整时显示“至少 N 次”，绝不称为终身累计。
`total_earned_count` 不等于已重置次数，不用于历史计数。

快照以独立 `openAIResetCredits` 数字/日期摘要保存，旧快照可缺省。
ChatGPT/Codex 共用 `.openai` 卡：保留现有额度条，在下方显示可用次数与最近到期，展开显示历史次数和时间范围。
轮盘 / 螺旋折叠卡以单行次数与到期日替换展开提示，固定卡高不追加完整面板。
摘要不进入计量排序、小组件额度条或阈值提醒；补充探针失败时不显示该部分，不沿用可能已兑换的旧次数。
两个补充探针也不参与 `RefreshPolicy` 的真实 HTTP 状态聚合，防止其 200/401 干扰核心超时/5xx 的 last-good 保护。
没有新增 ChatGPT 对话额度接口，不推算额度。

验证：2026-09-10 在用户既有 Chrome 登录页，以同源 fetch + session Bearer 实测两个 GET 均为 HTTP 200；
可用 1 次、到期 2026-10-05 04:21:20 UTC；近 30 天 `used` 1 条、`granted` 2 条、`next_cursor=null`。
响应正文不进入诊断日志，只记录状态码和长度，避免 credit id / 头像等非必要信息留存。

## 异常数值策略

JSON 布尔不得当作 0/1；`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。窗口时长、金额整数文案在转 Int 前检查范围，越界用安全占位；绝对/相对重置时间只接受 1970–9999。

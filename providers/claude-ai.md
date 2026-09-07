# Claude（claude.ai）用量接口目录

- **官网 Usage 页**：https://claude.ai/settings/usage
- **登录入口**（`loginURL`）：`https://claude.ai/login`
- **探针执行页**（`probeURL`）：`https://claude.ai/login`。claude.ai 根路径未登录时会 302 到 claude.com 营销站，相对路径 `/api/*` 会打到错误域名；`/login` 登录前后都停留在 claude.ai 同源。
- **鉴权**：本机 WebKit Cookie（`cookieDomains = ["claude.ai"]`）。探针在 claude.ai 源内以 `fetch(..., credentials: 'include')` 执行，请求头仅 `Accept: application/json`。**claude.ai 全部探针必须带 `noAuth: true`**：通用探针助手默认会把同源 localStorage / Cookie 里的 token 拼成 `Authorization: Bearer`，而这些接口纯 Cookie 鉴权，多出来的头是意料外的（CodexBar 的 web 链路也只发 `Cookie` + `Accept`）。
- **关键探针**（`keyProbe`）：`organizations`。

## 已解析 API（探针名 → 代码）

| 探针名 | 请求 | 超时 / 重试 | 性质 | 用途 | 解析器 |
|---|---|---|---|---|---|
| `organizations` | `GET https://claude.ai/api/organizations` | 12s，可重试 | 核心 | 登录判定 + org 选择 + 套餐名兜底 + 计费渠道 | `ClaudeParser` |
| `usage` | `GET https://claude.ai/api/organizations/{uuid}/usage` | 12s，可重试 | 核心 | 各限额窗口 + `extra_usage` | `ClaudeParser` |
| `account` | `GET https://claude.ai/api/account` | 4s，不重试 | 尽力而为 | 权威套餐档（`rate_limit_tier` / `billing_type` / `seat_tier`） | `ClaudeParser` |
| `overage` | `GET https://claude.ai/api/organizations/{uuid}/overage_spend_limit` | 4s，不重试 | 尽力而为，**仅当 `usage` 里没有 `extra_usage` 对象时才发** | Extra usage 月度已花 / 上限 | `ClaudeParser` |
| `prepaid` | `GET https://claude.ai/api/organizations/{uuid}/prepaid/credits` | 4s，不重试 | 尽力而为 | 预充值 Usage credits 余额 | `ClaudeParser` |

**编排 / 尽力而为语义**：`organizations → usage` 的 org 依赖保持串行；拿到核心结果后，`account` / `overage` / `prepaid` 同时发出，各自 4 秒且不重试。三条补充中任何一条挂住都只缺自身，已完成的核心结果仍受全局 27 秒 deadline 保护并按时返回。参考 CodexBar 的 `BoundedTaskJoin`：一个慢端点不许拖死整轮刷新。

`{uuid}` 由探针脚本从 `organizations` 响应里按下面的顺序选出；取不到 uuid 就不发 `usage` / `overage` / `prepaid`。

### org 选择顺序（探针脚本与解析器必须一致）

1. `capabilities` 含 `chat` 的第一个 org；
2. 否则第一个**不是纯 API**（`capabilities` 恰为 `["api"]`）的 org；
3. 否则第一个 org。

第 2 步是 2026-08 按 CodexBar 补的：只有一个非 chat org 且它是 API 工作区时，旧的两级兜底会选中 API org，`usage` 必然拿不到数据。

### organizations 响应形状

```json
[{ "uuid": "…", "name": "Personal", "capabilities": ["chat", "claude_max"], "rate_limit_tier": "default_claude_max_5x" }]
```

**计费渠道**：遍历 org 中键名含 `billing` / `payment` / `platform` / `subscription` 的字符串值，值含 `apple` / `ios` / `iap` / `app_store` 则快照 `billingSource = "app_store"`，标价改取 `PlanCatalog` 的 App Store 内购价（仅 Max 5x / 20x 有条目，其余回落官网价）。这一条是我们独有的（CodexBar 是 macOS 应用，没有内购档）。

### account 响应形状（按 CodexBar 实现整理，待真机确认）

```json
{ "email_address": "…",
  "memberships": [
    { "seat_tier": "team_standard",
      "organization": { "uuid": "…", "name": "…", "rate_limit_tier": "default_claude_max_5x", "billing_type": "stripe" } }
  ] }
```

取 `organization.uuid` 与上面选中的 org 相同的那条 membership，取不到就取第一条。**邮箱不解析、不落盘**（隐私约定：快照只存数字与诊断文本）。

### usage 响应形状（脱敏）

```json
{
  "five_hour":  { "utilization": 18.0, "resets_at": "2026-08-16T09:49:59.867726+00:00" },
  "seven_day":  { "utilization": 22.0, "resets_at": "…" },
  "seven_day_opus": null, "seven_day_sonnet": null,
  "seven_day_oauth_apps": null, "seven_day_cowork": null,
  "nimbus_quill": { "utilization": 0.0, "resets_at": null },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 18, "resets_at": "…", "scope": null, "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 22, "resets_at": "…", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 44, "resets_at": "…",
      "scope": { "model": { "id": null, "display_name": "Fable" } }, "is_active": true }
  ],
  "extra_usage": {
    "is_enabled": false, "monthly_limit": 0, "used_credits": 0.0,
    "utilization": null, "currency": "USD", "decimal_places": 2
  },
  "spend": { "…": "与 extra_usage 同源的另一种表述，未解析" }
}
```

### overage_spend_limit 响应形状（按 CodexBar 实现整理，待真机确认）

```json
{ "is_enabled": true, "monthly_credit_limit": 5000, "used_credits": 1234, "currency": "USD" }
```

金额是**分**（minor units）。只有 `is_enabled == true` 且上限 > 0 才产出计量。

### prepaid/credits 响应形状（按 CodexBar 实现整理，待真机确认）

```json
{ "amount": 2500, "currency": "USD" }
```

同样是**分**。`amount <= 0` 不产出计量。

## 解析口径（`ClaudeParser`）

### 套餐名

优先用 `account` 的 membership（`organization.rate_limit_tier` + `organization.billing_type` + `seat_tier`）；`account` 缺失或没解析出 membership 时回落到选中 org 的 `rate_limit_tier` / `capabilities`。

`rate_limit_tier` 按子串顺序命中（大小写不敏感）：

| 命中 | 展示名 | 月标价（官网） | iOS 内购月价 |
|---|---|---|---|
| `max` | Claude Max **+ 倍率** | （无标价） | |
| `max` + 倍率 `5x` | Claude Max 5x | $100 | $124.99 |
| `max` + 倍率 `20x` | Claude Max 20x | $200 | $249.99 |
| `pro` | Claude Pro | $20（年付 $200） | |
| `team` | Claude Team | （无标价） | |
| `enterprise` | Claude Enterprise | （无标价） | |
| `ultra` | Claude Ultra | （无标价） | |
| `free` | Claude Free | （无标价） | |

**倍率是通用解析**，不是写死的 5x / 20x：把 tier 按非字母数字切词，取 `max` 后面那个词，形如 `<整数>x` 就拼到展示名后面。`default_claude_max_5x` → Claude Max 5x，`max_20x` → Claude Max 20x，将来出现 `max_10x` 自动变成 Claude Max 10x。

**seat_tier 细分 Team**（仅在 tier 没命中或命中 team 时生效）：

| `seat_tier` | 展示名 | 月标价 |
|---|---|---|
| `team_standard` | Claude Team Standard | $30（年付 $300，即 $25/席位/月按年付） |
| `team_tier_1` | Claude Team Premium | $150（年付 $1500，即 $125/席位/月按年付） |

**stripe 兜底**：以上都没命中，但 `billing_type` 含 `stripe` 且 `rate_limit_tier` 含 `claude` → Claude Pro。

`rate_limit_tier` 缺失时的最后兜底：`capabilities` 含 `claude_max` → Claude Max，含 `claude_pro` → Claude Pro，否则展示名 `Claude`。有标价的套餐 `billingCycle` 固定为 `monthly`。

### 限额窗口

- 计量名一律用官网 Settings → Usage 原名。已知顶层窗口键 → 标签：`five_hour` / `session` → **Current session**，`seven_day` / `weekly` → **All models**，`seven_day_opus` → **Opus**，`seven_day_sonnet` → **Sonnet**；值为 `null` 的键跳过。
- **`five_hour`（及 `session`）存在且非 null 时 `pinned = true`**：正在进行的会话窗口即使 0% 也要露出来（`hasUsage` 默认藏 0%）。`five_hour: null`（企业 / 纯额度账号）则完全不产出该行——这样「真 0%」与「没有会话窗口」两种情况不再混为一谈。
- **别名窗口，首个存在的键胜出**：

| 别名键（按序） | id | 标签 |
|---|---|---|
| `seven_day_routines` / `seven_day_claude_routines` / `claude_routines` / `routines` / `routine` | `routines` | Daily Routines |
| `seven_day_cowork` / `cowork` | `cowork` | Cowork |
| `seven_day_oauth_apps` | `oauth_apps` | OAuth apps |

- **未知顶层窗口的自适应规则**：任何其它含 `utilization` 的顶层子对象，只有在 `resets_at` 非 null **或** `utilization > 0` 时才收进来（所以 `nimbus_quill: {utilization: 0, resets_at: null}` 这类占位键不会污染卡片）。标签由键名人类化：去掉 `seven_day_` 前缀、下划线转空格、首字母大写。
- `limits[]`：`session` 归一为 id `five_hour`（Current session，同样 `pinned`），`weekly_all` 归一为 `seven_day`（All models），与顶层同源者按 id 去重；其它 `kind` 原样作 id / 标签。`percent` 与 `resets_at` 都缺则跳过。
- `limits[]` 的 `weekly_scoped`：
  - **`scope.model` 是「全模型」的条目必须丢弃**——`display_name` 的 slug 等于 `all-models`，或 `model.id` 的 slug 等于 `all-models` / 以 `-all-models` 结尾。否则它会和顶层 `seven_day`（All models）重复成两行。
  - id 用 `weekly_scoped_<slug(model.id ?? display_name)>`；slug = 小写、非字母数字转 `-`、首尾去 `-`。**优先用 `model.id`**：两个模型同名不会撞 id，官网改展示名也不会让持久化的 `SharedStore.metricOrder` 失效。现网 `id: null` + `display_name: "Fable"` → `weekly_scoped_fable`。
  - 标签用 `display_name`。
- 百分比（`utilization` / `limits[].percent`）是 **0–100** 口径，用 `JSONHelp.percentAlreadyHundred`：`1` / `0.5` 就是 1% / 0.5%。不得走 `JSONHelp.percent`（`v <= 1` 会把 1% 放大成 100%）。选中 org 的 `uuid` 只用于拼 usage URL 与身份指纹 `SHA-256(aiusage-identity-v1|claude|org|<uuid>)`，**uuid 原文不落盘**。
- `resets_at` 兼容 ISO8601（含 6 位微秒小数，`JSONHelp.date` 会截到毫秒再解析）与 epoch 秒 / 毫秒。
- 键名漂移兜底：上面全部规则一条都没产出计量时，任何含 `utilization` 或 `resets_at` 的顶层子对象都按窗口收入，键名作 id 与标签。

### 金额类计量

| id | 标签 | 来源 | 口径 |
|---|---|---|---|
| `extra_usage` | Extra usage | `usage.extra_usage`，缺失时用 `overage` 探针 | `is_enabled == true` 且上限 > 0 才产出。`usedPercent` 取 `utilization`，缺失则 `used_credits / monthly_limit * 100` 钳制；`amount` = `used_credits / 10^decimal_places`（缺 `decimal_places` 按 2，即分转元）；`detail` = 「上限 <金额>」；`currency` 原样带上 |
| `prepaid_credits` | Usage credits | `prepaid` 探针 | `amount / 10^2`（分转元），仅 `amount > 0` 时产出 |

`overage` 的字段名是 `monthly_credit_limit`（`extra_usage` 里叫 `monthly_limit`），两个名字都认。

## 登录判定

- `organizations` 2xx 且解析出 org → 已登录（`status = ok`）；`usage` 2xx 且解析出至少一个窗口，或 `account` 2xx 且解析出 membership，同样视为已登录。
- 都不成立时：探针结果为空 → `error("未获取到任何响应")`；否则看 `organizations` 的状态码分级——401 / 403 → `needsLogin`，其它非 2xx → `error("HTTP <n>")`，超时 → `error("请求超时")`；`organizations` 本身 2xx 但解析不出东西 → `needsLogin`。
- 关键：**5xx 不再提示「重新登录」**。claude.ai 服务端抖动时告诉用户站点出错，而不是让他白登录一次。

## 异常数值策略

JSON 布尔不得当作 0/1；`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。需转成整数的金额文案先做 Int 范围检查，越界显示安全占位；时间只接受 1970–9999。

# DeepSeek（platform.deepseek.com）用量接口目录

- **官网 Usage 页**：https://platform.deepseek.com/usage
- **鉴权**：用量接口要 `Authorization`。Token 在同源 `localStorage.userToken`（JSON `{value, __version}`，取 `value`），探针读出后带 `Authorization: Bearer <value>`。Cookie-only 会 200 `{"code":40002,"msg":"Missing Token","data":null}`。所有请求附 `Accept: application/json`、`x-client-platform: web`、`x-client-version: 1.0.0`。Cookie 域：`deepseek.com`。
- **登录入口**：`https://platform.deepseek.com/usage`
- **探针执行页**：`https://platform.deepseek.com/usage`
- **计费形态**：预充值，**无订阅套餐**，不产出套餐名、不显示价格徽章。禁止用官方 `GET https://api.deepseek.com/user/balance`（API Key）替代官网探针。

## 已解析 API（探针名 → 代码）

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `current` | `GET /auth-api/v0/users/current` | 登录判定 + 币种 | `DeepSeekParser` |
| `summary` | `GET /api/v0/users/get_user_summary` | 充值余额 + 累计消费 | `DeepSeekParser` |
| `api_keys` | `GET /api/v0/users/get_api_keys` | Key 名称与最后使用时间 | `DeepSeekParser` |
| `usage_periods` | 对 6 个预设区间分别 `GET /api/v0/usage/by_api_key/cost?start=&end=&tz=28800` 与 `GET /api/v0/usage/by_api_key/amount?start=&end=&tz=28800` | 时间维度 + API Key 维度 | `DeepSeekParser` |

补充 fixture：`deepseek_summary_multi_currency.json`（USD + CNY 双币种钱包，按 CodexBar 实现构造，见「待真机确认」）、`deepseek_usage_periods_models.json`（两个模型 × 两个 Key，校验 token 分类与按模型维度）。

`usage_periods` 是探针脚本合成的一条：body 为 `{ "<区间 id>": { start, end, cost: {status, body}, amount: {status, body} } }`，外壳固定 `status: 200`，真实状态逐 cost / amount 保留。单条 401 / 503 不会挡掉其它已完成明细；失败子项即使 body 像用量也不进 today / 本月。所有子项失败时解析器与 `RefreshPolicy` 展开内层 status，还原未登录、HTTP 错误或超时。区间按 GMT+8 日界算，`start`/`end` 为 unix 秒：`today`、`yesterday`、`last_7d`（含今天共 7 天）、`last_30d`、`this_month`、`last_month`。官网的「自定义」区间未接。

编排：`current`、`summary`、`api_keys` 与六组 `usage_periods` 同时启动；每组 cost / amount 也并发。所有子请求共用 27 秒 deadline，默认单次 12 秒、瞬态最多重试一次；慢的明细不会阻止已经完成的钱包 / 登录结果越桥。

**current 响应形状**（fixture `deepseek_current.json`，已脱敏）。`id_profile.name` / 账号名不进诊断预览：该探针只记 HTTP 状态与响应长度。

```json
{ "code": 0, "data": { "biz_code": 0, "biz_data": { "id": "…", "currency": "CNY", "balance_alert": { "CNY": { "enabled": true } } } } }
```

**summary 响应形状**（fixture `deepseek_summary.json`）：

```json
{ "data": { "biz_data": {
  "normal_wallets": [{ "currency": "CNY", "balance": "54.48" }],
  "bonus_wallets":  [{ "currency": "CNY", "balance": "0" }],
  "total_costs":    [{ "currency": "CNY", "amount": "95.65" }]
} } }
```

**api_keys 响应形状**（fixture `deepseek_api_keys.json`）：

```json
{ "data": { "biz_data": { "api_keys": [
  { "tracking_id": "…", "name": "<key 名>", "created_at": 1700000000, "last_use": 1700000100, "sensitive_id": "sk-***" }
] } } }
```

**cost 响应形状**（fixture `deepseek_usage_cost.json`，series 挂在 `biz_data.data[]` 下）：

```json
{ "data": { "biz_data": {
  "start": 1785513600, "end": 1786896000, "bucket": 86400,
  "data": [{ "currency": "CNY", "series": [{
    "api_key": { "tracking_id": "…", "name": "…" },
    "model": "deepseek-v4-flash",
    "buckets": [{ "time": 1785686400, "cost": "1.89" }]
  }] }]
} } }
```

**amount 响应形状**（fixture `deepseek_usage_amount.json`，series 直接挂在 `biz_data.series[]`）：

```json
{ "data": { "biz_data": {
  "start": 1785513600, "end": 1786896000, "bucket": 86400,
  "series": [{
    "api_key": { "tracking_id": "…", "name": "…" },
    "model": "deepseek-v4-flash",
    "buckets": [{ "time": 1785686400,
      "usage": { "REQUEST": 205, "RESPONSE_TOKEN": 277952, "PROMPT_CACHE_HIT_TOKEN": 47614592, "PROMPT_CACHE_MISS_TOKEN": 382065 } }]
  }]
} } }
```

## 解析口径

- 所有响应先取 `data.biz_data`（缺失时退到 `data`）；键缺失跳过，不崩溃。
- **币种**：`current.biz_data.currency`，被 `summary` 钱包选中的币种覆盖；默认 CNY。
- **钱包按币种分组**：`normal_wallets`（充值）与 `bonus_wallets`（赠送）先按 `currency` 分组求和，**再选一个展示币种**，绝不把 USD 与 CNY 横加成一个数。选币顺序：**有余额的 USD > 任意有余额的币种（按响应中首次出现顺序）> 余额为 0 的 USD > 第一行**。
- **重置余额**（`balance`，官网「充值余额」）= 选中币种的 充值 + 赠送。另外拆两条：`balance_paid`「充值余额」= `normal_wallets` 该币种合计、`balance_granted`「赠送余额」= `bonus_wallets` 该币种合计，**> 0 才产出**（都是 0 时不堆 ¥0.00 的空条）。折叠态仍只画 `balance` 与 `total_spent`。
- **累计消费金额**（`total_spent`）= `total_costs` 中选中币种的 `amount`；选中币种在消费里不存在、且消费只有一个币种时用那一个（币种口径以钱包为准）。
- **时间维度**：每个区间产出一条 `UsageBreakdown`：消耗金额 = cost 全部 bucket 的 `cost` 之和；请求次数 = `usage.REQUEST` 之和；Tokens = `RESPONSE_TOKEN + PROMPT_CACHE_HIT_TOKEN + PROMPT_CACHE_MISS_TOKEN` 之和。折线序列按 bucket `time` 聚合，优先用金额序列，无金额时用 token 序列。
- **token 分类明细**：`usage` 的三类各自另存一份 —— `cacheHitTokens`（`PROMPT_CACHE_HIT_TOKEN`）、`cacheMissTokens`（`PROMPT_CACHE_MISS_TOKEN`）、`outputTokens`（`RESPONSE_TOKEN`）。`tokens` 仍是三者之和，口径不变；首页展开态在 Tokens 数字下画一行「命中 x · 未命中 y · 输出 z」。缓存命中率是 DeepSeek 用户最关心的指标之一，故不再只留合计。
- **模型维度**：`amount` / `cost` 的 `series[].model` 按模型合并（金额 / 次数 / tokens），落在 `ProviderSnapshot.modelBreakdowns`，排序为消耗金额多→少，其次 tokens，再次名称。首页展开态在「按 API Key」之后画一份「按模型」。数据取第一个有数据的区间，与 API Key 维度同源。
- **API Key 维度**：取第一个有数据区间的 cost / amount 按 `api_key.tracking_id` 合并（金额 / 次数 / tokens），再用 `api_keys` 补名称（`name`，缺则用 `tracking_id`）与 `last_use`（或 `last_used`）；按 `last_use` 新→旧排序，无 `last_use` 的排后、按名称排。
- **登录判定**：`current` 能解析出 `biz_data.id` 或 `currency`，或 `summary` 能解析出 `biz_data` → 已登录。

## 业务错误码与状态

信封 `code` 非 0（或 `code` 为 0 但 `data.biz_code` 非 0）即业务错误，取 `msg` / `biz_msg` 一并记录。**只有在一条用量都没解出来时**才影响状态：

| 情况 | 状态 |
|---|---|
| 解出任意用量 / 登录判定通过 | `ok`（业务码不覆盖已到手的数据） |
| `code` 40002（Missing Token）/ 40003（会话过期） | `needsLogin` |
| 其它非 0 `code` / `biz_code` | `error("DeepSeek code <n>: <msg>")` |
| HTTP 401 / 403 | `needsLogin` |
| 其它非 2xx | `error("HTTP <n>")` |
| 探针超时（status -3） | `error("请求超时")` |
| 没有任何响应 | `error("未获取到任何响应")` |

## 待真机确认

- **多币种钱包**：现有 fixture 只有 CNY 单币种，USD + CNY 并存的选币与拆分口径按 CodexBar 的实现（`DeepSeekUsageFetcher` 的 `normal/bonus` 分组）写成，未在真机上见过双币种账号。
- **`code` 40003 的确切语义**：40002「Missing Token」已在真机见过；40003 按 CodexBar 的会话过期口径处理，本机未复现。
- **`series[].model` 的取值集合**：fixture 里只有 `deepseek-v4-flash`。模型改名 / 新增时按模型维度的 id 直接跟随官网字符串，不做映射。
- 未接：`/api/v0/usage/{amount,cost}?month&year`（CodexBar 用的按月端点，可拿到分类成本）。要接需先在真机确认同一会话下可用。

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数不得进入金额 / token / 请求数。`code` / `biz_code` 只在 Int 范围内的整数时才解读为业务码；越界坏码跳过，不得触发转换崩溃。时间戳只接受 1970–9999。

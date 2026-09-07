# MiniMax TokenPlan（platform.minimaxi.com / platform.minimax.io）用量接口目录

- **ProviderID**：国内站 `minimax`；国际站 `minimaxGlobal`（落盘 raw value 为 `minimax_global`）
- **国内站 Usage / 登录 / 探针执行页**：`https://platform.minimaxi.com/console/usage`
- **国际站 Usage / 登录 / 探针执行页**：`https://platform.minimax.io/console/usage`
- **鉴权**：本机 WebKit Cookie（Cookie-only 即可 200）。请求另带 `x-group-id`（见下方回退链，取不到就不带）。页面在 `platform.*`，用量 XHR 打到 `www.*`。全部 `__probe`（含 billing）带 `noAuth: true`，禁止 helper 把 localStorage token 拼成 Bearer。
- **站点隔离**：两个 ProviderID 共用 `ProviderScripts.minimax` 与 `MiniMaxParser`，但分别在 `minimaxi.com` / `minimax.io` 源内执行并使用各自 Cookie；国际站不会借用国内站登录态，反之亦然。
- **Cookie 同步 / 退出登录边界**：`minimax` 只处理 `minimaxi.com`，`minimaxGlobal` 只处理 `minimax.io`，两组必须互斥。当前登录与探针契约没有使用 `minimax.chat`，因此不把它列入任何 ProviderID 的清理范围，避免退出一个账号时扩大删除面。
- **套餐详情**：https://platform.minimaxi.com/console/plan；**标价页**：https://platform.minimaxi.com/subscribe/token-plan
- **范围**：TokenPlan 订阅。按量付费 API Key 不接。

## 双站（国内 / 国际）

探针里**禁止再写死 `https://www.minimaxi.com`**，一律从 `location.hostname` 推导，同一份脚本在两个站都能跑：

| 当前页 hostname | `www` 主机（用量 / combo） | `platform` 主机（计费历史） |
|---|---|---|
| 以 `minimax.io` 结尾 | `https://www.minimax.io` | `https://platform.minimax.io` |
| 其它（默认，含 `minimaxi.com`） | `https://www.minimaxi.com` | `https://platform.minimaxi.com` |

`platform` 主机：当前页 hostname 已是 `platform.` 开头时直接用 `location.origin`，否则按上表拼。推导结果由 `region` 探针原样回给诊断日志，例如国内站为 `{"host":"https://www.minimaxi.com","platform":"https://platform.minimaxi.com"}`，国际站则是对应的两个 `minimax.io` origin。`host` 是用量 / combo origin，`platform` 是计费历史 origin；两者都只是本地推导的安全 origin 字符串，不含 Cookie、token 或 groupID，也不参与 Swift 解析。

两个 ProviderID 的账号、快照与登录入口独立；脚本只根据当前页面的 hostname 选主机，Swift 解析契约保持一致。

## groupID 回退链

`x-group-id` 依次取，第一个非空即用：

1. `localStorage.minimax_current_group_id`
2. Cookie `minimax_group_id_v2`
3. localStorage `access_token` / `accessToken` / `id_token` 的 JWT payload（base64url 解出）里的 `GroupID` → `group_id` → `groupId`

MiniMax 自家 claim 是**大写驼峰**（`GroupID` / `GroupName` / `SubjectID`），别只找 snake_case。JWT 只在脚本内解，payload 与 token 原文都不落盘、不进日志。

## 官网定义窗口

- **5 小时滚动额度**（页「5h 限额」，指标 `five_hour`，官网数值 `used%/total%`，如 `0%/100%`）
- **每周额度**（页「周限额」，指标 `seven_day`；`current_weekly_status == 3` 表示无限制）

页面另有视频赠送、积分余额、近 7 / 30 天调用量、累计调用量、活跃天数，字段存在时一并解析。

## 已解析 API

全部 `GET`，header `Accept: application/json`（+ `x-group-id`）。`{www}` / `{platform}` 见「双站」。

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `region` | 无（本地合成） | 诊断：本轮推导出的 `host`（`www`）与 `platform` 两个安全 origin | 不解析 |
| `remains` | `{www}/backend/account/token_plan/remains_percent` | 全模型窗口、积分兜底、套餐名兜底；登录判定（`keyProbe`） | `MiniMaxParser` |
| `credit` | `{www}/backend/account/token_plan_credit` | 积分余额 | `MiniMaxParser` |
| `usage_summary` | `{www}/backend/account/token_plan/usage_summary` | 累计调用量、活跃天数、近 7/30 天调用量 | `MiniMaxParser` |
| `combo` | `{www}/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7`（年）与 `cycle_type=1`（月）各打一次，探针合并成 `{"yearly":{"status":…, "body":"…"}, "monthly":{…}}` | 当前套餐名 + 计费周期 + 订阅到期 | `MiniMaxParser` |
| `billing` | `{platform}/account/amount?page=N&limit=100&aggregate=false`（最多 2 页），探针内聚合 | 今日 / 近 30 天 tokens 与消费、Top3 模型 | `MiniMaxParser` |

编排：`remains`、`credit`、`usage_summary`、年/月 `combo` 与 `billing` 第一页同时启动；只有 billing 自身的第 2 页依赖第 1 页并保留串行。billing 每页 8 秒且不重试，其余走默认 12 秒 / 一次瞬态重试；全部共用 27 秒 deadline。慢账单只会丢账单聚合，不会压掉已完成的 TokenPlan 核心结果。

`combo` 外壳固定 `status: 200`，年/月原始 body（字符串）及各自 status 完整保留；解析器只解包 2xx 子项，并兼容旧 fixture 的直接对象形状。一项 401 / 503 不会压掉另一项成功套餐；两项全失败时按内层状态还原登录失效、HTTP 错误或超时，`RefreshPolicy` 也展开同一组状态。

**remains_percent 形状**（fixture `minimax_remains.json`）：

```json
{ "model_remains": [
  { "model_name": "general",
    "current_interval_used_percent": "0%", "current_interval_total_percent": "100%",
    "current_interval_status": 1, "remains_time": 534976, "end_time": 1786896000000,
    "current_weekly_used_percent": "0%", "current_weekly_total_percent": "100%",
    "current_weekly_total_count": -1, "current_weekly_status": 3,
    "weekly_end_time": 1786896000000 },
  { "model_name": "video",
    "current_interval_total_count": 3, "current_interval_used_count": 0, "current_interval_remains_count": 3 }
] }
```

`model_remains` 也可能挂在 `data` 下（`{"data":{"model_remains":[…]}}`，CodexBar 的 `coding_plan/remains` 就是这形状），解析时两处都认。

## 解析口径

### `base_resp` 先于一切

每个探针的 body 只要有 `base_resp.status_code != 0` 就不是成功响应，**不许再当 200 解析出空指标**：

| 条件 | 结果 |
|---|---|
| `status_code == 1004`，或 `status_msg` 含 `cookie` / `login` / `log in` | 该信封不贡献登录判定或指标；没有其它独立成功探针时 → `needsLogin`（会话失效） |
| 其它非 0 code | 该信封不贡献登录判定或指标；没有其它独立成功探针时 → `error("MiniMax <code>: <msg>")` |

坏信封的错误仍参与最终状态判定，但不能被同一信封内伪造的 `model_remains`、积分或 `usage_summary` 字段抵消；其它独立且 `base_resp` 成功的探针仍可按既定优先级贡献登录态与指标。

在此之前是 HTTP 层：401 / 403 → `needsLogin`；其它非 2xx → `ProbeResult.failureStatus`。

### 窗口字段族（三套并存，全都要认）

同一个窗口，接口可能给三套键名中的任意一套，缺一套不能整条消失：

| 字段族 | 语义 | 换算 |
|---|---|---|
| `current_{interval,weekly}_used_percent` | 已用百分比，字符串带 `%`（如 `"0%"`） | 直接是 used% |
| `current_{interval,weekly}_remaining_percent` | **剩余**百分比，数字或字符串，0–100 | `used% = 100 − x` |
| `current_{interval,weekly}_used_count` | 已用次数 | 与 total 配对算百分比 |
| `current_{interval,weekly}_remains_count` | 剩余次数 | 同上 |
| `current_{interval,weekly}_usage_count` | **剩余**次数（名字是 usage，语义是 remaining，CodexBar 实测注释） | 同上 |
| `current_{interval,weekly}_total_count` | 总次数；`-1` 是共享额度哨兵，不是「总量 -1」 | 负数一律不展示 |

已经是 0–100 的百分比**禁止再过 `JSONHelp.percent`**（会把 0.9 放大成 90）。百分比缺失但次数可用（`total > 0`）时才用 `(total − remaining) / total`。

### boost（加速包）抬高分母

`interval_boost_permill`（别名 `interval_boost_permille`）/ `weekly_boost_permill(e)` 是**千分比形式的分母**：`total% = permille / 10`。没有 boost 字段时分母才是 100。展示沿用官网的 `used%/total%`（`displayValue`），例如 boost `permill: 2000` + 已用 40% → `40%/200%`。

### `status == 3` 的两种含义

| 条件 | 结果 |
|---|---|
| `total_count == 0` 且 剩余次数 `== 0` 且 剩余百分比 `≥ 100` | **该档位没有这条额度**（占位行）→ 整条不渲染 |
| 其它 | 无限制（`usedPercent 0`、`detail: 无限制`、不给重置倒计时） |

剩余百分比优先取 `*_remaining_percent`，没有时用 `100 − used%` 推。典型占位行是 Plus 账号返回的 video 通道。

### 全模型遍历与服务名

`model_remains` **全部条目都解析**，不再只看 `general` + `video`：

| `model_name` | 服务 | 指标 id | 备注 |
|---|---|---|---|
| `general` | 5h 限额 / 周限额 | `five_hour` / `seven_day` | `pinned` |
| 含 `video` | 视频赠送 | `video_gift` | `pinned`，走次数 |
| 含 `minimax-m` / 前缀 `m2.` | 文本生成（CodexBar: Text Generation） | `model_<slug>` | 不 `pinned` |
| 含 `speech` | 语音合成（Text to Speech） | `model_<slug>` | 不 `pinned` |
| 含 `hailuo` 且含 `fast` | 图生视频（Image to Video） | `model_<slug>` | 不 `pinned` |
| 含 `hailuo` | 文生视频（Text to Video） | `model_<slug>` | 不 `pinned` |
| 前缀 `image-` | 图像生成（Image Generation） | `model_<slug>` | 不 `pinned` |
| 含 `music` | 音乐生成（Music Generation） | `model_<slug>` | 不 `pinned` |
| 其它 | 原样用 `model_name` | `model_<slug>` | 不 `pinned` |

`<slug>` = 模型名小写、非字母数字换 `_`。新增行不 `pinned`，交给 `UsageMetric.hasUsage` 与用户的计量顺序设置去筛。

**周窗口按字段而不是只按模型名**：条目里出现 `current_weekly_*` / `weekly_end_time` 才画周窗口；`general` 仍映射成 `seven_day`，其它文本模型用 `model_<slug>_weekly`。视频 / 语音 / 图像 / 音乐 / hailuo 通道即使带了周字段也不画。解析入口是 `MiniMaxParser.parse(..., provider:)`：国际站 `.minimaxGlobal` 不套国内价目表周期，现金指标币种读 body 的 `currency` / `cash_currency`，缺省 USD（国内站缺省 CNY）。

### 套餐名、到期、积分

- 套餐名优先级：`combo` 打分结果 → `remains` body 里的 `current_subscribe_title` / `plan_name` / `combo_title` / `current_plan_title` / `current_combo_card.title`（snake / camel 双写都认）→ 已登录兜底「Token Plan」。
- **订阅到期**（`planExpiresAt`）：在 `combo` 响应里**递归**找 `current_subscribe_end_time_ts` → `current_subscribe_end_time` → `renewal_trigger_time_ts` → `renewal_date`，前两个（订阅结束）优先于后两个（续费日）。值可以是秒 / 毫秒时间戳、数字字符串，或 `MM/dd/yyyy`（按 Asia/Shanghai 解）。零新增请求。
- `credit`：`remaining_credits` / `total_credits` / `used_credits` → 指标 `credits`（积分余额）。`credit_packages_details` 不解析。
- `credit` 没给数时，从 `remains` body 里兜底取积分：`points_balance` / `point_balance` / `credits_balance` / `credit_balance` / `balance`（第一个可解析成数字的即用），落成同一个 `credits` 指标（只有余额、没有总量，走 `amount` + `detail`）。
- `usage_summary`：`total_token_consumed`（如 `4.52B`，原样展示并按 K/M/B 换算数值）→ `lifetime_tokens`；`active_days` → `active_days`；`daily_token_usage[]` 末 7 / 30 项求和 → `last_7d_calls` / `last_30d_calls`。
- `combo`：优先 `current_subscribe` 的标题（`current_subscribe_title` / `subscribe_title` / `title` / `combo_name` / `package_name`）或其 `combo_id` 对应的 `cycle_resource_packages[]`；否则在包列表里打分：`button_text` 含「续订」+100、标题含「年度 / 年付 / 年会员」+50、`cycle_type == 3` +10。标题含 plus / max / ultra 映射 Token Plan Plus / Max / Ultra；`cycle_type == 3` 或标题带年 → `yearly`，否则 `monthly`。都没有但已登录 → 「Token Plan」。

### 计费历史（`billing`）

**按 CodexBar 实现整理，待真机确认。** `{platform}/account/amount` 与 `probeURL`（`platform.*/console/usage`）同源，站内 fetch 直通。分页与聚合全在探针 JS 里做，Swift 只读聚合结果：

- 分页：`page` 从 1 起、`limit=100`，**最多 2 页**；`charge_records` 为空、或本页出现 30 天窗口之前的记录就停。
- 只统计 `result`（没有则 `status`）能判定为 `SUCCESS` 的记录；两个字段都不是字符串时不丢弃（无从判定，宁可算进去）。
- token 数：`consume_token > 0` 优先，否则 `consume_input_token + consume_output_token`。
- 金额：优先 `consume_cash_after_voucher`（抵扣券后），否则 `consume_cash`；币种记 CNY。
- 日期优先级：`created_at`（秒 / 毫秒自适应）→ `ymd`（`yyyy-MM-dd` / `yyyyMMdd` / `yyyy/MM/dd`）→ `consume_time`。「今日」按 **Asia/Shanghai** 切日。
- 探针产出：`{"todayTokens":…, "last30Tokens":…, "todayCash":…, "last30Cash":…, "topModels":[{"name":…, "tokens":…}]}`。
- 解析成三条**非 `pinned`** 指标：`today_tokens`「今日 tokens」、`last_30d_tokens`「近 30 天 tokens」（`detail` 列 Top 3 模型）、`last_30d_cash`「近 30 天消费」（`amount` + 币种：body 声明优先，否则国内 CNY / 国际 USD）。

## 备用端点（待真机对拍，暂不实现）

CodexBar 走的是另一套后端，返回 `current_interval_remaining_percent` 数字形态。同一账号可能两套都能打通，未对拍前不切换：

| 端点 | 说明 |
|---|---|
| `{api}/v1/token_plan/remains` | API-token 首选，`Authorization: Bearer sk-cp-*`；跨源，站内 fetch 会被 CORS 拦 |
| `{api}/v1/api/openplatform/coding_plan/remains` | 同上，旧端点 |
| `{platform}/v1/api/openplatform/coding_plan/remains?GroupId=<gid>` | 同源可打，返回 `data.model_remains`（本目录的字段族已兼容这形状） |
| `{platform}/user-center/payment/coding-plan?cycle_type=3` | HTML 页，需 `__NEXT_DATA__` / 正则兜底，成本高 |

## 标价（`PlanCatalog.swift`）

以下人民币标价只适用于国内站 `minimax`：

| 套餐 | 月付 | 年付 |
|---|---|---|
| Token Plan Plus | ¥49 | ¥490 |
| Token Plan Max | ¥119 | ¥1,190 |
| Token Plan Ultra | ¥469 | ¥4,690 |

套餐名不带「 年」后缀，周期进 `billingCycle`。

国际站 `minimaxGlobal` 的官方价格与计费周期尚未通过官网 / 真机校准。即使接口返回与国内站同名的 Token Plan，App 也不展示静态价格或周期徽章；确认国际站价目后，必须先更新本目录再改 `PlanCatalog.swift`。

## 登录判定

探针缺少 `base_resp`（兼容旧形状）或 `base_resp.status_code == 0` 时，满足任一即已登录：`remains` 含 `model_remains`（含 `data.model_remains`）；`credit` 含 `total_credits` / `remaining_credits`；`usage_summary` 含 `total_token_consumed` / `daily_token_usage`。`usage_summary` 信封为 1004、其它错误码、Bool / 非数值状态码时，不能贡献登录态、累计调用量、活跃天数或近 7/30 天调用量。

判定顺序：关键 `remains` 探针判定会话失效（HTTP 401 / 403，或信封 1004 / login）→ `needsLogin` 并清掉已解析的积分 / 账单 / 累计调用 leftover（优先于其它独立成功探针）；`remains` 5xx / 超时不是会话失效，合法 `credit` / `usage_summary` 仍可证明登录。否则任一独立成功用量探针已证明登录 → `ok`。因此 `usage_summary` / `credit` / `combo` 等补充探针的 1004 或其它信封错误不会降级另一份合法 `remains` / 用量结果，但坏信封自身仍不贡献任何字段。没有独立成功探针时，补充探针会话失效 → `needsLogin`，其它 `base_resp` 错误 → `error`；再否则有非 2xx 探针 → `failureStatus`；全无响应 → `error("未获取到任何响应")`；其余 → `needsLogin`。

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。`active_days` 与 `base_resp.status_code` 只在可安全转 Int 时解读；`status_code` 键存在但值为 Bool / 非数字 / 越界数时整份响应按形状错误处理，不能再从同一信封贡献套餐或用量；键完全缺失仍按旧响应形状兼容。官网直出百分比字段只接受 0–100，越界值直接拒绝而不 clamp 成 0 / 100；仍可由合法次数字段推导窗口。百分比对和相对重置时间越界时使用默认文案 / 丢弃日期，时间只接受 1970–9999。

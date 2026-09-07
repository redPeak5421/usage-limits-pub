# 智谱 Coding Plan CN（open.bigmodel.cn）用量接口目录

- **官网 Usage 页**：https://open.bigmodel.cn/coding-plan/personal/usage（窗口定义见 https://docs.bigmodel.cn/cn/coding-plan/overview）
- **鉴权**：用量接口要 `Authorization`。Token 在可读 Cookie `bigmodel_token_production`（JWT），探针读出后带 `Authorization: Bearer <jwt>`，请求附 `Accept: application/json`。Cookie-only 会 200 `{"code":1001,"msg":"Header中未收到Authorization参数，无法进行身份验证。","success":false}`。Cookie 域：`bigmodel.cn`。
- **登录入口**：`https://open.bigmodel.cn/coding-plan/personal/usage`
- **探针执行页**：`https://open.bigmodel.cn/coding-plan/personal/usage`
- **范围**：只接个人 **Coding Plan CN**（Lite / Pro / Max）。团队版、按量付费余额不接。

## 已解析 API（探针名 → 代码）

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `customer` | `GET /api/biz/customer/getCustomerInfo` | 登录判定 | `ZhipuParser` |
| `subscription` | `GET /api/biz/subscription/list?pageSize=9999&pageNum=1` | 套餐 / 周期 / 到期 / 标价（按 `productId`） | `ZhipuParser` |
| `quota` | `GET /api/monitor/usage/quota/limit` | 每 5 小时额度 + MCP 每月额度 | `ZhipuParser` |
| `model_usage` | `GET /api/monitor/usage/model-usage?startTime=<6 天前 00:00:00>&endTime=<今天 23:59:59>`（本地时间，`yyyy-MM-dd HH:mm:ss`） | 近 7 天 Token 总量 + 按模型 | `ZhipuParser` |

四条请求同时发出，默认单次 12 秒、瞬态最多重试一次，并共用 27 秒脚本 deadline；任何一条慢请求不会串行占用其它探针预算。

**customer 响应形状**（fixture `zhipu_customer.json`，已脱敏）：

```json
{ "code": 200, "success": true, "data": { "id": 10001, "customerNumber": "10001", "userType": "PERSONAL", "…": "…" } }
```

**subscription 响应形状**（fixture `zhipu_subscription.json`）：

```json
{ "code": 200, "data": [{
  "productId": "product-733034", "productName": "GLM Coding Pro", "status": "VALID",
  "valid": "2027-01-24 10:00:00-2028-01-24 10:00:00",
  "purchaseTime": "2026-01-24 14:42:50", "currentRenewTime": "2026-01-24", "nextRenewTime": "2027-01-24",
  "billingCycle": "annually", "standardPrice": 2400.0, "version": "V1"
}] }
```

**quota/limit 响应形状**（fixture `zhipu_quota_limit.json`）：

```json
{ "code": 200, "data": {
  "limits": [
    { "type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 1000, "currentValue": 0,
      "remaining": 1000, "percentage": 0, "nextResetTime": 1787553682998,
      "usageDetails": [{ "modelCode": "search-prime", "usage": 0 }, { "modelCode": "web-reader", "usage": 0 }, { "modelCode": "zread", "usage": 0 }] },
    { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 1, "nextResetTime": 1786909052482 }
  ],
  "level": "pro"
} }
```

多窗口形态（fixture `zhipu_quota_limit_units.json`，按真机可能的形态构造）：5 小时 `unit:3,number:5` 与每周 `unit:6,number:1` **都是 `TOKENS_LIMIT`**，另有一条 `CREDIT_LIMIT`（`unit:1,number:1`）与带 `usageDetails` 的 `TIME_LIMIT`，外加 `data.planName`。

**model-usage 响应形状**（fixture `zhipu_model_usage.json`）：

```json
{ "code": 200, "data": {
  "totalUsage": {
    "totalModelCallCount": 114, "totalTokensUsage": 6871706,
    "modelSummaryList": [{ "modelName": "GLM-5.3", "totalTokens": 249599 }, { "modelName": "GLM-5.2", "totalTokens": 6622107 }]
  },
  "granularity": "hourly", "x_time": ["2026-08-10 00:00"], "tokensUsage": [0]
} }
```

## 解析口径

- **套餐**：`subscription.data`（数组，或 `data.records` / `data.list`）里第一条 `status` 为 `VALID` / `ACTIVE` / `SUCCESS` 的记录（没有则取第一条）。`productId` 命中 `PlanCatalog.zhipuSKU` 时直接得到档位、周期、标价；否则用 `productName` 按含 `lite` / `max` / `pro` 映射为 Coding Plan Lite / Max / Pro。`subscription` 缺失时用 `quota.data` 的套餐名字段，按 `planName` → `plan` → `plan_type` → `packageName` → `level` 取第一个非空串再做同样映射（订阅接口仍是价格与周期的唯一权威，套餐名字段不参与定价）。
- **周期**：`billingCycle` 字段（如 `annually`）> SKU 表周期 > `productName` 里的周期词 > 由起止时间推算；仍无且有标价时按月。
- **到期**：`valid` 的结束时间（`"起-止"` 取末段 `yyyy-MM-dd HH:mm:ss`）> `nextRenewTime` > `expireTime`；起始取 `valid` 首段 > `currentRenewTime` > `purchaseTime`。

### `limits[]` 窗口映射

`unit` 是**时间单位**，`number` 是倍数，窗口时长 = `number × 乘数`：

| `unit` | 含义 | 分钟乘数 | 例 |
|---|---|---|---|
| 1 | 天 | 1440 | `unit:1, number:30` → 30 天 |
| 3 | 小时 | 60 | `unit:3, number:5` → 300 分钟 = 5 小时 |
| 5 | 分钟 | 1 | `unit:5, number:1` → 1 分钟（TIME_LIMIT 时是月度 MCP 标记，见下） |
| 6 | 周 | 10080 | `unit:6, number:1` → 一周 |

表外或溢出的 `unit` 不猜，窗口时长按缺失处理；缺时长的 `TOKENS_LIMIT` / `CREDIT_LIMIT` **整条丢掉**，不参与排序。

- **`TOKENS_LIMIT` 与 `CREDIT_LIMIT` 是同一批**（都是主用量窗口），合并后**按窗口时长升序**排：
  - **id 只看窗口时长**：300 分钟 → `five_hour`（始终 `pinned`），10080 分钟 → `seven_day`，其它已知分钟数 → `window_<minutes>`。因此**只有一条每周窗口时也是 `seven_day`**，不再因为「只有一条」就写成 `five_hour`。**禁止按数组位置或最短/最长猜 5h/周**。
  - 标签取真实时长（300 分钟即「每 5 小时」，10080 分钟即「每周」，其它写成「每 N 小时 / 每 N 天 / 每 N 周」）。
  - `CREDIT_LIMIT` 的标签追加「（积分）」。
  - 历史 bug（已修）：旧实现把所有 `TOKENS_LIMIT` 一律映射成「每 5 小时」，而 5 小时与每周**都是** `TOKENS_LIMIT`，导致两条 id 都是 `five_hour`、周额度被吞掉。
- **`TIME_LIMIT` 走 MCP 泳道**：id `mcp_monthly`「MCP 每月额度」，绝不与积分窗口混排。`unit==5 && number==1` 是官网的**月度 MCP 标记**，窗口按 30 天算，不是 1 分钟。`usageDetails[]` 里 `modelCode` 含 `search` / `reader` / `zread` / `mcp` 的启发式保留：未知 `type` 但明细像 MCP 时也归到这条。
- **MCP 按工具明细**：`usageDetails[]` 取 `usage > 0` 的前 5 个（按 usage 降序）拼成 `detail` 文案 `search-prime 12 · web-reader 3`；全为 0 时不产出文案。
- **未知 `type` 直接丢弃**，不再原样产出英文标签的兜底指标。
- **百分比**：`percentage` 已是 0–100 整数（1 = 1%），只钳制，**不得走 `JSONHelp.percent`**（它会把 ≤1 的值当 0–1 口径放大 100 倍）。有 `usage`（= 额度总量，不是已用量）且 > 0 时用更细的口径重算：`used = max(usage - remaining, currentValue)`，`percent = used / usage × 100`，再钳到 0–100。两者都拿不到时退回 `currentValue ÷ (currentValue + remaining)`（或 `limit` / `quota`）。
- **重置时间**：`nextResetTime` / `resetTime`（毫秒）。百分比与重置时间都缺失时跳过该条，不编数。
- **计费时段（高峰 / 低谷）**：`rate_period`「计费时段」，`displayValue` 为「高峰 1x」/「低谷 0.5x」，`resetsAt` 是下一次切换时刻。**纯本地时钟推导，零网络**：高峰 = **周一至周五 UTC 06:00–10:00**（即 UTC+8 的 14:00–18:00），周末全天低谷；低谷时下一次切换要跳过周六周日。**只有存在 `CREDIT_LIMIT` 窗口时才产出**（积分计划才有峰谷倍率，纯 token 套餐是模型固定价）。该条没有百分比也没有金额，因此按 `UsageMetric.hasUsage` 规则默认折叠在「未使用指标」里。
- **近 7 天 Token**：`data.totalUsage.totalTokensUsage`（或 `data.totalTokensUsage`）。id 默认 `seven_day`；**当 quota 已经产出了真正的周额度窗口（也叫 `seven_day`）时改用 `seven_day_tokens`**，避免两条同 id。`modelSummaryList[]` 每个 `totalTokens > 0` 的模型各产出一条 `model_<name>`（`modelName` / `totalTokens`）。
- **展示顺序**：`five_hour` → `seven_day` → 其余（中间窗口 / 计费时段 / 按模型）→ `mcp_monthly`。

### 信封与状态

`quota` / `model-usage` / `customer` / `subscription` 的信封统一按 `success === true && code === 200` 校验，失败时取 `msg`。校验按探针隔离：失败信封不能从自身 `data` 贡献登录态、套餐或用量；另一条合法探针仍可独立贡献数据并使整轮为 `ok`。**登录类信封优先**：任一探针 `code` 为 401 / 403 / 1001（或文案像未登录）时，整轮为 `needsLogin`，即使另一条业务信封先报了 500。`code` 键存在但为 Bool / 非数字 / 越界数时按形状错误处理，固定文案「智谱响应状态码异常」；键完全缺失仍兼容旧响应。

| 情况 | 状态 |
|---|---|
| 解出任意用量 / 登录判定通过 | `ok` |
| `success:false` 或 `code != 200`，且 code 为 401 / 403 / 1001，或 `msg` 含 Authorization / token / 登录 / 身份验证 / 未授权 | `needsLogin` |
| 其它信封失败 | `error(msg)`（msg 为空时写 `智谱接口失败 code <n>`） |
| HTTP 401 / 403 | `needsLogin` |
| 其它非 2xx | `error("HTTP <n>")` |
| 探针超时（status -3） | `error("请求超时")` |
| 没有任何响应 | `error("未获取到任何响应")` |

**登录判定**：`customer.data` 有 `customerNumber` 或 `id`，或 `subscription` 有记录，或 `quota.data` 可解析 → 已登录。

## 待真机确认（均未实现，勿凭本节直接写代码）

- **按量付费余额**：`GET https://www.bigmodel.cn/api/biz/account/query-customer-account-report`（`data.availableBalance` / `balance` / `rechargeAmount` / `giveAmount` / `totalSpendAmount`，币种硬编码 ¥）。探针页在 `open.bigmodel.cn`，该端点在 `www.bigmodel.cn`，属**跨源** fetch —— Cookie 域是 `bigmodel.cn` 所以凭据能带上，但 **CORS 行为未验证**，可能需要把探针执行页换成 / 追加一个 `www.bigmodel.cn` 的源。未实现。
- **30 天 model-usage 序列**：同一个 `model-usage` 端点换 `startTime/endTime` 再打一次即可拿到日粒度 30 天序列，`data.x_time[]` 与 `data.modelDataList[].tokensUsage[]` 按索引对齐。未实现（当前只打近 7 天，且只取标量）。
- **团队版**：quota 追加 `?type=2`、model-usage 追加 `&type=3`，并要 `Bigmodel-Organization` / `Bigmodel-Project` 两个头。缺任一 selector 时线上会返回 200 + 空 `data:{}`（静默出错）。org / project id 的运行时来源未验证。未实现。

## 标价（`PlanCatalog.swift`）

当前 glm-coding 页（连续包月 / 包季 8 折 / 包年 7 折），年付、季付显示该周期总额：

| 档位 | 月付 | 季付 | 年付 |
|---|---|---|---|
| Coding Plan Lite | ¥118 | ¥283 | ¥991 |
| Coding Plan Pro | ¥538 | ¥1,291 | ¥4,519 |
| Coding Plan Max | ¥1,078 | ¥2,587 | ¥9,055 |

`productId` → SKU 表（`PlanCatalog.zhipuSKUs`），历史 SKU 用当时原价，不拿当前页覆盖：

| 版本 | Lite 月 / 季 / 年 | Pro 月 / 季 / 年 | Max 月 / 季 / 年 |
|---|---|---|---|
| 当前 | `product-a490e5` ¥118 / `product-e90ff2` ¥283 / `product-86305b` ¥991 | `product-92f659` ¥538 / `product-f176ba` ¥1,291 / `product-6b9bb7` ¥4,519 | `product-5b41f6` ¥1,078 / `product-6a48ac` ¥2,587 / `product-c51c35` ¥9,055 |
| V3 | `product-02434c` ¥49 / `product-b8ea38` ¥132 / `product-70a804` ¥470 | `product-1df3e1` ¥149 / `product-fef82f` ¥402 / `product-5643e6` ¥1,430 | `product-2fc421` ¥469 / `product-5d3a03` ¥1,266 / `product-d46f8b` ¥4,502 |
| V2 | `product-bf2b62` ¥40 / `product-85eab1` ¥120 / `product-060148` ¥480 | `product-a6ef45` ¥200 / `product-fc5155` ¥600 / `product-733034` ¥2,400 | `product-1a52ed` ¥400 / `product-6e1f0f` ¥1,200 / `product-7fd668` ¥4,800 |

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。`unit` 必须是官网枚举表中的整数；计算出的窗口分钟、工具用量与信封 code 在转 Int 前检查范围，越界字段不展示；信封 code 键存在但不是合法整数时按上一节的形状错误处理。时间只接受 1970–9999；`valid` 文本即使能被 `DateFormatter` 解析，起止时间越界也只丢对应日期，不污染套餐快照或账期推断。

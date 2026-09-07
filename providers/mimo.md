# 小米 MiMo（platform.xiaomimimo.com）用量接口目录

- **官网 Usage 页**：`https://platform.xiaomimimo.com/#/console/balance`
- **登录入口 / 探针页**：`loginURL` 与 `probeURL` 都是上述余额页；API 与页面同源。
- **鉴权**：本机 WebKit Cookie。站内 `fetch(..., { credentials: 'include' })` 自动携带；不读取、不拼接、不落盘 Cookie，也不使用 Bearer / API key。三条探针 `noAuth: true`。CodexBar 桌面端会校验 `api-platform_serviceToken` 与 `userId`，iOS 交给浏览器 Cookie jar 和必需接口状态判定登录。
- **Cookie 域**：`xiaomimimo.com`。退出登录清该域 WebKit 数据。
- **keyProbe**：`balance`。
- **标价**：本轮没有可核实的官方订阅标价，`PlanCatalog` 不收录 MiMo；快照不写 `billingCycle`。
- **接入范围**：账户余额（必需），月度 Token Plan 用量、套餐代号与当前周期结束时间（可选）。不接 CodexBar 的 `~/.codexbar/mimo-local-usage.json` 桌面本地记账 fallback，不接请求历史或 API key。
- **代码**：探针 `ProviderScripts.mimo`，解析 `MiMoParser`，fixture `mimo_balance.json` / `mimo_plan_detail.json` / `mimo_plan_usage.json` / `mimo_plan_expired.json`，测试 `MiMoParserTests`。
- **观测**：2026-08-28 **按 CodexBar 实现整理，待真机确认**。字段与请求来自 `reference/CodexBar/Sources/CodexBarCore/Providers/MiMo/` 及其测试；本 App 尚未用 iOS 真机诊断日志确认响应形状、信封码或时区头是否仍为当前值。

## 接口表

所有接口同源 `https://platform.xiaomimimo.com`，全部为 GET、Cookie 鉴权。

| 探针名 | 请求 | 用途 |
|---|---|---|
| `balance` | `GET /api/v1/balance` | **必需**。登录判定与账户余额。 |
| `plan_detail` | `GET /api/v1/tokenPlan/detail` | 可选。套餐代号、周期结束时间、过期状态。 |
| `plan_usage` | `GET /api/v1/tokenPlan/usage` | 可选。月度 Token Plan 已用 / 总额 / 百分比。 |

请求头（`ProviderScripts.mimo`）：

```text
Accept: application/json, text/plain, */*
x-timeZone: UTC+01:00
credentials: include
```

`Origin` / `Referer` / `User-Agent` / `Accept-Language` 由 WKWebView 当前页面与系统自动提供，脚本不手写。`x-timeZone` 是 CodexBar 2026-08 的硬编码观测值，服务端是否实际使用尚待真机确认。

三条请求由 `Promise.all` **并发**发出，而不是 balance 后再串行等待两个可选接口：

- `balance` 的单次超时为 12 秒，保留默认的一次瞬时错误重试；最坏预算为 `12s × 2 + 300ms backoff = 24.3s`，严格低于 `WebViewFetcher` 的 30 秒整段上限。
- `plan_detail` / `plan_usage` 共用 SIDE 配置：单次 8 秒、`retry: false`。二者失败只返回各自 `ProbeResult`，不能拖掉已成功的余额。
- 并发整段理论最坏约 24.3 秒，另留约 5.7 秒给 WebKit 调度与结果桥接。

## 形状示例

以下均为按 CodexBar 实现整理的脱敏样例，待真机确认。

### 信封

```json
{ "code": 0, "message": "", "data": {} }
```

- `code == 0` 成功；`code` 必须是有限、无小数、可表示的整数。JSON `true` / `false` 不得经 `NSNumber` 桥接冒充 1 / 0。
- HTTP 或信封 `code` 为 300...399、401、403 时视为登录失效。
- 其它非零信封码是 API 错误；错误文字只取 `message` 的短文本，不保存响应中的身份或凭据字段。

### `balance`

```json
{
  "code": 0,
  "message": "",
  "data": {
    "balance": "50.00",
    "currency": "USD",
    "cashBalance": "30.00",
    "giftBalance": "20.00"
  }
}
```

- 四个金额字段都是**数字字符串**；`cashBalance` / `giftBalance` 可缺失。原生 JSON number 与 Bool 都不符合这份契约：必需 `balance` 因此判异常，可选分项因此不展示。
- `balance` 必须是有限非负数，`currency` 去首尾空白后不能为空，否则必需接口解析失败。
- 可选分项若不是有限非负数则整组分项不展示，不让 NaN / Infinity / 负数进入快照；余额本身仍可用。

### `plan_detail`

```json
{
  "code": 0,
  "data": {
    "planCode": "standard",
    "currentPeriodEnd": "2026-05-04 23:59:59",
    "expired": false
  }
}
```

`currentPeriodEnd` 固定按 UTC 的 `yyyy-MM-dd HH:mm:ss` 解析。无效日期丢弃，不回落到本地时区。`expired == true` 表示该计划不可再作为当前用量窗口。

### `plan_usage`

```json
{
  "code": 0,
  "data": {
    "monthUsage": {
      "percent": 0.0505,
      "items": [
        { "name": "month_total_token", "used": 10100158, "limit": 200000000, "percent": 0.0505 }
      ]
    }
  }
}
```

- 只取 `data.monthUsage.items.first`，不递归猜键。
- `used` / `limit` 必须有限且非负，`limit > 0` 才产月度指标。这里兼容真实 JSON number 与数值字符串，但明确拒绝 Bool，避免 `true` / `false` 被桥接成 1 / 0。
- 使用 item 自己的 `percent`；它是 **0...1 比值**，乘 100 后钳到 0...100，不能当成已经是百分数。

## 解析口径（`MiMoParser`）

- **必需余额**：`balance` 2xx、信封成功且余额 / 币种合法时产出：

  ```text
  UsageMetric(id: "balance", label: "余额",
              amount: balance, currency: currency,
              detail: "付费 <cash> · 赠送 <gift>"（两项都合法时才有）, pinned: true)
  ```

  余额是当前可用金额，不和 Token Plan 的总额度相加，也不写成 `remaining / total`。
- **月度 Token Plan**：`plan_usage` 合法、`limit > 0` 且 `plan_detail` 没明确标记 `expired == true` 时产出 `id: "monthly"`、标签「月度额度」：
  - `usedPercent = item.percent × 100` 后钳 0...100；0 与 1 分别显示 0% 与 100%。
  - `remaining = max(0, limit - used)`，`total = limit`。
  - `resetsAt` 来自合法的 `currentPeriodEnd`；详情为 `已用 <used> / <limit> credits`；`pinned: true`。
  - `planName` 取 `planCode`，只做去空白、下划线 / 连字符转空格和逐词首字母大写；不猜套餐或价格。
- **已过期计划**：明确 `expired == true` 时，不产月度指标、不写 `planName` / `planExpiresAt`，避免把陈旧用量伪装成当前额度；合法余额仍正常显示。
- **可选失败**：`plan_detail` / `plan_usage` 超时、非 2xx、信封失败、空数组或形状漂移都只丢掉对应可选信息，不能压掉有效余额。
- **数值安全**：进入快照的金额、用量、总额、百分比都必须有限且非负；减法后只对剩余量做 `max(0, ...)`。任何成功或失败快照都必须能被 `JSONEncoder` 编码。
- **指标顺序**：`monthly` > `balance`。只有余额时仍为 `.ok`。

### 登录判定与状态分档

| 情况 | 状态 |
|---|---|
| `results` 为空 | `.error("未获取到任何响应")` |
| `balance` 缺失 | `.error("未获取到余额响应")` |
| `balance` HTTP 300...399 / 401 / 403 | `.needsLogin` |
| `balance` HTTP 其它非 2xx / 网络失败 | `ProbeResult.failureStatus` |
| `balance` HTTP 2xx，但信封码为 300...399 / 401 / 403 | `.needsLogin` |
| `balance` HTTP 2xx，但信封其它错误或必需字段非法 | `.error("余额数据异常")`（有可信 `message` 时附短消息） |
| 合法余额至少产出一条核心指标 | `.ok` |

## 隐私与坑

- `api-platform_serviceToken`、`userId` 及其它 Cookie 只留在 WKWebsiteDataStore；解析器不接触它们，fixture 与目录也不放真实值。
- CodexBar 的本地 JSON 记账是 macOS CLI 包装器专用，并非官网配额；iOS 不读取桌面文件，也不把本地估算混进官方余额。
- `percent` 是 0...1，这一家必须乘 100；不要把其它供应商「已是 0...100」的规则套过来。

# LongCat（longcat.chat，美团）用量接口目录

- **官网 Usage 页**：`https://longcat.chat/platform/usage`（Token 额度 + 加油包）。单一 host，无国内 / 国际之分。
- **登录入口 / 探针页**：`loginURL` 与 `probeURL` 都是 `https://longcat.chat/platform/usage`。未登录时站内出登录墙，登录完成后停留同源。
- **鉴权**：本机 WebKit Cookie（美团 passport 体系）。站内 `fetch(..., { credentials: 'include' })` 自动携带；**无 CSRF、无 sec_token、无 Bearer / API key**，探针一律 `noAuth: true`。
- **Cookie 域**：`longcat.chat`。退出登录清该域 WebKit 数据。
- **keyProbe**：`user`（`/api/v1/user-current`）。
- **标价**：**无**。CodexBar 的 `docs/longcat.md` 未记录任何订阅标价，官网口径未确认，因此 `PlanCatalog` 不收录 LongCat，快照不写 `billingCycle`。
- **接入范围**：Token 包额度（活跃 lot）、旧版聚合 Token 额度（fallback）、加油包余量与最近过期时间。不接按模型明细（`extData`）、不接 API key。
- **代码**：探针 `ProviderScripts.longcat`，解析 `LongCatParser`，fixture `longcat_user.json` / `longcat_token_packs.json` / `longcat_token_packs_inactive.json` / `longcat_token_usage.json` / `longcat_fuel.json`，测试 `LongCatParserTests`。
- **观测**：**按 CodexBar 实现整理，待真机确认**。形状取自 `reference/CodexBar` 的 `Sources/CodexBarCore/Providers/LongCat/*` 与 `Tests/CodexBarTests/LongCatProviderTests.swift`（CodexBar 注明这些字段路径锁定自真实 longcat.chat 响应）。我们**尚未**在 iOS 真机登录态抓过报文，键名与信封码需按设置页「探针诊断日志」核对后再回写本文件。

## 接口表

所有地址同源 `https://longcat.chat`，全部走浏览器 Cookie。

| 探针名 | 请求 | 用途 |
|---|---|---|
| `user` | `GET /api/v1/user-current` | **必需**。会话校验（登录判定唯一依据）。返回体含手机号 / 会话 token，**不落任何账号字段**（见「隐私」）。 |
| `token_packs` | `POST /api/pay/quota/metering/token-packs/summary`，`Content-Type: application/json`，body `{}` | 主额度：当前 token 包 lot 的总量 / 已用。best-effort。 |
| `token_usage` | `GET /api/lc-platform/v1/tokenUsage` | 旧版聚合额度，**仅作 fallback**（见「坑」）。 |
| `fuel` | `GET /api/lc-platform/v1/pending-fuel-packages` | 加油包（会过期的次级额度）余量与最近过期时间。best-effort。 |

请求头只加 `Accept: application/json, text/plain, */*`；`Origin` / `Referer` / `User-Agent` 由 WKWebView 自动补，**禁止手写**。CodexBar 桌面端手写这三个头是因为它用裸 `URLSession`，我们在源内 `fetch`，不需要也不允许。

CodexBar 的调用顺序是「`token_packs` 没有活跃 lot 时才打 `token_usage`」。我们的探针**四条一次打完**（都在同源、都很便宜，省一次往返不值得多一轮脚本调度），由 `LongCatParser` 决定优先级——即「有活跃 lot 就忽略 `token_usage`」。

四条请求用 `Promise.all` 同时启动并共享 27 秒 deadline；`user` 走默认 12 秒预算，另外三条单次 8 秒，均只在剩余共享预算容许时瞬态重试。任一腿挂住不会阻止其它已完成响应越桥。

## 形状示例

**以下全部为按 CodexBar 实现整理的脱敏样例，待真机确认。**

### 信封

美团系信封，四个接口同构：

```json
{ "code": 0, "message": "success", "data": { } }
```

- `code == 0` 或 `code == 200` 为成功；`code` 缺失时按成功处理（只看 HTTP 状态）。
- `code == 401` / `403` 视同未登录（HTTP 200 也一样）。
- 失败信息在 `message`，部分接口用 `msg`。

### `user`（`/api/v1/user-current`）

```json
{ "code": 0, "data": { "userId": 1, "name": "<账号名>", "nickName": "<昵称>", "phone": "<手机号>", "token": "<会话 token>" } }
```

**`name` / `nickName` / `phone` / `token` 一律不解析、不存储、不进快照**：账号名对用量看板没有价值，而手机号与 token 属于凭据面。诊断日志里该探针只记 HTTP 状态与响应长度。

### `token_packs`（`/api/pay/quota/metering/token-packs/summary`）

```json
{ "code": 0, "data": { "currentLot": { "totalToken": 50000000, "consumedToken": 1212576,
                                       "consumedRatio": 0.02425152, "status": "ACTIVE" } } }
```

- 无活跃包时 `currentLot` 为 `null`，或 `status` 为 `"EXPIRED"`，或 `totalToken` 为 `0`。
- `consumedRatio` 是 0–1 比值，**我们不用它**：百分比一律客户端按 `consumedToken / totalToken` 现算，避免两个口径漂移。

### `token_usage`（`/api/lc-platform/v1/tokenUsage`）

```json
{ "code": 0, "data": {
    "usage": { "totalToken": 500000, "usedToken": 120000, "availableToken": 380000, "freeAvailableToken": 380000 },
    "extData": { "LongCat-Flash-Lite": { "totalToken": 50000000, "usedToken": 0 } } } }
```

- 聚合值在 `data.usage`；老形态可能直接把三个字段摊在 `data` 上，两种都吃。
- `extData` 是按模型明细，**不接**。

### `fuel`（`/api/lc-platform/v1/pending-fuel-packages`）

```json
{ "code": 0, "data": { "totalQuota": 1000,
                       "list": [ { "availableToken": 600, "expireTime": 1750000000000 },
                                 { "availableToken": 150, "expireTime": 1760000000000 } ] } }
```

- 无加油包时 `totalQuota` 为 `0`、`list` 为空数组。
- `expireTime` 观测到的是 **epoch 毫秒**；解析同时兼容 epoch 秒、ISO8601 与 `yyyy-MM-dd HH:mm:ss`。越界日期（早于 1970 或晚于 9999）丢弃 `resetsAt`，走 `JSONHelp.isSafeDate`。

## 解析口径（`LongCatParser`）

- **信封**：`LongCatParser.envelope(_:)` 统一拆信封，返回 `(data: [String: Any]?, code: Int?)`。`data` 缺失时回落整个对象。任何一步取不到就跳过该探针，不崩。
- **`token_pack`「Token 包」**（`pinned`）：`token_packs.data.currentLot` 的 `status` 忽略大小写等于 `ACTIVE` 且 `totalToken > 0` 时产出。
  - `usedPercent = consumedToken / totalToken × 100`，钳 0–100（`consumedToken` 缺失按 0）
  - `total = totalToken`，`remaining = totalToken − consumedToken` 后钳在 `0...totalToken`，避免服务端超额值产生负剩余
  - `detail = "已用 <已用> / <总量> tokens"`，数字走 `MoneyFormat.string(_, currency: nil)` 的 K / M / B 压缩（如 `已用 1.21M / 50.00M tokens`）
- **fallback（无活跃 lot 时才走）**：`token_usage.data.usage`（缺则 `token_usage.data` 本身）的 `totalToken > 0` 时，**复用同一个 id `token_pack`**、标签换成「Token 额度」。
  - `usedToken` 缺失时按 `totalToken − availableToken` 反推；两者都缺按 0
  - id 不换是为了让用户在卡片「…」里排好的计量顺序（`SharedStore.metricOrder`）在两条路径间保持稳定
  - **有活跃 lot 时绝不读 `token_usage`**：见「坑」
- **`fuel_packages`「加油包」**：
  - `remaining = Σ list[].availableToken`（一条都没有该字段时回落 `totalQuota`）
  - `totalQuota > 0` 时若上述合计超过总量，或加总溢出为非有限值，视为响应漂移并丢弃整条加油包；合法合计原值保留，不静默钳位
  - `total = totalQuota`（仅 `> 0` 时写入）；`total > 0` 时 `usedPercent = (total − remaining) / total × 100`，钳 0–100
  - `resetsAt` = `list[].expireTime` 里**最早**的一个（加油包会过期，最近的那张先失效）
  - `totalQuota` 缺失 / 为 0 但确有余量时，仍产出这条：只写 `remaining`、`amount = remaining` 与 `detail = "剩余 <余量> tokens"`，不写百分比（`amount > 0` 保证 `hasUsage` 为真，首页不会把它藏掉）
  - 既无 `totalQuota` 又无余量 → 不产出
- **百分比**：全部客户端现算后钳 0–100，**不走 `JSONHelp.percent`**（`consumedRatio` 这类 0–1 值我们根本不读，读的都是绝对 token 数）。
- **漂移防御**：`code` 只有有限、无小数且能精确放进 `Int` 时才认；NaN / Infinity / 越界值按信封解析失败处理。所有 token / quota 数值必须有限且非负，非法字段整条丢弃，不让不可编码数值进入快照。
- **`planName`**：不产出。LongCat 没有订阅套餐名，只有 token 包与加油包；`billingCycle` 恒为 nil（无标价）。
- **指标顺序**：`token_pack` > `fuel_packages`（主额度在前）。

### 登录判定与状态分档

| 情况 | 状态 |
|---|---|
| `user` 2xx 且信封 `code` 为 0 / 200 / 缺失 | 已登录；此时才解析额度 |
| `user` 未登录 / 失败 | 对应失败态，**不解析** `token_packs` / `token_usage` / `fuel`，metrics 为空 |
| `user` 401 / 403，或信封 `code` 为 401 / 403 | `.needsLogin` |
| `user` 为 3xx（会话过期被重定向到登录页） | `.needsLogin` |
| 已登录且至少产出一条指标 | `.ok` |
| 已登录但一条都没产出 | 取 `token_packs` / `token_usage` 的 `ProbeResult.failureStatus`（401/403 → `.needsLogin`，其余非 2xx → `.error("HTTP n")`）；都是 2xx 只是没数据 → `.error("未获取到用量数据")` |
| `user` 是其它非 2xx（5xx / 超时 / 脚本失效） | 该探针的 `failureStatus` |
| `results` 为空 | `.error("未获取到任何响应")` |

## 坑

- **`tokenUsage` 的陈旧 0**：对 token 包账号，`/api/lc-platform/v1/tokenUsage` 会返回过期的 0（CodexBar issue #2670）。因此它**只能**当 fallback，有活跃 lot 时必须忽略。回归测试 `LongCatParserTests.testActiveLotWinsOverStaleTokenUsage` 锁这条。
- **`token_packs` 的 Cookie path 作用域**：CodexBar 记录「部分浏览器 Cookie 的 path 作用域打不到 `/api/pay/...`」，所以把它标成 best-effort。WKWebView 内同源 `fetch` 不存在这个问题，但探针仍按 best-effort 处理（拿不到就走 fallback），不因它失败而整卡报错。
- **信封码优先于 HTTP 码**：HTTP 200 + `code: 401` 是过期会话的常见形态，必须判成 `.needsLogin`，不能当成「拿到了空数据」。

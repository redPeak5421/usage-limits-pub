# OpenCode（opencode.ai）用量接口目录

- **展示名称**：App、Widget、Watch、通知、设置与文档一律使用「OpenCode」。
- **官网控制台**：`https://opencode.ai/workspace/<wrk_id>`（首页 = Zen 余额；`/go` = OpenCode Go 三窗口；`/usage` = 按请求明细）
- **鉴权**：本机 WebKit Cookie `auth` 与 `__Host-auth`（均 HttpOnly）。站内 `fetch(..., { credentials: 'include' })` 自动携带；没有 Bearer / API key。`status` / `_server` / HTML 腿一律 `noAuth: true`，禁止 helper 注入 leftover Authorization。
- **登录入口 / 探针页**：`loginURL` 与 `probeURL` 都是 `https://opencode.ai/auth`。已登录 → 302 `/workspace/<wrk_id>`；未登录 → `/auth/authorize` → `auth.opencode.ai`（OpenAuth，只有 GitHub OAuth 与 Google OIDC，无邮箱验证码）。
- **Cookie 域**：`opencode.ai`。退出登录清该域 WebKit 数据。
- **标价**：`OpenCode Go` $10/月，无年付（年价按 12 个月合成 $120）。Zen 为预充值余额、OpenCode Black 不收录标价。
- **接入范围**：Zen 余额 + 月上限、Go 三窗口。不接 API key、不接按请求明细。
- **代码**：探针 `ProviderScripts.opencode`，解析 `OpenCodeParser`，seroval 文本解码规则 `OpenCodeSeroval`（Swift 侧镜像，探针 JS 里同名正则逐字一致），页面就绪判定 `OpenCodeSession`，fixture `opencode_status.json` / `opencode_billing.json` / `opencode_lite.json` / `opencode_billing_seroval.txt` / `opencode_go_ssr.html`，测试 `ParserTests`（`testOpenCode*`）、`OpenCodeGapTests`、`OpenCodeSessionTests`。
- **观测**：2026-08-26 对照 `anomalyco/opencode` `packages/console` 源码与线上 bundle；`billing.get` / `lite.subscription.get` / `/auth/status` 形状已在真机登录态诊断日志核对（Zen 余额 + 月上限账号，无 Go 订阅 → `lite` 为 `null`）。

## 接口表

所有地址同源 `https://opencode.ai`。控制台**没有 REST**：数据全部走 SolidStart server function（`POST /_server`），鉴权为 Cookie。

| 地址 / server fn | 方法 · 鉴权 | 返回 | App |
|---|---|---|---|
| `GET /auth/status` | Cookie 自动带 · `noAuth: true` | 已登录 `{ account: { <id>: { id, email } }, current }`；未登录 `{}` | 探针 `status`。HTTP 401/403 赢整轮，清掉 `billing` / `lite` 已解析指标 |
| `GET /auth` | Cookie | 已登录 302 `/workspace/<wrk_id>`；未登录 302 → `auth.opencode.ai` | `loginURL` / `probeURL` |
| `GET /workspace/<wrk_id>` | Cookie | SSR HTML，含 `/_build/assets/*.js` modulepreload | 探针自校准（取 chunk 与 server id） |
| `billing.get(workspaceID)` | `/_server` · Cookie | Zen 余额、月上限、月用量、reload 设置、Black 订阅、`liteSubscriptionID` | 探针 `billing` |
| `lite.subscription.get(workspaceID)` | `/_server` · Cookie | `null` 或 Go 三窗口 | 探针 `lite` |
| `workspaces()` | `/_server` · Cookie | `[{ id: "wrk_…", … }]` | 路径里没有 `wrk_` 时用它兜底取 workspace |
| `subscription.get(workspaceID)` | `/_server` · Cookie | **待验证**：CodexBar 记为旧版 Zen 配额窗口（`rollingUsage` / `weeklyUsage`），我们未在真机确认 | 不调用，仅登记 |
| `usage.list(workspaceID, page)` | `/_server` · Cookie · admin | 按请求：日期 / 模型 / token / 成本 / key / session | 未接 |
| `lite.subscription.usage(workspaceID, windowID)` | `/_server` · Cookie | 某窗口按模型分摊（含 `costMultiplier`） | 未接 |
| `GET /zen/go/v1/usage` | `Authorization: Bearer <Go key>` | `{ usage: { rolling\|weekly\|monthly: {…} } }`；无 key 401（已实测）。**窗口字段有两种记录，以真机为准**：①我们 2026-08-26 记的 `status` / `percent` / `resetsAt`；②CodexBar 实测的 `percent` / `resetInSec`（`percent` 强制按 0–100 解释，`1` 就是 1%），顶层或 `usage` 层可带 `renewAt` / `renew_at` | 备用：纯 key 用户走自定义模板 |
| `/zen/v1/models` `/zen/v1/messages` `/zen/v1/responses` `/zen/v1/chat/completions` | Bearer Zen key | 模型推理 | 不接；`/zen/v1/` 下没有 usage / balance 端点 |

官网 Go 页**渲染后的 DOM**（`data-slot="usage-value"` / `reset-time`）禁止抓取。

澄清：下文的「SSR HTML 兜底」抓的不是 DOM，而是 `fetch('/workspace/<wid>/go')` 拿到的**原始 SSR 响应文本**里的 hydration 载荷（`rollingUsage:$R[42]={status:"ok",resetInSec:5944,usagePercent:17}`）。它是服务端序列化出来的数据，不经过渲染、不读 `document`，属于最后一条兜底腿（前两条都拿不到 `lite` 时才用）。探针脚本里禁止出现 `querySelector` / `textContent` / `innerHTML` 一类 DOM API（`ParserTests` 有守卫）。

## `_server` 调用规范

server function 有两种调法，探针按下面的顺序逐条降级，**同一个 server fn 在哪条腿上拿到都产出同名探针、同一份 JSON body**，`OpenCodeParser` 不感知走的是哪条腿。

全脚本共享 27 秒 deadline。页面 runtime 的动态 `import()` 最多等 5 秒，`createServerReference(...).apply(...)` 最多等 8 秒；这两类 Promise 即使底层不可 Abort，也由通用 deadline race 提前返回。runtime 调用超时时的诊断保留调用开始时实际分配的预算（例如 `timeout after 8000ms`），不在 deadline 消耗后误写成 0ms。billing / lite 两组 fallback 并发执行，各组内部仍严格按腿 1 → 腿 2 →（仅 lite）腿 3 降级；一组卡住不能拖丢另一组或 `/auth/status` 已完成结果。

### 腿 1：页面 runtime 动态 `import()`（默认）

- 探针在源内动态 `import()` 页面自带的 `server-runtime-*.js`，用它导出的 `createServerReference(id)` 得到函数，`apply(null, [workspaceID])` 拿到反序列化对象后 `JSON.stringify` 交给解析器；调用抛错时取 `e.status`（无则 500）与 message 前 2000 字。
- 优点：由页面 runtime 自己解 seroval，最抗形状漂移。缺点：依赖 chunk 名与 `import()` 可用性。

### 腿 2：纯 GET `/_server`（腿 1 不可用或抛错时启用）

```
GET https://opencode.ai/_server?id=<64 位 hex>&args=<URL-encoded JSON 数组>
X-Server-Id:       <同 id>
X-Server-Instance: server-fn:<随机 uuid>
Accept:            text/javascript, application/json;q=0.9, */*;q=0.8
credentials: include        // Origin / Referer 由浏览器自动补，禁止手写
noAuth: true                // 禁止 leftover Bearer；status / HTML 腿同样
```

- `args` 是**普通 JSON 数组**（如 `["wrk_x"]`、无参函数用 `[]`），不是 seroval 编码。
- 响应是 seroval 流或普通 JSON，探针用 `__ocSeroval` 最小解码器抽取需要的字段（见下）。
- **禁止 POST 重试**：函数返回 null 的 workspace 上 POST `/_server` 会被 opencode.ai answer 成 HTTP 500（CodexBar 踩过）。GET 腿拿到显式 null 尾巴即判「无订阅」，直接收工。

### 腿 3：SSR HTML 兜底（只给 `lite`）

前两条腿都拿不到 `lite` 时：`GET https://opencode.ai/workspace/<wid>/go`，`Accept: text/html,…`，在**原始响应文本**里正则三窗口
（`rollingUsage[^}]*?usagePercent\s*:\s*([0-9.]+)`、`resetInSec\s*:\s*([0-9]+)`，weekly / monthly 同理），
合成与 `lite.subscription.get` 同形状的 JSON body，并加一个标记字段 `source: "ssr-html"`。三个窗口都取不到才算失败。
这条腿完全不依赖 server fn id 与 chunk 名，是抗构建漂移最彻底的一条。

### seroval 最小解码器（`__ocSeroval`）

seroval 流长这样（脱敏后的真实 `billing.get` 载荷见 fixture `opencode_billing_seroval.txt`）：

```
;0x000002b9;((self.$R=self.$R||{})["server-fn:<uuid>"]=[],($R=>$R[0]={
  customerID:"cus_…",balance:1250000000,reload:!0,monthlyLimit:20,monthlyUsage:1500000000,
  timeMonthlyUsageUpdated:$R[1]=new Date("2026-07-29T14:45:11.000Z"),
  subscription:null,subscriptionID:null,lite:$R[2]={},liteSubscriptionID:"sub_…"
})($R["server-fn:<uuid>"]))
```

`JSON.parse` 必然失败（十六进制长度前缀 + `$R[n]=` 引用 + `!0`/`!1` 布尔 + `new Date(...)`），所以只按字段名正则取值。
**兼容式（JS 与 Swift `OpenCodeSeroval` 两侧逐字一致，改一处必须改另一处）**：

```
(?:"字段"|字段)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?<值>
```

| 值类型 | 值子式 | 说明 |
|---|---|---|
| 数字 | `(-?[0-9]+(?:\.[0-9]+)?)` | |
| 布尔 | `(!0|!1|true|false)` | `!0` = true，`!1` = false |
| 字符串 | `(?:new\s+Date\(\s*)?"([^"]*)"` | 兼容 `new Date("…")` 包装 |
| `null` | 匹配不到字符串/数字 → 该字段直接不产出 | |

窗口这类嵌套对象用「同一层大括号内」的作用域式：`<窗口键>[^}]*?<兼容式>`（`[^}]*?` 保证不跨出该对象）。

- **`customerID` 守卫**：`billing.get` 只有先匹配到 `customerID:"…"` 才信任任何数字，避免把无关载荷（错误页、别的函数返回值）解成假余额。
- **显式 null 尾巴**：正文 trim 后等于 `null`，或匹配 `\]\s*=\s*\[\s*\]\s*,\s*null\s*\)\s*$`（即 `…["server-fn:<uuid>"]=[],null)`），视为「函数返回 null」→ 产出 body `null`、status 200，不再重试。
- 解码出来的字段按 server fn 原名重新组装成 JSON 对象再交给解析器：
  - `billing`：`balance` / `monthlyLimit` / `monthlyUsage` / `timeMonthlyUsageUpdated` / `subscriptionID` / `timeSubscriptionBooked` / `liteSubscriptionID`
  - `lite`：`mine` / `useBalance` / `renewAt` / `rollingUsage`·`weeklyUsage`·`monthlyUsage` 各自的 `usagePercent` / `resetInSec` / `status` / `resetsAt`

### server function id

id 是源码路径 + 函数名的哈希，跨构建通常稳定但不保证。探针运行时自校准，禁止只写死：

1. `workspaceID` 先从 `location.pathname` 正则 `wrk_[A-Za-z0-9]+`（`/auth` 302 后就在 `/workspace/<id>`）。
2. 取不到就调 `workspaces()`（腿 2，id = `def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f`，`args=[]`），
   正则 `id"?\s*:\s*"(wrk_[^"]+)"` 取**第一个** workspace，再回落任意 `wrk_[A-Za-z0-9]+`。仍取不到 → `billing` / `lite` 记 `status: -2` `no workspace`。
   多 workspace 只取第一个（与 CodexBar 一致）；member / 多 workspace 账号如需指定，未来再补账号级手填。
3. `GET /workspace/<id>` 取 HTML，正则出 `/_build/assets/server-runtime-*.js`、`common-*.js`、`entry-client-*.js`。
4. `common-*.js` 里 `createServerReference("<id>"); const … = query(…, "billing.get")` → billing id；`entry-client-*.js` 里 `routes/workspace/[id]/go/index.tsx` 对应的 `index-*.js` → 其中 `query(…, "lite.subscription.get")` → lite id。
5. 正则失败回落 2026-08-26 观测 id：`billing.get` = `c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d`；`lite.subscription.get` = `c7389bd0e731f80f49593e5ee53835475f4e28594dd6bd83eb229bab753498cd`。

**待验证的第三个 server fn**：`subscription.get` = `7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4`（CodexBar 在用，函数名与我们的 `lite.subscription.get` 不同、id 也不同，疑似旧版 Zen 配额窗口）。**探针不调用**，等真机诊断确认返回形状后再决定接不接。

### 离站判定

探针页 `location.hostname !== 'opencode.ai'`（还停在 `auth.opencode.ai` / `github.com`）→ 不发任何请求，`status` 记 401 `{}`，`billing` / `lite` 记 401 `off-site`。

## 按身份的取数分类

workspace 有 **admin**（创建者）与 **member**（被邀请）两种角色。Zen 余额是 **workspace 级**池子，所有 key / 成员共用，没有「每个 key 的余额」。Go 订阅绑定**成员本人**，一个 workspace 只能一个人订。

| 身份 | Zen | Go | App 接法 |
|---|---|---|---|
| admin（登录） | 总余额、月上限、月用量、reload | 自己订了才有三窗口（`mine == true`） | 内置 `opencode`，一次登录全拿（2026-08-26 真机验证） |
| member（登录） | 能看总余额；admin 给该成员设的月上限是否体现在 `billing.get.monthlyLimit` **未确认**（需 member 账号实测） | 只有订阅者本人看得到；别人订的 `mine == false`，App 不展示 | 内置 `opencode`；多账号走独立 dataStore |
| 纯 key、非成员 | 无接口可查 | `/zen/go/v1/usage` + Go key | 自定义模板（GET + Bearer）；只有百分比，`resetsAt` 是 ISO 字符串，自定义 `timestamp` 角色已识别 ISO8601 |

## 产品与窗口

| 产品 | 探针 | 展示 |
|---|---|---|
| OpenCode Zen | `billing` | 「Zen 余额」（美元，预充值）；设了月上限时另显示「Zen 月上限」已用 / 上限 |
| OpenCode Go | `lite` | 「5 小时窗口」/「每周窗口」（`pinned`）/「每月窗口」三条百分比 + 重置倒计时 |
| OpenCode Black | `billing.subscriptionID` / `timeSubscriptionBooked` | `planName = "OpenCode Black"`，不产出 Go 指标，无标价 |

Go 官网口径（docs/go）：5 小时 $12 / 每周 $30 / 每月 $60。滚动窗口 = 首次记账 + 5h；周窗口 = UTC 周一 00:00；月窗口按订阅日锚定。超限可勾 Use balance 回落 Zen 余额。

## 形状示例

### `billing.get`（2026-08-26 真机，id / 卡尾号已脱敏）

```json
{ "balance": 11777936060, "customerID": "cus_…", "lite": null, "liteSubscriptionID": null,
  "monthlyLimit": 100, "monthlyUsage": 222063940, "timeMonthlyUsageUpdated": "2026-08-11T02:02:50.000Z",
  "paymentMethodID": "pm_…", "paymentMethodLast4": "…", "paymentMethodType": "card",
  "reload": null, "reloadAmount": 20, "reloadAmountMin": 10, "reloadError": null,
  "reloadTrigger": 5, "reloadTriggerMin": 5, "timeReloadError": null,
  "subscription": null, "subscriptionID": null, "subscriptionPlan": null,
  "timeSubscriptionBooked": null, "timeSubscriptionSelected": null }
```

- `balance`、`monthlyUsage`：微分单位，÷ 1e8 = 美元（官网 `formatBalance`）。
- `monthlyLimit`：整数美元，`null` / `0` = 未设上限。
- `lite` **不只是 `null`**：CodexBar 的真实载荷里出现过 `lite:$R[2]={}`（空对象）且 `liteSubscriptionID` 非空。我们不看 `billing.lite`，只看 `lite` 探针本身，所以不受影响；但目录要记住这个形态。
- 布尔字段（`reload`、`useBalance`…）在 seroval 里是 `!0` / `!1`；共享 `JSONHelp.double` 与 `OpenCodeParser.number` 都必须把 CFBoolean 排除在数值之外，`monthlyLimit:true` 不得被误当成「上限 $1」。
- 诊断日志对 `customer*` / `payment*` 键脱敏（`DiagnosticRedactor`）。

### `lite.subscription.get`

真机已确认未订阅时为 `null`。**有 Go 订阅时的字段未在真机确认**，以下按 bundle 读取代码整理（fixture `opencode_lite.json` 同此）：

```json
{ "mine": true, "useBalance": false, "renewAt": "2026-09-26T00:00:00.000Z",
  "rollingUsage": { "usagePercent": 12.3, "resetInSec": 9800,    "status": "ok" },
  "weeklyUsage":  { "usagePercent": 40.0, "resetInSec": 302400,  "status": "ok" },
  "monthlyUsage": { "usagePercent": 8.5,  "resetInSec": 1900000, "status": "ok" } }
```

- `usagePercent` 官网保留一位小数；`resetInSec` 是相对秒。
- 每个窗口还带 **`status`**（CodexBar fixture 里为 `"ok"`，REST 版同名）。非 `"ok"` 时我们把它拼进该条指标的 `detail`（如 `状态 exhausted`），不据此隐藏指标。
- **`resetsAt`（ISO 字符串）** 作为 `resetInSec` 缺失时的兜底（REST 形态与 SSR 载荷都可能只给其一）。
- 顶层可能带 **`renewAt` / `renew_at`**（CodexBar 在 REST 响应上见过，server fn 上**未在真机确认**）→ 有 Go 订阅时映射成 `planExpiresAt`（续订日）。
- 未订阅时可能是 `null`（真机已确认），也可能是 **`{}`**：都按「没有 Go 订阅」处理，不产窗口、不产 `planName`。

## 解析口径（`OpenCodeParser`）

- 登录判定：`status` 2xx 且 `account` 非空对象或 `current` 非空字符串 → 已登录；`billing` 或 `lite` 任一 2xx 且为 JSON 对象也视为已登录。
- Zen：`balance` → `UsageMetric(id: "balance", label: "Zen 余额", amount: balance/1e8, currency: "USD", pinned: true)`；`monthlyLimit > 0` → `UsageMetric(id: "monthly_limit", label: "Zen 月上限", usedPercent: used/limit×100（钳 0–100）, detail: "上限 $<limit>", amount: used, currency: "USD", pinned: true)`。`used` 只在 `timeMonthlyUsageUpdated` 属于当月（UTC）时取 `monthlyUsage/1e8`，否则按 0；`timeMonthlyUsageUpdated` 缺失则直接取值。
- Black：`subscriptionID` 非空字符串，或 `timeSubscriptionBooked` 非 null / 非空 → `planName = "OpenCode Black"`，跳过 `lite`。
- Go（非 Black）：`lite` 为 `null` / `{}` / 无窗口 → 不产出。`mine` 缺省视为 true；`mine == false` 不产出。`rollingUsage` → `five_hour`「5 小时窗口」，`weeklyUsage` → `weekly`「每周窗口」（`pinned`），`monthlyUsage` → `monthly`「每月窗口」；`usedPercent = usagePercent` 钳 0–100；`resetInSec > 0` 时 `resetsAt = now + resetInSec`，`resetInSec` 缺失则退 `resetsAt`（ISO 字符串）；窗口 `status` 非 `"ok"` 时拼进 `detail`。至少产出一条 → `planName = "OpenCode Go"`，`billingCycle = .monthly`，顶层 `renewAt` / `renew_at` → `planExpiresAt`。
- 既无 Go 也无 Black：`planName = nil`（余额卡，无周期标签）。
- 指标顺序：`weekly` > `five_hour` > `monthly` > `balance` > `monthly_limit`；折叠摘要 `weekly` > `five_hour` > `balance`。
- 数值一律排除布尔、`NaN` / `Infinity` / 溢出指数：共享 `JSONHelp.double` 先做 CFBoolean 与 finite 检查，`OpenCodeParser.number` 保留同样契约。
- 状态分档：
  - 已登录且拿到 `billing` / `lite` 任一 JSON → `.ok`。**只有余额没有窗口**、**只有窗口 billing 失败**都算 `.ok`，不降级。
  - 已登录但两者都没拿到：`consoleFailureStatus(billing, lite, status)`——**只剩 lite 的 401 / 5xx 也算**（lite-only 401 → `.needsLogin`，503 → `.error("HTTP 503")`）；否则（如 `status: -2` 脚本失效）仍是 `.error("控制台接口无响应")`。
  - `results` 为空 → `.error("未获取到任何响应")`；其余 → `.needsLogin`。
- 键缺失 / `null` / 非 JSON：跳过对应指标，不崩。

## 登录与页面复用规则

- 离屏探针页的就绪判定 `OpenCodeSession.isProbeReady`（`WebViewFetcher.ensureLoaded` 按它收紧通用的 host 后缀匹配）：**host 必须正好是 `opencode.ai`**，且路径不是 `/auth`、`/auth/authorize`；其余任何 `opencode.ai` 页面都算就绪。停在 `auth.opencode.ai`、`opencode.ai/auth*` 一律重载 `/auth`。
  - `auth.opencode.ai` 必须排除的原因：它与源同后缀，通用后缀匹配会把 OAuth 页当成「已在源上」永不重载，登录后探针永远判未登录（2026-08-26 真机）。这条回归测试不得放宽。
  - 从「必须停在 `/workspace/<wrk_id>`」放宽到「任意非 auth 页」的前提：探针拿不到路径里的 workspace 时会调 `workspaces()` server fn 兜底，不再依赖 URL。
- `workspaceID` 正则：`wrk_[A-Za-z0-9]+`（探针脚本内，Swift 侧只有 `OpenCodeSeroval.firstWorkspaceID` 镜像），腿 1 的快路径直接从路径取。

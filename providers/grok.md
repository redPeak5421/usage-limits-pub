# Grok（grok.com）用量接口目录

- **官网 Usage 页**：https://grok.com/?_s=usage（头像 → 设置 → 使用量；付费套餐显示本周共享限额百分比 + Grok Build / Imagine 等产品占比）
- **登录入口**（`loginURL`）：`https://grok.com/`，从网页端发起官方认证，让网站生成网页客户端的登录参数和回跳地址。继续移除 Smart App Banner；Cookie 域含 `x.ai` 与 `grok.com`，与探针共用 WKWebsiteDataStore。
- **探针执行页**（`probeURL`）：`https://grok.com/`
- **鉴权**：本机 WebKit Cookie（`cookieDomains = ["grok.com", "x.ai"]`）。探针同源 `fetch(..., credentials: 'include')`，`rate_limits` / `subscriptions` / `credits` / `weekly` 一律 `noAuth: true`，不带 token、禁止 helper 注入 leftover Bearer。
- **关键探针**（`keyProbe`）：`rate_limits`。

## 已解析 API（探针名 → 代码）

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `rate_limits` | `POST https://grok.com/rest/rate-limits`，`Content-Type: application/json`，body `{"modelName":"<auto|fast|expert|heavy>"}`，四档各一次 | 短期限流次数（游客兜底展示 + 套餐反推） | `GrokParser` |
| `subscriptions` | `GET https://grok.com/rest/subscriptions` | 订阅套餐枚举 | `GrokParser` |
| `credits` | `GET https://grok.com/rest/grok/credits` | 周额度 + `subscription_tier`（JSON） | `GrokParser` / `GrokWeeklyParser` |
| `weekly` | `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`，`content-type: application/grpc-web+proto`、`x-grpc-web: 1`，body 空帧 `00 00 00 00 00`；响应字节 base64 后转交，响应头 `grpc-status` / `grpc-message` 一并回传（`ProbeResult.headers`） | 周额度百分比 + 产品占比（protobuf） | `GrokWeeklyParser` |
| `resets` | `POST https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets`，gRPC-Web 同 `weekly`，body 空帧 | 用量额度重置的可用次数 + 到期（protobuf） | `GrokUsageResets` |
| `resets_facade` | `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetRemainingResets`，同上 | 同上，账号走计费门面时的另一条服务 | `GrokUsageResets` |

只请求官网四个固定 mode（`auto` / `fast` / `expert` / `heavy`）。**没有已证实的动态发现接口，不发明第五个 mode**；解析器对未知 `modelName` 仍并入聚合。四个 `rate_limits` mode 同时发出；`subscriptions`、`credits` 与三条二进制探针（`weekly` / `resets` / `resets_facade`）也在同一时刻并发。这五条各 6 秒、不重试；二进制探针必须走共享的可 Abort 二进制 helper，禁止裸 `fetch/arrayBuffer`。mode 仍按普通 12 秒 / 一次瞬态重试，但全体共用 27 秒 deadline；某条补充永不 resolve 时，已完成 mode 结果仍会返回。

### rate_limits（探针脚本聚合后的形状）

```json
{ "results": [
  { "modelName": "auto", "requestKind": "DEFAULT", "status": 200,
    "body": { "windowSizeSeconds": 7200, "remainingQueries": 150, "totalQueries": 150 } },
  { "modelName": "fast", "…": "…" }
] }
```

合成探针外壳固定 `status: 200`，每档真实 `status` / `body` 留在 `results[]`；因此一档 503 / 401 不会压掉另一档已完成的 200。解析只收内层 `status` 2xx 且 `body.remainingQueries` 存在的项；`usedPercent = (1 - remaining / total) * 100`（保留一位小数）；`resetsAt = now + windowSizeSeconds`；detail「N 小时短期限流」。展示名：`auto` → 自动、`fast` → 快速、`expert` → 专家、`heavy` → Heavy；未知 modelName 用 `<modelName> 标准/推理`（`requestKind == REASONING` 为推理）。四档全失败时解析器按内层状态还原 401/403、HTTP 错误或 `-3` 超时；`RefreshPolicy` 同样展开这些状态。

### subscriptions 套餐枚举

响应里任意层级的 `tier` 字段（如 `{"subscriptions":[{"tier":"SUPER_GROK","status":"ACTIVE"}]}`），取第一个，转大写后按顺序匹配：

| `tier` 含 | 展示名 | 月标价 |
|---|---|---|
| `PREMIUM_PLUS` | X Premium+ | $40 |
| `SUPER_GROK_PRO` / `HEAVY` | SuperGrok Heavy | $300 |
| `SUPER_GROK_PLUS`，或同时含 `SUPER` 与 `PLUS` | SuperGrok Plus | （无标价） |
| `LITE` | SuperGrok Lite | （无标价） |
| `SUPER_GROK` / `GROK_PRO` | SuperGrok | $30 |
| `PREMIUM` | X Premium+ | $40 |
| 其它 | 原值首字母大写 | （无标价） |

拿到 subscriptions 套餐后再用 `rate_limits` 总额度反推校准：`heavy` 档存在、或 `auto` 总数 150、或 `fast` 总数 400 → SuperGrok Heavy（覆盖）；`auto` 50 或 `fast` 140 → SuperGrok（仅在 subscriptions 未给出时采用）。`credits` / `weekly` 若以 JSON 返回且含 `subscription_tier` / `subscriptionTier`，其值优先于 subscriptions（`HEAVY` → SuperGrok Heavy，`SUPER`+`PLUS` → SuperGrok Plus，`LITE` → SuperGrok Lite，含 `SuperGrok` 原样，其余走上表）。有标价的套餐 `billingCycle` 固定为 `monthly`。

### credits（JSON）

```json
{ "subscription_tier": "SuperGrok Heavy",
  "config": { "creditUsagePercent": 3,
    "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-08-21T07:52:00Z" },
    "productUsage": [ { "product": "PRODUCT_GROK_BUILD", "usagePercent": 2 }, { "product": "PRODUCT_IMAGINE", "usagePercent": 1 } ] } }
```

`GrokWeeklyParser.parse(json:)`：取 `config`（缺则顶层）；百分比 `creditUsagePercent` / `usagePercent`；重置 `resetsAt` / `billingPeriodEnd` / `currentPeriod.end`；周期起点 `currentPeriod.start` / `billingPeriodStart`；产品列表 `productUsage[]` / `products[]`，每项 `product` / `name`（字符串按名匹配）或 `code` / `product`（数字编码），占比 `usagePercent`。百分比与重置都缺则视为无效。

#### 百分比缺失的口径

- **protobuf（`weekly`）**：精确解析与通用扫描都拿不到百分比时，`usagePercent = nil`、`percentIsWirePublished = false`；不能根据 proto3 省略默认值的规则，把未知推断为 0%。
- **JSON（`credits`）**：缺 `creditUsagePercent` / `usagePercent` 就是缺，`usagePercent = nil`，不当 0。
- 周限额指标 `pinned = true` 常显；缺失百分比保留指标行，但不补造数字。

#### 周期类型 → 指标标签（`currentPeriod.type`）

| `currentPeriod.type` | 指标标签 |
|---|---|
| `USAGE_PERIOD_TYPE_DAILY` | 今日限额 |
| `USAGE_PERIOD_TYPE_WEEKLY` | 本周限额 |
| `USAGE_PERIOD_TYPE_MONTHLY` | 本月限额 |
| 缺失 | 按周期长度推断：起点→重置 4–12 天 → 本周限额；20–45 天 → 本月限额；其余一律默认本周限额 |

字段值只做大写子串匹配（含 `DAILY` / `WEEKLY` / `MONTHLY` 即可），不要求全等枚举名。

### weekly（gRPC-Web protobuf）

先按 gRPC-Web 帧（1 字节 flag + 4 字节长度）拆出数据帧（跳过 trailer 帧 `0x80`），再解析：

- 顶层消息 field 1（bytes）= config；无则整体当 config。
- config：field 1（float）= 本周已用百分比（0…100）；field 5（Timestamp）= 重置时间；field 7（重复消息）= 产品，其中 field 1（varint）= 产品编码、field 2（float）= 占比；field 8 = currentPeriod，其 field 2（Timestamp）= 周期起点、field 3（Timestamp）= 周期结束（field 5 缺失时作重置时间）。currentPeriod 的 field 1 是类型枚举，但数值语义未在真机确认，**不用它猜周/月**，protobuf 路径只按起点→结束的长度推断。
- **百分比缺失时不当 0**：只有重置时间、报文里没有百分比 → `usagePercent = nil` 且 `percentIsWirePublished = false`，`GrokParser` 输出 `usedPercent = nil`；周限额行因 `pinned = true` 保留，不显示百分比。**禁止**用 0% 顶替缺失值（会把未知说成已知）。JSON 路径同此口径。

**通用扫描回退**：按字段号的精确解析拿不到百分比时（字段号漂移 / 换了 schema），再跑一遍与 CodexBar 同款的通用扫描——

- 百分比：所有 `fixed32`（wire 5）字段中路径末位为 1、值落在 0…100 的那个，取路径最浅、其次出现序号最小的。
- 重置：所有 varint 中落在 `1_700_000_000…2_100_000_000` 的 Unix 秒，优先路径 `[1,5,1]`，否则取最早的未来时间。
- 扫描只补精确解析没拿到的字段（百分比 / 重置），产品占比仍只来自精确解析（通用扫描分不出产品维度）。扫描出的百分比同样算「报文已发布」。

`credits` 与 `weekly` 两个探针共用同一解析：先试 JSON，再试 base64 解码后的 protobuf；`credits` 优先。

### weekly 的 gRPC 状态（`grpc-status` / `grpc-message`）

gRPC-Web 的错误不体现在 HTTP 状态上：HTTP 200 也可能整条失败，真正的结果码在**响应头**或**trailer 帧**（flag 字节 `0x80`，帧体是 `key: value` 的文本行）。两处都读，trailer 优先于响应头。

| `grpc-status` | `grpc-message` 关键词 | 含义 | 我们的处理 |
|---|---|---|---|
| 0 / 缺失 | — | 正常 | 继续解析 protobuf |
| 7 | `bad-credentials` / `unauthenticated` / `could not be validated` | 凭据失效 | **只作为 weekly 探针自身的未登录证据**；卡片登录态仍以 `/rest/*` 为准。跳过 weekly，记诊断 |
| 9 | `no personal team` | 团队账号没有个人计费主体 | 跳过 weekly，记诊断「该账号无个人计费主体（team 账号），周额度不可用」 |
| 16 | `no-credentials` | 端点要求浏览器密钥交换（WKE），页面 JS 生成的签名头我们的裸 `fetch` 带不上 | **不判未登录**。跳过 weekly，记诊断「该端点需要浏览器密钥（WKE），Cookie 登录不够」；此时 `/rest/grok/credits` 才是主路径 |
| 其它非 0 | — | 端点报错 | 跳过 weekly，记诊断「gRPC 状态 N：<message>」 |

状态非 0 时**不解析 payload**——trailer-only 的响应里没有可用数据，硬解会产出垃圾百分比。

### 产品编码 → 展示名

| code | 展示名 |
|---|---|
| 0 | 第三方 |
| 1 | API |
| 2 | Grok Build（编码 agent / CLI） |
| 3 | 插件 |
| 4 | Chat |
| 5 | Imagine |
| 6 | Voice |
| 7 | App Builder（网页 Usage 页名；iOS 端本地化「应用构建器」） |
| 其它 | 分类 N |

按名称匹配（大写、去下划线与空格）顺序：`IMAGINE` → Imagine；`VOICE` / 语音 → Voice；`CHAT` / 聊天 → Chat；`APPBUILDER` / 应用构建 → App Builder（必须先于 `BUILD` 判断）；`BUILD` → Grok Build；`PLUGIN` / 插件 → 插件；`API` → API。

## 用量额度重置（2026-09-10 从官网 proto 描述符与前端逻辑确证）

grok.com 的「Usage Limit Reset」：付费账号会发到一批一次性重置券，用掉一张就把本周期用量清零一次。
官网文案：区块标题 `Usage Limit Reset`、状态 `Reset Available`、`Expires on {date}`，
说明 `A reset clears your weekly usage once. Resets don't stack and expire.`，
额度用尽卡片写 `You have {count} resets available, the next expires on {expiryDate}`。
只在 `ENABLE_USAGE_LIMIT_RESET` 且「usage pool 已启用」（有订阅、非 team 席位）时出现，与周额度是同一批用户。

两条探针只读，**绝不调用 `RedeemReset`**（那是兑换，会真的花掉用户的重置券）。失败不影响登录判定与已有额度窗口。

### 为什么打两条服务

grok.com 前端按 feature flag `ENABLE_BILLING_FACADE` 二选一，两条都在线：

| `ENABLE_BILLING_FACADE` | 服务 / 方法 | 响应消息 |
|---|---|---|
| false（默认分支） | `prod_mc_billing.ConsumerUiSvc/GetRemainingResets` | `ConsumerGetRemainingResetsResp` |
| true | `grok_api_v2.GrokBuildBilling/GetRemainingResets` | `GetRemainingResetsResponse` |

标志值随账号下发，故两条并发各打一次（探针名 `resets` / `resets_facade`），采用首个完整有效响应；
`resets` 优先，有效的零次也优先。两条都拿不到且本次核心刷新正常提交时，不显示该区块、不复制旧重置摘要；核心刷新失败仍遵循整个快照的 last-good 规则。

### 请求

与 `weekly` 完全同构：`POST`、`content-type: application/grpc-web+proto`、`x-grpc-web: 1`、
body 空帧 `00 00 00 00 00`（两条的请求消息分别是 `google.protobuf.Empty` 与空的 `ConsumerGetRemainingResetsReq`，
序列化都是零字节）、`noAuth: true`、6 秒、不重试、走可 Abort 的二进制 helper，响应字节 base64 后转交。

### 响应形状（字段号取自官网自带的 proto 描述符）

```proto
// grok_api_v2（resets_facade）
message ResetToken         { string token_id = 1;  google.protobuf.Timestamp validity_start = 2;  validity_end = 3; }
message GetRemainingResetsResponse { repeated ResetToken tokens = 1; }

// prod_mc_billing（resets）
message ConsumerResetToken { string token_id = 10; google.protobuf.Timestamp validity_start = 20; validity_end = 30; }
message ConsumerGetRemainingResetsResp { repeated ConsumerResetToken tokens = 10; }
```

解析口径与官网前端一致（`tokens` → 过滤 → 计数 + 取最早到期）：

- 丢弃 `token_id` 为空、缺 `validity_end`、或 `validity_end` 已过期的条目；
- `availableCount` = 剩余条目数；`expiresAt` = 其中**最早**的 `validity_end`；`availableExpirations` = 全部到期时间正序；
- 同 `token_id` 只算一次（仅在内存去重）。
- **`token_id` 绝不落盘、绝不进诊断日志**：它是 `RedeemReset` 的兑换凭据，快照只存数字与日期数组。
- `validity_start` 不展示，也不保存。
- 响应里一个 token 都没有（proto3 空列表不上线）→ `availableCount = 0`，仍展示「0 次」，不显示到期日期。
- 只接受一个完整、未压缩的数据帧。截断帧、压缩帧、损坏 protobuf 或非空消息缺少已知列表字段均跳过并尝试另一服务，不冒充零次。

### gRPC 状态

沿用 `weekly` 的同一张表（`grpc-status` / `grpc-message`，trailer 优先于响应头）：非 0 一律跳过、不解析 payload、记诊断，
**不参与登录判定**。两条探针也不参与 `RefreshPolicy` 的真实 HTTP 状态聚合，
防止其 200/401 干扰核心探针的超时 / 5xx last-good 保护。

### 验证

2026-09-10 在未登录的受控 Chrome 上以同源 gRPC-Web 空帧实测：
`prod_mc_billing.ConsumerUiSvc/GetRemainingResets` → HTTP 200、`grpc-status: 3`（anon auth 不支持）；
`grok_api_v2.GrokBuildBilling/GetRemainingResets` → HTTP 200、`grpc-status: 16`（User not authenticated），
与同批实测的 `GetGrokCreditsConfig` 表现一致——两条路径都存在（不是 12 unimplemented），空 body 能被服务端正常受理。
字段号、消息名、服务名取自 grok.com 自己加载的 `fileDesc` 编译描述符
（`prod/grok/backend/proto/grok_build_billing.proto`、`prod/mc/billing-proto/proto/consumer_ui.proto`），不是猜测。
同日进一步在用户已有的 Chrome 普通窗口、已登录的 SuperGrok Heavy 会话中，通过 DevTools Console 按上述同源请求实测：两条接口均 HTTP 200，trailer 均 `grpc-status:0`，均返回 1 张未过期重置券，`validity_end = 2026-09-12T18:49:00Z`（Asia/Shanghai 为 `2026-09-13 02:49:00`）。官网「设置 → 使用量」同步显示「重置可用，2 天后过期」。没有调用兑换接口。

`Fixtures/grok_resets_authenticated.json` 保留这两条响应的真实 protobuf/gRPC 帧形状，兑换 ID 在浏览器内替换为 13 个 `x` 后才导出；无真实 Cookie、token_id 或账号标识。Core 回归测试直接读取夹具，验证两条服务均解析为 1 次及相同到期时间，快照不含兑换 ID。iOS WKWebView 的真实账号与 Cookie 环境仍需设备复验。

## 展示规则

- 拿到周额度（`credits` 或 `weekly` 任一解析成功）：指标替换为周期标签（id `weekly`，标签按上表的 `currentPeriod.type` 取「今日/本周/本月限额」，detail「已使用」，重置时间）+ 占比 > 0 的产品各一行（id `weekly.<code>`）；`rate_limits` 的短期次数不展示。
- 有套餐但没拿到周额度：指标为空（付费用户不展示 2 小时次数）。
- 没有套餐（游客）：展示 `rate_limits` 的四档短期次数，套餐名「游客额度」，快照 `isAnonymous = true`，无标价，卡片保留登录入口。
- 用量额度重置以独立摘要 `grokUsageResets` 保存（次数 + 到期日期数组），旧快照可缺省。展开 Grok 卡时在额度条下方显示「可用重置 N 次」及到期正序的三行日期，超出部分内部滚动；与 ChatGPT 共用列表布局。零次只显示总数、不显示日期。**只在展开态渲染**，折叠卡不追加行、不改卡高。分享由独立的「重置次数」开关控制次数和最多三条最早到期记录，与「明细」互不影响；日期按设备时区显示 `yyyy-MM-dd HH:mm:ss`。新设置默认关闭，旧设置沿用原「明细」选择迁移，此后独立保存；仅选中 Grok / ChatGPT 的内置账号时显示此开关。
- 该摘要不进入计量排序、不进小组件额度条、不参与阈值提醒；两条探针都没给出结果时整块不显示。
- 只有重置摘要、没有任何额度指标时，Grok 卡依然可展开（与 ChatGPT 的 `openAIResetCredits` 同规则）。

## 登录判定

### 2026-09-05 真机登录验证补充

- 用户诊断中，46 轮返回空订阅和游客额度，随后 12 轮 REST 403 明确包含 `WKE=unauthorized:second-factor-needed`；这两种情况都不能作为登录完成的证据。
- 优先在当前可见的 `grok.com` 主页面或 OAuth 弹窗执行本次探针；认证中转页没有回跳时，改用同账号 `WKWebsiteDataStore` 的离屏 Grok 网页发起新请求。必须是本轮 `ok` 且非游客结果才弹登录确认，绝不读取 last-good 或根据 Cookie 存在就宣告成功。`accounts.x.ai` → `grok.com` 的弹窗回跳保留 WebKit configuration 与 opener。
- 所有 rate-limit 档位都被上述 WKE 挑战拒绝时，显示「Grok 需要浏览器验证」，保留已有有效用量；普通 401/403 仍判未登录。部分档位成功时继续保留成功数据。
- WKE 是浏览器验证要求；不能仅根据该字符串断言用户密码错误或账号开启了二步验证，也不能以 Cookie 存在假装已通过。当前探针不实现 WKE 签名，不导入桌面 CLI/OAuth token。是否能在完成官网验证后恢复用量仍需真机复验。
- 23:53 的新真机日志已返回付费档位 rate-limits、订阅，以及周额度 / Grok Build 各 2%，解析为 `ok / SuperGrok Heavy`，同时可选 `credits` 为 404；用户明确提示仍在登录窗口显示「请先在官网完成登录」。此前可见 URL 闸门会遗漏已生效的官网会话，不能把这份成功响应重新解释成 WKE 失败或未登录。
- 登录全程留在网页：Grok 登录上下文中的自定义 App scheme / 商店链接在普通导航和新弹窗两个入口均取消，显示「继续网页登录」入口。Grok / xAI 自有站点的主框 GET 点击或跨域回跳使用原 WebView 的 `load(原请求)`，程序重载只放行一次，保留查询参数和现有弹窗 opener；POST、第三方 HTTPS OAuth 与 iframe 不走该重载分支。不使用私有 WebKit 策略枚举或将 App 回调参数拼成伪造的网页登录凭据。已安装 Grok App 的 Universal Link 与完整第三方登录仍需真机复测。

`rate_limits` 解析出至少一档、`subscriptions` 解析出套餐、`credits` / `weekly` 给出套餐或周额度——任一成立即 `ok`。全部不成立时按探针状态分流：

| 情况 | 快照状态 |
|---|---|
| 无任何探针结果 | `error("未获取到任何响应")` |
| `rate_limits`（缺则 `subscriptions`）401 / 403 | `needsLogin` |
| 同上探针其它非 2xx | `error("HTTP n")`；网络层 -3 → `error("请求超时")`、-1 → 错误描述 |
| 探针 2xx 但解析不出任何东西 | `needsLogin` |

`weekly` 的 gRPC 状态**不参与**上表判定（见上一节）。grok.com 对未登录访客也返回 200 的 rate-limits，因此「已登录」不等于「已订阅」，见上方游客态。

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数不得进入用量。HTTP 状态、产品 code 必须是 Int 范围内整数；越界的单项直接跳过。短期限流的 `remainingQueries` 必须非负，存在的 `totalQueries` / `windowSizeSeconds` 也必须非负；任一为负就只跳过该档，不用 clamp 伪装。weekly JSON 的 `creditUsagePercent` / `usagePercent` 及产品 `usagePercent` 只接受 0–100：主百分比异常时只丢百分比、保留合法周期，产品百分比异常时只跳过该产品。窗口秒数不能得出 1970–9999 以外的日期，无效时保留其他用量但不显示重置时间。重置券的 `availableCount` 必须是非负 Int（越界 / 非整数直接丢弃整块），到期时间只接受 1970–9999，越界的单条跳过；写入快照前经 `persistenceValidationIssue` 闸门，不合法就不落盘。

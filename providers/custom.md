# 自定义用量 · 契约校准源

用户向导配置的 HTTPS 用量接口。**不是**内置供应商：代码身份是 `AccountSource.custom(templateID)`，**禁止** `ProviderID.custom`。

本文件是探针备份与校准源，不是逐步点击教程。禁止写入真实 token / Authorization。

代码：`Core/Sources/UsageLimitsCore/CustomUsage.swift`（模板、JSON 预览、解析、刷新提交）、`CustomUsageClient.swift`（HTTP）、`CustomFieldSemantics.swift`（角色推断）、`CustomUsageDisplay.swift`（卡片推导）、`CustomFavicon.swift`（图标解析）；界面 `App/Views/CustomUsageWizardView.swift`、`CustomUsageCardBody.swift`、`CustomTokenSheet.swift`。测试 `CustomUsageParserTests` / `CustomUsageClientTests` / `CustomUsageStoreTests` / `CustomFieldSemanticsTests` / `CustomUsageDisplayTests` / `CustomFaviconParserTests`。

## 1. 定位

- 模板（`CustomUsageTemplate`）只存显示名、HTTPS URL、字段列表 `[{ path, displayName, role?, currency? }]`、可选默认色 `tint`、`logoRelativePath` / `logoIsManual`。无密钥。
- 同一模板可挂多个本机账号；每个账号一份 token、一份 `snapshot.account.<uuid>`。
- 不进 `ProviderID.allCases`、不进 `PlanCatalog`、不进演示橱窗（演示模式隐藏真实自定义卡）。

## 1.1 Bearer 预设（不是新 ProviderID）

`CustomUsagePreset.all` 只预填 URL 与字段，保存前**必须现场测通**。Crof 标实验性。币种以叶子推断为准，叶子没有时才用预设币种。

| id | URL | 币种 |
|---|---|---|
| `kimi-api-intl` | `https://api.moonshot.ai/v1/users/me/balance` | USD |
| `kimi-api-cn` | `https://api.moonshot.cn/v1/users/me/balance` | CNY |
| `crof`（实验性） | `https://crof.ai/usage_api/` | USD（积分） |
| `poe` | `https://api.poe.com/usage/current_balance` | — |
| `openrouter-key` | `https://openrouter.ai/api/v1/key`（不是 `/auth/key`） | USD |


## 2. 请求（`CustomUsageClient`）

| 项 | 约定 |
|---|---|
| 方法 | 仅 `GET` |
| 鉴权 | `Authorization: Bearer <token>` |
| Accept | `application/json` |
| 执行上下文 | `URLSession`（ephemeral），不是 WKWebView 源内 fetch |
| Cookie | 不收不发（`httpCookieAcceptPolicy = .never`、`httpShouldSetCookies = false`） |
| 超时 | 向导 `wizardTimeout` 15s；App 刷新 / 后台刷新 `refreshTimeout` 10s |
| 重定向 | 只跟随同 host（大小写不敏感）；跨 host 3xx 中止，不转发 Bearer |
| TLS | 只接受 `https` + 系统信任证书；不关 ATS，不收 `http` / 自签 |

- 非 https URL 直接返回 `status -1, body "明文被拦"`，不发请求。
- 网络错误映射为 `status -1` + 文案：证书类 → `证书不受信任`；ATS 拦截 → `明文被拦`；`timedOut` → `超时`；`notConnectedToInternet` → `无网络`；其余用系统描述。
- 响应体与错误文案里若出现 token 原文，替换成 `***` 再返回。

## 3. URL

- 落盘只保留 scheme + host + port + path（`sanitizedURLString`），剥掉 query / fragment；path 为空补 `/`。
- 探针页（`probeURL`）不适用。
- 向导路径芯片 `/v1/usage`、`/api/usage` 只是输入建议（host 为空时填成 `https://example.com<path>`），不自动轮询。

## 4. 存储

| 键 | 内容 | 谁读 |
|---|---|---|
| `custom.templates` | 模板数组，无密钥 | App / Widget |
| App Group `custom-logos/<uuid>.<ext>` | 模板图标文件 | App / Widget |
| `custom.accountTokens` | `[accountId: token]` | **仅** App / `BackgroundRefresh` |
| `extraAccounts` | 与内置账号同一数组；自定义写 `source`、不写 `provider` | App / Widget |
| `snapshot.account.<uuid>` | 用量数字 | App / Widget / Watch（经 iPhone 推送） |

- 自定义**只**写 `snapshot.account.<uuid>`；`SharedStore.save` 对 `isCustom` 快照拒绝写 `snapshot.<provider>` 并记诊断。
- token 不进快照、不进诊断、不进 Watch 载荷、不上传。Widget / Watch 源码不得出现 token 键名。
- 删账号：`removeCustomAccountData` 清 token + 账号快照；禁止 `clearAccountData` / `logout(provider)`。删模板同时删图标文件。

## 5. Logo（首页 favicon，不是用量探针）

探针只打用户填的 usage URL（Bearer）。**不要**用 usage URL 当 logo 源。

测试连接 2xx **且向导当前没有图标**（`CustomUsageLogoPolicy.shouldResolveOnTest`）时，另发不带 token 的 GET 解析 favicon。已有图标（自动或手动）则不再抓、不覆盖。「选择 / 替换图标」置 `logoIsManual = true`；「清除图标」后下一次测试才再解析。

| 项 | 约定 |
|---|---|
| 目标 | usage URL 的 origin 首页：`https://host[:port]/` |
| 方法 | `GET`，无 `Authorization`，`Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.8` |
| 体积 | HTML 截断 512KB（`maxHTMLBytes`）；图片 GET 截断 256KB（`maxLogoBytes`） |
| 超时 | `min(会话超时, 8s)` |
| 重定向 / TLS | 同第 2 节 |

解析（`CustomFaviconParser`）：只扫 `<link>` 且 `rel` 含 `icon`。类型优先级 svg > png > ico > jpeg > webp（按 `type` MIME；无 `type` 按 href 后缀）。多条 png 时按 `sizes` 取 32–128 边内最接近 64 的，范围内没有则取距离 64 最近的（无 `sizes` 按 64 计）。href 解析成绝对 URL（绝对地址必须 https）再 GET；下载后按魔数 / `<svg` 判是否图片（png / jpeg / gif / ico / webp / svg）。任一步失败静默保留占位链环，不挡保存。

## 6. 字段路径语法（`CustomJSONPreview`）

- 点路径：`data.usage.used`；数组下标必须写出：`items[0].balance`（不自动取 `[0]`）
- 叶子：`JSONHelp.double` 能解析的标量，或宽松可解析的字符串（`"$168.80"`、`"1,024.5"`、`"42%"`、`"12 USD"`，见 `CustomFieldSemantics.lenientNumber`：去掉 `$ ¥ ￥ € £ % ,` 与已知币种码前后缀后 `Double()`）
- 布尔、对象、数组本身不可选
- 遍历：对象键按字母序，数组按下标；深度 > 8 或叶子 ≥ 200 即截断（`truncated`）；body > 1 MiB 直接报「响应过大」；非 JSON 报「不是 JSON」
- **不要**对金额套 `JSONHelp.percent`

## 7. 字段语义推断（`CustomFieldSemantics.infer`）

按键名（大小写 / 驼峰 / 下划线 / 中划线拆词）、父键名、原始文本、同级 `currency` / `unit` / `currency_code` 字段推断一个角色 `CustomFieldRole` 与分数。只影响向导默认值与卡片展示，不改抓取。判定顺序即优先级：

| 顺序 | 角色 | 条件 | 分 | 展示 |
|---|---|---|---|---|
| 1 | `timestamp` | 原文是 ISO 8601 日期字符串；或键名 / 父键含 expire / reset / renew / valid_until / deadline / end_time / period_end / next_ / 到期 / 重置，且数值像 epoch（1e9–1e10 秒或 1e12–1e13 毫秒） | 30 | 相对 + 绝对时间 |
| 2 | `percent` | 原文以 `%` 结尾，或键名含 percent / pct / ratio / rate / 占比；且 0 ≤ 值 ≤ 100。`remaining_percent` / `remaining.percent` / `available.pct` 走 remaining（剩余占比），`used.percent` 仍是已用% | 70 | `42%` 原样；剩余占比展示 80%、进度条按 20% 已用，不得和上限金额配对 |
| 3 | `remaining` | balance / remain(ing) / left / available / credit(s) / quota_left / 余额 / 剩余 / 可用 | 90 | 余额（主指标首选） |
| 4 | `used` | used / usage / spent / consumed / cost / charged / expense / 已用 / 消耗 / 使用 | 80 | 已用 |
| 5 | `limit` | total / limit / max / quota / cap / allowance / granted / 总额 / 上限 / 总量 / 配额 | 60 | 总额 |
| 6 | `count` | token(s) / request(s) / call(s) / count / num / 次数 | 40 | 整数（≥ 10000 千分位） |
| 7 | `other` | 识别出币种但无角色 | 35 | 金额 |
| 8 | `other` | 键名含 id / code / status / version / type / page / size / offset / ts / time / timestamp，或数值像 epoch | 0 | 普通数字 |
| 9 | `other` | 其余 | 10 | 普通数字 |

- 币种：原文 `$` → USD、`¥` / `￥` → CNY、`€` → EUR、`£` → GBP，或原文前后缀为已知币种码；键名含 usd / dollar / cny / rmb / yuan / eur / gbp / jpy；同级 `currency` / `unit` 字符串。RMB 归一为 CNY。有币种走 `MoneyFormat`
- 向导首次测试按分数自动勾选（`suggestedPaths`）：只勾 ≥ 40 分，最多 4 条，同角色最多 2 条，同分保持原顺序。`timestamp`（30）与 `other` 不会被自动勾上；用户可增减、可改角色与展示名
- 默认展示名：当前界面语言的角色名（已用 / 余额 / 总额 / 已用占比 / 次数 / 到期时间）；`other` 用路径末段
- 模板字段 `role` / `currency` 可空；旧模板无此键照常解码按 `other` 展示；未知角色字符串解码为 nil，不报错
- 仅有 `usedPath` / `balancePath` 的旧模板 decode 时补 `used` / `remaining` 角色

## 8. 解析口径（`CustomUsageParser`）

- HTTP 401 / 403 → `needsLogin`，metrics 为空；刷新层（`CustomUsageRefresh.commit`）经 `RefreshPolicy` 后合成旧数字保留展示
- 其它非 2xx → `error("HTTP <status>")`；`status ≤ 0` → `error("请求失败")`
- 2xx 但非 JSON → `error("不是 JSON")`
- 按模板字段顺序逐条取值；取不到的字段不生成指标；全部缺 → `error("字段无法读取")`
- 至少勾选一项才能保存；用户没勾的字段永远不产生指标，不编造已用 / 余额
- metric：`label` 用展示名，`amount` + `pinned == true`，`kind` 存角色 rawValue，`usedPercent` 恒为 `nil`（不触发百分比阈值提醒）
  - `percent` 角色 → `displayValue: "42%"`（整数不带小数，否则一位）
  - `timestamp` 角色 → `resetsAt`：ISO 8601 字符串走 `JSONHelp.date`（含无时区、空格分隔、仅日期，一律按 UTC）；数字 > 1e12 按毫秒，否则按秒
  - 其余：`currency` 取模板字段值，缺失时再从原始字符串推断
- metric `id` 默认用字段 path。用 `balance`（供预充值提醒识别）的两种情形：模板**仅一条**字段且展示名为「余额」；或该字段是**唯一**一条 `remaining` 角色且没有别的字段展示名叫「余额」
- `amount == 0` 仍显示（`pinned`）
- 旧模板只有 `usedPath` / `balancePath` 时 decode 成字段列表，展示名默认「已用」「余额」
- 产出快照 `isCustom == true`；`provider` 编码占位固定 `.claude`，**禁止**用它做品牌、标题、货币、提醒档

## 9. 登录判定

- token 空或 HTTP 401 / 403 → `needsLogin`（token 空时不发请求，按 401 记诊断）
- CTA 是「更新令牌」（`CustomTokenSheet`），禁止打开 `LoginSheetView` / WebKit 登录

## 10. 刷新、诊断、提醒、后台

- 诊断行：`custom.<模板名>: HTTP <status>，<bytes> 字节 host=<host>`，另有 `custom.<模板名>.parsed= <脱敏摘要>`；未提交时记 `探针不可靠，保留上次有效快照`。不含 token、Authorization、完整 URL
- 提醒：只接**统一档**预充值余额（`NotificationDecider.customPrepaidEvents`：`prepaidScope == .unified` 且 `prepaidAmountEnabled`，余额取 `id == "balance"` 或展示名「余额」，新旧快照都 ok 且从阈值上方跌到下方）；`perProvider` 时不发；不要对自定义快照调用 `events(old:new:)`
- 后台（`BackgroundRefresh`）：闸门先过 `needsBackgroundProbe`；主号 / 附加内置 / 自定义按上次成功快照从旧到新排队（`RefreshSweep`），同样陈旧时附加内置优先，避免 20s 预算被主号吃完。自定义账号只在 `prepaidScope == .unified && prepaidAmountEnabled` 时进队，且只扫已启用、上次快照 ok 的账号；URLSession 10s，计入整轮 20s 预算

## 11. 卡片展示（`CustomUsageDisplay` / `CustomUsageCardBody`）

- `tiles`：按快照 metrics 顺序，`displayValue` 优先，否则金额格式化（有币种 `MoneyFormat`；无币种整数保持整数、≥ 10000 千分位，小数最多 2 位）
- 主指标 `hero`：`remaining` > `used` > `percent` > `limit` > `count` > `other` > 第一条（时间戳不参与）
- 进度条 `gauge` 来源优先级：百分比字段（0–100）> 已用/总额 > 已用/(已用+余额)（展示名「已用」+「余额」成对，或 `used` + `remaining` 角色成对）> (总额−余额)/总额；都没有就不画。颜色按阈值绿 / 橙 / 红
- 配对必须同单位：币种相同（忽略大小写），或两边都没有币种。一边是 USD、一边没币种视为不同单位（Crof 美元积分不得和请求上限画成 98%）。多条同角色时取第一条同单位且数量合法的一对
- 「用量最高」在自定义没有 `usedPercent` / 百分比角色 / 已用+余额占比时，用同一条 `gauge.riskPercent`（含已用/总额与余额/总额）；混单位配对不得进最高用量
- 折叠：主指标大号 + 右侧最多 2 格次指标 + 细进度条（无说明）+「还有 N 项，展开查看」（N = 未显示的次指标数 + 时间戳条数）
- 展开：主指标着色区块（账号 / 模板 tint 淡底，含进度条与说明「已用 x / 总额 y」）→ 其余数字 2 列网格（角色小图标）→ 时间戳行（相对 + 绝对）
- 抬头元信息：账号名与模板名不同时显示模板名，否则显示 host
- 小组件 / Watch / 分享图按 `tiles` 列表原样展示，不画推导进度条

## 12. 禁止

- POST、自定义 Header、Cookie、HMAC、OAuth
- `http` / 自签 / 关闭 ATS
- `ProviderID.custom` 或新增内置 case
- 真实凭据写入本文件、fixture、诊断或 git
- 用占位 `provider` 画 Claude / Grok 等商标

## 13. 异常数值与时间

- JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数不得成为可选字段。
- 超出 Int 范围的有限数仍可作为普通数值，预览 `rawDisplay` 使用有界的科学计数法，禁止直接 `Int(Double)`。
- `timestamp` 角色：ISO 8601 字符串或 1970–9999 内的 epoch 秒 / 毫秒转为 `resetsAt`；越界数字保留原值但不生成日期。无时区（`2026-09-01T00:00:00`）、空格分隔、仅日期按 UTC。向导拍扁时 ISO 字符串也是可选叶子。

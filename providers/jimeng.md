# 即梦（jimeng.jianying.com）积分额度目录

- **官网积分页**：`https://jimeng.jianying.com/ai-tool/personal/<sec_uid>`（路径末段是当前账号 `sec_uid`，只在运行时发现）
- **登录入口 / 探针执行页**：`https://jimeng.jianying.com/ai-tool/home`（`loginURL` 与 `probeURL` 同一页；根路径 `/` 是营销落地页，不能当登录 / 探针页）
- **鉴权**：本机 WebKit Cookie（`sessionid` / `sid_tt` 等，同源 `fetch` 自动带）。请求另带官网 Web 客户端公开头 `Appid: 513695`、`Appvr: 5.8.0`、`Pf: 7`（`JimengSession.appID / appVersion / platform`），以及 commerce 签名头（见下）。
- **Cookie 域**：`jimeng.jianying.com`、`jianying.com`。会话只认 `jianying.com`，抖音域的 `sessionid` 不算即梦已登录。
- **计费形态**：积分预充值 / 订阅赠送混合，无订阅标价，不进 `PlanCatalog`，不展示价格徽章。
- **范围**：仅国内站 `jimeng.jianying.com`；海外 Dreamina 不接。

## 约束

- 禁止把任何真实 `sec_uid` / `user_id` / `uifid` / `msToken` 写进代码、目录、fixture；全部运行时读取。
- 禁止发明 `a_bogus`；签名只走页面 `webSignBody` 或 native 兜底 `Sign`。
- 积分是整数，禁止走 `JSONHelp.percent`。充值积分用 `purchase_credit` 原值，禁止用「剩余 − 订阅 − 赠送」反推。
- 即梦保留独立签名包装 `__jimengProbe`，签名完成后调用共享 `__probe`，并强制 `noAuth: true` / `retry: false`；这样既不会注入 `Authorization`，又继承可 Abort 的单次预算与 27 秒共享 deadline。禁止在签名包装里再写裸 `fetch`。
- 禁止裸 `URLSession` + 手填 sessionid。

## 已解析 API

| 探针名 | 请求 | 用途 | 解析器 |
|---|---|---|---|
| `credit` | `POST /commerce/v1/benefits/user_credit?<query>` body `{}` | 订阅 / 充值 / 赠送原值（`keyProbe`） | `JimengParser` |
| `history` | `POST /commerce/v1/benefits/user_credit_history?<query>` body `{"count":20,"cursor":"","history_type":0}` | `total_credit` 兜底剩余；`records` 进近 1 个月明细 | `JimengParser` |
| `user` | `GET /passport/web/account/info/v2/?aid=513695&account_sdk_source=web` | 过桥只回 `{loggedIn:true|false}`（脚本内看 sec_uid / user_id 是否存在，原文不越桥）；解析器也认旧 fixture 的 discoveredID | `JimengParser` |
| `page` | 不发请求；读 `window.__isLogined` / `window.__userInfo`，回报 `isLogined` / `hasUserInfo` / `hasUifid` / `hasSigner` / `hasNativeSign` 布尔 | 官网 SSR 登录标志 + 签名能力 | `JimengParser` |
| `session` | native 注入，body 仅 `{"hasSession":true|false}`，不发 HTTP。RefreshPolicy 按本地快照处理（body 只有 `hasSession`），不得把同名 ChatGPT `/api/auth/session` 当真合成壳 | 本机是否出现会话 Cookie 名（`sessionid` / `sessionid_ss` / `sid_tt` / `sid_guard`） | `JimengParser` |

探针不再产出 `identity`：路径、`window.__userInfo`、localStorage 与 Cookie 中的 `sec_uid` / `user_id` 原值都不得跨过 JavaScript→Swift 边界。`page` 只回传是否存在用户信息 / 签名能力的布尔摘要；诊断因此只包含布尔与 HTTP 状态/长度。

`credit` 特例：页面 `__STORE__`（`userStore.credit` / `userCredit` / `userInfo.credit` / `creditStore.*`）里已有带 `vip_credit` / `purchase_credit` / `gift_credit` / `total_credit` 的对象时，直接封装成 `{ret:"0",data:{credit:…}}`，不再发请求。

**Query**（额度 / 流水共用，运行时拼）：`aid=513695&device_platform=web&region=CN&timestamp=<unix秒>`，再按有无追加 `uifid=<运行时值>`、`msToken=<运行时值>`。

| 参数 | 来源 |
|---|---|
| `uifid` | 依次 `window._secsdk_uifid` → `SSR_RENDER_DATA.app.odin.user_id` → `__STORE__.userStore.userInfo.id_str/user_id/uid` → native 注入的 Cookie `uifid` → `document.cookie`。没有就不传，等待就绪时不要求它 |
| `msToken` | native 从 `WKHTTPCookieStore` 注入，缺则 `document.cookie` |
| `x-tt-passport-csrf-token` 头 | native 从 Cookie 库取 `passport_csrf_token` / `passport_csrf_token_default` / `csrf_token`（常为 HttpOnly，页面读不到） |

**签名头**（不带会稳定回 `ret=1014 system busy`）：

| 头 | 值 |
|---|---|
| `Device-Time` | Unix 秒 |
| `Sign` | `md5("9e2c|" + 路径末 7 位 + "|" + Pf + "|" + Appvr + "|" + Device-Time + "||11ac")`，路径不含 query（`user_credit` → `_credit`，`user_credit_history` → `history`） |
| `Sign-Ver` | `1` |

来源两条任一：① 页面 secsdk `window.use('webSignBody')` 就绪时由它改写 URL + 补头；② 否则用 native 兜底——`WebViewFetcher.probeArguments` 用 CryptoKit MD5 算好 `deviceTime` / `signCredit` / `signHistory` 注入探针（`JimengSession.signPayload`）。探针收到 `ret:"1014"` 时只在共享 deadline 仍容得下 400ms backoff 时重试一次；等待签名器的 250ms 轮询同样在 deadline 耗尽时停止。

**响应形状**（fixture `jimeng_credit.json` / `jimeng_history.json`）：

```json
{ "ret": "0", "errmsg": "success",
  "data": { "credit": { "vip_credit": 0, "purchase_credit": 149, "gift_credit": 30 } } }
```

```json
{ "ret": "0", "errmsg": "success",
  "data": { "new_cursor": "1000:1", "has_more": true, "total_credit": 179,
    "records": [ { "amount": 30, "create_time": 1787494919, "title": "每日免费积分",
                   "history_type": 1, "history_id": "1001", "submit_id": "…", "extra_content": "" } ] } }
```

## 解析口径

- 信封：`ret == "0"`（或数字 0 / `errmsg == success`）为成功；`data` 缺失时读 `response`（`data` 的 JSON 字符串镜像）。
- 积分包：`data.credit`，或 `data` / 顶层扁平的 `vip_credit` / `purchase_credit` / `gift_credit`。别名 `subscription_credit` / `recharge_credit` / `bonus_credit` 也认。
- 指标（全部 `pinned`）：`remaining` 剩余、`subscription` 订阅 = `vip_credit`、`recharge` 充值 = `purchase_credit`、`gift` 赠送 = `gift_credit`。剩余 = 三者之和（官网公式）；三者不齐时用包内 `total_credit`，再缺用 `history.data.total_credit`，再缺用已有项之和。
- 流水：`records[]` 只取 `title`、`amount`（正整数，UI 按类型加 +/-）、`history_type`（1 获得 / 2 消耗，其它跳过）、`create_time`（Unix 秒）、`history_id`（缺则 `submit_id`）、`extra_content`。任一必填缺失即跳过该行。不翻页（忽略 `has_more` / `new_cursor`），只发 `history_type: 0`。
- `ret == "1014"` / `errmsg` 含 `system busy` = 缺签名，**不是未登录**。

## 登录判定

满足任一即已登录（`status = ok`）：

- `credit` / `history` 成功且解析出积分
- `user` 能解析出 `sec_uid` / `sec_user_id` / `user_id` 等账号 id
- `page.isLogined == true` 或 `hasUserInfo == true`
- `session.hasSession == true`

否则：全无响应 → error；任一响应 1014 → error「系统繁忙」；其余 → `needsLogin`。

已登录但四档积分全缺、且额度 / 流水是 1014：钉住 `remaining` 占位（`displayValue "—"`，`detail = JimengParser.unavailableDetail`），卡片显示「积分暂未获取到 / 系统繁忙，下拉重试」，不交空白 ok；有真实数字的旧快照不被占位盖掉。

## 登录 WebView 与探针页契约

- 官网登录是抖音护照 SDK。护照 / Apple 的 iframe（`LoginWebViewScripts.ssoPopupHosts` + `douyin.com` 登录路径）必须 `window.open` 提到顶层，交给 `createWebViewWith`（保留 `opener`），不得自建 WKWebView；`decidePolicyFor` 只取消这些子框，不提升即梦自己的 iframe。弹窗关闭后重载 `/ai-tool/home`（`reloadJimengHomeAfterSSO`），SSR 才会把 `__isLogined` 写成 true。
- 登录页弹确认：`jimengIndicatesLogin`（会话 Cookie 名）或 `jimengPageIndicatesLogin`（`JimengSession.pageLoginScript`）任一为真。Cookie / SSR 旁证只负责弹确认，不算已抓到积分。
- 点确认后：`prepareJimengLivePage` 在可见登录页等 `isLoading` 结束；不在 `/ai-tool/` 或匿名 SSR 且无签名器时只重载一次 home；再等 `__isLogined` + `webSignBody`（`isCommerceReady`）约 3s，等不到也放行（有 native 签名）。随后 `adoptLiveJimengWebView` 接管这张 WKWebView 给首页复用。
- 接管的页挂进 key window 最底层：全尺寸、不透明、`isUserInteractionEnabled = false`，不 `makeKeyAndVisible`（近乎透明宿主窗会被 iOS freezer 杀掉 WebContent；禁止 `CGRect.zero`）。首页下拉 / 自动刷新优先复用（诊断 `jimeng.probe= live`），无热文档才走离屏页（`offscreen`）；离屏页加载后等会话 Cookie 最多 2s。
- **iPad 视口（2026-09-08 待验证项）**：接管页的 frame = key window bounds 并 autoresize，所以在 iPad 上它是**窗口那么宽**，不是 390×844。模拟器上以未登录状态打开 `/ai-tool/home`（iPad Air 11 全屏竖屏，视口 820pt，UA 未变）实测拿到的是**桌面版布局**，不是移动版。离屏探针页不受影响，仍是固定 390×844 的移动版 SSR。
  桌面版 SSR 是否照样写 `window.__isLogined` / `webSignBody`，需要真实账号在 iPad 上登录后才能定论——**尚未验证**，不得据此断言即梦在 iPad 上可用或不可用。若真机验证发现形状变化，按本文件顶部的维护顺序同轮更新目录、脚本与 fixture；不要为此改 UA 或改回隐藏小窗。

- 探针 JS 内 `__jimengWaitHomeReady`：有 native 签名给 SSR / 签名器约 2s，否则约 10s 再等签名器最多 8s；都不要求 uifid。
- 诊断只写布尔与 HTTP 摘要，不写 Cookie / token / uifid 值。

## 展示约定

- 折叠：四档积分一行均分（剩余 / 订阅 / 充值 / 赠送），不露流水；未获取到时「剩余积分 —」+ 提示。
- 展开：四档数字 + 「近1个月明细」（标题、时间、+/- 积分），列表约 5 行高内部滚动；caption「仅展示近1个月，更新可能有延迟」。
- 无套餐徽章；订阅为 0 仍展示。

## 异常数值策略

JSON 布尔、`NaN` / `Infinity` / 溢出指数字符串与非有限数直接丢弃。流水 `history_type` 与数字 id 在转 Int 前检查范围，越界整条丢弃；积分分项求和溢出时不覆盖可用总额。流水时间只接受 1970–9999。

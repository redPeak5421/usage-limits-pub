# Gemini（gemini.google.com）用量接口目录

- **官网 / 登录 / 探针页**：`https://gemini.google.com/usage`；Google 多账号页面为 `/u/<index>/usage`。
- **鉴权**：本机 WebKit Cookie + 当前账号页面 `window.WIZ_global_data.SNlM0e` 的 CSRF 字段 `at`。请求 `noAuth: true`，不附加 Bearer。
- **Cookie 域**：`gemini.google.com`、`google.com`。
- **代码**：`GeminiProbeScript.body` → `ProviderScripts.gemini`；`GeminiParser`；`GeminiWebUsageTests`。
- **验证**：2026-09-09，Chrome `/u/3/usage` Network 捕获 + 官方前端 `GetUsageInfo` / `Chm` 字段映射 + 页面源内 fetch 重放 HTTP 200。iPhone 17 Pro / iOS 26.5 模拟器复用已有 Cookie：可见 WKWebView 登录检测、确认后落盘、冷启动离屏刷新均 `ok`，两条用量均 0%，重置约 5 小时 / 7 天。物理真机与新账号 OAuth 全流程尚未验证。

## 请求

```text
POST /u/<index>/_/BardChatUi/data/batchexecute
  ?rpcids=jSf9Qc&source-path=/u/<index>/usage&bl=<cfb2h>&f.sid=<FdrFJe>&hl=<language>&rt=c
Content-Type: application/x-www-form-urlencoded;charset=UTF-8
f.req = [[["jSf9Qc","[]",null,"generic"]]]
at = <SNlM0e>
```

无账号前缀时用 `/_/BardChatUi/data/batchexecute`。这是官网 `BardFrontendService.GetUsageInfo`，不是桌面 OAuth 的 `cloudcode-pa` / CLI 配额。

运行时只直接请求会话引导页和这一条 usage RPC；不监听、收集或解析浏览器全部请求记录，不读取 HAR。`batchexecute` 只是传输格式，`f.req` 中仅包含 `jSf9Qc`，不批量调用其他业务接口。Chrome 网络捕获仅用于本次定位接口，不属于 App 实现。

引导页 `GET <account-prefix>/usage` 仅用于读取具名 `window.WIZ_global_data` JSON（`SNlM0e`、`cfb2h`、`FdrFJe`、`S06Grb`），不从 HTML / UI 文本推测额度。通过 JSON.parse 解码，不执行网页脚本；原始 HTML 与 CSRF 不返回 Swift、不记诊断。

可见登录检测以当前 URL 账号为准；离屏刷新使用同一 WKWebsiteDataStore 的 localStorage `usage-limits.gemini.account-path` 保存的路径。只有有效配额返回才更新路径；绝不硬编码 `/u/3`。附加 App 账号因独立 dataStore 隔离。`S06Grb` 是捕获并核对的 Google 账号 ID，在源内按 `aiusage-identity-v1|gemini|sub|<id>` 做 SHA-256，仅指纹进入 `identity` 探针，现有 AccountIdentity 闸门拒绝串号。

## 响应与字段

响应有 `)]}'` XSSI 前缀、长度行及 JSON 帧。仅解包 `wrb.fr`、RPC ID `jSf9Qc` 的第三项 JSON 字符串，忽略计时 / 其他 RPC。

脱敏 payload 示例：

```json
[2,[[48384,0,2,[[1789554602,79296000]]],[2400,0,1,[[1788967802,79295000]]]],false]
```

| 路径（0-based） | 含义 |
|---|---|
| `[0]` | 套餐：官网映射 2 PRO / 3、6 ULTRA / 4 PLUS；其他不猜名称 |
| `[1][][2]` | 窗口类型：1 当前（5 小时）、2 每周；其他类型忽略 |
| `[1][][1]` | **已用比例 0…1**；官网 `Math.round(value * 100)`，快照保留百分比精度 |
| `[1][][3][0]` | 重置 `[Unix 秒, 纳秒]`；不能按毫秒解释 |
| `[1][][0]` | 内部额度单位，不能当百分比、请求数或剩余额度展示 |

窗口按类型识别，显示顺序为 `five_hour`、`weekly`，不依赖返回数组顺序。缺字段 / 非法比例跳过该窗口；无有效指标为 error，绝不返回空 ok。真实 401/403 → needsLogin；HTML / RPC 错误 / 截断数据 → error，不覆盖 last-good。`quota` 诊断只记状态和字节数，不记录 RPC 原文。旧 remainingFraction JSON 解码保留兼容，但不再由官网探针生成。

## 历史问题

此前 `/app` 占位响应是网页，却交给 JSON 配额解析器，约 850 KB 的 HTTP 200 反复报「配额数据异常」。1.5.584 只改错误归因；本轮凭真实 `/usage` 网络捕获接通 `jSf9Qc`。不能用扩大响应上限或改提示代替接口适配。

# Gemini（gemini.google.com）用量接口目录

- **官网 / 登录 / 探针页**：`https://gemini.google.com/app`。
- **鉴权**：本机 `gemini.google.com` + `google.com` WebKit Cookie。探针 `noAuth: true`。
- **Cookie 域**：`gemini.google.com`、`google.com`。退出登录清这些域。
- **接入范围**：若同源响应是 CodexBar 的 `remainingFraction` 桶，映射为已用百分比。**没有已确认的官网 Cookie 配额 API**。
- **标价**：无。
- **代码**：`GeminiProbeScript.body` → `ProviderScripts.gemini`；解析 `GeminiParser`；测试 `NewProvidersTests`。
- **观测**：2026-08-29。CodexBar 桌面路径是 OAuth + `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`，**不能**从 WKWebView Cookie 搬过来。禁止发明 `batchexecute` / BardChatUi 刮页。

## 请求

当前只打同源占位：

```text
GET /app
Accept: application/json
noAuth: true
```

真机若仍返回 HTML / CORS 失败，解析器必须 `.error`，不得编配额。

## 字段映射（仅当 body 已是 JSON）

| 字段 | 用途 |
|---|---|
| `buckets[].modelId` | 指标 id |
| `buckets[].remainingFraction` | 剩余比例 0…1；已用 = `(1 - remainingFraction) * 100` |
| `buckets[].resetTime` | 重置时间 |
| `buckets[].displayName` | 指标名 |

401 / 403 → `.needsLogin`，指标为空。HTML、缺桶、非有限 `remainingFraction` → `.error`。

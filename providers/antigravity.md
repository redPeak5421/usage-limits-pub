# Antigravity（antigravity.google）用量接口目录

- **官网 / 登录 / 探针页**：`https://antigravity.google/`。
- **鉴权**：本机 `antigravity.google` + `google.com` WebKit Cookie。探针 `noAuth: true`。
- **Cookie 域**：`antigravity.google`、`google.com`。
- **接入范围**：若同源响应是 `groups[].buckets[].remainingFraction`，映射为已用百分比。
- **标价**：无。
- **代码**：`AntigravityProbeScript.body` → `ProviderScripts.antigravity`；解析 `AntigravityParser`；测试 `NewProvidersTests`。
- **观测**：2026-08-29。CodexBar 用本地 `agy`/IDE 或 OAuth `retrieveUserQuotaSummary`，**都不能**从 iOS WKWebView Cookie 复刻。禁止发明未证实的 `/api/usage`。

## 请求

```text
GET /
Accept: application/json
noAuth: true
```

占位同源请求。HTML / 缺 JSON → `.error`，不得编数字。

## 字段映射（仅当 body 已是 JSON）

| 字段 | 用途 |
|---|---|
| `groups[].buckets[].bucketId` | 指标 id |
| `groups[].buckets[].displayName` | 指标名 |
| `groups[].buckets[].remainingFraction` | 剩余比例 0…1；已用 = `(1 - remainingFraction) * 100` |

无 `groups` 时回退顶层 `buckets`，与 Gemini 同形。401 / 403 → `.needsLogin`。

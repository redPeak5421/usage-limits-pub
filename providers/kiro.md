# Kiro（app.kiro.dev）用量接口目录

- **官网 / 登录 / 探针页**：`https://app.kiro.dev/`。Settings → Estimated Usage 是网页入口，**没有已确认的同源 JSON 路径**。
- **鉴权**：本机 `kiro.dev` WebKit Cookie。探针 `noAuth: true`。
- **Cookie 域**：`kiro.dev`（覆盖 `app.kiro.dev`）。
- **接入范围**：若同源响应已是 `{ planLimit, planUsed, nextDateReset }`，映射套餐额度。
- **标价**：无。
- **代码**：`KiroProbeScript.body` → `ProviderScripts.kiro`；解析 `KiroParser`；测试 `NewProvidersTests`。
- **观测**：2026-08-29。CodexBar / `kiro-cli` 走 `POST https://codewhisperer.us-east-1.amazonaws.com/` `GetUsageLimits`，要 AWS 签名，**不能**用 Cookie 伪造。禁止发明 `/api/usage`。

## 请求

```text
GET /
Accept: application/json
noAuth: true
```

占位同源请求。HTML / 缺 JSON → `.error`。

## 字段映射（仅当 body 已是 JSON）

| 字段 | 用途 |
|---|---|
| `planLimit` / `plan_limit` | 套餐上限 |
| `planUsed` / `plan_used` | 已用 |
| `nextDateReset` / `next_date_reset` | 重置（epoch 秒或 ISO） |

也可包在 `credit` 对象里。已用百分比 = `planUsed / planLimit * 100`。401 leftover body 不得出指标。

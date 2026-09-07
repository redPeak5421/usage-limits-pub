# Copilot（github.com）用量接口目录

- **官网 / 登录入口**：`https://github.com/login`。
- **探针页**：`https://github.com/settings/copilot`，只打同源相对路径。
- **鉴权**：本机 `github.com` WebKit Cookie；`fetch(..., { credentials: 'include' })` 自动携带，探针 `noAuth: true`。不走 GitHub OAuth device flow，也不打 `api.github.com/copilot_internal/user`（那条要桌面 OAuth token）。
- **Cookie 域**：`github.com`。退出登录清该域 WebKit 数据。
- **接入范围**：个人账单里带 Copilot SKU 的预算条。不读账号、邮箱、组织名原文进诊断预览。
- **标价**：无。`PlanCatalog` 不收录 Copilot。
- **代码**：Foundation-only `CopilotProbeScript.body`，App 组合为 `ProviderScripts.copilot`；解析 `CopilotParser`；测试 `NewProvidersTests`。
- **观测**：2026-08-29 按 CodexBar `CopilotBudgetWebFetcher` 整理，**待真机确认**。这是目前唯一确认的同源 Cookie 用量接口。

## 请求

```text
GET /settings/billing/budgets?page=1&page_size=10&scope=customer
Accept: application/json
X-Requested-With: XMLHttpRequest
GitHub-Verified-Fetch: true
noAuth: true
```

`Origin` / `Referer` / `User-Agent` / Cookie 由 WKWebView 自动带。不手写桌面 UA，不从 HTML 抓 `X-Fetch-Nonce`（禁止 DOM 刮页）。GitHub 若强制 nonce，本轮会失败并保持诚实错误，不得编预算数字。

## 字段映射

响应可能是 `{ budgets: [...] }` 或 `{ payload: { budgets: [...] } }`。

| 字段 | 用途 |
|---|---|
| `budgetAmount` / `budget_amount` | 预算上限 |
| `currentAmount` / `current_amount` | 已用金额 |
| `name` / `displayName` | 指标名 |
| `budgetProductSkus` | 只收 `copilot` / `copilot_premium_request` / `copilot_agent_premium_request` / `spark_premium_request` |

已用百分比 = `currentAmount / budgetAmount * 100`，钳到 0–100。401 / 403 整轮 `.needsLogin`，忽略 leftover body。200 但不是 JSON 或没有 Copilot SKU → `.error`，指标为空。

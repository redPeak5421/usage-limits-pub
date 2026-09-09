# 接入可见性核验 · 2026-09-09

发布目录开放 11 家；另外 14 家暂时隐藏。隐藏表示当前 App 接入证据不足，不表示官网没有用量功能。`ProviderAvailability` 只控制目录、展示和自动探针；25 个 ProviderID、解析器、凭据、账号、快照和排序仍保留。自定义账号不受影响。恢复时先补同源鉴权与真实响应验证，再开放门禁。

## 已确认并保留

本轮用户明确确认以下 11 家可接入；沿用各目录已记录接口，不重复获取全站请求记录。Gemini 另完成本轮真实 Chrome RPC 与模拟器冷启动验证。

| 供应商 | 契约 |
|---|---|
| Claude | [claude-ai.md](claude-ai.md) |
| OpenAI / Codex | [chatgpt.md](chatgpt.md) |
| Kimi | [kimi.md](kimi.md) |
| DeepSeek | [deepseek.md](deepseek.md) |
| OpenCode | [opencode.md](opencode.md) |
| Gemini | [gemini.md](gemini.md)：只请求 GetUsageInfo `jSf9Qc` |
| Grok | [grok.md](grok.md) |
| Cursor | [cursor.md](cursor.md) |
| 即梦 | [jimeng.md](jimeng.md) |
| 智谱 | [zhipu.md](zhipu.md) |
| MiniMax 国内 | [minimax.md](minimax.md) |

## 暂时隐藏

公开官方资料只能证明用量入口或计费口径时，不能据此把现有参考实现认定为已验证。以下结论是对当前 App 接入的判断，未登录这些账号进行验证。

| 供应商 | 官方核对来源与当前缺口 |
|---|---|
| MiniMax 国际 | [Token Plan](https://platform.minimax.io/subscribe/token-plan) 提供 `www.minimax.io/v1/token_plan/remains` Bearer API Key；现有共享国内脚本使用网站登录态，尚未验证国际站鉴权与响应，不能以国内成功代替。 |
| LongCat | [官方更新](https://longcat.chat/platform/docs/ChangeLog.html) 确认 Token Pack / 按量计费；当前私有 summary / tokenUsage 接口来自参考实现，无本 App 登录态验证。 |
| MiMo | [官方 Token Plan](https://platform.xiaomimimo.com/token-plan) 确认 Credits；现有 balance / tokenPlan 私有接口及固定时区头未获当前响应证据。 |
| Qoder | [官方用量说明](https://docs.qoder.com/cli/usage) 提供 CLI 用量面板；无法证明现有网页版 big_model_credits 和固定版本头有效。 |
| Perplexity | [官方 Credits](https://www.perplexity.ai/help-center/en/articles/13838041-how-credits-work-on-perplexity) 说明 Computer 用量及三类余额；现有带固定 version 参数的私有接口未验证。 |
| Augment | [官方政策](https://docs.augmentcode.com/models/credits-policy) 以账单面板为准；[Analytics API](https://docs.augmentcode.com/analytics/analytics-api) 不能直接证明现有 Cookie `/api/credits` 字段契约。 |
| Abacus | [官方帮助](https://api.abacus.ai/help/abacusai-desktop/providers) 提及 Credits；现有 `_getOrganizationComputePoints` 为第三方参考，未验证网站 Cookie 信封。 |
| T3 Chat | [官网](https://t3.chat/) 公开页没有可验证用量报文；现有 getCustomerData tRPC 来自第三方参考。 |
| Notion AI | [官方 Credits 面板](https://www.notion.com/help/track-usage-in-the-notion-credits-dashboard) 涉及 workspace 与角色；现有私有 v3 workspace 选择及字段仍待真实验证。 |
| Ollama | [官方 API Usage](https://docs.ollama.com/api/usage) 是单次推理计数，并非订阅剩余；现有 settings HTML 抽取没有本 App 真实验证，也不是直接用量接口。 |
| StepFun | [官方控制台](https://platform.stepfun.com/account-overview) 提供 Step Plan；现有 Dashboard RPC 对可见 Oasis-Webid Cookie 的假设仍待验证。 |
| Copilot | [官方监控说明](https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/monitor-premium-requests) 已区分旧年付请求制；当前 budgets 接口仅账单预算，不能当作通用套餐配额。 |
| Antigravity | [官方 Plans](https://antigravity.google/docs/plans) 确认 quota；现有探针为 HTML 占位，没有已验证同源用量接口。 |
| Kiro | [官方 usage 命令](https://kiro.dev/docs/cli/reference/slash-commands/) 确认余额入口；当前网页探针仍是 HTML 占位，不能搬用桌面 AWS 鉴权。 |

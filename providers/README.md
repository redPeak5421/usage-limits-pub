# providers/ · 供应商用量接口目录

每个供应商一份目录文件：官网 Usage 页地址、已解析与备用的用量 API、鉴权方式、官方套餐标价表。

**定位**：这是探针的**备份与校准源**。接口漂移时的维护顺序：

1. 先在真机/模拟器上确认新形状（诊断页「探针诊断日志」可看到每个探针的 HTTP 状态与响应长度）；
2. 更新对应目录文件（本目录）；
3. 再改代码：探针脚本 `App/Networking/ProviderScripts.swift`、解析器 `Core/Sources/UsageLimitsCore/*Parser.swift`（fixture 同步更新）；
4. 套餐价格漂移时同步 `Core/Sources/UsageLimitsCore/PlanCatalog.swift`。

自定义抓取（用户自填 HTTPS URL / 字段映射 / 模板）变更必须同步 [custom.md](custom.md)。

**鉴权红线**（所有供应商一致）：App 运行时只携带本机 WebKit 登录态（Cookie / 站内 token）去打各自官方域名；凭据只存本机 WKWebsiteDataStore 与 App Group 沙盒，**绝不外发、绝不上传**。目录文件中也不允许出现任何真实 Cookie / token 值。

**WebKit 导航线程**：离屏探针的 `decidePolicyFor` 继承 `WebViewFetcher` 的 `@MainActor` 隔离，读取 `WKNavigationAction.request` / `targetFrame` 并调用策略回调均在主线程。广告拦截、Apple SSO iframe 取消及其它初始化 iframe 放行规则不变；不要用 `nonisolated` 绕开 WebKit 的隔离契约。

**展示约定**：某模型/产品未使用（用量为 0 或额度未动）时，首页默认不显示该条（`UsageMetric.hasUsage`）。

**数值约定**（所有供应商一致）：JSON 布尔不是 0/1 用量；`NaN` / `Infinity` / 溢出指数字符串与任何非有限数直接丢弃。所有 Double→Int 先做 finite / 范围检查，日期只接受 1970–9999。快照落盘前递归验证百分比、金额、余额/总额、breakdown / history 和日期；无效快照拒绝落盘并记诊断，不覆盖上一份有效快照。

**探针响应上限**（所有原生供应商一致）：文本响应最多 **1 MB**（`__PROBE_TEXT_LIMIT_BYTES`，超过按 UTF-8 字节截断；Gemini quota 单次超过 200 KB，旧上限 200 KB 会截成坏 JSON），二进制响应最多 150,000 原始字节（base64 后 200,000）。

**探针时间预算**（所有原生供应商一致）：一轮脚本从启动起共享 **27 秒 deadline**，给 `callAsyncJavaScript` 的 30 秒外层留至少 3 秒编码与回桥余量。普通子请求默认单次 12 秒；显式短预算仍以各供应商文件为准。每次实际 timeout 都夹到本轮剩余时间，deadline 耗尽后不再发新请求并返回 `status: -3`。网络错误 / 408 / 502 / 503 / 504 默认只重试一次，300ms backoff 也计入共享预算；剩余时间不足时跳过重试。整个 `fetch` + body 消费无条件走同一 deadline race：即使 `AbortController` 存在但底层忽略 signal、`text()` / `arrayBuffer()` / stream reader 永不完成，也会按预算返回。响应优先逐块读取 `ReadableStream`：文本最多 **200,000 个 UTF-8 字节**，二进制最多 **150,000 个原始字节**（base64 后不超过 200,000 字节），到上限立即 cancel；无 stream 时按同一字节上限截断，可信 `Content-Length` 已超限则不读取 body、2xx 返回 `status: -2`。`finalURL` 只保留 origin + pathname，响应头仅白名单透传 `grpc-status` / `grpc-message` / `x-vercel-mitigated`。因此可选探针挂住时，已经完成的核心结果仍会在 30 秒前返回。

`rate_limits`、`usage_periods`、`combo` 是固定 `status: 200` 的合成运输壳，真实 HTTP / timeout 状态留在各子项；解析器和 `RefreshPolicy` 都展开子 status。单项 401 / 503 不得压掉另一项已完成的 200；所有子项失败时仍分别还原为登录失效、HTTP 错误或请求超时。

**文件名**：Claude 目录文件是 `claude-ai.md`，不要写成 `claude.md` / `CLAUDE.md`。macOS 默认大小写不敏感，后者会被 Claude Code 当成指令文件加载。

| 供应商 | 目录文件 | 官网 Usage 页 |
|---|---|---|
| Claude | [claude-ai.md](claude-ai.md) | https://claude.ai/settings/usage |
| ChatGPT | [chatgpt.md](chatgpt.md) | https://chatgpt.com/#settings（订阅/用量入口） |
| Grok | [grok.md](grok.md) | https://grok.com/?open=settings（Settings → Usage） |
| Cursor | [cursor.md](cursor.md) | https://cursor.com/dashboard/usage |
| DeepSeek | [deepseek.md](deepseek.md) | https://platform.deepseek.com/usage |
| 智谱 | [zhipu.md](zhipu.md) | https://open.bigmodel.cn/coding-plan/personal/usage |
| Kimi | [kimi.md](kimi.md) | https://www.kimi.com/code/console |
| MiniMax（国内） | [minimax.md](minimax.md) | https://platform.minimaxi.com/console/usage |
| MiniMax（国际） | [minimax.md](minimax.md) | https://platform.minimax.io/console/usage |
| 即梦 | [jimeng.md](jimeng.md) | https://jimeng.jianying.com/ai-tool/home（个人页路径含运行时 sec_uid，禁止写死） |
| OpenCode | [opencode.md](opencode.md) | https://opencode.ai/workspace/<wrk_id>（首页余额；`/go` 三窗口；入口 `/auth` 302 到 workspace） |
| LongCat | [longcat.md](longcat.md) | https://longcat.chat/platform/usage |
| 小米 MiMo | [mimo.md](mimo.md) | https://platform.xiaomimimo.com/#/console/balance |
| Qoder | [qoder.md](qoder.md) | https://qoder.com/account/usage |
| Perplexity | [perplexity.md](perplexity.md) | https://www.perplexity.ai/account/usage |
| Augment | [augment.md](augment.md) | https://app.augmentcode.com/account/subscription |
| Abacus AI | [abacus.md](abacus.md) | https://apps.abacus.ai/ |
| T3 Chat | [t3chat.md](t3chat.md) | https://t3.chat/settings/subscription |
| Notion AI | [notion.md](notion.md) | https://app.notion.com/（Settings → Notion AI → Usage） |
| Ollama Cloud | [ollama.md](ollama.md) | https://ollama.com/settings |
| StepFun | [stepfun.md](stepfun.md) | https://platform.stepfun.com/plan-usage |
| Copilot | [copilot.md](copilot.md) | https://github.com/settings/copilot |
| Gemini | [gemini.md](gemini.md) | https://gemini.google.com/app |
| Antigravity | [antigravity.md](antigravity.md) | https://antigravity.google/ |
| Kiro | [kiro.md](kiro.md) | https://app.kiro.dev/ |
| 自定义 | [custom.md](custom.md) | 用户自填 HTTPS URL，或选 5 个 Bearer 预设（Kimi API 国际/中国、Crof 实验性、Poe、OpenRouter Key）；字段勾选 + 自定义展示名；无图标时才从 origin 首页解析 favicon |

## 官方套餐标价表

首页卡片展开后显示「套餐 + 周期标签（月/年）+ 对应金额」。价格来源是静态标价，不是计费接口实时价；代码侧镜像在 `PlanCatalog.swift`，两处需同步。年付显示年金额，月付显示月金额。2026-08 校准：

| 供应商 | 套餐（App 内展示名） | 月标价 | 年标价 |
|---|---|---|---|
| Claude | Claude Pro | $20 | $200 |
| Claude | Claude Max 5x | $100 | $1200（无官网年价，按 12 个月合计） |
| Claude | Claude Max 20x | $200 | $2400（无官网年价，按 12 个月合计） |
| ChatGPT | ChatGPT Plus | $20 | $200 |
| ChatGPT | ChatGPT Pro 5x | $100 | $1200（无官网年价，按 12 个月合计） |
| ChatGPT | ChatGPT Pro | $200 | $2400（无官网年价，按 12 个月合计） |
| ChatGPT | ChatGPT Team | $30 | $300 |
| Grok | SuperGrok | $30 | $360（无官网年价，按 12 个月合计） |
| Grok | SuperGrok Heavy | $300 | $3600（无官网年价，按 12 个月合计） |
| Grok | X Premium+ | $40 | $480（无官网年价，按 12 个月合计） |
| Cursor | Cursor Pro | $20 | $192 |
| Cursor | Cursor Pro+ | $60 | $720（无官网年价，按 12 个月合计） |
| Cursor | Cursor Ultra | $200 | $2400（无官网年价，按 12 个月合计） |
| Cursor | Cursor Teams | $40 | $480（无官网年价，按 12 个月合计） |
| 智谱 | Coding Plan Lite | ¥118 | ¥991（glm-coding 连续包年 7 折） |
| 智谱 | Coding Plan Pro | ¥538 | ¥4,519（glm-coding 连续包年 7 折） |
| 智谱 | Coding Plan Max | ¥1078 | ¥9,055（glm-coding 连续包年 7 折） |
| Kimi | Kimi Code Moderato | ¥19 | ¥228 |
| Kimi | Kimi Code Allegretto | ¥159 | ¥1,908 |
| Kimi | Kimi Code Allegro | ¥99 | ¥1,188 |
| Kimi | Kimi Code Vivace | ¥199 | ¥2,388 |
| MiniMax（国内） | Token Plan Plus | ¥49 | ¥490 |
| MiniMax（国内） | Token Plan Max | ¥119 | ¥1,190 |
| MiniMax（国内） | Token Plan Ultra | ¥469 | ¥4,690 |
| OpenCode | OpenCode Go | $10 | $120（无官网年价，按 12 个月合计） |

DeepSeek、即梦、OpenCode Zen 余额为预充值/积分，无订阅价（OpenCode Black 档位不收录），不展示周期标签和价格徽章。MiniMax 国际站的标价尚未通过官网 / 真机校准，即使套餐名与国内站相同也不展示静态价格或周期徽章。未收录的套餐（Free、游客额度、企业定制价等）不展示价格。周期标签仅在展开卡片、且有标价时出现，紧贴金额前方。

补充口径（与 `PlanCatalog.swift` 一致）：

- 智谱按订阅接口返回的 `productId` 匹配 SKU 表（`zhipuSKUs`），覆盖当前 glm-coding、V3、V2 三代月/季/年价；上表只列当前月价与年价，季付与历史版本以代码为准。
- Claude 通过 App Store 内购（`billingSource == "app_store"`）时显示内购价：Max 5x $124.99、Max 20x $249.99。
- 无官网年价的套餐年价 = 月价 × 12 合成；季付 = 月价 × 3。

# Perplexity（perplexity.ai）用量接口目录

- **官网 Usage 页**：`https://www.perplexity.ai/account/usage`
- **登录入口 / 探针页**：`loginURL` 与 `probeURL` 都是上述 Usage 页，接口与页面同源。
- **鉴权**：本机 WebKit Cookie（NextAuth / AuthJS session）。站内 `fetch(..., { credentials: 'include' })` 自动携带，包括浏览器管理的分片 Cookie；App 不读取、不拼接、不保存 session token，也不使用 Bearer / API key。
- **Cookie 域**：`perplexity.ai`。退出登录清该域 WebKit 数据。
- **keyProbe**：`credits`。
- **标价**：本轮没有核对官方订阅标价，`PlanCatalog` 不收录 Perplexity；`planName` 只按 recurring 额度推断，`billingCycle` 恒为 nil。
- **接入范围**：月度 recurring、购买 purchased、促销 promotional 三个 credit 池，当前可用余额和月度续期时间。不接请求明细、模型统计或账号身份。
- **代码**：探针 `ProviderScripts.perplexity`，解析 `PerplexityParser`，fixture `perplexity_credits.json` / `perplexity_expired_promo.json` / `perplexity_empty.json` / `perplexity_purchased_max.json` / `perplexity_null_expiry.json`，测试 `PerplexityParserTests`。
- **观测**：2026-08-28 **按 CodexBar 实现整理，待真机确认**。字段与算法来自 `reference/CodexBar/Sources/CodexBarCore/Providers/Perplexity/` 及其测试；本 App 尚未用 iOS 真机登录态核对接口版本、Cookie 行为或数值语义。

## 接口表

| 探针名 | 请求 | 鉴权 / 用途 |
|---|---|---|
| `credits` | `GET /rest/billing/credits?version=2.18&source=default` | **必需**。同源 Cookie；返回所有额度池、余额与续期时间。 |

请求头仅加 `Accept: application/json`，且 `noAuth: true`（禁止 helper 注入 leftover Bearer）。`Origin` / `Referer` / `User-Agent` 由 WKWebView 当前页面自动提供。脚本使用 `credentials: include`，不手动构造 Cookie header，因此 AuthJS / NextAuth 的 `.0`、`.1` 等分片也由浏览器自动处理。

## 响应形状

以下为按 CodexBar 实现整理的脱敏样例，待真机确认：

```json
{
  "balance_cents": 23065,
  "renewal_date_ts": 1788000000,
  "current_period_purchased_cents": 3000,
  "credit_grants": [
    { "type": "recurring", "amount_cents": 10000, "expires_at_ts": 1788000000 },
    { "type": "purchased", "amount_cents": 8000 },
    { "type": "promotional", "amount_cents": 4000, "expires_at_ts": 1789000000 }
  ],
  "total_usage_cents": 14000
}
```

| 字段 | 语义 |
|---|---|
| `balance_cents` | 当前可用金额，单位**美分**；不是各 grant 的总量字段。 |
| `renewal_date_ts` | 月度 recurring 的 Unix epoch **秒**；只接受 `(0, 253402300799]`（最晚 9999-12-31T23:59:59Z），越界 / 非有限 / Bool 时不写 Date。 |
| `current_period_purchased_cents` | purchased 的顶层兼容值。 |
| `credit_grants` | 数组；只识别 `recurring`、`purchased`、`promotional`。未知 type 跳过。 |
| `amount_cents` | 对应池额度，有限非负美分。 |
| `expires_at_ts` | grant 过期时间，Unix epoch 秒，同样只接受 `(0, 253402300799]`；promotional 只有严格晚于 `now` 才有效。 |
| `total_usage_cents` | 本周期累计消费，美分；由客户端按瀑布顺序分摊。 |

所有金额 / 用量必须是有限非负数；已识别 grant 的金额非法或同类加总溢出时，整份必需响应判异常，不能把 NaN / Infinity 写进快照。数值字段可兼容 JSON number 与数值字符串，但 **Bool 永远不是数值**：必须显式拒绝 Swift/Objective-C 的 `Bool → NSNumber` 桥接，不能让 `true` 变成 1 美分、`false` 变成 0。时间字段按上面的可展示范围单独处理。

## 解析口径（`PerplexityParser`）

### 额度池与瀑布分摊

1. `recurringTotal` = 所有 recurring grant 的安全求和。
2. `purchasedFromGrants` = 所有 purchased grant 的安全求和；`purchasedTotal = max(purchasedFromGrants, current_period_purchased_cents)`，避免两种来源重复相加。
3. `promotionalTotal` = 所有**未过期** promotional grant 的安全求和；过期项完全过滤。
4. `total_usage_cents` 依次消耗 recurring → purchased → promotional：每池 `used = min(尚未分配用量, poolTotal)`；超过三个池总量的部分忽略，不制造负剩余或超过 100% 的条。

### 指标

稳定顺序：`monthly` > `purchased` > `promotional` > `balance`。

- 有 recurring 池（`total > 0`）才产 `monthly`「月度额度」，`remaining = total - used`，`usedPercent = used / total × 100`，`resetsAt` 取合法 `renewal_date_ts`，`pinned: true`。
- 有 purchased 池（`total > 0`）才产 `purchased`「购买额度」，同样写 used / remaining / total / percent；不设重置时间，`pinned` 留空。
- 有未过期 promotional 池（`total > 0`）才产 `promotional`「赠送额度」；`resetsAt` 取所有有效 promotional grant 中**最近的未来过期时间**，详情同时说明过期日，`pinned` 留空。
- 不为不存在的池制造 `0 / 0`、`usedPercent: 100`、`pinned: true` 的空条；这符合本 App「无实际用量默认隐藏」约定，也避免只有 purchased / promotional 时出现假的月度耗尽条。
- 余额总是单独产 `balance`「余额」：`amount = balance_cents / 100`、`currency = "USD"`、`pinned: true`。它表示 API 给出的当前可用金额，不参与三个 grant 池的 total / remaining 计算，也不把 grant 总量重复当余额。
- 即使三种 grant 都为空，只要必需响应与余额合法，仍有余额核心指标并返回 `.ok`。

### 套餐名

只按 recurring 总额度推断：

| recurringTotal（美分） | `planName` |
|---:|---|
| `<= 0` | nil |
| `< 5000` | `Perplexity Pro` |
| `>= 5000` | `Perplexity Max` |

这是 CodexBar 的客户端启发式，不是 API 返回的真实 tier；待真机与官网套餐核对。快照不写标价、周期或到期提醒。

### 状态与防御

| 情况 | 状态 |
|---|---|
| `results` 为空 | `.error("未获取到任何响应")` |
| `credits` 缺失 | `.error("未获取到额度响应")` |
| HTTP 401 / 403 | `.needsLogin` |
| 其它非 2xx / 网络失败 | `ProbeResult.failureStatus` |
| body 不是对象、必需顶层数值 / 数组缺失或非法、加总溢出 | `.error("额度数据异常")` |
| 合法响应至少产出余额核心指标 | `.ok` |

- `renewal_date_ts` 缺失、Bool、非有限、非正数或超过 9999 年上界时只丢重置时间，不让非法 Date 进入快照；其余必需额度仍可用。
- grant 提供了 `expires_at_ts`，但它为 `null`、Bool、非有限、非正数或超过上界时，**只丢该 grant**；不能把坏时间静默当作「永不过期」。只有 key 本身不存在的 promotional 才视为不自动过期，符合 CodexBar 口径。
- 任何成功 / 失败快照都必须可由 `JSONEncoder` 编码。

## 隐私与坑

- session Cookie 可能是 HttpOnly 或分片；WKWebView 同源 `fetch` 会自动携带，App 不应尝试把它们抄到 Swift 或落盘。
- 全部金额字段单位是**美分**。grant 的 `amount_cents` 用于额度池，只有 `balance_cents` 在余额指标中除以 100 转成 USD；不要对池 totals 再除 100，否则 remaining / percent 会错位。
- API 不给百分比，必须用安全分摊后的 used / total 本地计算。

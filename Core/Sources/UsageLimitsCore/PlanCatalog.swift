import Foundation

/// 各家套餐的官方标价表。
/// 这是已知官网价目页的静态快照，不是计费接口实时价；
/// 数据来源与维护说明见仓库 `providers/` 目录（价格漂移时先改目录再改这里）。
public enum PlanCatalog {
    /// 套餐展示名（与各解析器产出的 planName 一致）→ 月标价（USD）。
    private static let monthlyUSD: [String: Int] = [
        // Claude（claude.ai）
        "Claude Pro": 20,
        "Claude Max 5x": 100,
        "Claude Max 20x": 200,
        // 2026-08 官网 Team 席位价：Standard $25/席位/月按年付（$30 月付）、Premium $125/席位/月按年付（$150 月付）
        "Claude Team Standard": 30,
        "Claude Team Premium": 150,
        // ChatGPT（chatgpt.com）；Pro 5x = $100（5x Plus），plain Pro = $200（20x Plus）
        "ChatGPT Plus": 20,
        "ChatGPT Pro 5x": 100,
        "ChatGPT Pro": 200,
        "ChatGPT Team": 30,
        // Grok（grok.com）
        "SuperGrok": 30,
        "SuperGrok Heavy": 300,
        "X Premium+": 40,
        // Cursor（cursor.com）
        "Cursor Pro": 20,
        "Cursor Pro+": 60,
        "Cursor Ultra": 200,
        "Cursor Teams": 40,
        // OpenCode（opencode.ai）；Go 无年付，年价按 12 个月合成。Zen 余额 / Black 不收录。
        "OpenCode Go": 10,
    ]

    /// 已证实的年标价（USD，按年一次性支付的金额）。
    private static let yearlyUSD: [String: Int] = [
        "Claude Pro": 200,
        "Claude Team Standard": 300,
        "Claude Team Premium": 1500,
        "ChatGPT Plus": 200,
        "ChatGPT Team": 300,
        "Cursor Pro": 192,
    ]

    /// 非美元标价（人民币套餐）。与 monthlyUSD 互斥，命中则直接返回展示文案。
    private static let monthlyDisplay: [String: String] = [
        "Coding Plan Lite": "¥118",
        "Coding Plan Pro": "¥538",
        "Coding Plan Max": "¥1078",
        "Kimi Code Moderato": "¥19",
        "Kimi Code Allegretto": "¥159",
        "Kimi Code Allegro": "¥99",
        "Kimi Code Vivace": "¥199",
        "Token Plan Plus": "¥49",
        "Token Plan Max": "¥119",
        "Token Plan Ultra": "¥469",
    ]

    /// 已证实的年标价（人民币，按年一次性支付的金额）。
    /// 智谱当前档来自 2026-08 glm-coding「连续包年 7 折」页（年付总额 = 月价×12×0.7）。
    private static let yearlyDisplay: [String: String] = [
        "Coding Plan Lite": "¥991",
        "Coding Plan Pro": "¥4,519",
        "Coding Plan Max": "¥9,055",
        "Kimi Code Moderato": "¥228",
        "Kimi Code Allegretto": "¥1,908",
        "Kimi Code Allegro": "¥1,188",
        "Kimi Code Vivace": "¥2,388",
        "Token Plan Plus": "¥490",
        "Token Plan Max": "¥1,190",
        "Token Plan Ultra": "¥4,690",
    ]

    /// 当前智谱连续包季（8 折 × 3 个月）。
    private static let quarterlyDisplay: [String: String] = [
        "Coding Plan Lite": "¥283",
        "Coding Plan Pro": "¥1,291",
        "Coding Plan Max": "¥2,587",
    ]

    /// 智谱 glm-coding / subscribe-overview 商品表（productId → 档位 + 周期 + 该周期标价）。
    /// 历史 V2 年付 Pro（product-733034）标价 ¥2,400，与当前页 7 折年付不同。
    private static let zhipuSKUs: [String: (plan: String, cycle: BillingCycle, price: String)] = [
        // 当前 glm-coding（连续包月 / 包季 8 折 / 包年 7 折）
        "product-a490e5": ("Coding Plan Lite", .monthly, "¥118"),
        "product-92f659": ("Coding Plan Pro", .monthly, "¥538"),
        "product-5b41f6": ("Coding Plan Max", .monthly, "¥1,078"),
        "product-e90ff2": ("Coding Plan Lite", .quarterly, "¥283"),
        "product-f176ba": ("Coding Plan Pro", .quarterly, "¥1,291"),
        "product-6a48ac": ("Coding Plan Max", .quarterly, "¥2,587"),
        "product-86305b": ("Coding Plan Lite", .yearly, "¥991"),
        "product-6b9bb7": ("Coding Plan Pro", .yearly, "¥4,519"),
        "product-c51c35": ("Coding Plan Max", .yearly, "¥9,055"),
        // V3
        "product-02434c": ("Coding Plan Lite", .monthly, "¥49"),
        "product-1df3e1": ("Coding Plan Pro", .monthly, "¥149"),
        "product-2fc421": ("Coding Plan Max", .monthly, "¥469"),
        "product-b8ea38": ("Coding Plan Lite", .quarterly, "¥132"),
        "product-fef82f": ("Coding Plan Pro", .quarterly, "¥402"),
        "product-5d3a03": ("Coding Plan Max", .quarterly, "¥1,266"),
        "product-70a804": ("Coding Plan Lite", .yearly, "¥470"),
        "product-5643e6": ("Coding Plan Pro", .yearly, "¥1,430"),
        "product-d46f8b": ("Coding Plan Max", .yearly, "¥4,502"),
        // V2（概览页「历史版本」；年付按年总额）
        "product-bf2b62": ("Coding Plan Lite", .monthly, "¥40"),
        "product-a6ef45": ("Coding Plan Pro", .monthly, "¥200"),
        "product-1a52ed": ("Coding Plan Max", .monthly, "¥400"),
        "product-85eab1": ("Coding Plan Lite", .quarterly, "¥120"),
        "product-fc5155": ("Coding Plan Pro", .quarterly, "¥600"),
        "product-6e1f0f": ("Coding Plan Max", .quarterly, "¥1,200"),
        "product-060148": ("Coding Plan Lite", .yearly, "¥480"),
        "product-733034": ("Coding Plan Pro", .yearly, "¥2,400"),
        "product-7fd668": ("Coding Plan Max", .yearly, "¥4,800"),
    ]

    public static func zhipuSKU(_ productID: String?) -> (plan: String, cycle: BillingCycle, price: String)? {
        guard let productID, !productID.isEmpty else { return nil }
        return zhipuSKUs[productID]
    }

    /// iOS 内购（App Store）月标价，仅收录已证实档位；无对应条目时回落官网价。
    /// 内购价高于官网价（苹果渠道抽成），来源见 providers/ 目录。
    private static let appStoreMonthlyUSD: [String: Double] = [
        "Claude Max 5x": 124.99,
        "Claude Max 20x": 249.99,
    ]

    /// 官方标价的展示文本（如 "$300" / "¥1,190"）。
    /// 年付取年金额，月付取月金额；未知套餐 / 免费档 / 游客态返回 nil。
    /// appStoreBilling 为 true 时优先取 iOS 内购价（如 Max 20x → "$249.99"）。
    public static func listPrice(
        planName: String?,
        billingCycle: BillingCycle? = nil,
        appStoreBilling: Bool = false,
        productID: String? = nil,
        provider: ProviderID? = nil
    ) -> String? {
        // 国内 / 国际站可能返回同名 Token Plan；国际价未校准前禁用全部静态价，
        // 避免未来其它套餐名碰撞时误显示 CNY / USD 价格。
        if provider == .minimaxGlobal { return nil }
        if let sku = zhipuSKU(productID) { return sku.price }
        guard let raw = planName else { return nil }
        var name = raw
        var cycle = billingCycle ?? .monthly
        if name.hasSuffix(" 年") {
            name = String(name.dropLast(2))
            if billingCycle == nil { cycle = .yearly }
        }
        if cycle == .yearly {
            if let display = yearlyDisplay[name] { return display }
            if let usd = yearlyUSD[name] { return "$\(usd)" }
            if let monthly = parseDisplayAmount(monthlyDisplay[name]) {
                return formatCNY(monthly * 12)
            }
            if appStoreBilling, let usd = appStoreMonthlyUSD[name] {
                return String(format: "$%.2f", usd * 12)
            }
            if let usd = monthlyUSD[name] { return "$\(usd * 12)" }
            return nil
        }
        if cycle == .quarterly {
            if let display = quarterlyDisplay[name] { return display }
            if let monthly = parseDisplayAmount(monthlyDisplay[name]) {
                return formatCNY(monthly * 3)
            }
            if let usd = monthlyUSD[name] { return "$\(usd * 3)" }
            return nil
        }
        if let display = monthlyDisplay[name] { return display }
        if appStoreBilling, let usd = appStoreMonthlyUSD[name] {
            return String(format: "$%.2f", usd)
        }
        guard let usd = monthlyUSD[name] else { return nil }
        return "$\(usd)"
    }

    /// 有官方标价的付费套餐才画周期标签。
    public static func hasListPrice(_ planName: String?, provider: ProviderID? = nil) -> Bool {
        listPrice(planName: planName, provider: provider) != nil
    }

    public static func formatCNY(_ amount: Double) -> String {
        guard let n = JSONHelp.intRounded(amount) else { return "¥—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return "¥" + (formatter.string(from: NSNumber(value: n)) ?? "\(n)")
    }

    private static func parseDisplayAmount(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let digits = raw.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        return Double(digits)
    }
}

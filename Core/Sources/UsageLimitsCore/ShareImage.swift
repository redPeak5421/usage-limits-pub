import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif
import Foundation
import ImageIO

/// App Store 二维码：打包一张静态图（URL 稳定、离线可用）。
/// 资源缺失时用同一常量 URL 走 Core Image 现生成，行为等价，不是第二套产品要求。
public enum ShareChrome {
    public static let appTitle = "Usage Limits"
    /// App Store 记录的 Apple ID（数字）。
    public static let appStoreID = "6808912101"
    /// 按 Apple ID 直达本 App 的商店页：全局唯一，不随名称、搜索结果或地区变化。
    /// 改 URL 必须同步重生成 `Resources/AppStoreQR.png`（`ShareImageTests` 会解码核对）。
    public static let appStoreURL = URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    public static let weixinURL = URL(string: "weixin://")!

    /// 包内静态 QR（`AppStoreQR.png`）。
    public static func bundledQRImage() -> CGImage? {
        guard let url = Bundle.module.url(forResource: "AppStoreQR", withExtension: "png") else {
            return nil
        }
        return cgImage(contentsOf: url)
    }

    /// 对同一 App Store URL 做 Core Image 二维码（资源缺失或单测兜底）。
    /// watchOS 没有 Core Image，只走打包好的静态图。
    public static func generatedQRImage(dimension: Int = 320) -> CGImage? {
        #if canImport(CoreImage)
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(appStoreURL.absoluteString.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scale = CGFloat(dimension) / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.createCGImage(scaled, from: scaled.extent)
        #else
        return nil
        #endif
    }

    public static func qrImage(dimension: Int = 320) -> CGImage? {
        bundledQRImage() ?? generatedQRImage(dimension: dimension)
    }

    public static func cgImage(contentsOf url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// 分享预览上可切换、并持久化的四项：隐藏更新时间 / 隐藏未使用指标 / 用量条同色 / 彩虹光晕。
public struct ShareComposeOptions: Codable, Equatable, Sendable {
    public var hideUpdateTime: Bool
    public var hideUnusedMetrics: Bool
    public var sameColorBars: Bool
    public var rainbowGlow: Bool
    /// 隐藏底部 App 图标 + 二维码整行（需组合键解锁后才出现设置开关）。
    public var hideBrandRow: Bool
    /// 计量条下带实例明细：重置倒计时、已用金额等（只画实例实际有的，不预设）。
    public var showMetricDetails: Bool

    public init(
        hideUpdateTime: Bool = false,
        hideUnusedMetrics: Bool = true,
        sameColorBars: Bool = false,
        rainbowGlow: Bool = true,
        hideBrandRow: Bool = false,
        showMetricDetails: Bool = false
    ) {
        self.hideUpdateTime = hideUpdateTime
        self.hideUnusedMetrics = hideUnusedMetrics
        self.sameColorBars = sameColorBars
        self.rainbowGlow = rainbowGlow
        self.hideBrandRow = hideBrandRow
        self.showMetricDetails = showMetricDetails
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideUpdateTime = try c.decodeIfPresent(Bool.self, forKey: .hideUpdateTime) ?? false
        hideUnusedMetrics = try c.decodeIfPresent(Bool.self, forKey: .hideUnusedMetrics) ?? true
        sameColorBars = try c.decodeIfPresent(Bool.self, forKey: .sameColorBars) ?? false
        // 老版本存的 JSON 没有这个键：默认开启。
        rainbowGlow = try c.decodeIfPresent(Bool.self, forKey: .rainbowGlow) ?? true
        hideBrandRow = try c.decodeIfPresent(Bool.self, forKey: .hideBrandRow) ?? false
        showMetricDetails = try c.decodeIfPresent(Bool.self, forKey: .showMetricDetails) ?? false
    }
}

/// 一条用量：标签 + 进度条 + 数值（首页卡片同款）。
public struct ShareMeter: Equatable, Sendable {
    public var label: String
    public var valueText: String
    public var usedPercent: Double?
    public var isUnused: Bool
    /// 计量条下左侧的明细（如「已用 ¥12.3 / ¥50」），nil = 该实例没有。
    public var detailText: String?
    /// 计量条下右侧的重置文案（含前缀），nil = 该指标没有重置时间。
    public var resetText: String?

    public init(
        label: String,
        valueText: String,
        usedPercent: Double?,
        isUnused: Bool,
        detailText: String? = nil,
        resetText: String? = nil
    ) {
        self.label = label
        self.valueText = valueText
        self.usedPercent = usedPercent
        self.isUnused = isUnused
        self.detailText = detailText
        self.resetText = resetText
    }

    /// 明细行是否有内容可画。
    public var hasCaption: Bool {
        detailText != nil || resetText != nil
    }
}

/// 分享画布上会画出来的结构化内容（测试断言用，也是渲染输入）。
public struct ShareCardModel: Equatable, Sendable {
    public var title: String
    public var appStoreURL: String
    public var includesAppIcon: Bool
    public var includesQR: Bool
    public var includesSubtitle: Bool
    public var brandAtBottom: Bool
    public var options: ShareComposeOptions
    public var sections: [Section]
    /// 画布顶部预留空白（pt），全屏查看时避开刘海 / 灵动岛。
    public var topSafeReserve: CGFloat
    /// 画布上实际绘制的全部可见字符串（标题、套餐、指标名、金额/百分比）。
    public var visibleTexts: [String]
    /// 百分比展示口径（条随消耗增长还是缩短）；数值文本在合成时已按此口径写好。
    public var displayMode: UsageDisplayMode = .used
    public struct Section: Equatable, Sendable {
        public var provider: ProviderID
        public var providerName: String
        public var planName: String?
        /// 周期短标签（月 / 季 / 年，已本地化）；只有「明细」开着且套餐查得到标价才有。
        public var planCycleTag: String?
        /// 该周期的官方标价；nil = 标价表没收录，套餐行退回纯文本。
        public var planPrice: String?
        public var meters: [ShareMeter]
        public var updateTime: String?
        public var includesLogo: Bool
        /// 该条目（账号）解析后的主题色；nil 回落内置品牌色。
        public var tint: BrandTint?
        public var isCustom: Bool
        public var lines: [String] { meters.map { "\($0.label)  \($0.valueText)" } }

        public var resolvedTint: BrandTint {
            tint ?? (isCustom ? TintResolver.customDefault : provider.builtinTint)
        }

        /// 套餐行画成首页同款胶囊：套餐名恒有一枚，「明细」开着才多出周期与标价。
        public var planBadges: [String] {
            guard let planName else { return [] }
            return [planName, planCycleTag, planPrice].compactMap { $0 }
        }

        public init(
            provider: ProviderID,
            providerName: String,
            planName: String?,
            planCycleTag: String? = nil,
            planPrice: String? = nil,
            meters: [ShareMeter],
            updateTime: String?,
            includesLogo: Bool,
            tint: BrandTint?,
            isCustom: Bool = false
        ) {
            self.provider = provider
            self.providerName = providerName
            self.planName = planName
            self.planCycleTag = planCycleTag
            self.planPrice = planPrice
            self.meters = meters
            self.updateTime = updateTime
            self.includesLogo = includesLogo
            self.tint = tint
            self.isCustom = isCustom
        }
    }
}

/// 首页一张可见卡片对应的分享条目。同供应商多账号用账号 UUID 区分，
/// 不能用 `ProviderSnapshot.id`（它只是服务商 rawValue，会撞车）。
public struct ShareCardInput: Identifiable, Equatable, Sendable {
    public var id: String
    public var snapshot: ProviderSnapshot
    public var title: String
    public var tint: BrandTint
    public var customLogoData: Data?

    public init(
        id: String,
        snapshot: ProviderSnapshot,
        title: String,
        tint: BrandTint,
        customLogoData: Data? = nil
    ) {
        self.id = id
        self.snapshot = snapshot
        self.title = title
        self.tint = tint
        self.customLogoData = customLogoData
    }

    public static func accountID(_ accountID: UUID) -> String { accountID.uuidString }

    public static func demoID(_ provider: ProviderID) -> String { "demo.\(provider.rawValue)" }

    /// 按首页目录顺序取出勾选项；`ids` 无序，结果跟 catalog 走。
    public static func picked(from catalog: [ShareCardInput], ids: Set<String>) -> [ShareCardInput] {
        catalog.filter { ids.contains($0.id) }
    }
}

/// 从快照合成分享图：单服务商或全部展开。不依赖 UIKit，App / 单测共用。
public enum ShareImageComposer {
    public static func model(
        snapshots: [ProviderSnapshot],
        expanded: Bool,
        language: AppLanguage,
        hasIcon: Bool,
        hasQR: Bool,
        options: ShareComposeOptions = ShareComposeOptions(),
        logoProviders: Set<ProviderID> = [],
        titles: [String] = [],
        tints: [BrandTint?] = [],
        displayMode: UsageDisplayMode = .used,
        resetTimeStyle: ResetTimeStyle = .countdown,
        now: Date = Date()
    ) -> ShareCardModel {
        var sections: [ShareCardModel.Section] = []
        var texts: [String] = [ShareChrome.appTitle]
        for (index, snap) in snapshots.enumerated() {
            var meters: [ShareMeter] = []
            if snap.isPrepaidCard {
                let currency = snap.currency
                if let balance = snap.metrics.first(where: { $0.id == "balance" }) {
                    let value = MoneyFormat.string(balance.amount ?? 0, currency: currency ?? balance.currency)
                    meters.append(ShareMeter(
                        label: L10n.tr("deepseek.balance", language),
                        valueText: value, usedPercent: nil, isUnused: false
                    ))
                }
                if let spent = snap.metrics.first(where: { $0.id == "total_spent" }) {
                    let value = MoneyFormat.string(spent.amount ?? 0, currency: currency ?? spent.currency)
                    meters.append(ShareMeter(
                        label: L10n.tr("deepseek.spent", language),
                        valueText: value, usedPercent: nil, isUnused: false
                    ))
                }
                if expanded, let period = snap.timeBreakdowns?.first(where: { $0.id == "this_month" }) ?? snap.timeBreakdowns?.first {
                    let cost = MoneyFormat.string(period.cost ?? 0, currency: currency)
                    meters.append(ShareMeter(
                        label: L10n.tr(period.label, language), valueText: cost, usedPercent: nil, isUnused: false
                    ))
                }
            } else if snap.isCustom {
                if snap.status.isOK {
                    for metric in snap.metrics {
                        meters.append(ShareMeter(
                            label: L10n.tr(metric.label, language),
                            valueText: CustomUsageDisplay.valueText(
                                for: metric,
                                mode: displayMode,
                                language: language,
                                resetStyle: resetTimeStyle,
                                now: now
                            ),
                            usedPercent: nil,
                            isUnused: false
                        ))
                    }
                }
                if meters.isEmpty {
                    meters.append(ShareMeter(
                        label: L10n.tr("custom.noNumeric", language),
                        valueText: "",
                        usedPercent: nil,
                        isUnused: true
                    ))
                }
            } else {
                let metrics: [UsageMetric]
                if expanded {
                    let pool = options.hideUnusedMetrics ? snap.activeMetrics : snap.metrics
                    metrics = pool.isEmpty ? snap.metrics : pool
                } else {
                    metrics = snap.collapsedMetric.map { [$0] } ?? []
                }
                for metric in metrics {
                    // 明细与首页卡片同口径：左侧 detail、右侧重置；开关关着就不带
                    let detailText = options.showMetricDetails
                        ? metric.detail.map { L10n.trDetail($0, language) }
                        : nil
                    let resetText = options.showMetricDetails
                        ? metric.resetsAt.map {
                            L10n.tr("metric.resetPrefix", language)
                                + TimeFormat.reset($0, now: now, language: language, style: resetTimeStyle)
                        }
                        : nil
                    meters.append(ShareMeter(
                        label: L10n.metricLabel(
                            provider: snap.provider,
                            id: metric.id,
                            fallback: metric.label,
                            language: language
                        ),
                        valueText: UsagePresentation.valueText(for: metric, language: language, mode: displayMode),
                        usedPercent: metric.usedPercent,
                        isUnused: !metric.hasUsage,
                        detailText: detailText,
                        resetText: resetText
                    ))
                }
            }
            let update: String?
            if options.hideUpdateTime {
                update = nil
            } else {
                update = L10n.tr("card.updatedAt", language, TimeFormat.hourMinute(snap.fetchedAt))
            }
            let title: String = {
                if index < titles.count {
                    let raw = titles[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty { return raw }
                }
                if snap.isCustom { return "" }
                return snap.provider.localizedName(language)
            }()
            let plan = snap.planName.map { L10n.tr($0, language) }
            // 周期与标价只跟「明细」开关走，与首页展开态同一次查询口径。
            let price = options.showMetricDetails
                ? PlanCatalog.listPrice(
                    planName: snap.planName,
                    billingCycle: snap.billingCycle,
                    appStoreBilling: snap.billingSource == "app_store",
                    productID: snap.planProductID,
                    provider: snap.provider
                )
                : nil
            let cycleTag = price == nil
                ? nil
                : L10n.tr((snap.billingCycle ?? .monthly).tag, language)
            if let plan { texts.append(plan) }
            if let cycleTag { texts.append(cycleTag) }
            if let price { texts.append(price) }
            texts.append(title)
            texts.append(contentsOf: meters.map { "\($0.label)  \($0.valueText)" })
            texts.append(contentsOf: meters.flatMap { [$0.detailText, $0.resetText].compactMap { $0 } })
            if let update { texts.append(update) }
            sections.append(.init(
                provider: snap.provider,
                providerName: title,
                planName: plan,
                planCycleTag: cycleTag,
                planPrice: price,
                meters: meters,
                updateTime: update,
                includesLogo: !snap.isCustom && logoProviders.contains(snap.provider),
                tint: index < tints.count ? tints[index] : nil,
                isCustom: snap.isCustom
            ))
        }
        if !options.hideBrandRow {
            texts.append(L10n.tr("share.scanAppStore", language))
        }
        let showBrand = !options.hideBrandRow
        return ShareCardModel(
            title: ShareChrome.appTitle,
            appStoreURL: ShareChrome.appStoreURL.absoluteString,
            includesAppIcon: hasIcon && showBrand,
            includesQR: hasQR && showBrand,
            includesSubtitle: false,
            brandAtBottom: showBrand,
            options: options,
            sections: sections,
            topSafeReserve: topSafeReserve,
            visibleTexts: texts,
            displayMode: displayMode
        )
    }

    /// 画布顶部预留（pt）。全屏查看时避开刘海 / 灵动岛（约 59pt）。
    public static let topSafeReserve: CGFloat = 59
}

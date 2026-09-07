import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif
import CoreText
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

        public init(
            provider: ProviderID,
            providerName: String,
            planName: String?,
            meters: [ShareMeter],
            updateTime: String?,
            includesLogo: Bool,
            tint: BrandTint?,
            isCustom: Bool = false
        ) {
            self.provider = provider
            self.providerName = providerName
            self.planName = planName
            self.meters = meters
            self.updateTime = updateTime
            self.includesLogo = includesLogo
            self.tint = tint
            self.isCustom = isCustom
        }
    }
}

public struct ShareResult: Sendable {
    public let image: CGImage
    public let pngData: Data
    public let model: ShareCardModel

    public var options: ShareComposeOptions { model.options }

    /// 系统分享面板与「保存到相册」共用这一份 PNG。
    public var activityItems: [Data] { [pngData] }
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
            if let plan { texts.append(plan) }
            texts.append(title)
            texts.append(contentsOf: meters.map { "\($0.label)  \($0.valueText)" })
            texts.append(contentsOf: meters.flatMap { [$0.detailText, $0.resetText].compactMap { $0 } })
            if let update { texts.append(update) }
            sections.append(.init(
                provider: snap.provider,
                providerName: title,
                planName: plan,
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

    /// 已发布入口：合成 PNG + 模型 + 分享载荷。
    public static func compose(
        snapshots: [ProviderSnapshot],
        titles: [String] = [],
        tints: [BrandTint?] = [],
        expanded: Bool,
        language: AppLanguage,
        icon: CGImage? = nil,
        qr: CGImage? = nil,
        options: ShareComposeOptions = ShareComposeOptions(),
        logos: [ProviderID: CGImage] = [:],
        customMark: CGImage? = nil,
        customMarks: [CGImage?] = [],
        displayMode: UsageDisplayMode = .used,
        resetTimeStyle: ResetTimeStyle = .countdown,
        now: Date = Date()
    ) -> ShareResult {
        let qrImage = qr ?? ShareChrome.qrImage()
        let showBrand = !options.hideBrandRow
        let model = model(
            snapshots: snapshots,
            expanded: expanded,
            language: language,
            hasIcon: icon != nil && showBrand,
            hasQR: qrImage != nil && showBrand,
            options: options,
            logoProviders: Set(logos.keys),
            titles: titles,
            tints: tints,
            displayMode: displayMode,
            resetTimeStyle: resetTimeStyle,
            now: now
        )
        let image = render(
            model: model, snapshots: snapshots, icon: icon, qr: qrImage,
            logos: logos, customMark: customMark, customMarks: customMarks
        )
        let png = pngData(from: image) ?? Data()
        return ShareResult(image: image, pngData: png, model: model)
    }

    /// 保存到相册与分享到其他 App 都从同一份合成结果取 PNG。
    public static func payload(from result: ShareResult) -> (pngData: Data, activityItems: [Data]) {
        (result.pngData, result.activityItems)
    }

    private static let width: CGFloat = 390
    private static let scale: CGFloat = 3
    /// 大卡片四周留白，给阴影留出呼吸空间。
    private static let margin: CGFloat = 16
    /// 大卡片内边距。
    private static let padding: CGFloat = 16
    /// 画布顶部预留（pt）。全屏查看时避开刘海 / 灵动岛（约 59pt）。
    public static let topSafeReserve: CGFloat = 59

    private static func render(
        model: ShareCardModel,
        snapshots: [ProviderSnapshot],
        icon: CGImage?,
        qr: CGImage?,
        logos: [ProviderID: CGImage] = [:],
        customMark: CGImage? = nil,
        customMarks: [CGImage?] = []
    ) -> CGImage {
        let brandH: CGFloat = 108
        let scanH: CGFloat = 18
        let meterH: CGFloat = 36
        let labelOnlyH: CGFloat = 20
        var bodyH: CGFloat = 0
        for section in model.sections {
            bodyH += 18 + 8
            if section.planName != nil { bodyH += 16 }
            bodyH += metersHeight(section.meters, meterH: meterH, labelOnlyH: labelOnlyH) + 16
            if section.updateTime != nil { bodyH += 16 }
        }
        bodyH += CGFloat(max(model.sections.count - 1, 0)) * 10
        let showBrand = model.brandAtBottom
        // 全部内容（含扫码文案）收在一张带阴影的大圆角卡片内。
        let shellH = padding + bodyH + (showBrand ? 12 + brandH + 10 + scanH : 0) + padding
        // 顶部多留 topSafeReserve，全屏查看时刘海 / 灵动岛压在空白上，不挡首条标题。
        let topPad = model.topSafeReserve + margin
        let height = topPad + shellH + margin
        let contentX = margin + padding
        let contentW = width - (margin + padding) * 2
        let pw = Int(width * scale)
        let ph = Int(height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return fallbackImage()
        }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)

        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let shellRect = CGRect(x: margin, y: topPad, width: width - margin * 2, height: shellH)
        if model.options.rainbowGlow {
            drawRainbowGlow(ctx, around: shellRect, radius: 24)
        }
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -4 * scale),
            blur: 8 * scale,
            color: CGColor(gray: 0.3, alpha: 0.14)
        )
        fillRoundRect(ctx, shellRect, 24, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.restoreGState()

        var y = topPad + padding

        for (index, section) in model.sections.enumerated() {
            let metersH = metersHeight(section.meters, meterH: meterH, labelOnlyH: labelOnlyH)
            let cardH = 18 + 8 + (section.planName != nil ? 16 : 0)
                + metersH + 16
                + (section.updateTime != nil ? 16 : 0)
            fillRoundRect(ctx, CGRect(x: contentX, y: y, width: contentW, height: cardH), 16,
                          CGColor(srgbRed: 0.955, green: 0.965, blue: 0.978, alpha: 1))
            let sectionTint = section.resolvedTint
            let tint = sectionTint.startCGColor
            let logoRect = CGRect(x: contentX + 16, y: y + 16, width: 18, height: 18)
            if section.isCustom {
                let mark = customMarks.indices.contains(index)
                    ? (customMarks[index] ?? customMark)
                    : customMark
                if let mark {
                    ctx.interpolationQuality = .high
                    drawUpright(mark, in: logoRect, context: ctx)
                } else {
                    fillRoundRect(ctx, CGRect(x: contentX + 16, y: y + 22, width: 8, height: 8), 4, tint)
                }
            } else if let logo = logos[section.provider] {
                ctx.interpolationQuality = .high
                drawUpright(logo, in: logoRect, context: ctx)
            } else {
                fillRoundRect(ctx, CGRect(x: contentX + 16, y: y + 22, width: 8, height: 8), 4, tint)
            }
            drawText(
                section.providerName,
                in: CGRect(x: contentX + 40, y: y + 14, width: 220, height: 22),
                size: 16, weight: .semibold, color: CGColor(gray: 0.12, alpha: 1), context: ctx
            )
            var ly = y + 38
            if let plan = section.planName {
                drawText(
                    plan, in: CGRect(x: contentX + 16, y: ly, width: contentW - 32, height: 16),
                    size: 12, weight: .medium, color: tint, context: ctx
                )
                ly += 16
            }
            if section.meters.isEmpty {
                drawText(
                    "—", in: CGRect(x: contentX + 16, y: ly, width: contentW - 32, height: 20),
                    size: 13, weight: .regular, color: CGColor(gray: 0.45, alpha: 1), context: ctx
                )
            } else {
                for meter in section.meters {
                    let sameColor = model.options.sameColorBars
                    let valueColor = sameColor ? tint : levelColor(meter.usedPercent)
                    drawText(
                        meter.label,
                        in: CGRect(x: contentX + 16, y: ly, width: 200, height: 16),
                        size: 13, weight: .regular, color: CGColor(gray: 0.2, alpha: 1), context: ctx
                    )
                    drawText(
                        meter.valueText,
                        in: CGRect(x: contentX + contentW - 16 - 80, y: ly, width: 80, height: 16),
                        size: 13, weight: .semibold, color: valueColor, context: ctx, align: .right
                    )
                    if let used = meter.usedPercent {
                        let barRect = CGRect(x: contentX + 16, y: ly + 18, width: contentW - 32, height: 6)
                        let pct = UsagePresentation.barPercent(used: used, mode: model.displayMode)
                        let fillW = max(barRect.width * CGFloat(pct / 100), pct > 0 ? 4 : 0)
                        if sameColor {
                            // 同色条：渐变按轨道完整长度铺开，已用部分只是「揭开」前段
                            drawTintedBar(ctx, barRect: barRect, fillWidth: fillW, tint: sectionTint)
                        } else {
                            fillRoundRect(ctx, barRect, 3, valueColor.copy(alpha: 0.18) ?? valueColor)
                            if fillW > 0 {
                                fillRoundRect(ctx, CGRect(x: barRect.minX, y: barRect.minY, width: fillW, height: barRect.height), 3, valueColor)
                            }
                        }
                        ly += meterH
                    } else {
                        ly += labelOnlyH
                    }
                    if meter.hasCaption {
                        // 无条指标的标签行只有 20pt，不能套用进度条行的上移量，否则两行文字重叠。
                        let captionY = ly - (meter.usedPercent == nil ? 0 : 8)
                        if let detail = meter.detailText {
                            drawText(
                                detail,
                                in: CGRect(x: contentX + 16, y: captionY, width: contentW - 32, height: 12),
                                size: 10, weight: .regular, color: CGColor(gray: 0.55, alpha: 1), context: ctx
                            )
                        }
                        if let reset = meter.resetText {
                            drawText(
                                reset,
                                in: CGRect(x: contentX + 16, y: captionY, width: contentW - 32, height: 12),
                                size: 10, weight: .regular, color: CGColor(gray: 0.45, alpha: 1), context: ctx, align: .right
                            )
                        }
                        ly += captionAdvance(for: meter)
                    }
                }
            }
            if let update = section.updateTime {
                drawText(
                    update,
                    in: CGRect(x: contentX + 16, y: ly, width: contentW - 32, height: 14),
                    size: 11, weight: .regular, color: CGColor(gray: 0.55, alpha: 1), context: ctx
                )
            }
            y += cardH + 10
        }

        if showBrand {
            y += 2
            fillRoundRect(ctx, CGRect(x: contentX, y: y, width: contentW, height: brandH), 16,
                          CGColor(srgbRed: 0.955, green: 0.965, blue: 0.978, alpha: 1))
            let iconRect = CGRect(x: contentX + 16, y: y + 26, width: 56, height: 56)
            if let icon {
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.clip()
                // 画布 y 向下；直接 draw 会把 App 图标上下颠倒，再翻一次与主屏一致。
                drawUpright(icon, in: iconRect, context: ctx)
                ctx.restoreGState()
            } else {
                fillRoundRect(ctx, iconRect, 12, CGColor(srgbRed: 0.15, green: 0.45, blue: 0.85, alpha: 1))
            }
            drawText(
                model.title, in: CGRect(x: contentX + 84, y: y + 42, width: 170, height: 26),
                size: 20, weight: .semibold, color: CGColor(gray: 0.12, alpha: 1), context: ctx
            )
            let qrRect = CGRect(x: contentX + contentW - 16 - 72, y: y + 18, width: 72, height: 72)
            if let qr {
                ctx.interpolationQuality = .none
                drawUpright(qr, in: qrRect, context: ctx)
                ctx.interpolationQuality = .default
            }
            // 扫码文案画在大卡片内部（品牌区下方），不落在卡片外。
            if let scan = model.visibleTexts.last, scan.contains("Usage Limits") || scan.contains("扫码") {
                drawText(
                    scan,
                    in: CGRect(x: contentX, y: y + brandH + 10, width: contentW, height: scanH),
                    size: 11, weight: .regular, color: CGColor(gray: 0.45, alpha: 1), context: ctx,
                    align: .center
                )
            }
        }

        return ctx.makeImage() ?? fallbackImage()
    }

    private static func levelColor(_ percent: Double?) -> CGColor {
        switch UsagePresentation.riskLevel(for: percent) {
        case .unknown: return CGColor(gray: 0.55, alpha: 1)
        case .low: return CGColor(srgbRed: 0.20, green: 0.72, blue: 0.35, alpha: 1)
        case .medium: return CGColor(srgbRed: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        case .high: return CGColor(srgbRed: 0.90, green: 0.22, blue: 0.21, alpha: 1)
        }
    }

    /// 同色用量条：渐变（或纯色）按轨道完整长度铺，填充区域只是揭开渐变前段。
    private static func drawTintedBar(
        _ ctx: CGContext, barRect: CGRect, fillWidth: CGFloat, tint: BrandTint
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [tint.startCGColor, tint.endCGColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        func draw(in clip: CGRect, alpha: CGFloat) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: clip, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.clip()
            ctx.setAlpha(alpha)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: barRect.minX, y: barRect.midY),
                end: CGPoint(x: barRect.maxX, y: barRect.midY),
                options: []
            )
            ctx.restoreGState()
        }
        draw(in: barRect, alpha: 0.18)
        if fillWidth > 0 {
            draw(
                in: CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height),
                alpha: 1
            )
        }
    }

    private static func drawRainbowGlow(_ ctx: CGContext, around rect: CGRect, radius: CGFloat) {
        let colors: [CGColor] = [
            CGColor(srgbRed: 1.00, green: 0.42, blue: 0.62, alpha: 1), // 粉
            CGColor(srgbRed: 0.72, green: 0.40, blue: 0.98, alpha: 1), // 紫
            CGColor(srgbRed: 0.30, green: 0.56, blue: 1.00, alpha: 1), // 蓝
            CGColor(srgbRed: 0.20, green: 0.82, blue: 0.90, alpha: 1), // 青
            CGColor(srgbRed: 1.00, green: 0.60, blue: 0.38, alpha: 1), // 橙
        ]
        let locations: [CGFloat] = [0, 0.28, 0.55, 0.8, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else { return }
        let cardPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let steps = 12
        let spread: CGFloat = 13
        for i in 1...steps {
            let d = spread * CGFloat(i) / CGFloat(steps)
            let outer = rect.insetBy(dx: -d, dy: -d)
            let outerPath = CGPath(
                roundedRect: outer, cornerWidth: radius + d, cornerHeight: radius + d, transform: nil
            )
            ctx.saveGState()
            ctx.addPath(outerPath)
            ctx.addPath(cardPath)
            ctx.clip(using: .evenOdd)
            ctx.setAlpha(0.07)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.restoreGState()
        }
    }

    /// 当前画布是 UIKit 坐标系（y 向下）。`CGContext.draw` 把图像底边对齐 rect.origin，
    /// 直接画会上下颠倒；绕 rect 再翻一次，方向与主屏 App 图标一致。
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// 明细占高同时用于画布测量与绘制：无条指标额外留 8pt，保持标题、明细、下一指标的间距。
    private static func captionAdvance(for meter: ShareMeter) -> CGFloat {
        meter.usedPercent == nil ? 22 : 14
    }

    private static func metersHeight(_ meters: [ShareMeter], meterH: CGFloat, labelOnlyH: CGFloat) -> CGFloat {
        if meters.isEmpty { return meterH }
        return meters.reduce(0) {
            $0 + ($1.usedPercent == nil ? labelOnlyH : meterH) + ($1.hasCaption ? captionAdvance(for: $1) : 0)
        }
    }

    private static func fillRoundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawText(
        _ string: String,
        in rect: CGRect,
        size: CGFloat,
        weight: FontWeight,
        color: CGColor,
        context: CGContext,
        align: CTTextAlignment = .left
    ) {
        let font = CTFontCreateUIFontForLanguage(weight.uiFont, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var alignment = align
        let para = withUnsafeBytes(of: &alignment) { raw in
            let settings = [CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: raw.baseAddress!
            )]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: para,
        ]
        let attr = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let typo = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x: CGFloat
        switch align {
        case .center: x = rect.midX - CGFloat(typo) / 2
        case .right: x = rect.maxX - CGFloat(typo)
        default: x = rect.minX
        }
        context.textPosition = CGPoint(x: x, y: 4)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private enum FontWeight {
        case regular, medium, semibold
        var uiFont: CTFontUIFontType {
            switch self {
            case .regular: return .system
            case .medium: return .emphasizedSystem
            case .semibold: return .emphasizedSystem
            }
        }
    }

    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func fallbackImage() -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }
}

import SwiftUI
import UIKit
import UsageLimitsCore

/// 分享画布的 SwiftUI 版本：与 `ShareImageComposer.render` 逐项对齐的同一套布局。
///
/// 存在的理由是动效——预览里切「明细」要像首页卡片展开那样，徽章从套餐胶囊旁弹出、
/// 下方每行各自滑到新位置；位图做不到这件事。几何数字全部取自 `ShareLayout`，
/// 与 CoreGraphics 渲染器共用，改一处两边同时生效。
///
/// 画布固定 `ShareLayout.canvasWidth` 宽，高度由内容撑开；调用方自己缩放。
struct ShareCardView: View {
    let model: ShareCardModel
    let assets: ShareCardAssets
    let lang: AppLanguage

    /// 徽章、指标行的 matchedGeometry 命名空间，切换「明细」时元素才有连续身份。
    @Namespace private var motion

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.topSafeReserve)
            shell
                .padding(ShareLayout.margin)
        }
        .frame(width: ShareLayout.canvasWidth)
        .background(ShareLayout.canvasBackground)
    }

    private var shell: some View {
        VStack(spacing: ShareLayout.sectionGap) {
            ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                sectionCard(section, index: index)
            }
            if model.brandAtBottom {
                brandBlock
                    .padding(.top, ShareLayout.brandTopGap - ShareLayout.sectionGap)
            }
        }
        .padding(ShareLayout.padding)
        .frame(maxWidth: .infinity)
        .background(
            // 阴影挂在背景形状上，不能挂在整棵子树上——否则每张内层卡片都会各带一份。
            RoundedRectangle(cornerRadius: ShareLayout.shellCorner, style: .continuous)
                .fill(.white)
                .shadow(color: ShareLayout.shellShadow, radius: 4, x: 0, y: 4)
        )
        .background(rainbowGlow)
    }

    // MARK: 服务商卡片

    private func sectionCard(_ section: ShareCardModel.Section, index: Int) -> some View {
        let tint = section.resolvedTint
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                mark(section, index: index, tint: tint)
                    .frame(width: ShareLayout.logoSize, height: ShareLayout.logoSize)
                Text(section.providerName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ShareLayout.titleInk)
                Spacer(minLength: 0)
            }
            .frame(height: ShareLayout.headerHeight, alignment: .center)

            if section.planName != nil {
                planBadges(section, tint: tint)
                    .frame(height: ShareLayout.planRowHeight, alignment: .top)
            }

            if section.meters.isEmpty {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundStyle(ShareLayout.mutedInk)
                    .frame(height: ShareLayout.meterHeight, alignment: .top)
            } else {
                ForEach(Array(section.meters.enumerated()), id: \.element.label) { _, meter in
                    meterRow(meter, section: section, tint: tint)
                }
            }

            if let update = section.updateTime {
                Text(update)
                    .font(.system(size: 11))
                    .foregroundStyle(ShareLayout.captionInk)
                    .frame(height: ShareLayout.updateHeight, alignment: .top)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, ShareLayout.cardInset)
        .padding(.top, ShareLayout.cardInset)
        .padding(.bottom, ShareLayout.cardBottomSlack(hasUpdate: section.updateTime != nil))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ShareLayout.cardCorner, style: .continuous)
                .fill(ShareLayout.cardFill)
        )
    }

    @ViewBuilder
    private func mark(_ section: ShareCardModel.Section, index: Int, tint: BrandTint) -> some View {
        if section.isCustom {
            if let mark = assets.customMarks.indices.contains(index) ? assets.customMarks[index] : nil {
                Image(uiImage: mark).resizable().scaledToFit()
            } else {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: ShareLayout.logoSize, weight: .semibold))
                    .foregroundStyle(tint.startColor)
            }
        } else {
            ProviderLogo(provider: section.provider, size: ShareLayout.logoSize)
        }
    }

    // MARK: 套餐徽章行

    /// 套餐名恒为一枚胶囊；「明细」打开时右侧再长出周期与标价两枚。
    /// 三枚共用同一命名空间，弹出时从套餐胶囊的位置缩放出来，与首页展开态一致。
    private func planBadges(_ section: ShareCardModel.Section, tint: BrandTint) -> some View {
        HStack(spacing: ShareLayout.badgeSpacing) {
            if let plan = section.planName {
                badge(plan, tint: tint)
                    .matchedGeometryEffect(id: "plan-\(section.providerName)", in: motion)
                    .layoutPriority(1)
            }
            if let cycle = section.planCycleTag {
                badge(cycle, tint: tint)
                    .transition(badgePop)
            }
            if let price = section.planPrice {
                badge(price, tint: tint, monospacedDigit: true)
                    .transition(badgePop)
            }
            Spacer(minLength: 0)
        }
    }

    /// 与首页 `.opacity.combined(with: .scale(scale: 0.8))` 同款弹出。
    private var badgePop: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.8))
    }

    private func badge(_ text: String, tint: BrandTint, monospacedDigit: Bool = false) -> some View {
        Text(text)
            .font(monospacedDigit
                  ? .system(size: ShareLayout.badgeFontSize, weight: .semibold).monospacedDigit()
                  : .system(size: ShareLayout.badgeFontSize, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, ShareLayout.badgePadding)
            .frame(height: ShareLayout.badgeHeight)
            .background(Capsule().fill(tint.badgeFill))
            .foregroundStyle(tint.badgeForeground)
    }

    // MARK: 指标行

    private func meterRow(
        _ meter: ShareMeter, section: ShareCardModel.Section, tint: BrandTint
    ) -> some View {
        let hasBar = meter.usedPercent != nil
        let valueColor: Color = model.options.sameColorBars
            ? tint.startColor
            : ShareLayout.levelColor(meter.usedPercent)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 8) {
                    Text(meter.label)
                        .font(.system(size: 13))
                        .foregroundStyle(ShareLayout.bodyInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(meter.valueText)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                }
                .frame(height: ShareLayout.labelHeight)

                if let used = meter.usedPercent {
                    bar(used: used, tint: tint, valueColor: valueColor)
                        .offset(y: ShareLayout.barOffsetY)
                }
            }
            .frame(height: hasBar ? ShareLayout.meterHeight : ShareLayout.labelOnlyHeight,
                   alignment: .top)

            if meter.hasCaption {
                HStack(spacing: 8) {
                    Text(meter.detailText ?? "")
                        .foregroundStyle(ShareLayout.captionInk)
                    Spacer(minLength: 0)
                    Text(meter.resetText ?? "")
                        .foregroundStyle(ShareLayout.resetInk)
                }
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(height: ShareLayout.captionTextHeight, alignment: .top)
                // 有条指标的明细压回行内 8pt 空隙里，与 CoreGraphics 的 captionY 同口径。
                .padding(.top, hasBar ? -ShareLayout.captionLift : 0)
                .frame(height: ShareLayout.captionAdvance(hasBar: hasBar), alignment: .top)
                .transition(.opacity)
            }
        }
    }

    private func bar(used: Double, tint: BrandTint, valueColor: Color) -> some View {
        let pct = UsagePresentation.barPercent(used: used, mode: model.displayMode)
        return GeometryReader { geo in
            let fill = max(geo.size.width * pct / 100, pct > 0 ? 4 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(barTint(tint: tint, valueColor: valueColor)).opacity(0.18)
                if fill > 0 {
                    Capsule()
                        .fill(barTint(tint: tint, valueColor: valueColor))
                        .frame(width: fill)
                }
            }
        }
        .frame(height: ShareLayout.barHeight)
    }

    /// 同色条：渐变按轨道完整长度铺开，已用部分只是「揭开」前段（与渲染器同一约定）。
    private func barTint(tint: BrandTint, valueColor: Color) -> LinearGradient {
        model.options.sameColorBars
            ? tint.barFill
            : LinearGradient(colors: [valueColor, valueColor], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: 底部品牌区

    private var brandBlock: some View {
        VStack(spacing: ShareLayout.scanGap) {
            HStack(spacing: 0) {
                Group {
                    if let icon = assets.appIcon {
                        Image(uiImage: icon).resizable().scaledToFill()
                    } else {
                        Color(red: 0.15, green: 0.45, blue: 0.85)
                    }
                }
                .frame(width: ShareLayout.brandIcon, height: ShareLayout.brandIcon)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.leading, ShareLayout.cardInset)

                Text(model.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ShareLayout.titleInk)
                    .padding(.leading, 12)

                Spacer(minLength: 0)

                Group {
                    if let qr = assets.qr {
                        Image(uiImage: qr).resizable().interpolation(.none)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: ShareLayout.brandQR, height: ShareLayout.brandQR)
                .padding(.trailing, ShareLayout.cardInset)
            }
            .frame(height: ShareLayout.brandHeight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ShareLayout.cardCorner, style: .continuous)
                    .fill(ShareLayout.cardFill)
            )

            Text(L10n.tr("share.scanAppStore", lang))
                .font(.system(size: 11))
                .foregroundStyle(ShareLayout.resetInk)
                .frame(height: ShareLayout.scanHeight)
        }
    }


    @ViewBuilder
    private var rainbowGlow: some View {
        if model.options.rainbowGlow {
            ZStack {
                ForEach(1...ShareLayout.glowSteps, id: \.self) { step in
                    let d = ShareLayout.glowSpread * CGFloat(step) / CGFloat(ShareLayout.glowSteps)
                    LinearGradient(
                        gradient: ShareLayout.glowGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(ShareLayout.glowLayerAlpha)
                    .padding(-d)
                    .mask(
                        RoundedRectangle(cornerRadius: ShareLayout.shellCorner + d, style: .continuous)
                            .padding(-d)
                            .overlay(
                                RoundedRectangle(cornerRadius: ShareLayout.shellCorner, style: .continuous)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )
                }
            }
        }
    }
}

/// 预览与导出都要的位图资源（服务商商标走 `ProviderLogo`，不在此列）。
struct ShareCardAssets {
    var appIcon: UIImage?
    var qr: UIImage?
    /// 按 section 顺序排列的自定义账号商标。
    var customMarks: [UIImage?] = []

    @MainActor
    static func make(customLogoData: [Data?] = []) -> ShareCardAssets {
        ShareCardAssets(
            appIcon: UIImage(named: "ShareAppIcon") ?? UIImage(named: "AppIcon"),
            qr: ShareChrome.qrImage().map { UIImage(cgImage: $0) },
            customMarks: customLogoData.map { $0.flatMap(UIImage.init(data:)) }
        )
    }
}

/// 分享画布的配色与光晕（几何常量在 Core 的 `ShareLayout`，两边共用）。
extension ShareLayout {
    static let canvasBackground = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let cardFill = Color(red: 0.955, green: 0.965, blue: 0.978)
    static let shellShadow = Color(white: 0.3, opacity: 0.14)
    static let titleInk = Color(white: 0.12)
    static let bodyInk = Color(white: 0.2)
    static let captionInk = Color(white: 0.55)
    static let resetInk = Color(white: 0.45)
    static let mutedInk = Color(white: 0.45)

    static func levelColor(_ percent: Double?) -> Color {
        switch UsagePresentation.riskLevel(for: percent) {
        case .unknown: return Color(white: 0.55)
        case .low: return Color(red: 0.20, green: 0.72, blue: 0.35)
        case .medium: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .high: return Color(red: 0.90, green: 0.22, blue: 0.21)
        }
    }

    static let glowSteps = 12
    static let glowSpread: CGFloat = 13
    static let glowLayerAlpha: Double = 0.07
    static let glowGradient = Gradient(stops: [
        .init(color: Color(red: 1.00, green: 0.42, blue: 0.62), location: 0),
        .init(color: Color(red: 0.72, green: 0.40, blue: 0.98), location: 0.28),
        .init(color: Color(red: 0.30, green: 0.56, blue: 1.00), location: 0.55),
        .init(color: Color(red: 0.20, green: 0.82, blue: 0.90), location: 0.80),
        .init(color: Color(red: 1.00, green: 0.60, blue: 0.38), location: 1),
    ])
}

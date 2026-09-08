import SwiftUI
import UIKit
import UsageLimitsCore

/// 首页侧边键（操作按钮）的屏幕菜单：按下机身左侧的操作按钮（绑定快捷指令「打开侧边菜单」）后，
/// 在左侧弹出「设置 / 分享 / 主题」，再按一次轮换选中，点菜单项确认；「主题」进三级小菜单。
/// 状态机在 `DashboardSideKeyController`，这里只画。
struct DashboardSideKeyView: View {
    @ObservedObject var controller: DashboardSideKeyController
    /// 场景主题（轮盘 / 螺旋）；平铺为 nil，用系统色。
    let theme: DashboardSceneTheme?
    let currentTheme: DashboardTheme
    /// 启动参数 `--open-side-key`：出现即弹出一级菜单（自动化截图用）。
    let opensMenuOnAppear: Bool

    /// 操作按钮在机身左侧、约整窗高度 22% 处（iPhone 15 Pro 起竖持）；菜单中心对齐到它。
    private static let actionButtonScreenRatio: CGFloat = 0.22

    /// 锚定基准取 App 自己那扇窗口的高度，不再取 `UIScreen`：iPad 分屏 / Stage Manager 下窗口比屏幕矮，
    /// 按整屏算会把菜单顶到窗口外（再被下面的 90pt 夹紧贴在边上）。全屏时窗口高 = 屏高，iPhone 上取值与以前一致。
    /// 不能直接拿 `GeometryReader` 的容器高度当基准：本视图的容器是导航栏与 Home 条之间的内容区，
    /// 比窗口矮一截，按它算 22% 会把菜单整体下移，iPhone 上的位置就变了。
    /// 多窗口时优先前台活跃场景的 key window；一扇都拿不到才退回容器高度（`fallback`），结果仍会被下面夹进容器内。
    @MainActor
    private static func hostWindowHeight(fallback: CGFloat) -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes.filter({ $0.activationState == .foregroundActive }) + scenes {
            let window = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
            if let height = window?.bounds.height, height > 0 { return height }
        }
        return fallback
    }

    @Environment(\.appLanguage) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack(alignment: .leading) {
            if controller.menu != nil {
                // 菜单打开时给页面罩一层淡色：菜单浮在卡片上也读得清，菜单外任意处点一下收起；
                // 这层只在菜单打开时存在，空闲时不挡场景手势
                scrim
                    .contentShape(Rectangle())
                    .onTapGesture { controller.dismiss() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            if let menu = controller.menu {
                // 菜单竖直位置对齐机身左侧的操作按钮（按整窗高度的比例定位，再换算到本视图坐标）
                GeometryReader { proxy in
                    let hostHeight = Self.hostWindowHeight(fallback: proxy.size.height)
                    let targetY = hostHeight * Self.actionButtonScreenRatio - proxy.frame(in: .global).minY
                    menuColumn(menu)
                        .padding(.leading, 14)
                        .frame(width: proxy.size.width, alignment: .leading)
                        .position(x: proxy.size.width / 2, y: min(max(targetY, 90), proxy.size.height - 90))
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .leading).combined(with: .opacity)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: controller.menu)
        .onAppear {
            if opensMenuOnAppear {
                controller.openMenuForAutomation()
            }
        }
    }

    // MARK: - 菜单

    @Namespace private var glassNamespace

    /// 一级 ⇄ 三级切换用同一组 glassEffectID 变形过渡（iOS 26 液态玻璃），并配弹性弹簧；
    /// 老系统走材质胶囊 + 同样的弹簧与缩放过渡，不会突然切换。
    @ViewBuilder
    private func menuColumn(_ menu: DashboardSideKeyMenu) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    menuChips(menu)
                }
            } else {
                menuChips(menu)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("sideKey.label", lang))
        .accessibilityHint(L10n.tr("sideKey.hint", lang))
        .accessibilityIdentifier("dashboard.sideKey.menu")
    }

    @ViewBuilder
    private func menuChips(_ menu: DashboardSideKeyMenu) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch menu {
            case .root(let selected):
                ForEach(Array(DashboardSideKeyItem.allCases.enumerated()), id: \.element) { index, item in
                    chip(
                        title: L10n.tr(item.titleKey, lang),
                        symbol: Self.symbol(for: item),
                        isSelected: item == selected,
                        isCurrent: false,
                        identifier: "dashboard.sideKey.\(item.rawValue)",
                        glassID: "chip.\(index)"
                    ) {
                        controller.choose(item)
                    }
                }
                hint(L10n.tr("sideKey.menu.rootHint", lang))
            case .theme(let selected):
                ForEach(Array(DashboardTheme.allCases.enumerated()), id: \.element) { index, option in
                    chip(
                        title: L10n.tr(option.titleKey, lang),
                        symbol: Self.symbol(for: option),
                        isSelected: option == selected,
                        isCurrent: option == currentTheme,
                        identifier: "dashboard.sideKey.theme.\(option.rawValue)",
                        glassID: "chip.\(index)"
                    ) {
                        controller.choose(option)
                    }
                }
                hint(L10n.tr("sideKey.menu.themeHint", lang))
            }
        }
        .animation(reduceMotion ? nil : .spring(.bouncy(duration: 0.45)), value: controller.menu)
    }

    private func chip(
        title: String,
        symbol: String,
        isSelected: Bool,
        isCurrent: Bool,
        identifier: String,
        glassID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? selectedForeground : chipForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // 整颗胶囊可点：液态玻璃由 GlassEffectContainer 渲染、不参与命中测试，不声明形状就只有图标 / 文字的字形能点到，
            // 点在胶囊空白处会穿到遮罩把菜单收起（真机反馈「菜单点击不生效」，DEVLOG #95）
            .contentShape(Capsule(style: .continuous))
            .modifier(SideKeyChipSurface(
                isSelected: isSelected,
                accent: accent,
                fill: chipBackground,
                stroke: chipStroke,
                shadow: shadowColor,
                reduceTransparency: reduceTransparency,
                glassID: glassID,
                namespace: glassNamespace
            ))
            .scaleEffect(isSelected ? 1.05 : 1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(.bouncy(duration: 0.35)), value: isSelected)
        // 换层时每个胶囊从 0.6 弹到 1，配合玻璃变形，而不是硬切
        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(hintForeground)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 200, alignment: .leading)
            .padding(.top, 2)
            .padding(.leading, 4)
    }

    private static func symbol(for item: DashboardSideKeyItem) -> String {
        switch item {
        case .settings: "gearshape"
        case .share: "square.and.arrow.up"
        case .theme: "paintpalette"
        }
    }

    private static func symbol(for theme: DashboardTheme) -> String {
        switch theme {
        case .flat: "rectangle.grid.1x2"
        case .roulette: "dial.medium"
        case .helix: "tornado"
        }
    }

    // MARK: - 配色

    private var scrim: some View {
        (theme?.pageBackground ?? Color(.systemGroupedBackground))
            .opacity(reduceTransparency ? 0.88 : 0.58)
            .ignoresSafeArea()
    }

    private var accent: Color {
        theme?.metalAccent ?? Color.accentColor
    }

    private var shadowColor: Color {
        theme?.surfaceShadow ?? Color.black
    }

    private var chipBackground: Color {
        theme.map { $0.isDark ? $0.surfaceBase.opacity(0.96) : $0.surfaceHighlight.opacity(0.96) }
            ?? Color(.secondarySystemGroupedBackground)
    }

    private var chipStroke: Color {
        theme.map { $0.isDark ? $0.surfaceHighlight.opacity(0.14) : $0.surfaceShadow.opacity(0.12) }
            ?? Color.primary.opacity(0.1)
    }

    private var chipForeground: Color {
        theme?.primaryForeground ?? Color.primary
    }

    private var selectedForeground: Color {
        theme?.pageBackground ?? Color.white
    }

    private var hintForeground: Color {
        theme?.secondaryForeground ?? Color.secondary
    }
}

/// 菜单胶囊的表面：iOS 26 用液态玻璃（同 glassEffectID 在换层时变形），老系统用材质胶囊。
private struct SideKeyChipSurface: ViewModifier {
    let isSelected: Bool
    let accent: Color
    let fill: Color
    let stroke: Color
    let shadow: Color
    let reduceTransparency: Bool
    let glassID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(
                    isSelected ? .regular.tint(accent).interactive() : .regular.interactive(),
                    in: Capsule(style: .continuous)
                )
                .glassEffectID(glassID, in: namespace)
        } else {
            content
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : fill)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isSelected ? accent : stroke, lineWidth: reduceTransparency ? 1.5 : 1)
                        )
                        .shadow(
                            color: shadow.opacity(reduceTransparency ? 0 : (isSelected ? 0.3 : 0.16)),
                            radius: isSelected ? 10 : 6,
                            y: 3
                        )
                )
        }
    }
}

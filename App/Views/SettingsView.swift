import SwiftUI
import UIKit
import UsageLimitsCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    /// 自动刷新行的折叠状态：收起只显示当前值，展开挂编辑器。
    @State private var autoRefreshExpanded = false
    /// 组合键进度放引用类型里，点的过程不触发界面刷新（无动画、无闪动）。
    @State private var unlockTracker = UnlockTracker()
    @EnvironmentObject private var edition: Edition
    @State private var showFeedbackOptions = false
    @State private var pendingFeedbackIncludesDiagnostics: Bool?
    @State private var feedbackAlert: FeedbackAlert?
    /// 「侧边键」说明弹窗：分步说明怎么把操作按钮绑到本 App 的快捷指令，确定后跳系统设置。
    @State private var showSideKeyGuide = false
    /// `--open-side-key-guide` 只弹一次。
    @State private var didHandleAutoRoute = false

    var body: some View {
        Form {
            Section {
                // 服务商升级为二级菜单：开关/排序 + 多账号管理 + 新增供应商都在里面。
                NavigationLink {
                    ProvidersSettingsView()
                } label: {
                    HStack {
                        Text(L10n.tr("settings.providers", lang))
                        Spacer(minLength: 8)
                        Text(providersCountLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    HStack {
                        Text(L10n.tr("settings.appearance", lang))
                        Spacer(minLength: 8)
                        Text(L10n.tr("settings.theme.\(state.theme.rawValue)", lang))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.appearance")

                // 侧边键（操作按钮）：弹分步说明，「前往设置」只能到系统设置首页（DEVLOG #97）
                Button {
                    showSideKeyGuide = true
                } label: {
                    Label(L10n.tr("sideKey.label", lang), systemImage: "button.horizontal.top.press")
                }
                .accessibilityIdentifier("settings.sideKey")
                .alert(L10n.tr("settings.sideKey.guideTitle", lang), isPresented: $showSideKeyGuide) {
                    Button(L10n.tr("settings.sideKey.open", lang)) { SideKeySettingsLink.open() }
                    Button(L10n.tr("feedback.cancel", lang), role: .cancel) {}
                } message: {
                    Text(L10n.tr("settings.sideKey.guideSteps", lang))
                }
            }

            Section {
                // 自动刷新：就地折叠。用 Button + withTransaction（本文件因组合键契约不能用隐式动画 API 与点按手势）。
                Button {
                    withTransaction(Transaction(animation: .snappy(duration: 0.25))) {
                        autoRefreshExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(L10n.tr("settings.autoRefresh", lang))
                        Spacer(minLength: 8)
                        if !autoRefreshExpanded {
                            Text(autoRefreshValueLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(autoRefreshExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.autoRefresh.toggle")

                if autoRefreshExpanded {
                    AutoRefreshEditor()
                }

                NavigationLink(L10n.tr("settings.notifications", lang)) {
                    NotificationSettingsView()
                }

                NavigationLink(L10n.tr("settings.widgetPreview", lang)) {
                    WidgetPreviewView()
                }
            } header: {
                Text(L10n.tr("settings.refreshGroup", lang))
            }

            if let entry = edition.settingsEntry() {
                entry
            }

            Section {
                Toggle(isOn: $state.demoMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("settings.demo", lang))
                        Text(L10n.tr("settings.demo.footer", lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink(L10n.tr("settings.diagLog", lang)) {
                    DiagnosticsView()
                }

                Button {
                    showFeedbackOptions = true
                } label: {
                    Label(L10n.tr("settings.feedback", lang), systemImage: "envelope")
                }
                .accessibilityIdentifier("settings.feedback")
                .sheet(
                    isPresented: $showFeedbackOptions,
                    onDismiss: presentPendingFeedback
                ) {
                    FeedbackOptionsSheet { includeDiagnostics in
                        pendingFeedbackIncludesDiagnostics = includeDiagnostics
                    }
                }
            } header: {
                Text(L10n.tr("settings.advanced", lang))
            }

            Section(L10n.tr("settings.privacy", lang)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.subheadline.bold())
                            .padding(8)
                            .overlay {
                                SilentTapCatcher { registerUnlockTap(.shield) }
                            }
                            .padding(-8)
                        Text(L10n.tr("settings.privacy.title", lang))
                            .font(.subheadline.bold())
                    }
                    Text(L10n.tr("settings.privacy.body", lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay {
                            SilentHotspotText(
                                text: L10n.tr("settings.privacy.body", lang),
                                onTap: registerUnlockTap
                            )
                        }
                }
                .padding(.vertical, 4)

                if state.shareBrandUnlocked {
                    Toggle(
                        L10n.tr("settings.share.hideBrand", lang),
                        isOn: hideBrandRowBinding
                    )
                }

                HStack {
                    Text(L10n.tr("settings.version", lang))
                    Spacer()
                    // 版本号唯一来源是 project.yml 的 MARKETING_VERSION，这里只读不写
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .foregroundStyle(.secondary)
                        .overlay {
                            SilentTapCatcher { registerUnlockTap(.version) }
                        }
                }
            }
        }
        .readableWidth()
        .alert(item: $feedbackAlert) { alert in
            Alert(
                title: Text(L10n.tr(alert.titleKey, lang)),
                message: Text(L10n.tr(alert.messageKey, lang)),
                dismissButton: .cancel(Text(L10n.tr("feedback.cancel", lang)))
            )
        }
        .animation(nil, value: state.shareBrandUnlocked)
        .onAppear {
            state.expireShareBrandUnlockIfNeeded()
            // --open-side-key-guide：进入本页直接弹「侧边键」说明（模拟器验证弹窗与「前往设置」落点用）
            if case .sideKeyGuide = state.autoRoute, !didHandleAutoRoute {
                didHandleAutoRoute = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    showSideKeyGuide = true
                }
            }
        }
        .navigationTitle(L10n.tr("settings.title", lang))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 计数徽章：已添加的账号总数（主账号 + 附加账号）。
    private var providersCountLabel: String {
        "\(state.accounts.count)"
    }

    /// 自动刷新折叠行的当前值：关 → 「不自动刷新」，否则数字 + 秒/分钟。
    private var autoRefreshValueLabel: String {
        let seconds = state.autoRefreshInterval
        guard AutoRefreshInterval.clamped(seconds) > 0 else {
            return L10n.tr("settings.autoRefresh.off", lang)
        }
        let unitKey = AutoRefreshInterval.unit(forStored: seconds) == .seconds
            ? "settings.autoRefresh.unitSeconds" : "settings.autoRefresh.unit"
        return "\(AutoRefreshInterval.displayNumber(seconds)) \(L10n.tr(unitKey, lang))"
    }

    private var hideBrandRowBinding: Binding<Bool> {
        Binding(
            get: { state.store.shareComposeOptions.hideBrandRow },
            set: { new in
                var opts = state.store.shareComposeOptions
                opts.hideBrandRow = new
                state.store.shareComposeOptions = opts
            }
        )
    }

    private func presentPendingFeedback() {
        guard let includeDiagnostics = pendingFeedbackIncludesDiagnostics else { return }
        pendingFeedbackIncludesDiagnostics = nil
        presentFeedback(includeDiagnostics: includeDiagnostics)
    }

    private func presentFeedback(includeDiagnostics: Bool) {
        // 撰写器由 UIKit 直接 present、附件在 present 前挂好，不走 SwiftUI sheet（子控制器嵌入会丢附件，DEVLOG #94）。
        // 选项 sheet 的 onDismiss 里要等一拍再 present；代理只捕获 alert 的 binding，别把整个视图拴在它上面。
        let diagnostics = includeDiagnostics
            ? FeedbackMailDraft.diagnosticAttachment(from: state.store.diagnostics())
            : nil
        let alert = $feedbackAlert
        let store = state.store
        let language = lang.resolved
        Task { @MainActor in
            let presented = FeedbackMailComposer.present(
                language: language,
                diagnostics: diagnostics,
                log: { store.appendDiagnostic($0) }
            ) { failed in
                if failed { alert.wrappedValue = .failed }
            }
            if !presented { alert.wrappedValue = .unavailable }
        }
    }

    private func registerUnlockTap(_ tap: BrandUnlockTap) {
        guard !state.shareBrandUnlocked else { return }
        unlockTracker.progress = BrandUnlockCombo.advance(
            progress: unlockTracker.progress, tap: tap
        )
        guard BrandUnlockCombo.isComplete(unlockTracker.progress) else { return }
        unlockTracker.progress = 0
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            state.unlockShareBrand()
        }
    }
}

private enum FeedbackAlert: String, Identifiable {
    case unavailable
    case failed

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .unavailable: "feedback.mail.unavailable.title"
        case .failed: "feedback.mail.failed.title"
        }
    }

    var messageKey: String {
        switch self {
        case .unavailable: "feedback.mail.unavailable.message"
        case .failed: "feedback.mail.failed.message"
        }
    }
}

/// 自动刷新编辑器：数值框 + 秒/分钟分段 + 滑块 + 说明。只在折叠行展开时挂载，
/// 每次展开 `onAppear` 从库重新同步；输入即写入，收起不丢数据。
private struct AutoRefreshEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    /// 滑块的本地档位：拖动期间只动这个轻量状态，松手才提交到 AppState
    ///（否则每帧都触发 @Published 重渲染 + UserDefaults 写入 + 刷新任务重建，非常卡）。
    @State private var refreshStepIndex: Double = 0
    @State private var minutesText = "0"
    @State private var unit: AutoRefreshUnit = .minutes
    @FocusState private var minutesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                HStack(alignment: .center, spacing: 8) {
                    TextField("0", text: $minutesText)
                        .font(AutoRefreshFieldChrome.font)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                        .frame(width: 56, height: AutoRefreshFieldChrome.height)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .focused($minutesFocused)
                        .accessibilityIdentifier("settings.autoRefresh.minutes")
                    EqualWidthUnitPicker(
                        unit: unitBinding,
                        secondsTitle: L10n.tr("settings.autoRefresh.unitSeconds", lang),
                        minutesTitle: L10n.tr("settings.autoRefresh.unit", lang)
                    )
                    .frame(width: 120, height: AutoRefreshFieldChrome.height)
                }
            }
            Slider(
                value: $refreshStepIndex,
                in: 0...Double(AutoRefreshInterval.sliderSteps.count - 1),
                step: 1
            ) { editing in
                if !editing {
                    applyChoice(
                        AutoRefreshInterval.choice(fromSliderStep:
                            AutoRefreshInterval.sliderStep(at: refreshStepIndex)
                        ),
                        persist: true
                    )
                }
            }
            Text(L10n.tr("settings.autoRefresh.footer", lang))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { syncFromStore() }
        .onChange(of: refreshStepIndex) { _, idx in
            guard !minutesFocused else { return }
            applyChoice(
                AutoRefreshInterval.choice(fromSliderStep:
                    AutoRefreshInterval.sliderStep(at: idx)
                ),
                persist: false
            )
        }
        .onChange(of: minutesFocused) { _, focused in
            if !focused { commitMinutesText() }
        }
        .onChange(of: minutesText) { _, new in
            var cleaned = new
            if let cut = cleaned.firstIndex(where: { $0 == "." || $0 == "," || $0 == "．" }) {
                cleaned = String(cleaned[..<cut])
            }
            cleaned = String(cleaned.filter(\.isNumber).prefix(4))
            if cleaned != new {
                minutesText = cleaned
                return
            }
            guard minutesFocused else { return }
            applyChoice(
                AutoRefreshInterval.applyingTypedAmount(cleaned, currentUnit: unit),
                persist: true
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("settings.done", lang)) {
                    minutesFocused = false
                    commitMinutesText()
                }
            }
        }
    }

    private var unitBinding: Binding<AutoRefreshUnit> {
        Binding(
            get: { unit },
            set: { newUnit in
                let amount = AutoRefreshInterval.integerAmount(from: minutesText)
                applyChoice(
                    AutoRefreshInterval.applyingUnitSwitch(amount: amount, to: newUnit),
                    persist: true
                )
            }
        )
    }

    private func syncFromStore() {
        applyChoice(AutoRefreshInterval.choice(fromStored: state.autoRefreshInterval), persist: false)
    }

    private func commitMinutesText() {
        applyChoice(
            AutoRefreshInterval.applyingTypedAmount(minutesText, currentUnit: unit),
            persist: true
        )
    }

    private func applyChoice(_ choice: AutoRefreshChoice, persist: Bool) {
        unit = choice.unit
        minutesText = "\(choice.amount)"
        refreshStepIndex = Self.stepIndex(forSeconds: choice.storedSeconds)
        if persist {
            state.autoRefreshInterval = choice.storedSeconds
        }
    }

    private static func stepIndex(forSeconds seconds: Double) -> Double {
        let steps = AutoRefreshInterval.sliderSteps
        if let idx = steps.firstIndex(of: seconds) { return Double(idx) }
        let nearest = steps.enumerated().min(by: { abs($0.element - seconds) < abs($1.element - seconds) })
        return Double(nearest?.offset ?? 0)
    }
}

/// 数值框与秒/分钟分段共用高度、字号、字重。
private enum AutoRefreshFieldChrome {
    static let height: CGFloat = 32
    static let fontSize: CGFloat = 15
    static var font: Font { .system(size: fontSize, weight: .regular) }
}

/// 秒 / 分钟两档等宽，高度/字重与左侧数值胶囊一致。
private struct EqualWidthUnitPicker: View {
    @Binding var unit: AutoRefreshUnit
    let secondsTitle: String
    let minutesTitle: String

    var body: some View {
        HStack(spacing: 2) {
            segment(.seconds, secondsTitle)
            segment(.minutes, minutesTitle)
        }
        .padding(2)
        .frame(height: AutoRefreshFieldChrome.height)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .accessibilityIdentifier("settings.autoRefresh.unitPicker")
    }

    private func segment(_ value: AutoRefreshUnit, _ title: String) -> some View {
        Button {
            unit = value
        } label: {
            Text(title)
                .font(AutoRefreshFieldChrome.font)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if unit == value {
                        Capsule().fill(Color(.systemBackground))
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(title)
        .accessibilityAddTraits(unit == value ? [.isButton, .isSelected] : .isButton)
    }
}

/// 组合键进度：类实例变更不会触发 SwiftUI 刷新。
private final class UnlockTracker {
    var progress = 0
}

/// 透明点击层：吃掉触摸，避免 Form 行高亮 / 触感 / 动画。
private struct SilentTapCatcher: UIViewRepresentable {
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = false
        let gesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        gesture.cancelsTouchesInView = true
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func tapped() { onTap() }
    }
}

/// 正文里 Cookie / WebKit 可点，但外观与普通 caption 完全一样：无高亮、无触感、无动画。
private struct SilentHotspotText: UIViewRepresentable {
    let text: String
    let onTap: (BrandUnlockTap) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.isOpaque = false
        tv.isUserInteractionEnabled = true
        tv.dataDetectorTypes = []
        tv.tintColor = .clear
        tv.delaysContentTouches = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.isAccessibilityElement = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let gesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        gesture.cancelsTouchesInView = true
        tv.addGestureRecognizer(gesture)
        context.coordinator.textView = tv
        apply(text, to: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        if tv.attributedText?.string != text {
            apply(text, to: tv)
        }
        layout(tv)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? max(uiView.bounds.width, 1)
        let height = proposal.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        layout(uiView, width: width, height: height)
        if let height {
            return CGSize(width: width, height: height)
        }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    private func layout(_ tv: UITextView, width: CGFloat? = nil, height: CGFloat? = nil) {
        if let width {
            tv.textContainer.size = CGSize(
                width: width,
                height: height ?? max(tv.bounds.height, 1)
            )
        } else if tv.bounds.width > 0 {
            tv.textContainer.size = tv.bounds.size
        }
    }

    private func apply(_ string: String, to tv: UITextView) {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        // 字透明：可见文案由上层 SwiftUI Text 负责，避免 UITextView 把卡片撑成一行。
        tv.attributedText = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: UIColor.clear,
        ])
    }

    final class Coordinator: NSObject {
        var onTap: (BrandUnlockTap) -> Void
        weak var textView: UITextView?

        init(onTap: @escaping (BrandUnlockTap) -> Void) {
            self.onTap = onTap
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let tv = textView else { return }
            var loc = gesture.location(in: tv)
            loc.x -= tv.textContainerInset.left
            loc.y -= tv.textContainerInset.top
            var fraction: CGFloat = 0
            let idx = tv.layoutManager.characterIndex(
                for: loc,
                in: tv.textContainer,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )
            let glyphRange = tv.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: idx, length: 1),
                actualCharacterRange: nil
            )
            let rect = tv.layoutManager.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            guard rect.insetBy(dx: -6, dy: -6).contains(loc) else { return }
            guard let tap = BrandUnlockCombo.hotspot(in: tv.attributedText?.string ?? "", utf16Index: idx) else {
                return
            }
            onTap(tap)
        }
    }
}

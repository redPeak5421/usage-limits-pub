import SwiftUI
import UIKit
import UsageLimitsCore

/// 主题色编辑器：纯色/渐变切换，取色器 + 色号 + RGB 分值三种输入双向同步。
/// 账号级与供应商级共用；「恢复默认」保存 nil（清除本层覆盖，回落下一层）。
struct ColorEditorSheet: View {
    let title: String
    /// 本层已保存的自定义色（nil = 尚未自定义，从回落色起编）。
    let current: BrandTint?
    /// 清除本层覆盖后的回落色（初始编辑值 + 恢复默认的预览依据）。
    let fallback: BrandTint
    let onSave: (BrandTint?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var lang

    @State private var isGradient: Bool
    @State private var startHex: String
    @State private var endHex: String

    init(title: String, current: BrandTint?, fallback: BrandTint, onSave: @escaping (BrandTint?) -> Void) {
        self.title = title
        self.current = current
        self.fallback = fallback
        self.onSave = onSave
        let seed = current ?? fallback
        _isGradient = State(initialValue: seed.isGradient)
        _startHex = State(initialValue: BrandTint.normalized(hex: seed.startHex) ?? "#808080")
        _endHex = State(initialValue: BrandTint.normalized(hex: seed.endHex ?? seed.startHex) ?? "#808080")
    }

    private var editedTint: BrandTint {
        BrandTint(startHex: startHex, endHex: isGradient ? endHex : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("tint.preview", lang)) {
                    preview
                }
                Section {
                    Picker(L10n.tr("tint.mode", lang), selection: $isGradient.animation(.snappy(duration: 0.2))) {
                        Text(L10n.tr("tint.solid", lang)).tag(false)
                        Text(L10n.tr("tint.gradient", lang)).tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section(L10n.tr(isGradient ? "tint.start" : "tint.color", lang)) {
                    ColorStopEditor(hex: $startHex)
                }
                if isGradient {
                    Section(L10n.tr("tint.end", lang)) {
                        ColorStopEditor(hex: $endHex)
                    }
                }
                Section {
                    Button(L10n.tr("tint.restoreDefault", lang), role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                } footer: {
                    Text(L10n.tr("tint.restoreDefault.footer", lang))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("login.close", lang)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("settings.done", lang)) {
                        onSave(editedTint)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// 实时预览：三枚标签（套餐 / 周期 / 价格）+ 一根 62% 的用量条。
    /// 用量条按轨道完整长度铺渐变，填充只是揭开前段（与分享图同一约定）。
    private var preview: some View {
        let tint = editedTint
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                previewCapsule("Pro", tint: tint)
                previewCapsule(L10n.tr(BillingCycle.monthly.tag, lang), tint: tint)
                previewCapsule("$20", tint: tint)
                Spacer()
            }
            GeometryReader { geo in
                let gradient = LinearGradient(
                    colors: [tint.startColor, tint.endColor],
                    startPoint: .leading, endPoint: .trailing
                )
                ZStack(alignment: .leading) {
                    Capsule().fill(gradient).opacity(0.18)
                    Capsule()
                        .fill(gradient)
                        .frame(width: geo.size.width)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: geo.size.width * 0.62)
                        }
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 4)
    }

    private func previewCapsule(_ text: String, tint: BrandTint) -> some View {
        Text(text)
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.badgeFill))
            .foregroundStyle(tint.badgeForeground)
    }
}

/// 单个颜色停靠点：取色器 + 色号 + R/G/B，三者双向同步。真源是 hex 字符串。
private struct ColorStopEditor: View {
    @Binding var hex: String
    @Environment(\.appLanguage) private var lang

    @State private var hexText: String = ""
    @State private var red: String = ""
    @State private var green: String = ""
    @State private var blue: String = ""

    var body: some View {
        ColorPicker(
            L10n.tr("tint.picker", lang),
            selection: Binding(
                get: { Color(brandTintHex: hex) },
                set: { apply(color: $0) }
            ),
            supportsOpacity: false
        )
        HStack {
            Text(L10n.tr("tint.hex", lang))
            Spacer()
            TextField("#RRGGBB", text: $hexText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .onSubmit(commitHex)
                .onChange(of: hexText) { _, text in
                    // 满 6 位十六进制即生效，不必等回车
                    if BrandTint.normalized(hex: text) != nil { commitHex() }
                }
        }
        HStack(spacing: 8) {
            rgbField("R", $red)
            rgbField("G", $green)
            rgbField("B", $blue)
        }
        .onAppear(perform: syncFromHex)
        .onChange(of: hex) { _, _ in syncFromHex() }
    }

    private func rgbField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text.wrappedValue) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(3))
                    if digits != new { text.wrappedValue = digits }
                    commitRGB()
                }
        }
    }

    private func syncFromHex() {
        guard let rgb = BrandTint.rgb(fromHex: hex) else { return }
        hexText = BrandTint.hexString(rgb)
        red = String(rgb.red)
        green = String(rgb.green)
        blue = String(rgb.blue)
    }

    private func commitHex() {
        guard let normalized = BrandTint.normalized(hex: hexText) else { return }
        hex = normalized
    }

    private func commitRGB() {
        guard let r = Int(red), let g = Int(green), let b = Int(blue),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return }
        hex = BrandTint.hexString(.init(red: r, green: g, blue: b))
    }

    private func apply(color: Color) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        hex = BrandTint.hexString(.init(
            red: IntegerFormat.rounded(Double(r * 255)) ?? 0,
            green: IntegerFormat.rounded(Double(g * 255)) ?? 0,
            blue: IntegerFormat.rounded(Double(b * 255)) ?? 0
        ))
    }
}

import SwiftUI
import UsageLimitsCore

/// 探针诊断日志：每次抓取每个接口的状态码、字节数与脱敏后的响应预览，
/// 以及解析产出的指标摘要（`*.parsed=`）。Release 也记录；用户用「复制 / 分享」交日志即可定位接口漂移。
struct DiagnosticsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @State private var lines: [String] = []
    @State private var copied = false

    private var joined: String { lines.joined(separator: "\n") }

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView(
                    L10n.tr("diagnostics.empty", lang),
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text(L10n.tr("diagnostics.emptyHint", lang))
                )
            } else {
                List(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(lineColor(line))
                        .textSelection(.enabled)
                }
                .listStyle(.plain)
            }
        }
        // 诊断日志是 .plain 列表，底色跟着系统底色而不是分组灰
        .readableWidth(background: Color(.systemBackground))
        .navigationTitle(L10n.tr("settings.diagLog", lang))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? L10n.tr("diagnostics.copied", lang) : L10n.tr("diagnostics.copy", lang)) {
                    UIPasteboard.general.string = joined
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .disabled(lines.isEmpty)
                ShareLink(item: joined, subject: Text(L10n.tr("diagnostics.shareSubject", lang))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(lines.isEmpty)
                Button(L10n.tr("diagnostics.clear", lang), role: .destructive) {
                    state.store.clearDiagnostics()
                    lines = []
                }
                .disabled(lines.isEmpty)
            }
        }
        .onAppear { lines = state.store.diagnostics() }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains(".parsed=") { return .blue }
        if line.contains("HTTP 2") || line.contains("HTTP 200") { return .primary }
        if line.contains("HTTP ") { return .orange }
        return .secondary
    }
}

import SwiftUI
import WidgetKit
import UsageLimitsCore

/// 首页卡片「…」→ 编辑计量顺序：List 原生拖动排序，落盘到 `SharedStore.metricOrder`。
/// 首页 / 小组件 / 手表读快照时统一套用（`MetricOrdering`），这里不碰快照本身。
struct MetricOrderTarget: Identifiable {
    let key: String
    let title: String
    let metrics: [UsageMetric]
    /// 内置卡传服务商，自定义卡为 nil（展示名保持用户字段名）。
    let provider: ProviderID?
    /// 从 store 重新读一遍（已套用当前顺序）；恢复默认时用它拿解析器顺序。
    let reload: () -> [UsageMetric]
    var id: String { key }
}

struct MetricOrderSheet: View {
    let target: MetricOrderTarget
    @EnvironmentObject private var state: AppState
    @Environment(\.appLanguage) private var lang
    @Environment(\.usageDisplayMode) private var displayMode
    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String]

    init(target: MetricOrderTarget) {
        self.target = target
        _ids = State(initialValue: target.metrics.map(\.id))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ids, id: \.self) { id in
                        HStack {
                            Text(localizedMetricLabel(id))
                                .lineLimit(1)
                            Spacer()
                            if let percent = target.metrics.first(where: { $0.id == id })?.usedPercent {
                                Text(UsagePresentation.percentText(used: percent, mode: displayMode))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("metricOrder.row.\(id)")
                    }
                    .onMove { from, to in
                        ids.move(fromOffsets: from, toOffset: to)
                        commit()
                    }
                } footer: {
                    Text(L10n.tr("metricOrder.footer", lang))
                }
                Section {
                    Button(L10n.tr("metricOrder.reset", lang), role: .destructive) {
                        state.store.setMetricOrder([], for: target.key)
                        ids = target.reload().map(\.id)
                        propagate()
                    }
                    .accessibilityIdentifier("metricOrder.reset")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("settings.done", lang)) { dismiss() }
                }
            }
        }
    }

    private func localizedMetricLabel(_ id: String) -> String {
        let fallback = target.metrics.first { $0.id == id }?.label ?? id
        guard let provider = target.provider else { return L10n.tr(fallback, lang) }
        return L10n.metricLabel(provider: provider, id: id, fallback: fallback, language: lang)
    }

    private func commit() {
        state.store.setMetricOrder(ids, for: target.key)
        propagate()
    }

    private func propagate() {
        state.reloadFromStore()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.pushState()
    }
}

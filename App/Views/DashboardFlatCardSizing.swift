import SwiftUI

extension EnvironmentValues {
    @Entry var dashboardFlatCollapsedHeight: CGFloat = 0
}

struct DashboardFlatCollapsedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 先量自然高度，再填充平铺缩略卡片的公共高度；展开内容不参与测量。
struct DashboardFlatCardSizing: ViewModifier {
    let isActive: Bool
    @Environment(\.dashboardFlatCollapsedHeight) private var sharedHeight

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: isActive)
            .background {
                if isActive {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DashboardFlatCollapsedHeightKey.self, value: proxy.size.height)
                    }
                }
            }
            .frame(minHeight: isActive ? sharedHeight : nil, alignment: .topLeading)
    }
}

import Foundation
import UsageLimitsCore

struct DashboardSceneItem: Identifiable {
    enum Source {
        case builtin(provider: ProviderID, account: ProviderAccount?)
        case custom(account: ProviderAccount)
        case demo(provider: ProviderID)
    }

    let id: DashboardSceneItemID
    let source: Source
    let snapshot: ProviderSnapshot?
    let title: String
    let tint: BrandTint
    let isRefreshing: Bool
    let canExpand: Bool
    let refreshGlow: Bool
    let tintedBars: Bool
    let barShimmer: Bool
    let customLogoData: Data?
    let customSubtitle: String?
    let onLogin: @MainActor () -> Void
    let onRefresh: @MainActor () -> Void
    let onLogout: @MainActor () -> Void
    let onShare: @MainActor () -> Void
    let onEdit: (@MainActor () -> Void)?
    let onReorderMetrics: (@MainActor () -> Void)?

    var provider: ProviderID? {
        switch source {
        case .builtin(let provider, _), .demo(let provider):
            provider
        case .custom(let account):
            account.provider
        }
    }

    var isCustom: Bool {
        if case .custom = source { return true }
        return false
    }

    var reorderDomain: DashboardReorderDomain {
        id.domain
    }
}

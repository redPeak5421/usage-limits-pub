import Foundation

/// 发布目录门禁；不修改 ProviderID、账号、开关或缓存。接入证据见 providers/availability.md。
public enum ProviderAvailability {
    public static func isAvailable(_ provider: ProviderID) -> Bool {
        switch provider {
        case .claude, .openai, .kimi, .deepseek, .opencode, .gemini,
             .grok, .cursor, .jimeng, .zhipu, .minimax:
            return true
        default:
            return false
        }
    }

    public static var providers: [ProviderID] { ProviderID.allCases.filter(isAvailable) }

    public static func isAvailable(_ account: ProviderAccount) -> Bool {
        account.isCustom || account.provider.map(isAvailable) == true
    }

    /// 按可见行拖动，隐藏账号留在原位置，避免 UI 索引错位或删除隐藏配置。
    public static func movingVisibleAccounts(
        _ accounts: [ProviderAccount], fromOffsets: IndexSet, toOffset: Int
    ) -> [ProviderAccount] {
        var moved = AccountOrder.moving(accounts.filter(isAvailable), fromOffsets: fromOffsets, toOffset: toOffset).makeIterator()
        return accounts.map { isAvailable($0) ? moved.next()! : $0 }
    }
}

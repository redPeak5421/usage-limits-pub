import Foundation

/// 停用账号：配置仍在列表里，但不进首页/小组件，也不向官网拉用量。
/// 服务商级开关（`SharedStore.isEnabled(provider)`）就是主账号的开关：主账号快照按服务商键存，
/// 首页主卡 / 小组件 / 手表都按它取。附加账号各有独立 dataStore 与快照，只看自己的 `isEnabled`，
/// 不随主账号一起停用（2026-09-15 用户反馈：停用第一个 Grok / Cursor 后第二个也没了）。
public enum AccountVisibility {
    public static func shouldShowOnHome(_ account: ProviderAccount, providerEnabled: Bool) -> Bool {
        guard account.isEnabled, ProviderAvailability.isAvailable(account) else { return false }
        if account.isCustom || !account.isPrimary { return true }
        return providerEnabled
    }

    public static func shouldProbe(_ account: ProviderAccount, providerEnabled: Bool) -> Bool {
        shouldShowOnHome(account, providerEnabled: providerEnabled)
    }
}

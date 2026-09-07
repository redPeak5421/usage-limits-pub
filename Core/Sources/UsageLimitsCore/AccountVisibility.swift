import Foundation

/// 停用账号：配置仍在列表里，但不进首页/小组件，也不向官网拉用量。
public enum AccountVisibility {
    public static func shouldShowOnHome(_ account: ProviderAccount, providerEnabled: Bool) -> Bool {
        guard account.isEnabled else { return false }
        if account.isCustom { return true }
        return providerEnabled
    }

    public static func shouldProbe(_ account: ProviderAccount, providerEnabled: Bool) -> Bool {
        shouldShowOnHome(account, providerEnabled: providerEnabled)
    }
}

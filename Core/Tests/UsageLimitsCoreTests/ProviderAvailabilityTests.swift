import XCTest
@testable import UsageLimitsCore

final class ProviderAvailabilityTests: XCTestCase {
    func testCatalogContainsOnlyConfirmedIntegrationsWithoutRemovingIDs() {
        let expected: Set<ProviderID> = [.claude, .openai, .kimi, .deepseek, .opencode,
                                       .gemini, .grok, .cursor, .jimeng, .zhipu, .minimax]
        XCTAssertEqual(Set(ProviderCatalog.sortedProviders(.en)), expected)
        XCTAssertEqual(ProviderID.allCases.count, 25)
    }

    func testHiddenAccountsAreNotDisplayedOrProbed() {
        let account = ProviderAccount(provider: .kiro, name: "Saved", isPrimary: true)
        XCTAssertFalse(AccountVisibility.shouldShowOnHome(account, providerEnabled: true))
        XCTAssertFalse(AccountVisibility.shouldProbe(account, providerEnabled: true))
        // 附加账号不看服务商开关，但目录门禁仍在前面：隐藏服务商的附加账号照样不显示、不探针
        let extra = ProviderAccount(provider: .kiro, name: "Extra")
        XCTAssertFalse(AccountVisibility.shouldShowOnHome(extra, providerEnabled: false))
        XCTAssertFalse(AccountVisibility.shouldProbe(extra, providerEnabled: false))
    }

    func testVisibleReorderingPreservesHiddenAccountsAndCustomAccounts() throws {
        let a = ProviderAccount(provider: .claude, name: "A", isPrimary: true)
        let hidden = ProviderAccount(provider: .kiro, name: "Saved", isPrimary: true)
        let b = ProviderAccount(provider: .gemini, name: "B", isPrimary: true)
        let custom = ProviderAccount(source: .custom(templateID: UUID()), name: "Custom")
        XCTAssertTrue(ProviderAvailability.isAvailable(custom))
        XCTAssertTrue(AccountVisibility.shouldShowOnHome(custom, providerEnabled: false))
        let original = [a, hidden, b, custom]
        let reordered = ProviderAvailability.movingVisibleAccounts(original, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(reordered, [b, hidden, a, custom])
        XCTAssertEqual(try JSONDecoder().decode([ProviderAccount].self, from: JSONEncoder().encode(reordered)), reordered)
        XCTAssertEqual(original, [a, hidden, b, custom])
    }

    func testPreviewDoesNotResurrectHiddenProviders() {
        let items = WidgetAccountItems.overview(pickedIDs: [], accounts: [], providerOrder: [.kiro, .gemini], preview: true, isProviderEnabled: { _ in true })
        XCTAssertEqual(items.map(\.provider), [.gemini])
    }
}

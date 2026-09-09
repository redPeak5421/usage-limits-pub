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

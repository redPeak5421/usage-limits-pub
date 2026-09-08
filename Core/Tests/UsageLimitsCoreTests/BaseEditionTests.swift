import XCTest
@testable import UsageLimitsCore

final class BaseEditionTests: XCTestCase {
    @MainActor
    func testBaseEditionHasNoOptionalEffectsOrRoutes() async {
        let edition = BaseEdition()
        XCTAssertFalse(edition.showsCardEffects)
        XCTAssertEqual(edition.cardDecorations(), .empty)
        XCTAssertNil(edition.settingsEntry())
        XCTAssertNil(edition.appearanceSection())
        XCTAssertNil(edition.widgetPreviewHeader())
        XCTAssertNil(edition.widgetPreviewRim(cornerRadius: 24))
        XCTAssertNil(edition.refreshGlowOverlay(cornerRadius: 24))
        XCTAssertNil(edition.usageBarDecorator(tint: nil, tinted: true, shimmer: true))
        XCTAssertNil(edition.route("optional"))
        edition.handleLaunch(["--optional"])
        await edition.onForeground()
        XCTAssertNil(edition.pendingRoute)
    }
}

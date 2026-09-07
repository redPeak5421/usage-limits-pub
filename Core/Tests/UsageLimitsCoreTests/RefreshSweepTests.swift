import XCTest
@testable import UsageLimitsCore

final class RefreshSweepTests: XCTestCase {
    func testOldestSnapshotsRunFirstAndExtrasBeatPrimariesOnTie() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_600)
        let extraID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let customID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let order = RefreshSweep.order(
            primaries: [
                (id: .claude, fetchedAt: newer),
                (id: .openai, fetchedAt: older),
            ],
            extras: [
                (id: extraID, fetchedAt: older),
            ],
            customs: [
                (id: customID, fetchedAt: newer),
            ]
        )
        XCTAssertEqual(order, [
            .extra(extraID),
            .primary(.openai),
            .primary(.claude),
            .custom(customID),
        ])
    }

    func testEqualFetchedAtPrefersExtraThenPrimaryThenCustom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let extraID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let customID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        XCTAssertEqual(
            RefreshSweep.order(
                primaries: [(id: .kimi, fetchedAt: now)],
                extras: [(id: extraID, fetchedAt: now)],
                customs: [(id: customID, fetchedAt: now)]
            ),
            [.extra(extraID), .primary(.kimi), .custom(customID)]
        )
    }
}

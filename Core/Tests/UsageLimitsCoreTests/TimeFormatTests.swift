import XCTest
@testable import UsageLimitsCore

final class TimeFormatTests: XCTestCase {
    func testCompactRelativeUsesLargestUnitOnly() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(59 * 60), now: now, language: .zh), "59 分后")
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(3 * 3600 + 21 * 60), now: now, language: .zh), "3 小时后")
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(4 * 86400 + 3 * 3600), now: now, language: .zh), "4 天后")
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(-60), now: now, language: .zh), "已重置")
    }
}

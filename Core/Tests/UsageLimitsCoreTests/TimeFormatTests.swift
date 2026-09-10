import XCTest
@testable import UsageLimitsCore

final class TimeFormatTests: XCTestCase {
    func testLocalDateTimeUses24HourClockAndSecondsAcrossTimeZones() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T04:21:20Z"))
        XCTAssertEqual(TimeFormat.localDateTime(date, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))), "2026-10-05 12:21:20")
        XCTAssertEqual(TimeFormat.localDateTime(date, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))), "2026-10-04 21:21:20")
    }

    func testLocalDateTimeUsesCalendarYearAndFixedDigits() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2021-01-01T00:30:00Z"))
        XCTAssertEqual(TimeFormat.localDateTime(date, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))), "2021-01-01 00:30:00")
        XCTAssertEqual(TimeFormat.localDateTime(Date(timeIntervalSince1970: .infinity)), "—")
    }
    func testCompactRelativeUsesLargestUnitOnly() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(59 * 60), now: now, language: .zh), "59 分后")
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(3 * 3600 + 21 * 60), now: now, language: .zh), "3 小时后")
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(4 * 86400 + 3 * 3600), now: now, language: .zh), "4 天后")
        XCTAssertEqual(TimeFormat.compactRelative(now.addingTimeInterval(-60), now: now, language: .zh), "已重置")
    }
}

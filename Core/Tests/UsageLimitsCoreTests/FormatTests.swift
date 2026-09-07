import XCTest
@testable import UsageLimitsCore

final class FormatTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_766_000_000)

    func testMinutes() {
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(59 * 60), now: now, language: .zh), "59 分钟后")
    }

    func testHoursWithMinutes() {
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(2 * 3600 + 600), now: now, language: .zh), "2 小时 10 分后")
    }

    func testWholeHours() {
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(3 * 3600), now: now, language: .zh), "3 小时后")
    }

    func testDays() {
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(3 * 86400), now: now, language: .zh), "3 天后")
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(2 * 86400 + 5 * 3600), now: now, language: .zh), "2 天 5 小时后")
    }

    func testPast() {
        XCTAssertEqual(TimeFormat.relative(now.addingTimeInterval(-60), now: now, language: .zh), "已重置")
    }

    func testIntegerFormatSafelyRoundsAndUsesPlaceholderForUnrepresentableValues() {
        XCTAssertEqual(IntegerFormat.rounded(12.4), 12)
        XCTAssertEqual(IntegerFormat.rounded(12.5), 13)
        XCTAssertEqual(IntegerFormat.truncating(12.9), 12)
        XCTAssertEqual(IntegerFormat.truncating(-12.9), -12)
        XCTAssertEqual(IntegerFormat.string(12.5), "13")
        XCTAssertEqual(IntegerFormat.signedString(12.5), "+13")
        XCTAssertEqual(IntegerFormat.signedString(-12.5), "-13")

        for invalid in [Double.nan, .infinity, -.infinity, 1e308] {
            XCTAssertNil(IntegerFormat.rounded(invalid))
            XCTAssertNil(IntegerFormat.truncating(invalid))
            XCTAssertEqual(IntegerFormat.string(invalid), "—")
            XCTAssertEqual(IntegerFormat.signedString(invalid), "—")
        }
        XCTAssertEqual(IntegerFormat.string(nil, placeholder: "n/a"), "n/a")
    }
}

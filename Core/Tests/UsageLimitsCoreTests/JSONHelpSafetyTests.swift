import CoreFoundation
import XCTest
@testable import UsageLimitsCore

final class JSONHelpSafetyTests: XCTestCase {
    func testDoubleRejectsBooleansAndNonFiniteValues() {
        let rejected: [Any] = [
            true,
            false,
            kCFBooleanTrue as Any,
            kCFBooleanFalse as Any,
            "NaN",
            "Infinity",
            "-Infinity",
            "1e309",
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ]

        for value in rejected {
            XCTAssertNil(JSONHelp.double(value), "must reject \(String(describing: value))")
        }
    }

    func testDoubleKeepsFiniteNumbersAndNumericStrings() {
        XCTAssertEqual(JSONHelp.double(7), 7)
        XCTAssertEqual(JSONHelp.double(NSNumber(value: 8)), 8)
        XCTAssertEqual(JSONHelp.double(2.5), 2.5)
        XCTAssertEqual(JSONHelp.double("3.25"), 3.25)
        XCTAssertEqual(JSONHelp.double("0"), 0)
    }

    func testSafeIntConversionsRejectNonFiniteAndOutOfRangeWithoutChangingRounding() {
        XCTAssertEqual(JSONHelp.intExactly(12.0), 12)
        XCTAssertNil(JSONHelp.intExactly(12.5))
        XCTAssertEqual(JSONHelp.intRounded(12.5), 13)
        XCTAssertEqual(JSONHelp.intRounded(-12.5), -13)
        XCTAssertEqual(JSONHelp.intTruncating(12.9), 12)
        XCTAssertEqual(JSONHelp.intTruncating(-12.9), -12)

        for value in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertNil(JSONHelp.intExactly(value))
            XCTAssertNil(JSONHelp.intRounded(value))
            XCTAssertNil(JSONHelp.intTruncating(value))
        }
    }

    func testDateAcceptsOnlyFiniteEpochsInSupportedRange() {
        XCTAssertEqual(JSONHelp.date(0), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(JSONHelp.date("253402300799"), Date(timeIntervalSince1970: 253_402_300_799))
        XCTAssertNil(JSONHelp.date(-1))
        XCTAssertNil(JSONHelp.date(253_402_300_800))
        XCTAssertNil(JSONHelp.date("253402300800000"))
        XCTAssertNil(JSONHelp.date(true))
        XCTAssertNil(JSONHelp.date(Double.nan))
        XCTAssertNil(JSONHelp.date(Double.infinity))
        XCTAssertNil(JSONHelp.date("10000-01-01T00:00:00Z"))
        XCTAssertNotNil(JSONHelp.date("9999-12-31T23:59:59Z"))
        let utcMidnight = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01T00:00:00Z
        XCTAssertEqual(JSONHelp.date("2026-09-01T00:00:00"), utcMidnight)
        XCTAssertEqual(JSONHelp.date("2026-09-01 00:00:00"), utcMidnight)
        XCTAssertEqual(JSONHelp.date("2026-09-01"), utcMidnight)
        XCTAssertNil(JSONHelp.date("not-a-date"))

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(JSONHelp.date(byAdding: 60, to: base), base.addingTimeInterval(60))
        XCTAssertNil(JSONHelp.date(byAdding: .greatestFiniteMagnitude, to: base))
        XCTAssertNil(JSONHelp.date(byAdding: -1_800_000_000, to: base))
    }

    func testPercentNeverReturnsNonFinite() {
        for value in ["NaN", "Infinity", "-Infinity", "1e309"] {
            XCTAssertNil(JSONHelp.percent(value))
        }
        XCTAssertEqual(JSONHelp.percent(0.25), 25)
        XCTAssertEqual(JSONHelp.percent(25), 25)
    }

    func testPercentAlreadyHundredKeepsNativeZeroToHundred() {
        XCTAssertEqual(JSONHelp.percentAlreadyHundred(1), 1)
        XCTAssertEqual(JSONHelp.percentAlreadyHundred(0.5), 0.5)
        XCTAssertEqual(JSONHelp.percentAlreadyHundred(25), 25)
        XCTAssertEqual(JSONHelp.percentAlreadyHundred(150), 100)
        XCTAssertEqual(JSONHelp.percentAlreadyHundred(-3), 0)
        XCTAssertNil(JSONHelp.percentAlreadyHundred(true))
        XCTAssertNil(JSONHelp.percentAlreadyHundred("NaN"))
    }

}

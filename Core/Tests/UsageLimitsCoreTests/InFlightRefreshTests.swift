import XCTest
@testable import UsageLimitsCore

final class InFlightRefreshTests: XCTestCase {
    func testMatchingStateDoesNotAbort() {
        XCTAssertFalse(InFlightRefresh.shouldAbort(
            startAccountPresent: true,
            currentAccountPresent: true,
            startFingerprint: "a",
            currentFingerprint: "a",
            startGeneration: 1,
            currentGeneration: 1
        ))
    }

    func testLoginProbeWithoutAccountDoesNotAbort() {
        XCTAssertFalse(InFlightRefresh.shouldAbort(
            startAccountPresent: false,
            currentAccountPresent: false,
            startFingerprint: nil,
            currentFingerprint: nil,
            startGeneration: 0,
            currentGeneration: 0
        ))
    }

    func testAbortsWhenAccountRemoved() {
        XCTAssertTrue(InFlightRefresh.shouldAbort(
            startAccountPresent: true,
            currentAccountPresent: false,
            startFingerprint: nil,
            currentFingerprint: nil,
            startGeneration: 0,
            currentGeneration: 0
        ))
    }

    func testAbortsWhenFingerprintCleared() {
        XCTAssertTrue(InFlightRefresh.shouldAbort(
            startAccountPresent: true,
            currentAccountPresent: true,
            startFingerprint: "bound",
            currentFingerprint: nil,
            startGeneration: 2,
            currentGeneration: 2
        ))
    }

    func testAbortsWhenGenerationBumpsEvenWithoutFingerprint() {
        XCTAssertTrue(InFlightRefresh.shouldAbort(
            startAccountPresent: true,
            currentAccountPresent: true,
            startFingerprint: nil,
            currentFingerprint: nil,
            startGeneration: 0,
            currentGeneration: 1
        ))
    }

    func testAddingAccountDuringLoginProbeDoesNotAbort() {
        XCTAssertFalse(InFlightRefresh.shouldAbort(
            startAccountPresent: false,
            currentAccountPresent: true,
            startFingerprint: nil,
            currentFingerprint: nil,
            startGeneration: 0,
            currentGeneration: 0
        ))
    }
}

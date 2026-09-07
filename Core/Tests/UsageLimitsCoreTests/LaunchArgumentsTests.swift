import XCTest
@testable import UsageLimitsCore

final class LaunchArgumentsTests: XCTestCase {
    func testValueAfterFlagAndMissingCases() {
        let args = LaunchArguments(["app", "--demo", "--dashboard-theme", "helix", "--helix-coil-gain"])
        XCTAssertTrue(args.contains("--demo"))
        XCTAssertFalse(args.contains("--no-demo"))
        XCTAssertEqual(args.value(after: "--dashboard-theme"), "helix")
        XCTAssertNil(args.value(after: "--helix-coil-gain"), "flag 是最后一个参数时没有值")
        XCTAssertNil(args.value(after: "--open-login"))
    }
}

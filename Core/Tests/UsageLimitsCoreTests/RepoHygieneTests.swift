import XCTest
@testable import UsageLimitsCore

final class RepoHygieneTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testGitignoreBlocksLocalAuthDumpsAndBuildArtifacts() throws {
        let ignore = try String(
            contentsOf: repoRoot.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        for line in ["logs/", "my-interface-docs/", "Core/build/", "HANDOFF.md", "*.p8"] {
            XCTAssertTrue(ignore.contains(line), "\(line) 必须单独忽略，防止再把本机抓包或中间产物推进 git")
        }
        XCTAssertFalse(
            ignore.contains("logs/my-interface-docs/"),
            "不得再写成一条错误路径：它忽略不了 logs/ 或根目录 my-interface-docs/"
        )
    }

    func testGitIndexOmitsCaptureDumpsAndLocalBuild() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.currentDirectoryURL = repoRoot
        proc.arguments = ["ls-files", "--", "logs", "my-interface-docs", "Core/build", "HANDOFF.md"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "git ls-files 失败")
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(out.isEmpty, "这些本机路径不得再出现在 git 索引：\(out)")
    }
}

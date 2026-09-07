import Foundation

// XcodeGen 只定义一份共享 scheme；关闭 Xcode 为依赖目标自动创建额外 scheme。
// 由 project.yml 的 postGenCommand 调用，不修改 pbxproj 或本机签名配置。
let project = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "UsageLimits.xcodeproj")
let directory = project.appendingPathComponent("project.xcworkspace/xcshareddata", isDirectory: true)
let settingsURL = directory.appendingPathComponent("WorkspaceSettings.xcsettings")
let files = FileManager.default
var settings: [String: Any] = [:]
if files.fileExists(atPath: settingsURL.path) {
    let data = try Data(contentsOf: settingsURL)
    guard let existing = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    settings = existing
}
settings["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded"] = false
try files.createDirectory(at: directory, withIntermediateDirectories: true)
try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
    .write(to: settingsURL, options: .atomic)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageLimitsCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "UsageLimitsCore", targets: ["UsageLimitsCore"])
    ],
    targets: [
        .target(
            name: "UsageLimitsCore",
            resources: [.copy("Resources/AppStoreQR.png")]
        ),
        .testTarget(
            name: "UsageLimitsCoreTests",
            dependencies: ["UsageLimitsCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)

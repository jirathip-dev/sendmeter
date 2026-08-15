// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SendmeterNative",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "SendmeterCore", targets: ["SendmeterCore"])
    ],
    targets: [
        .target(
            name: "SendmeterCore",
            path: "Sources/Core"
        ),
        .testTarget(
            name: "SendmeterCoreTests",
            dependencies: ["SendmeterCore"],
            path: "Tests/SendmeterCoreTests"
        )
    ]
)

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
    dependencies: [
        // Local path dependency mirrors project.yml's SendLogWatchCore pin.
        // The core library REUSES the watch's pure model code rather than
        // duplicating it: RPEDepletion (W'-depletion RPE prediction, #627)
        // and HandsFreeForce (the hands-free arming state machine, #628).
        .package(path: "../../ios/App/SendLogWatchCore")
    ],
    targets: [
        .target(
            name: "SendmeterCore",
            dependencies: ["SendLogWatchCore"],
            path: "Sources/Core"
        ),
        .testTarget(
            name: "SendmeterCoreTests",
            dependencies: ["SendmeterCore", "SendLogWatchCore"],
            path: "Tests/SendmeterCoreTests"
        )
    ]
)

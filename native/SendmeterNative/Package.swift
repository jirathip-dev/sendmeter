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
            // #649: ChartTheme.swift lives at Sources/App/ChartTheme.swift
            // (the issue's placement, next to DesignSystem.swift) but must be
            // unit-testable via `swift test`, which only compiles this
            // package — so it is compiled into SendmeterCore here. The
            // XcodeGen app target EXCLUDES the same file (project.yml) so the
            // app gets exactly one definition, via this module.
            path: "Sources",
            sources: ["Core", "App/ChartTheme.swift"]
        ),
        .testTarget(
            name: "SendmeterCoreTests",
            dependencies: ["SendmeterCore", "SendLogWatchCore"],
            path: "Tests/SendmeterCoreTests"
        )
    ]
)

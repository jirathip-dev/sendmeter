// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SendmeterNative",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "SendmeterCore", targets: ["SendmeterCore"]),
        .library(name: "SendmeterWeather", targets: ["SendmeterWeather"])
    ],
    dependencies: [
        // Local path dependency mirrors project.yml's SendLogWatchCore pin.
        // The core library REUSES the watch's pure model code rather than
        // duplicating it: RPEDepletion (W'-depletion RPE prediction, #627)
        // and HandsFreeForce (the hands-free arming state machine, #628).
        .package(path: "../../ios/App/SendLogWatchCore"),
        // #661 F3: `SyncTrigger`/`ReadinessWritePolicy` (#109) live in the
        // readiness core the shipped plugin shares — SendmeterCore maps its
        // triggers to the same `SyncTrigger` and consults the same policy
        // rather than reimplementing either.
        .package(path: "../../native-plugins/sendlog-health-core"),
        // #747: remote GRDB pin — the package identity is GRDB.swift (derived
        // from the URL), so target dependencies must use `package: "GRDB.swift"`.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")
    ],
    targets: [
        .target(
            name: "SendmeterCore",
            dependencies: [
                "SendLogWatchCore",
                .product(name: "SendLogHealthCore", package: "sendlog-health-core"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            // #649: ChartTheme.swift lives at Sources/App/ChartTheme.swift
            // (the issue's placement, next to DesignSystem.swift) but must be
            // unit-testable via `swift test`, which only compiles this
            // package — so it is compiled into SendmeterCore here. The
            // XcodeGen app target EXCLUDES the same file (project.yml) so the
            // app gets exactly one definition, via this module.
            path: "Sources",
            sources: ["Core", "App/ChartTheme.swift"]
        ),
        .target(
            name: "SendmeterWeather",
            dependencies: ["SendmeterCore"],
            path: "Sources",
            sources: ["Platform/WeatherService.swift"]
        ),
        .testTarget(
            name: "SendmeterCoreTests",
            dependencies: ["SendmeterCore", "SendLogWatchCore", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/SendmeterCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SendmeterWeatherTests",
            dependencies: ["SendmeterWeather", "SendmeterCore"],
            path: "Tests/SendmeterWeatherTests"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift (Foundation only) watch-app logic — attempt detection, RPE
// modeling, ACWR, Tindeq protocol parsing, hands-free force control, and the
// tag/queue policy decisions — kept free of WatchKit/SwiftUI/HealthKit/CoreBluetooth/Supabase
// so its unit tests run on the host via `swift test`, no watchOS simulator
// required (issue #191).
let package = Package(
    name: "SendLogWatchCore",
    platforms: [.watchOS(.v10), .iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SendLogWatchCore", targets: ["SendLogWatchCore"])
    ],
    dependencies: [
        // #802: the watch reads its own HealthKit and computes readiness
        // with the SAME RecoveryEngine the phone uses — the readiness math
        // and the #109 write policy live in the shared health-core package.
        .package(path: "../../../native-plugins/sendlog-health-core")
    ],
    targets: [
        .target(
            name: "SendLogWatchCore",
            dependencies: [
                .product(name: "SendLogHealthCore", package: "sendlog-health-core")
            ],
            path: "Sources/SendLogWatchCore"
        ),
        .testTarget(
            name: "SendLogWatchCoreTests",
            dependencies: ["SendLogWatchCore"],
            path: "Tests/SendLogWatchCoreTests",
            resources: [
                .copy("Fixtures/rpe-depletion-parity.json"),
                .copy("Fixtures/readiness-acwr-parity.json")
            ]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift (Foundation only) watch-app logic — attempt detection, RPE
// modeling, ACWR, Tindeq protocol parsing, and the tag/queue policy
// decisions — kept free of WatchKit/SwiftUI/HealthKit/CoreBluetooth/Supabase
// so its unit tests run on the host via `swift test`, no watchOS simulator
// required (issue #191).
let package = Package(
    name: "SendLogWatchCore",
    platforms: [.watchOS(.v10), .iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SendLogWatchCore", targets: ["SendLogWatchCore"])
    ],
    targets: [
        .target(name: "SendLogWatchCore", path: "Sources/SendLogWatchCore"),
        .testTarget(
            name: "SendLogWatchCoreTests",
            dependencies: ["SendLogWatchCore"],
            path: "Tests/SendLogWatchCoreTests",
            resources: [.copy("Fixtures/rpe-depletion-parity.json")]
        )
    ]
)

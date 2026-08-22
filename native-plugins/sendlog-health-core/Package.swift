// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift (Foundation only) readiness math shared by the iOS health
// plugin. Deliberately free of HealthKit / Supabase / Capacitor so its unit
// tests run on the host via `swift test` — the readiness score's correctness
// is verifiable without a device or simulator.
let package = Package(
    name: "SendLogHealthCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SendLogHealthCore", targets: ["SendLogHealthCore"])
    ],
    targets: [
        .target(name: "SendLogHealthCore", path: "Sources/SendLogHealthCore"),
        .testTarget(
            name: "SendLogHealthCoreTests",
            dependencies: ["SendLogHealthCore"],
            path: "Tests/SendLogHealthCoreTests",
            resources: [.copy("Fixtures/readiness-acwr-parity.json")]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SendlogHealth",
    // iOS 16: the Supabase SDK's minimum. Consistent with the app already
    // shipping a watchOS 10 (2023) companion.
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "SendlogHealth",
            targets: ["SendLogHealth"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.5.0"),
        .package(path: "../sendlog-health-core")
    ],
    targets: [
        .target(
            name: "SendLogHealth",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "SendLogHealthCore", package: "sendlog-health-core")
            ],
            path: "ios/Sources/SendLogHealth")
    ]
)

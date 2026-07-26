// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SendlogAuthBridge",
    // iOS 16, matching the app's actual minimum and every other local plugin.
    // Raised from 15 for SendLogWatchCore, which floors at 16 (the Supabase
    // SDK's minimum, inherited by the whole native side).
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "SendlogAuthBridge",
            targets: ["SendLogAuthBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        // The watch↔phone message contract (build report shape + verdict)
        // lives in the watch's pure-logic package so both ends read it from
        // one place and it stays unit-tested on Linux CI (#191/#199, #228).
        .package(path: "../../ios/App/SendLogWatchCore")
    ],
    targets: [
        .target(
            name: "SendLogAuthBridge",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "SendLogWatchCore", package: "SendLogWatchCore")
            ],
            path: "ios/Sources/SendLogAuthBridge")
    ]
)

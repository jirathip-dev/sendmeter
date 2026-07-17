// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SendlogPasskey",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "SendlogPasskey",
            targets: ["SendLogPasskey"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "SendLogPasskey",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/SendLogPasskey")
    ]
)

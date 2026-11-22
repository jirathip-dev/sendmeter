// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SendmeterRedesign",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/jirathip-dev/blocks", revision: "e823e0b1987b59059a77e56266d06749ba4d860d")
    ],
    targets: [
        .executableTarget(
            name: "redesign-render",
            dependencies: [.product(name: "Blocks", package: "blocks"), .product(name: "BlocksUI", package: "blocks")],
            path: "Sources/redesign-render",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

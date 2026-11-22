# swift/warnings: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## strict-flag-missing

Writes `Package.swift`:

```
// swift-tools-version: 6.0
import Foundation
import PackageDescription

let strict: [SwiftSetting] = []

let package = Package(
    name: "App",
    targets: [
        .target(name: "App", swiftSettings: strict),
        .testTarget(name: "AppTests", dependencies: ["App"], swiftSettings: strict),
    ]
)
```

The gate fails and its log prints `Package.swift: treats warnings as errors under no GATEKEEPER_STRICT=1`.

Fix: fix the warning the compiler names; a package's Package.swift adds -warnings-as-errors to its targets when GATEKEEPER_STRICT is 1. Rerun: `./.gatekeeper/run check --gate swift/warnings`

## warning

Writes `Tests/AppTests/WarningTests.swift`:

```
import Testing

@Test func unused() {
    let value = 1
}
```

The gate fails and its log prints `never used`.

Fix: fix the warning the compiler names; a package's Package.swift adds -warnings-as-errors to its targets when GATEKEEPER_STRICT is 1. Rerun: `./.gatekeeper/run check --gate swift/warnings`

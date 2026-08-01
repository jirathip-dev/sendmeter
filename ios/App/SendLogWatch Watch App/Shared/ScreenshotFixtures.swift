import Foundation

/// Deterministic App Store screenshot data. Fastlane's official SnapshotHelper
/// adds `-FASTLANE_SNAPSHOT YES` only to the UI-test launch; normal simulator,
/// TestFlight and App Store launches never enter this path.
enum ScreenshotFixtures {
    static let enabled: Bool = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-FASTLANE_SNAPSHOT") else {
            return false
        }
        return args.indices.contains(index + 1) && args[index + 1] == "YES"
    }()

    static let status = WidgetSnapshot(
        readiness: 82,
        readinessZone: "Push",
        acwr: 1.08,
        acwrRisk: "Optimal",
        workoutActive: false,
        boulders: 0,
        climbing: false,
        phaseSinceEpoch: nil,
        restTargetS: 180,
        updatedAt: 1_788_000_000
    )
}

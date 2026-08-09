import Foundation
import SendLogWatchCore

/// The screenshot target starts the real watch hierarchy with one of these
/// deterministic states. Fixtures are intentionally presentation-only: they
/// never replace a production view with a marketing mock and never alter a
/// queue, auth relay, workout detector or force algorithm.
enum ScreenshotFixtureState: String, CaseIterable {
    case status
    case statusEmpty
    case statusSyncing
    case statusOffline
    case statusCached
    case waiting
    case actions
    case actionsOffline
    case actionsSyncing
    case workoutIdle
    case workoutLive
    case workoutRest
    case workoutSaved
    case workoutError
    case forceIdle
    case forceConnecting
    case forceSetup
    case forceConnected
    case forceLive
    case forceSaved
    case forceError
}

struct ScreenshotWorkoutVisual {
    let phase: WorkoutPhase
    let heartRate: Double
    let elapsed: TimeInterval
    let attempts: Int
    let activeKcal: Double
    let altitude: Double
    let currentTimer: String
    let stillQueued: Bool
    let errorMessage: String?
}

struct ScreenshotForceVisual {
    enum Status {
        case idle, connecting, connected, measuring
    }

    let status: Status
    let tag: String
    let side: String
    let currentKg: Double
    let peakKg: Double
    let elapsedS: Double
    let sessionCount: Int
    let savedMessage: String?
    let errorMessage: String?
}

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

    static var state: ScreenshotFixtureState {
        guard enabled,
              let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-sendmeter-fixture"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1),
              let state = ScreenshotFixtureState(rawValue: ProcessInfo.processInfo.arguments[index + 1])
        else { return .status }
        return state
    }

    static var status: WidgetSnapshot {
        switch state {
        case .statusEmpty:
            return WidgetSnapshot(
                readiness: nil, readinessZone: nil,
                acwr: nil, acwrRisk: nil,
                workoutActive: false, boulders: 0, climbing: false,
                phaseSinceEpoch: nil, restTargetS: 180, updatedAt: 0
            )
        case .statusOffline:
            return WidgetSnapshot(
                readiness: nil, readinessZone: nil,
                acwr: nil, acwrRisk: nil,
                workoutActive: false, boulders: 0, climbing: false,
                phaseSinceEpoch: nil, restTargetS: 180, updatedAt: 0
            )
        case .statusCached:
            return WidgetSnapshot(
                readiness: 64, readinessZone: "Maintain",
                acwr: 1.31, acwrRisk: "Caution",
                workoutActive: false, boulders: 0, climbing: false,
                phaseSinceEpoch: nil, restTargetS: 180, updatedAt: 1_788_000_000
            )
        default:
            return WidgetSnapshot(
                readiness: 82, readinessZone: "Push",
                acwr: 1.08, acwrRisk: "Optimal",
                workoutActive: false, boulders: 0, climbing: false,
                phaseSinceEpoch: nil, restTargetS: 180, updatedAt: 1_788_000_000
            )
        }
    }

    static var waitingSyncing: Bool { state == .waiting }
    static var waitingPendingUploads: Int? { state == .waiting ? 2 : nil }
    static var waitingRejectionMessage: String? {
        state == .waiting ? "Your iPhone is not answering yet. Keep Sendmeter open nearby." : nil
    }

    static var actionPendingUploads: Int? {
        switch state {
        case .actionsOffline: 3
        case .actionsSyncing: 1
        default: nil
        }
    }

    static var actionState: WatchVisualState? {
        switch state {
        case .actionsOffline: .offline
        case .actionsSyncing: .syncing
        default: nil
        }
    }

    static var workoutScreen: WorkoutScreen? {
        switch state {
        case .workoutLive, .workoutRest: .live
        case .workoutSaved: .saved
        case .workoutIdle, .workoutError: .start
        default: nil
        }
    }

    static var workout: ScreenshotWorkoutVisual? {
        switch state {
        case .workoutLive:
            ScreenshotWorkoutVisual(
                phase: .climbing, heartRate: 148, elapsed: 2_712,
                attempts: 12, activeKcal: 327, altitude: 1.4,
                currentTimer: "01:13", stillQueued: false, errorMessage: nil
            )
        case .workoutRest:
            ScreenshotWorkoutVisual(
                phase: .resting, heartRate: 142, elapsed: 2_793,
                attempts: 12, activeKcal: 341, altitude: 1.4,
                currentTimer: "02:07", stillQueued: false, errorMessage: nil
            )
        case .workoutSaved:
            ScreenshotWorkoutVisual(
                phase: .idle, heartRate: 0, elapsed: 0,
                attempts: 12, activeKcal: 341, altitude: 1.4,
                currentTimer: "", stillQueued: true, errorMessage: nil
            )
        case .workoutError:
            ScreenshotWorkoutVisual(
                phase: .idle, heartRate: 0, elapsed: 0,
                attempts: 0, activeKcal: 0, altitude: 0,
                currentTimer: "", stillQueued: false,
                errorMessage: "Health sensors are unavailable. Try again or start offline."
            )
        default: nil
        }
    }

    static var workoutRestTargetS: Int? {
        state == .workoutRest ? 180 : nil
    }

    static var force: ScreenshotForceVisual? {
        switch state {
        case .forceIdle:
            ScreenshotForceVisual(status: .idle, tag: "", side: "", currentKg: 0, peakKg: 0, elapsedS: 0, sessionCount: 0, savedMessage: nil, errorMessage: nil)
        case .forceConnecting:
            ScreenshotForceVisual(status: .connecting, tag: "", side: "", currentKg: 0, peakKg: 0, elapsedS: 0, sessionCount: 0, savedMessage: nil, errorMessage: nil)
        case .forceSetup:
            ScreenshotForceVisual(status: .connected, tag: "Half crimp", side: "Left", currentKg: 0, peakKg: 0, elapsedS: 0, sessionCount: 0, savedMessage: nil, errorMessage: nil)
        case .forceConnected:
            ScreenshotForceVisual(status: .connected, tag: "Crimp edge", side: "Left", currentKg: 0, peakKg: 0, elapsedS: 0, sessionCount: 3, savedMessage: nil, errorMessage: nil)
        case .forceLive:
            ScreenshotForceVisual(status: .measuring, tag: "Crimp edge", side: "Left", currentKg: 34.7, peakKg: 38.2, elapsedS: 7.4, sessionCount: 3, savedMessage: nil, errorMessage: nil)
        case .forceSaved:
            ScreenshotForceVisual(status: .connected, tag: "Crimp edge", side: "Left", currentKg: 0, peakKg: 0, elapsedS: 0, sessionCount: 3, savedMessage: "Saved · 38.2 kg · Crimp edge", errorMessage: nil)
        case .forceError:
            ScreenshotForceVisual(status: .connected, tag: "", side: "", currentKg: 0, peakKg: 0, elapsedS: 0, sessionCount: 0, savedMessage: nil, errorMessage: "Progressor is out of range. Check the gauge and try again.")
        default: nil
        }
    }
}

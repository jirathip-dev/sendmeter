import AppIntents
import Foundation
import os

// Lock-screen Boulder/Stop for the Manual workout Live Activity (#763).
// LiveActivityIntent.perform() runs in the APP process, so these call the
// shared ManualWorkoutActivityManager directly. The widget extension has
// matching no-op stubs purely so Button(intent:) compiles there.

private let intentLog = Logger(
    subsystem: "com.jirathip.sendlog.native",
    category: "manual-workout-intent"
)

@available(iOS 17.0, *)
struct BoulderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start boulder"

    func perform() async throws -> some IntentResult {
        intentLog.info("Manual workout BoulderIntent running in app process")
        await ManualWorkoutActivityManager.shared.handleAction(.beginBoulder, at: Date())
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop boulder"

    func perform() async throws -> some IntentResult {
        intentLog.info("Manual workout StopIntent running in app process")
        await ManualWorkoutActivityManager.shared.handleAction(.endBoulder, at: Date())
        return .result()
    }
}

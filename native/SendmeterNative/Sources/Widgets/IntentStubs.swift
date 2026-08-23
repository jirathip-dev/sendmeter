import AppIntents
import os

// Compile-time stubs so Button(intent:) resolves inside the widget target.
// LiveActivityIntent execution is routed by the system to the APP process,
// where the real implementations in App/LiveActivityIntents.swift run (they
// call ManualWorkoutActivityManager.shared). These bodies should never
// execute — the os_log lines exist to verify that on device.

private let stubLog = Logger(
    subsystem: "com.jirathip.sendlog.native.widgets",
    category: "intent-stub"
)

@available(iOS 17.0, *)
struct BoulderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start boulder"
    func perform() async throws -> some IntentResult {
        stubLog.error("BoulderIntent STUB ran in widget process — expected app-process routing")
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop boulder"
    func perform() async throws -> some IntentResult {
        stubLog.error("StopIntent STUB ran in widget process — expected app-process routing")
        return .result()
    }
}

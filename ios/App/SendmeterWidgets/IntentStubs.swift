import AppIntents

// Compile-time stubs so `Button(intent:)` resolves inside the widget.
// LiveActivityIntent execution is routed by the system to the APP process,
// where the real implementations in App/LiveActivityIntents.swift run
// (they call LiveActivityManager). These bodies should never execute —
// the os_log lines exist to verify that on device.

import os

private let stubLog = Logger(subsystem: "com.jirathip.sendlog.widgets", category: "intent-stub")

struct BoulderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start boulder"
    func perform() async throws -> some IntentResult {
        stubLog.error("BoulderIntent STUB ran in widget process — expected app-process routing")
        return .result()
    }
}

struct StopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop boulder"
    func perform() async throws -> some IntentResult {
        stubLog.error("StopIntent STUB ran in widget process — expected app-process routing")
        return .result()
    }
}

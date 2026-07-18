import AppIntents
import Foundation
import SendLogLiveActivity
import os

// Lock-screen Boulder/Stop for the workout Live Activity. LiveActivityIntent
// runs in the APP process (the system launches the app headlessly if
// needed), so these can use LiveActivityManager + UserDefaults.standard
// directly. Twin no-op stubs exist in the widget target purely so
// Button(intent:) compiles there — these are the implementations that run.

private let intentLog = Logger(subsystem: "com.jirathip.sendlog", category: "live-activity-intent")

@available(iOS 17.0, *)
struct BoulderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start boulder"

    func perform() async throws -> some IntentResult {
        intentLog.info("BoulderIntent running in app process")
        await LiveActivityManager.shared.handleAction("beginBoulder", at: Date())
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop boulder"

    func perform() async throws -> some IntentResult {
        intentLog.info("StopIntent running in app process")
        await LiveActivityManager.shared.handleAction("endBoulder", at: Date())
        return .result()
    }
}

import SwiftUI

@main
struct SendLogWatchApp: App {
    @State private var auth = AuthManager()
    // Owned here (not in ForceGaugeView) so the Progressor stays connected and
    // the active gauge session survives navigating away from the Force screen
    // (SL-58 #5). The disconnect-mid-session prompt is presented from RootView.
    @State private var tindeq = TindeqManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(tindeq)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // An access token expires by the clock alone, with no event to
                // react to (#265) — re-evaluate on every foreground, which also
                // re-asks the phone when the token has gone stale.
                Task { @MainActor in auth.refreshState() }
                Task { await OfflineQueue.shared.drain() }
                Task { await PendingSessionQueue.shared.drain() }
                Task { await PendingRecordingQueue.shared.drain() }
                Task { await WatchBuild.refreshAndReportQueueStatus() }
                // Keep the complications/Smart-Stack readiness + ACWR fresh.
                Task { await WidgetBridge.refreshStatus() }
            }
        }
    }
}

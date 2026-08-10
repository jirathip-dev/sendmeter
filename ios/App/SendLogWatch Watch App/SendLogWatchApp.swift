import SwiftUI
import SendLogWatchCore

@main
struct SendLogWatchApp: App {
    @State private var auth = AuthManager()
    @State private var readiness = ReadinessManager()
    // Owned here (not in ForceGaugeView) so the Progressor stays connected and
    // the active gauge session survives navigating away from the Force screen
    // (SL-58 #5). The disconnect-mid-session prompt is presented from RootView.
    @State private var tindeq = TindeqManager()
    // #476: was `@State` inside WorkoutLiveView, a navigationDestination — it
    // died whenever that view was popped (a Force/status complication deep
    // link) or the NavigationStack was swapped out from under it (a
    // signedOut auth relay mid-workout), silently orphaning a live
    // HKWorkoutSession with no reachable End control. Hoisted to App scope,
    // matching `tindeq` above — the asymmetry between the two was the bug.
    @State private var workout = WorkoutManager()
    // The read-only Force catalog lives at app scope so a navigation pop does
    // not throw away a fresh response while the gauge remains connected. Its
    // cache/selection are still persisted independently for relaunch recovery.
    @State private var forceProtocolCatalog = ForceProtocolCatalog()
    // Guided Force runs outlive the setup navigation destination. Keeping the
    // request/state here lets RootView switch to the runner without retaining
    // a closure captured by a view that may have disappeared.
    @State private var guidedForceRunner = GuidedForceRunner()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(readiness)
                .environment(tindeq)
                .environment(workout)
                .environment(forceProtocolCatalog)
                .environment(guidedForceRunner)
                .task { @MainActor in
                    readiness.request(reason: .launch)
                }
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
                // #531: a failed terminal live_workouts upsert has no other
                // trigger once its owning LiveWorkoutSync actor is gone.
                Task { await LiveWorkoutTerminalRetry.shared.retryNow() }
                Task { await WatchBuild.refreshAndReportQueueStatus() }
                // One watch-triggered path keeps the cached score, widgets,
                // and open status UI in sync; there is no duplicate foreground
                // health_metrics fetch from the app scene.
                Task { @MainActor in
                    readiness.request(reason: .foreground)
                }
                guidedForceRunner.refresh()
            }
        }
        // AuthManager stores the relay before publishing this state. Rebind
        // the catalog in the same synchronous turn so a new account can never
        // render the previous account's cached protocol rows or selection.
        .onChange(of: auth.state) { _, _ in
            forceProtocolCatalog.synchronizeAccountScope()
            guidedForceRunner.authStateDidChange(to: auth.state)
            // #529 slice-2 review F2: a manual/hands-free gauge session has
            // no natural end of its own (it spans the whole connect, not one
            // run) — called AFTER the guided runner so persistenceOwnerAssigned
            // truthfully reflects whether ITS teardown (discardWithoutSaving())
            // already ran this same event; tindeq.handleAccountTransition
            // no-ops while a guided run still owns the manager either way.
            tindeq.handleAccountTransition(to: auth.state.userId)
        }
    }
}

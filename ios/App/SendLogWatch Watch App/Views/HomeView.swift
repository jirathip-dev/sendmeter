import SendLogWatchCore
import SwiftUI

/// The watch home: two swipeable pages (#278). Page 1 is status — what shape
/// am I in — and page 2 is the things you can start. Swiping starts nothing;
/// page 2 has the same taps it always had.
///
/// Horizontal `.page` paging, not `.verticalPage`: page 2 is a List and page 1
/// scrolls when the text wraps, and both of those are driven by the Digital
/// Crown — vertical paging would fight the scroll on every page. Sideways also
/// matches the mental model better, since neither page is "below" the other.
///
/// This stays the root of RootView's NavigationStack, so the two
/// `NavigationLink(value:)`s below and the complication deep links push onto
/// the same path. The `.navigationDestination` lives up in RootView, outside
/// the TabView — a destination declared inside a paged TabView is only
/// registered while its page is realized, which is exactly how a deep link
/// arriving on the wrong page silently does nothing.
struct HomeView: View {
    @Binding var selection: WatchHomePage
    @State private var showGaugeSessionLoss = false

    var body: some View {
        TabView(selection: $selection) {
            StatusView()
                .tag(WatchHomePage.status)
            ActionsView()
                .tag(WatchHomePage.actions)
        }
        .tabViewStyle(.page)
        .navigationTitle("Sendmeter")
        .onAppear {
            if GaugeSessionLossNotice.consume() {
                showGaugeSessionLoss = true
            }
        }
        .alert("Force session not saved", isPresented: $showGaugeSessionLoss) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your force recordings may appear ungrouped in History. Create a session for them on your phone.")
        }
    }
}

/// Page 2 — the things you can start from the wrist.
private struct ActionsView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(WorkoutManager.self) private var workout
    @State private var pendingUploads = 0

    var body: some View {
        List {
            NavigationLink(value: WatchDest.force) {
                Label("Force Gauge", systemImage: "scalemass")
            }

            NavigationLink(value: WatchDest.workout) {
                Label("Climb Workout", systemImage: "figure.climbing")
            }

            // #476: the workout survives a Force/status complication tap now
            // (hoisted to App scope), but this link is still the only way
            // back to it from Home — say so, since nothing on the Force/
            // status screens themselves hints a workout is running behind them.
            if workout.isRunning {
                Label("Workout running — tap Climb Workout to end it", systemImage: "figure.climbing")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if pendingUploads > 0 {
                Label("\(pendingUploads) pending upload\(pendingUploads == 1 ? "" : "s")", systemImage: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            // The offline window (#265): the relayed access token has expired
            // and only the phone can supply another. Recording still works —
            // everything is persist-first and drains later — so say that
            // rather than dumping the user on a sign-in screen mid-session.
            if auth.needsToken && !ScreenshotFixtures.enabled {
                Label(
                    "Waiting for iPhone — new saves upload once it's in range",
                    systemImage: "iphone.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            // No Sign Out here, and none anywhere else on the watch (#278).
            // The watch has no session of its own to end — it mirrors the
            // phone's — and the old button called supabase-swift's
            // globally-scoped signOut, which revoked every session on the
            // account, including the phone's. The "Signed in from your iPhone"
            // footer went with it: automatic sign-in is the normal path and
            // doesn't need narrating.
        }
        .task {
            async let workouts = OfflineQueue.shared.pendingCount()
            async let sessions = PendingSessionQueue.shared.pendingCount()
            pendingUploads = await workouts + sessions
        }
    }
}

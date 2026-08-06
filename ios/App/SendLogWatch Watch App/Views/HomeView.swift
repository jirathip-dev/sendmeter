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
    @State private var pendingUploads = 0
    /// nil until the `.task` below resolves (review F22) — unknown must not
    /// render as `.current`/healthy, so the row simply doesn't show until
    /// there's an actual reading, rather than defaulting to "fine".
    @State private var syncFreshness: SyncFreshness?
    /// Whether `OfflineQueue` currently has a backoff retry armed (review
    /// F18) — read alongside `syncFreshness` so the row's copy can say
    /// "retrying automatically" only when that's actually true, rather than
    /// asserting it for every stale reading.
    @State private var retryScheduled = false

    var body: some View {
        List {
            NavigationLink(value: WatchDest.force) {
                Label("Force Gauge", systemImage: "scalemass")
            }

            NavigationLink(value: WatchDest.workout) {
                Label("Climb Workout", systemImage: "figure.climbing")
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
            if auth.needsTokenForDisplay && !ScreenshotFixtures.enabled {
                Label(
                    "Waiting for iPhone — new saves upload once it's in range",
                    systemImage: "iphone.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else if case let .stale(lastSuccessfulSyncAt)? = syncFreshness, !ScreenshotFixtures.enabled {
                // #472b: a different signal from the row above — items are
                // waiting AND the queue hasn't landed anything in a while,
                // which `auth.needsToken` alone wouldn't catch (a queue can
                // stall on a real outage or an unrecognized rejection with a
                // perfectly fresh token). Shown only when `needsToken` isn't
                // already saying something (review nit: the two otherwise
                // overlap, and the `needsToken` row already covers "no token
                // yet" — the case where nothing is actually retrying, F18).
                // Same honest-states rule as everywhere else here: never
                // having synced reads as stale, not as quiet/healthy.
                Label(
                    staleSyncMessage(lastSuccessfulSyncAt, retryScheduled: retryScheduled),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
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
            // #472b review F19: `syncFreshness` is scoped to `OfflineQueue`
            // ALONE, matching `lastSuccessfulSyncAt()`'s own source — joining
            // it with `PendingSessionQueue`'s count (which has no relation to
            // that marker at all, and no retry machinery of its own) made the
            // signal describe something neither queue actually does. The
            // combined `pendingUploads` badge above is unrelated and keeps
            // counting both, same as before.
            async let workouts = OfflineQueue.shared.pendingCount()
            async let sessions = PendingSessionQueue.shared.pendingCount()
            async let lastSync = OfflineQueue.shared.lastSuccessfulSyncAt()
            async let armed = OfflineQueue.shared.isRetryScheduled()
            let (workoutCount, sessionCount, syncedAt, isArmed) = await (workouts, sessions, lastSync, armed)
            pendingUploads = workoutCount + sessionCount
            retryScheduled = isArmed
            syncFreshness = SyncFreshnessPolicy.evaluate(
                lastSuccessfulSyncAt: syncedAt,
                hasPending: workoutCount > 0,
                now: Date()
            )
        }
    }

    private func staleSyncMessage(_ lastSuccessfulSyncAt: Date?, retryScheduled: Bool) -> String {
        var base = "Nothing has synced yet"
        if let lastSuccessfulSyncAt {
            let minutes = max(0, Int(Date().timeIntervalSince(lastSuccessfulSyncAt) / 60))
            base = "Last synced \(minutes)m ago"
        }
        // Review F18: only claim an automatic retry is happening when one
        // actually is armed — e.g. NOT true for a signed-out watch, where
        // `drainPass` never even attempts an upload and so never stalls.
        return retryScheduled ? "\(base) — retrying automatically" : base
    }
}

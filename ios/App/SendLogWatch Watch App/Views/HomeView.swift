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
/// #486 review F6: `GaugeSessionLossNotice` and `RecordingLossNotice` are
/// both destructive one-shot `UserDefaults` flags, and — far from an
/// exotic edge case — the SAME event can set both: a BLE drop mid-hold can
/// both lose the in-flight rep (`RecordingLossNotice`) AND, since
/// `logSessionNow()` always runs right after, fail to log the gauge session
/// that was grouping it (`GaugeSessionLossNotice`). Two independently
/// chained `.alert` modifiers on one view race to present; whichever loses
/// has ALREADY had its `consume()` called (destructive, before the race even
/// starts), so that notice is gone for good — precisely the #264 "reported,
/// never swallowed" failure the notices exist to prevent. `LossNotice` below
/// queues whatever `onAppear` consumed and a single `.alert` presents them
/// one at a time, advancing on dismiss.
enum LossNotice {
    case gaugeSession
    case recording

    /// #495 R4: `onAppear` used to ASSIGN the freshly consumed notices over
    /// `lossQueue` — if an earlier notice was still waiting (its alert was
    /// dismissed by navigation before anyone tapped OK), the assignment
    /// silently dropped it: the durable flag had already been consumed, so
    /// the loss was never presented anywhere. Same shape as the round-1
    /// finding on #486 (a consumed-but-never-presented notice), one step
    /// later in the pipeline. Merge instead: whatever is still waiting stays
    /// at the front, newly consumed kinds append behind it. A kind already
    /// waiting is not duplicated — the backing flags are one-shot booleans,
    /// so any number of losses of one kind collapse to a single notice
    /// anyway, and presenting it twice would claim two events we cannot
    /// actually distinguish.
    static func merged(existing: [LossNotice], consumed: [LossNotice]) -> [LossNotice] {
        existing + consumed.filter { !existing.contains($0) }
    }

    var title: String {
        switch self {
        case .gaugeSession: return "Force session not saved"
        case .recording: return "A force rep was lost"
        }
    }

    var message: String {
        switch self {
        case .gaugeSession:
            return "Your force recordings may appear ungrouped in History. Create a session for them on your phone."
        case .recording:
            return "A recording couldn't be saved to your watch or uploaded. It's gone — the rest of your session is unaffected."
        }
    }
}

struct HomeView: View {
    @Binding var selection: WatchHomePage
    // #476 review finding F4: `sendmeter://status` sends the user to page 1
    // (`StatusView`), but the "workout running" hint used to live only in
    // `ActionsView` (page 2) — a status complication tap mid-workout landed
    // on a page that said nothing about it, reachable only by a blind swipe.
    // A banner ABOVE the pager, outside the `TabView`, is visible on
    // whichever page is selected.
    @Environment(WorkoutManager.self) private var workout

    // #486 review F6 supersedes the old single `showGaugeSessionLoss` flag:
    // two chained `.alert`s each with a destructive `consume()` could swallow
    // a notice when only one presented. One queue, one alert.
    @State private var lossQueue: [LossNotice] = []
    @State private var showLossAlert = false

    private var activeLossNotice: LossNotice? { lossQueue.first }

    var body: some View {
        VStack(spacing: 2) {
            if workout.isRunning {
                Label("Workout running — tap Climb Workout to end it", systemImage: "figure.climbing")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
            TabView(selection: $selection) {
                StatusView()
                    .tag(WatchHomePage.status)
                ActionsView()
                    .tag(WatchHomePage.actions)
            }
            .tabViewStyle(.page)
        }
        .navigationTitle("Sendmeter")
        .onAppear {
            var consumed: [LossNotice] = []
            if GaugeSessionLossNotice.consume() { consumed.append(.gaugeSession) }
            if RecordingLossNotice.consume() { consumed.append(.recording) }
            // #495 R4: MERGE onto whatever is still waiting (see
            // `LossNotice.merged`) — assigning here dropped an un-presented
            // notice — and re-present whenever the queue is non-empty, even
            // if nothing new was consumed this time: a navigation-dismissed
            // alert left `showLossAlert` false with its notice still queued,
            // which the old `guard !notices.isEmpty` return left stuck
            // forever.
            lossQueue = LossNotice.merged(existing: lossQueue, consumed: consumed)
            if !lossQueue.isEmpty { showLossAlert = true }
        }
        .alert(activeLossNotice?.title ?? "", isPresented: $showLossAlert) {
            Button("OK", role: .cancel) {
                if !lossQueue.isEmpty { lossQueue.removeFirst() }
                guard !lossQueue.isEmpty else { return }
                // Deferred a tick: SwiftUI is still processing this alert's
                // own dismiss (which also writes `showLossAlert = false`) —
                // flipping it back to true in the same pass is exactly the
                // "two alerts racing" shape this fix exists to avoid, just
                // sequential instead of concurrent. One tick later, the
                // dismiss has fully settled and the SAME `.alert` (now
                // reading the next `activeLossNotice`) presents cleanly.
                DispatchQueue.main.async { showLossAlert = true }
            }
        } message: {
            Text(activeLossNotice?.message ?? "")
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

            // The "workout running" hint lives in HomeView now, above the
            // pager (#476 review finding F4) — it needs to be visible on
            // whichever page a status/force deep link lands on, not just here.

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
            async let recordings = PendingRecordingQueue.shared.pendingCount()
            let (workoutCount, sessionCount, recordingCount, syncedAt, isArmed) = await (workouts, sessions, recordings, lastSync, armed)
            pendingUploads = workoutCount + sessionCount + recordingCount
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

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
private enum LossNotice {
    case gaugeSession
    case recording

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
    @State private var lossQueue: [LossNotice] = []
    @State private var showLossAlert = false

    private var activeLossNotice: LossNotice? { lossQueue.first }

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
            var notices: [LossNotice] = []
            if GaugeSessionLossNotice.consume() { notices.append(.gaugeSession) }
            if RecordingLossNotice.consume() { notices.append(.recording) }
            guard !notices.isEmpty else { return }
            lossQueue = notices
            showLossAlert = true
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
            async let recordings = PendingRecordingQueue.shared.pendingCount()
            pendingUploads = await workouts + sessions + recordings
        }
    }
}

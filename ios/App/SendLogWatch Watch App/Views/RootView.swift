import SwiftUI
import SendLogWatchCore

/// Navigation destinations reachable from the home list — also the targets the
/// quick-launch complications deep-link to (see .onOpenURL below).
enum WatchDest: Hashable {
    case force, workout
}

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(TindeqManager.self) private var tindeq
    @State private var path: [WatchDest] = []

    @ViewBuilder
    var body: some View {
        if ScreenshotFixtures.enabled {
            signedInContent
        } else {
            switch auth.state {
            case .signedOut:
                WaitingForPhoneView()
            // Deliberately includes `tokenFresh: false` — an expired access token
            // keeps the watch usable (recording is offline-first and queues), and
            // HomeView shows the "waiting for iPhone" banner instead of throwing
            // the user back to a sign-in screen (#265's offline window).
            case .signedIn(_, _):
                signedInContent
            }
        }
    }

    /// The real signed-in UI is also the screenshot fixture UI. Snapshot's
    /// launch flag only bypasses the phone-relay gate; it never swaps in a
    /// marketing-only mock screen, so the capture still exercises production
    /// navigation and layout.
    private var signedInContent: some View {
        NavigationStack(path: $path) {
            // HomeView is a paged TabView (#278). The destination map stays
            // attached HERE, to the stack root, and not inside either page:
            // a `.navigationDestination` declared inside a paged TabView is
            // only registered while its page is realized.
            HomeView()
                .navigationDestination(for: WatchDest.self) { dest in
                    switch dest {
                    case .force: ForceGaugeView()
                    case .workout: WorkoutLiveView()
                    }
                }
        }
        // No finish-gauge-session prompt any more (#280): the session's RPE is
        // predicted from W' depletion and logged the moment it ends.
        .onOpenURL { open($0) }
    }

    /// Routes a complication's deep link (`sendmeter://force|workout`) by
    /// replacing the stack's path. Setting `path` — rather than driving the
    /// TabView's selection — is what keeps this working now that the home is a
    /// paged TabView (#278): the destination is pushed over both pages, so the
    /// visible page when the link arrives doesn't matter.
    private func open(_ url: URL) {
        switch url.host {
        case "force": path = [.force]
        case "workout": path = [.workout]
        default: break
        }
    }
}

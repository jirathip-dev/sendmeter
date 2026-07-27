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

    var body: some View {
        @Bindable var tindeq = tindeq
        switch auth.state {
        case .signedOut:
            WaitingForPhoneView()
        // Deliberately includes `tokenFresh: false` — an expired access token
        // keeps the watch usable (recording is offline-first and queues), and
        // HomeView shows the "waiting for iPhone" banner instead of throwing
        // the user back to a sign-in screen (#265's offline window).
        case .signedIn(_, _):
            NavigationStack(path: $path) {
                // HomeView is a paged TabView (#278). The destination map stays
                // attached HERE, to the stack root, and not inside either page:
                // a `.navigationDestination` declared inside a paged TabView is
                // only registered while that page is realized, so a deep link
                // that arrived while the other page was showing would push
                // nothing. Both `sendmeter://force` and `sendmeter://workout`
                // below drive this same path regardless of the visible page.
                HomeView()
                    .navigationDestination(for: WatchDest.self) { dest in
                        switch dest {
                        case .force: ForceGaugeView()
                        case .workout: WorkoutLiveView()
                        }
                    }
            }
            // Finish-gauge-session prompt lives at the root so it surfaces even
            // when the Progressor drops after leaving the Force screen (SL-58 #5).
            .sheet(isPresented: $tindeq.pendingFinish) {
                GaugeFinishSheet()
            }
            // Quick-launch complications open the app to a screen.
            .onOpenURL { open($0) }
        }
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

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
            .onOpenURL { url in
                switch url.host {
                case "force": path = [.force]
                case "workout": path = [.workout]
                default: break
                }
            }
        }
    }
}

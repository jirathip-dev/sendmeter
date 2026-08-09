import SwiftUI
import SendLogWatchCore

// `WatchDest` (the navigationDestination values, also the quick-launch
// complication deep-link targets — see .onOpenURL below) lives in
// SendLogWatchCore now, alongside `WatchNavigation.resolvedPath` (#476):
// keeping the running-workout navigation guard in Core makes it
// unit-testable without a simulator.

enum WatchHomePage: Hashable {
    case status, actions
}

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(TindeqManager.self) private var tindeq
    @Environment(WorkoutManager.self) private var workout
    @Environment(GuidedForceRunner.self) private var guidedForceRunner
    @State private var path: [WatchDest] = []
    @State private var homePage: WatchHomePage = .status

    @ViewBuilder
    var body: some View {
        if ScreenshotFixtures.enabled, ScreenshotFixtures.state == .waiting {
            WaitingForPhoneView()
        } else if ScreenshotFixtures.enabled {
            screenshotSignedInSurface
        } else {
            switch auth.state {
            case .signedOut:
                WaitingForPhoneView()
            // Deliberately includes `tokenFresh: false` — an expired access token
            // keeps the watch usable (recording is offline-first and queues), and
            // HomeView shows the "waiting for iPhone" banner instead of throwing
            // the user back to a sign-in screen (#265's offline window).
            case .signedIn(_, _):
                signedInSurface
            }
        }
    }

    @ViewBuilder
    private var screenshotSignedInSurface: some View {
        if ScreenshotFixtures.accessibilityLarge {
            signedInSurface
                .environment(\.dynamicTypeSize, .accessibility3)
        } else {
            signedInSurface
        }
    }

    @ViewBuilder
    private var signedInSurface: some View {
        if guidedForceRunner.isActive {
            GuidedForceRunnerView()
        } else {
            signedInContent
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
            HomeView(selection: $homePage)
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

    /// Routes complication deep links. Status first clears any pushed screen
    /// and selects page one; force/workout replace the stack path and therefore
    /// work regardless of which home page is currently visible.
    ///
    /// #476: this used to replace `path` unconditionally, so a Force
    /// complication tap while a workout was running popped WorkoutLiveView
    /// off the stack with no way back to its End control. All the routing
    /// decision now lives in `WatchNavigation.resolvedPath` (Core,
    /// unit-tested) — this is just plumbing, so there's no separate
    /// untested copy of the logic to drift from what's tested.
    private func open(_ url: URL) {
        guard let host = url.host.flatMap(WatchDeepLinkHost.init(rawValue:)) else { return }
        path = WatchNavigation.resolvedPath(for: host, workoutRunning: workout.isRunning)
        if host == .status {
            homePage = .status
        }
    }
}

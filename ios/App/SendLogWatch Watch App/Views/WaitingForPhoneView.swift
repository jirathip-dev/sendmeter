import SwiftUI
import SendLogWatchCore

/// Shown while the watch has no session. Replaces the email+password sign-in
/// form (#265/#266).
///
/// The form is gone because there is nothing left for it to sign in *with*:
/// the watch holds an access token relayed from the phone and no refresh
/// token, so a watch-native login would create a second, independently-rotating
/// session — the exact arrangement that revoked a healthy session family in
/// production. Removing it is only defensible alongside a pull path that
/// actually works, so this screen's job is to make the pull visible: what the
/// watch is waiting for, whether the phone answered, and a way to ask again.
struct WaitingForPhoneView: View {
    @Environment(AuthManager.self) private var auth
    // #476 review finding F2: this screen used to surface no workout
    // affordance at all — a running HKWorkoutSession, fusion timer, and
    // pushBeat() kept going with no End control and no indication anything
    // was running, until the phone re-relayed. The data already survived a
    // signedOut relay (WorkoutManager is App-scoped, above this switch); this
    // makes that survival actually reachable from here too.
    @Environment(WorkoutManager.self) private var workout
    @State private var pendingUploads = ScreenshotFixtures.waitingPendingUploads ?? 0

    private var fixtureWaiting: Bool { ScreenshotFixtures.state == .waiting }
    private var isSyncing: Bool { fixtureWaiting ? ScreenshotFixtures.waitingSyncing : auth.syncing }
    private var rejectionMessage: String? {
        ScreenshotFixtures.waitingRejectionMessage ?? auth.lastRejection?.watchMessage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SENDMETER")
                            .font(.system(.headline, design: .rounded).weight(.heavy))
                            .tracking(1.1)
                        Text("Companion watch")
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textTertiary)
                    }
                    Spacer(minLength: 4)
                    WatchStateChip(
                        state: isSyncing ? .syncing : .offline,
                        title: isSyncing ? "Checking" : "Waiting",
                        compact: true
                    )
                }

                if workout.isRunning {
                    workoutRunningBanner
                }

                // A workout/session can be saved locally while signed out
                // (offline-first: OfflineQueue/PendingSessionQueue persist
                // before upload) — surface that here (issue #189), since this
                // is the one screen shown for the entire duration nobody's
                // signed in, exactly when it matters most.
                if pendingUploads > 0 {
                    WatchStateBanner(
                        state: .offline,
                        title: "\(pendingUploads) save\(pendingUploads == 1 ? "" : "s") waiting",
                        message: "They upload when your iPhone signs this watch in."
                    )
                }

                // No dedicated "Signing in from your iPhone…" state any more
                // (#278): signing in from the phone IS the normal path, and a
                // screen that swapped its whole explanation for a spinner every
                // time a request was in flight narrated the routine case at the
                // expense of the one the user is actually here to read. The
                // explanation stays put; the spinner below it is the only thing
                // that comes and goes.
                WatchCard(accent: WatchPalette.secondary) {
                    VStack(alignment: .leading, spacing: 7) {
                        WatchEyebrow(text: "Sign in from iPhone")
                        Text(explanation)
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .foregroundStyle(WatchPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Open Sendmeter on your iPhone. This watch uses its session — there is no separate watch login.")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(WatchPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isSyncing {
                    WatchLoadingState(title: "Asking your iPhone…")
                }

                // The refusal reason, when there was one — the difference
                // between "your phone isn't answering" and "your phone
                // answered with something this watch can't use" is the whole
                // diagnosis, and it used to be invisible.
                if let rejectionMessage {
                    WatchStateBanner(
                        state: .danger,
                        title: "Could not use that relay",
                        message: rejectionMessage
                    )
                }

                Button("Try Again") { auth.requestSessionFromPhone(force: true) }
                    .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.primary))
                    .disabled(isSyncing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .watchCanvas()
        // Ask the moment this screen appears (covers a bootstrap request made
        // before WCSession finished activating). Throttled in AuthManager, so
        // this coinciding with the launch ask costs one message, not two.
        .onAppear {
            if !fixtureWaiting { auth.requestSessionFromPhone() }
        }
        .task {
            guard !fixtureWaiting else { return }
            async let workouts = OfflineQueue.shared.pendingCount()
            async let sessions = PendingSessionQueue.shared.pendingCount()
            async let recordings = PendingRecordingQueue.shared.pendingCount()
            // #549 F2: keep this sum in step with the phone-reported total,
            // which now includes this queue too (`PendingSyncCache`).
            async let liveWorkoutTerminal = LiveWorkoutTerminalRetry.shared.pendingCount()
            pendingUploads = await workouts + sessions + recordings + liveWorkoutTerminal
        }
    }

    private var explanation: String {
        if fixtureWaiting { return "Waiting for your iPhone to send a sign-in." }
        return auth.lastRelayAt == nil
            ? "Waiting for your iPhone to send a sign-in."
            : "Your iPhone's last sign-in has expired. Asking it for a new one."
    }

    /// #476 review finding F2: an End control reachable from the one screen
    /// that has no `NavigationStack` to push `WorkoutLiveView` onto — calls
    /// straight into the App-scoped manager's save path, same as the live
    /// screen's toolbar button.
    @ViewBuilder
    private var workoutRunningBanner: some View {
        WatchStateBanner(
            state: .warning,
            title: "Workout running",
            message: "\(workout.liveAttempts) boulder\(workout.liveAttempts == 1 ? "" : "s") so far.",
            actionTitle: workout.ending ? "Ending…" : "End Workout",
            action: { workout.endAndSave() },
            actionDisabled: workout.ending
        )
    }
}

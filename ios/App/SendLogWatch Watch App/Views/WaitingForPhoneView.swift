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
    @State private var pendingUploads = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("SENDMETER")
                    .font(.headline)

                if workout.isRunning {
                    workoutRunningBanner
                }

                // A workout/session can be saved locally while signed out
                // (offline-first: OfflineQueue/PendingSessionQueue persist
                // before upload) — surface that here (issue #189), since this
                // is the one screen shown for the entire duration nobody's
                // signed in, exactly when it matters most.
                if pendingUploads > 0 {
                    Text("\(pendingUploads) workout\(pendingUploads == 1 ? "" : "s") waiting to upload — they'll go up once your iPhone signs this watch in")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                // No dedicated "Signing in from your iPhone…" state any more
                // (#278): signing in from the phone IS the normal path, and a
                // screen that swapped its whole explanation for a spinner every
                // time a request was in flight narrated the routine case at the
                // expense of the one the user is actually here to read. The
                // explanation stays put; the spinner below it is the only thing
                // that comes and goes.
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if auth.syncing {
                    ProgressView()
                        .controlSize(.small)
                }

                // The refusal reason, when there was one — the difference
                // between "your phone isn't answering" and "your phone
                // answered with something this watch can't use" is the whole
                // diagnosis, and it used to be invisible.
                if let rejection = auth.lastRejection {
                    Text(rejection.watchMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Text("Open Sendmeter on your iPhone. This watch signs in from it — there's no separate watch login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Button("Try Again") { auth.requestSessionFromPhone(force: true) }
                    .font(.footnote)
                    .disabled(auth.syncing)
            }
            .padding(.horizontal, 4)
        }
        // Ask the moment this screen appears (covers a bootstrap request made
        // before WCSession finished activating). Throttled in AuthManager, so
        // this coinciding with the launch ask costs one message, not two.
        .onAppear { auth.requestSessionFromPhone() }
        .task {
            async let workouts = OfflineQueue.shared.pendingCount()
            async let sessions = PendingSessionQueue.shared.pendingCount()
            pendingUploads = await workouts + sessions
        }
    }

    private var explanation: String {
        auth.lastRelayAt == nil
            ? "Waiting for your iPhone to send a sign-in."
            : "Your iPhone's last sign-in has expired. Asking it for a new one."
    }

    /// #476 review finding F2: an End control reachable from the one screen
    /// that has no `NavigationStack` to push `WorkoutLiveView` onto — calls
    /// straight into the App-scoped manager's save path, same as the live
    /// screen's toolbar button.
    @ViewBuilder
    private var workoutRunningBanner: some View {
        VStack(spacing: 6) {
            Label("Workout running", systemImage: "figure.climbing")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Text("\(workout.liveAttempts) boulder\(workout.liveAttempts == 1 ? "" : "s") so far")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(workout.ending ? "Ending…" : "End Workout") {
                workout.endAndSave()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(workout.ending)
        }
        .padding(.bottom, 4)
    }
}

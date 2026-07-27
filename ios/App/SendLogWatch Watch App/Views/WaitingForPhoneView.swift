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
    @State private var pendingUploads = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("SENDMETER")
                    .font(.headline)

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

                if auth.syncing {
                    ProgressView()
                    Text("Signing in from your iPhone…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
}

import SwiftUI

struct HomeView: View {
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
            if auth.needsToken {
                Label(
                    "Waiting for iPhone — new saves upload once it's in range",
                    systemImage: "iphone.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            // No Sign Out here any more. The watch has no session of its own
            // to end — it mirrors the phone's — and the old button called
            // supabase-swift's globally-scoped signOut, which revoked every
            // session on the account, including the phone's.
            Text("Signed in from your iPhone")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .navigationTitle("Sendmeter")
        .task {
            async let workouts = OfflineQueue.shared.pendingCount()
            async let sessions = PendingSessionQueue.shared.pendingCount()
            pendingUploads = await workouts + sessions
        }
    }
}

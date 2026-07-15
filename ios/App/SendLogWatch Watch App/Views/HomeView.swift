import SwiftUI

struct HomeView: View {
    @Environment(AuthManager.self) private var auth
    @State private var pendingUploads = 0

    var body: some View {
        List {
            NavigationLink {
                ForceGaugeView()
            } label: {
                Label("Force Gauge", systemImage: "scalemass")
            }

            NavigationLink {
                WorkoutLiveView()
            } label: {
                Label("Climb Workout", systemImage: "figure.climbing")
            }

            if pendingUploads > 0 {
                Label("\(pendingUploads) pending upload\(pendingUploads == 1 ? "" : "s")", systemImage: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Button(role: .destructive) {
                Task { await auth.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .navigationTitle("Sendmeter")
        .task {
            pendingUploads = await OfflineQueue.shared.pendingCount()
        }
    }
}

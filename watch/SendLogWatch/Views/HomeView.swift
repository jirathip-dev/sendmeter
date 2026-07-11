import SwiftUI

struct HomeView: View {
    @Environment(AuthManager.self) private var auth
    @State private var readiness = ReadinessManager()
    @State private var pendingUploads = 0

    var body: some View {
        List {
            Section {
                readinessCard
            }

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
        .navigationTitle("Send Log")
        .task {
            pendingUploads = await OfflineQueue.shared.pendingCount()
            await readiness.refresh()
        }
    }

    private var zoneColor: Color {
        switch readiness.result?.zone {
        case .push: .green
        case .maintain: .yellow
        case .recover: .red
        case nil: .gray
        }
    }

    @ViewBuilder
    private var readinessCard: some View {
        Button {
            Task { await readiness.refresh() }
        } label: {
            HStack(spacing: 12) {
                if readiness.loading && readiness.result == nil {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    ZStack {
                        Circle()
                            .stroke(zoneColor.opacity(0.25), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: CGFloat(readiness.result?.score ?? 0) / 100)
                            .stroke(zoneColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(readiness.result?.score.map(String.init) ?? "—")
                            .font(.system(.body, design: .rounded, weight: .heavy))
                            .monospacedDigit()
                    }
                    .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(readiness.result?.zone?.rawValue.uppercased() ?? "READINESS")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(zoneColor)
                    Text(readiness.result?.driver ?? "Tap to compute")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}

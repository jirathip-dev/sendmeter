import SendLogWatchCore
import SwiftUI

/// The "log this gauge session?" prompt (SL-58 #5). Presented at the root so it
/// surfaces both when the user taps Finish on the Force screen AND when the
/// Progressor drops mid-session after they've navigated away. Duration is the
/// actual wall-clock time (read-only); only RPE is asked — matching the web
/// Force tab and the in-app capture flow.
struct GaugeFinishSheet: View {
    @Environment(TindeqManager.self) private var tindeq

    @State private var rpe = 5.0

    private var durationMin: Int {
        guard let started = tindeq.sessionStartedAt else { return 1 }
        return max(1, Int((Date().timeIntervalSince(started) / 60).rounded()))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Log session")
                    .font(.headline)
                HStack {
                    VStack(alignment: .leading) {
                        Text("DURATION").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(durationMin) min").monospacedDigit()
                    }
                    Spacer()
                    Text("actual time")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Stepper(value: $rpe, in: 1...10, step: 0.5) {
                    VStack(alignment: .leading) {
                        Text("RPE").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(rpe.truncatingRemainder(dividingBy: 1) == 0
                            ? "\(Int(rpe))" : String(format: "%.1f", rpe))
                            .monospacedDigit()
                    }
                }
                Button("Log Session") {
                    guard let groupId = tindeq.sessionId else { return }
                    // Build the payload synchronously, at tap time — date and
                    // duration must reflect this exact moment, not whenever
                    // the queued upload eventually lands (issue #144: the old
                    // `try? await` here froze mid-flight the instant the user
                    // lowered their wrist, so the session could arrive
                    // minutes to hours late, if at all). Persist-first +
                    // idempotent upsert (PendingSessionQueue/Repo) means this
                    // can dismiss immediately without waiting on the network.
                    let pending = PendingTindeqSession.build(
                        sessionStartedAt: tindeq.sessionStartedAt,
                        recordingCount: tindeq.sessionCount,
                        rpe: rpe,
                        groupId: groupId
                    )
                    tindeq.clearSession()
                    Task { await PendingSessionQueue.shared.enqueue(pending) }
                }
                .buttonStyle(.borderedProminent)
                Button("Skip") { tindeq.clearSession() }
                    .font(.footnote)
            }
        }
    }
}

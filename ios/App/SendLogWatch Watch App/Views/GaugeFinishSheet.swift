import SwiftUI

/// The "log this gauge session?" prompt (SL-58 #5). Presented at the root so it
/// surfaces both when the user taps Finish on the Force screen AND when the
/// Progressor drops mid-session after they've navigated away. Duration is the
/// actual wall-clock time (read-only); only RPE is asked — matching the web
/// Force tab and the in-app capture flow.
struct GaugeFinishSheet: View {
    @Environment(TindeqManager.self) private var tindeq

    @State private var rpe = 5
    @State private var logging = false

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
                Stepper(value: $rpe, in: 1...10) {
                    VStack(alignment: .leading) {
                        Text("RPE").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(rpe)").monospacedDigit()
                    }
                }
                Button(logging ? "Logging…" : "Log Session") {
                    guard let groupId = tindeq.sessionId else { return }
                    let count = tindeq.sessionCount
                    let dur = durationMin
                    logging = true
                    Task {
                        let note = "\(count) recording\(count == 1 ? "" : "s")"
                        try? await Repo.logTindeqSession(
                            durationMin: dur,
                            rpe: rpe,
                            note: note,
                            groupId: groupId
                        )
                        logging = false
                        tindeq.clearSession()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(logging)
                Button("Skip") { tindeq.clearSession() }
                    .font(.footnote)
            }
        }
    }
}

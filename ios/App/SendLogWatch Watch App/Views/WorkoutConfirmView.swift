import SwiftUI

struct WorkoutConfirmView: View {
    let summary: WorkoutSummary
    let onDone: () -> Void

    @State private var boulders: Int
    @State private var rpe: Int
    @State private var saving = false
    @State private var errorMsg: String?

    init(summary: WorkoutSummary, onDone: @escaping () -> Void) {
        self.summary = summary
        self.onDone = onDone
        _boulders = State(initialValue: summary.attempts.count)
        _rpe = State(initialValue: Int(summary.predictedRPE.rounded()))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Confirm session")
                    .font(.headline)

                HStack {
                    Text("Duration")
                    Spacer()
                    Text(timeString(summary.endedAt.timeIntervalSince(summary.startedAt)))
                }
                .font(.footnote).foregroundStyle(.secondary)

                if let hr = summary.avgHR {
                    HStack {
                        Text("Avg HR")
                        Spacer()
                        Text("\(Int(hr.rounded())) bpm")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }

                Stepper(value: $boulders, in: 0...200) {
                    VStack(alignment: .center) {
                        Text("BOULDERS").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(boulders)").monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }

                Stepper(value: $rpe, in: 1...10) {
                    VStack(alignment: .center) {
                        Text("RPE (predicted \(String(format: "%.1f", summary.predictedRPE)))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(rpe)").monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }

                if let errorMsg {
                    Text(errorMsg).font(.footnote).foregroundStyle(.red)
                }

                Button(saving ? "Saving…" : "Save Session") {
                    saving = true
                    Task {
                        let phase = (try? await Repo.fetchCurrentPhase()) ?? "capacity"
                        let bundle = Repo.makeSaveBundle(
                            summary: summary,
                            boulders: boulders,
                            rpe: rpe,
                            phase: phase,
                            tunables: .default
                        )
                        // Persist-first queue: survives dead gym wifi
                        await OfflineQueue.shared.enqueueAndUpload(bundle)
                        saving = false
                        onDone()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)

                Button("Discard", role: .destructive) { onDone() }
                    .font(.footnote)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

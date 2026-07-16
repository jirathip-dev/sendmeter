import SwiftUI

struct WorkoutLiveView: View {
    @State private var workout = WorkoutManager()
    @State private var summary: WorkoutSummary?
    @State private var ending = false

    var body: some View {
        Group {
            if let summary {
                WorkoutConfirmView(summary: summary) {
                    self.summary = nil
                }
            } else if workout.isRunning {
                liveContent
            } else {
                startContent
            }
        }
        .navigationTitle("Climb")
        .navigationBarBackButtonHidden(workout.isRunning)
    }

    @ViewBuilder
    private var startContent: some View {
        VStack(spacing: 10) {
            Text("Tracks heart rate, wrist motion and altitude to count your boulders automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Start Workout") {
                Task { await workout.start() }
            }
            .buttonStyle(.borderedProminent)
            if let msg = workout.errorMsg {
                Text(msg).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                    Text(workout.heartRate.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.title2).monospacedDigit()
                    Spacer()
                    Text(timeString(workout.elapsed))
                        .font(.title3).monospacedDigit()
                }

                // Manual boulder logging alongside auto-detection: tap when
                // you get on the wall, tap again when you drop off. Auto
                // detection is suspended while a manual attempt is open.
                Button(workout.manualClimbing ? "Stop" : "Boulder") {
                    workout.toggleManualAttempt()
                }
                .buttonStyle(.borderedProminent)
                .tint(workout.manualClimbing ? .orange : .green)

                // Rest timer between boulders, right under the header so it's
                // reachable the instant you drop off the wall — no scrolling.
                // It never touches the workout clock above.
                RestTimer()

                HStack {
                    VStack(alignment: .leading) {
                        Text("BOULDERS").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(workout.liveAttempts)")
                            .font(.title2).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Δ ALT").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(String(format: "%+.1fm", workout.relativeAltitude))
                            .font(.title3).monospacedDigit()
                    }
                }

                HStack {
                    Text("\(Int(workout.activeKcal)) kcal")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }

                Button(ending ? "Ending…" : "End Workout") {
                    ending = true
                    Task {
                        summary = await workout.end()
                        ending = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(ending)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

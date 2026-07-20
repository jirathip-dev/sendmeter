import SwiftUI
import WatchKit

struct WorkoutLiveView: View {
    @State private var workout = WorkoutManager()
    @State private var ending = false
    /// Brief "Saved ✓" confirmation after auto-save-on-stop.
    @State private var justSaved = false
    @State private var restAlarmTask: Task<Void, Never>?

    private let restTargets = [60, 120, 180, 300]

    var body: some View {
        Group {
            if justSaved {
                savedContent
            } else if workout.isRunning {
                liveContent
            } else {
                startContent
            }
        }
        .navigationTitle("Climb")
        .navigationBarBackButtonHidden(workout.isRunning)
    }

    // Stopping SAVES immediately (no confirm form) — banks the model's
    // predicted RPE + detected boulders and persists locally; the upload
    // drains in the background. Adjust RPE/type later on the phone.
    private func endAndSave() {
        ending = true
        cancelRestAlarm()
        Task {
            guard let summary = await workout.end() else {
                ending = false
                return
            }
            let bundle = Repo.makeSaveBundle(
                summary: summary,
                boulders: summary.attempts.count,
                // Bank the prediction at half-point precision (SL-89) — no
                // rounding to whole numbers, adjust later on the phone.
                rpe: min(10, max(1, (summary.predictedRPE * 2).rounded() / 2)),
                phase: workout.cachedPhase,
                tunables: .default
            )
            await OfflineQueue.shared.enqueue(bundle)
            WidgetBridge.updateLiveWorkout(active: false) // clear the live widget
            await WidgetBridge.refreshStatus()            // fresh ACWR after the save
            ending = false
            justSaved = true
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(for: .seconds(1.6))
            justSaved = false
        }
    }

    @ViewBuilder
    private var savedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("Saved").font(.headline)
            Text("Set RPE on your phone")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
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

    // Same logic as the phone fullscreen: CLIMBING counts up from the boulder
    // start; stopping drops straight into a RESTING countdown toward the
    // persisted target. One screen, no scrolling — End lives in the toolbar.
    @ViewBuilder
    private var liveContent: some View {
        VStack(spacing: 4) {
            // HR + total elapsed stacked on the LEFT — the elapsed time used to
            // sit top-right, where it collided with the End toolbar button.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Text(workout.heartRate.map { "\(Int($0.rounded()))" } ?? "--")
                            .font(.body).monospacedDigit()
                    }
                    Text(timeString(workout.elapsed))
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Spacer(minLength: 0)

            phaseTimer

            Spacer(minLength: 0)

            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("BOULDERS").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("\(workout.liveAttempts)")
                        .font(.title3).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(workout.activeKcal)) kcal")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1fm", workout.relativeAltitude))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Play = start a boulder, stop = drop off into the rest countdown
            // (phone-workout logic; icons instead of words). Compact circular
            // button so the whole screen fits a 40mm watch without scrolling
            // (SL-59) — still the biggest tap target on screen.
            Button {
                workout.toggleManualAttempt()
                if workout.manualClimbing {
                    cancelRestAlarm()
                } else {
                    scheduleRestAlarm()
                }
            } label: {
                Image(systemName: workout.manualClimbing ? "stop.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(workout.manualClimbing ? .orange : .green)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ending ? "…" : "End") {
                    endAndSave()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .disabled(ending)
            }
        }
        .onAppear { scheduleRestAlarm() }
        .onDisappear { cancelRestAlarm() }
    }

    // CLIMBING count-up / RESTING countdown, colored like the phone. The
    // TimelineView re-evaluates each second so "rest over" flips to red
    // without any stored state.
    @ViewBuilder
    private var phaseTimer: some View {
        if workout.manualClimbing, let since = workout.climbingSince {
            VStack(spacing: 0) {
                Text("CLIMBING")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                Text(timerInterval: since...since.addingTimeInterval(3600), countsDown: false)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
        } else if let rest = workout.restStartedAt {
            let end = rest.addingTimeInterval(Double(workout.restTargetS))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let over = context.date >= end
                VStack(spacing: 0) {
                    Text(over ? "REST OVER" : "RESTING")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(over ? .red : .blue)
                    Text(timerInterval: rest...end, countsDown: true)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .foregroundStyle(over ? .red : .primary)
                    // Rest-target chips (1/2/3/5m) — obvious selector like the
                    // phone's; persisted + mirrored via the live heartbeat.
                    HStack(spacing: 4) {
                        ForEach(restTargets, id: \.self) { t in
                            let selected = workout.restTargetS == t
                            Button("\(t / 60)m") {
                                workout.restTargetS = t
                                scheduleRestAlarm()
                            }
                            .font(.system(size: 11, weight: selected ? .bold : .regular))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(selected ? .blue : .gray)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Double haptic when the rest countdown hits zero — cuts through gym
    /// noise, same as the old manual RestTimer.
    private func scheduleRestAlarm() {
        cancelRestAlarm()
        guard let rest = workout.restStartedAt else { return }
        let end = rest.addingTimeInterval(Double(workout.restTargetS))
        let interval = end.timeIntervalSinceNow
        guard interval > 0 else { return }
        restAlarmTask = Task {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(for: .seconds(0.6))
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func cancelRestAlarm() {
        restAlarmTask?.cancel()
        restAlarmTask = nil
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

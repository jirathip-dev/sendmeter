import SendLogWatchCore
import SwiftUI
import WatchKit

struct WorkoutLiveView: View {
    @State private var workout = WorkoutManager()
    @State private var ending = false
    /// Brief "Saved ✓" confirmation after auto-save-on-stop.
    @State private var justSaved = false
    /// Whether the just-saved bundle is still sitting in the offline queue
    /// (issue #189) — checked right before showing `justSaved`, so
    /// `WidgetBridge.refreshStatus()`'s own network round trip below gives
    /// `drain()` a real chance to finish uploading first when signed in.
    /// Signed-out stays queued deterministically (`drain()` no-ops
    /// immediately), so this reliably distinguishes "still uploading" from
    /// "stuck until sign-in" without touching `drain()`/`shouldDrain`.
    @State private var stillQueued = false
    @State private var restAlarmTask: Task<Void, Never>?
    /// True in the always-on dimmed state. watchOS dims hard on its own, and a
    /// full-screen tint left at full value on top of that is a burn-in and
    /// battery liability — the palette has a reduced variant for it (#243).
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

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
                // Bank the model's raw prediction at 0.1 precision (#107) —
                // no rounding to half-points, adjust later on the phone. The
                // 0.5-step steppers are for MANUAL entry only (SL-89).
                rpe: RPEQuantization.autoTracked(summary.predictedRPE),
                phase: workout.cachedPhase,
                tunables: .default
            )
            await OfflineQueue.shared.enqueue(bundle)
            WidgetBridge.updateLiveWorkout(active: false) // clear the live widget
            await WidgetBridge.refreshStatus()            // fresh ACWR after the save
            stillQueued = await OfflineQueue.shared.pendingCount() > 0
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
            Text(stillQueued ? "Saved to watch" : "Saved").font(.headline)
            Text(stillQueued ? "uploads when signed in" : "Set RPE on your phone")
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
    //
    // One TimelineView drives BOTH the full-screen phase fill and the phase
    // timer (#243) so they flip on the same tick — a background that says
    // RESTING behind a countdown that says REST OVER would be worse than no
    // fill at all. It also replaces the timer's own per-second timeline
    // rather than adding a second one.
    @ViewBuilder
    private var liveContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = workout.livePhase(at: context.date)
            liveStack(phase: phase)
                .background(phaseFill(phase).ignoresSafeArea())
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ending ? "…" : "End") {
                    endAndSave()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                // Neutral, not red: at REST OVER the whole screen is red, and
                // a red-on-red chip is the first thing to disappear. The word
                // carries the meaning; the fill owns the colour now.
                .tint(.white)
                .disabled(ending)
            }
        }
        .onAppear { scheduleRestAlarm() }
        .onDisappear { cancelRestAlarm() }
    }

    /// The whole screen, painted by phase. A solid animated colour with a
    /// static wash toward black at the bottom — the wash buys contrast under
    /// the secondary readouts and the action button without touching the hue
    /// at the top, where the phase label and countdown live. `Rectangle().fill`
    /// rather than a bare `Color` because a filled shape style interpolates
    /// between colours; the cross-fade is the point, a hard cut is not.
    private func phaseFill(_ phase: WorkoutPhase) -> some View {
        let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: isLuminanceReduced)
        return ZStack {
            Rectangle().fill(color(fill.background))
            LinearGradient(
                colors: [.clear, .black.opacity(WorkoutPhasePalette.bottomShade)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: WorkoutPhasePalette.transitionSeconds), value: phase)
    }

    private func color(_ rgb: PhaseRGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Text that sits on the fill — the palette's label colour for that
    /// phase, never the phase's own hue. Green "CLIMBING" on a green fill is
    /// how this feature fails; the package tests hold every pairing here at
    /// AAA contrast, dimmed and not.
    private func onFill(_ phase: WorkoutPhase) -> Color {
        color(WorkoutPhasePalette.fill(for: phase, luminanceReduced: isLuminanceReduced).label)
    }

    @ViewBuilder
    private func liveStack(phase: WorkoutPhase) -> some View {
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

            phaseTimer(phase: phase)

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
    }

    // CLIMBING count-up / RESTING countdown. The phase now comes from the
    // enclosing TimelineView, so "rest over" flips the label and the
    // full-screen fill on the same tick — still no stored state. The text
    // itself is the on-fill colour rather than the phase's hue: the whole
    // background is already saying which phase this is.
    @ViewBuilder
    private func phaseTimer(phase: WorkoutPhase) -> some View {
        if phase == .climbing, let since = workout.climbingSince {
            VStack(spacing: 0) {
                Text("CLIMBING")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(onFill(phase))
                Text(timerInterval: since...since.addingTimeInterval(3600), countsDown: false)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onFill(phase))
            }
        } else if let rest = workout.restStartedAt {
            let end = rest.addingTimeInterval(Double(workout.restTargetS))
            VStack(spacing: 0) {
                Text(phase == .restOver ? "REST OVER" : "RESTING")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(onFill(phase))
                Text(timerInterval: rest...end, countsDown: true)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onFill(phase))
                // Rest-target chips (1/2/3/5m) — obvious selector like the
                // phone's; persisted + mirrored via the live heartbeat. The
                // selected chip is neutral, not blue: RESTING paints the
                // screen blue, and a blue chip on it stops reading as chosen.
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
                        .tint(selected ? .white : .gray)
                    }
                }
                .padding(.top, 2)
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

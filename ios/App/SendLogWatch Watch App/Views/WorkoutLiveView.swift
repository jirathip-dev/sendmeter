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
    /// Kept in memory after both persistence and direct upload fail (#287),
    /// so Retry can replay the same idempotent bundle instead of pretending
    /// the workout was saved.
    @State private var failedBundle: WorkoutSaveBundle?
    @State private var restAlarmTask: Task<Void, Never>?
    /// True in the always-on dimmed state. watchOS dims hard on its own, and a
    /// saturated colour block left at full value on top of that is a burn-in
    /// and battery liability — the palette has a reduced variant for it (#243).
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private let restTargets = [60, 120, 180, 300]

    init() {}

    #if DEBUG
    /// Preview-only seam: poses the view mid-workout so the live layout can be
    /// checked at 40mm and 49mm (#277) without an `HKWorkoutSession`.
    init(previewWorkout: WorkoutManager) {
        _workout = State(initialValue: previewWorkout)
    }
    #endif

    var body: some View {
        Group {
            if failedBundle != nil {
                failedSaveContent
            } else if justSaved {
                savedContent
            } else if workout.isRunning {
                liveContent
            } else {
                startContent
            }
        }
        // No title while running. watchOS floats the nav bar OVER the content
        // rather than insetting it, so "Climb" was being drawn straight
        // through the elapsed-time readout — and once the band says RESTING
        // next to an End button, the title is telling nobody anything.
        .navigationTitle(workout.isRunning ? "" : "Climb")
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
            WidgetBridge.updateLiveWorkout(active: false) // clear the live widget
            await save(bundle)
        }
    }

    private func retryFailedSave() {
        guard let failedBundle, !ending else { return }
        ending = true
        Task { await save(failedBundle) }
    }

    private func save(_ bundle: WorkoutSaveBundle) async {
        let outcome = await OfflineQueue.shared.enqueue(bundle)
        guard outcome != .lost else {
            failedBundle = bundle
            ending = false
            WKInterfaceDevice.current().play(.failure)
            return
        }

        failedBundle = nil
        await WidgetBridge.refreshStatus() // fresh ACWR after the save
        if outcome == .queued {
            stillQueued = await OfflineQueue.shared.pendingCount() > 0
        } else {
            stillQueued = false
        }
        ending = false
        justSaved = true
        WKInterfaceDevice.current().play(.success)
        try? await Task.sleep(for: .seconds(1.6))
        justSaved = false
    }

    @ViewBuilder
    private var failedSaveContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)
            Text("Workout not saved").font(.headline)
            Text("Keep this screen open and retry.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(ending ? "Retrying…" : "Retry Save") {
                retryFailedSave()
            }
            .buttonStyle(.borderedProminent)
            .disabled(ending)
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
    // One TimelineView drives BOTH the phase band and the phase timer (#243)
    // so they flip on the same tick — a band that says RESTING behind a
    // countdown that says REST OVER would be worse than no colour at all. It
    // also replaces the timer's own per-second timeline rather than adding a
    // second one.
    @ViewBuilder
    private var liveContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = workout.livePhase(at: context.date)
            // Resolved once per tick and threaded down, so the band and the
            // text on it can never be read from two different resolutions.
            let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: isLuminanceReduced)
            liveStack(phase: phase, fill: fill)
                .background(color(fill.screen).ignoresSafeArea())
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ending ? "…" : "End") {
                    endAndSave()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                // Phone's "act now" orange (#277 follow-up) — ending a
                // workout is the same weight of action as the phone
                // fullscreen's Stop pill, and it now sits on black rather
                // than on a band that itself can be red, so the two colours
                // never collide.
                .tint(color(WorkoutPhasePalette.phoneDanger))
                .disabled(ending)
            }
        }
        .onAppear { scheduleRestAlarm() }
        .onDisappear { cancelRestAlarm() }
    }

    private func color(_ rgb: PhaseRGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The phase colour, as a rounded block behind the eyebrow and the
    /// countdown (#277) — TimerPlus-style, rather than flooded across the
    /// whole display. Everything else on the screen is now on black, which is
    /// why the old bottom wash is gone: it existed purely to buy contrast on
    /// top of a full-screen fill.
    ///
    /// `RoundedRectangle().fill` rather than a bare `Color` because a filled
    /// shape style interpolates between colours; the cross-fade is the point,
    /// a hard cut is not. The text on it takes the palette's label colour for
    /// the phase, never the phase's own hue — green "CLIMBING" on a green band
    /// is how this feature fails, and the package tests hold every pairing
    /// here at AAA contrast, dimmed and not.
    private func phaseBand<Content: View>(
        phase: WorkoutPhase,
        fill: PhaseFill,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(color(fill.label))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color(fill.band))
                    .animation(.easeInOut(duration: WorkoutPhasePalette.transitionSeconds), value: phase)
            )
    }

    @ViewBuilder
    private func liveStack(phase: WorkoutPhase, fill: PhaseFill) -> some View {
        // Spacing is 2, not the usual 4: RESTING stacks the HR line, the band,
        // the rest chips and the action row, and on a 40mm screen the gaps are
        // the difference between the button clearing the bottom edge and
        // sitting flush against it.
        VStack(spacing: 2) {
            // HR + total elapsed on ONE line at the LEFT. They used to be
            // stacked, which cost a whole footnote line of height that RESTING
            // — the tall phase, band + chips + action row — does not have on a
            // 40mm screen. Still left-aligned: the elapsed time sat top-right
            // once and collided with the End toolbar button.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            phaseTimer(phase: phase, fill: fill)

            Spacer(minLength: 0)

            actionRow
        }
    }

    /// BOULDERS · play/stop · kcal + altitude, all on one line (#277). The
    /// button used to own a full-width row of its own underneath this one,
    /// which left it stranded bottom-left with dead space beside it and spent
    /// ~50pt of a 40mm screen on nothing. Between the two readouts it reads as
    /// the row's action and the screen gets that height back.
    ///
    /// Both readout columns take an equal share of the leftover width, so the
    /// button stays optically centred whatever the numbers do.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("BOULDERS")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(workout.liveAttempts)")
                    .font(.title3).monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Play = start a boulder, stop = drop off into the rest countdown
            // (phone-workout logic; icons instead of words). 44pt is Apple's
            // minimum tap target and here the visual circle IS the tap target
            // — no invisible padding to get out of step with the artwork.
            // `fixedSize` keeps it at 44 whatever the readouts either side ask
            // for, down to 40mm.
            Button {
                workout.toggleManualAttempt()
                if workout.manualClimbing {
                    cancelRestAlarm()
                } else {
                    scheduleRestAlarm()
                }
            } label: {
                Image(systemName: workout.manualClimbing ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            // Same hues as the phase band (#277 follow-up): stop reads "act
            // now" like rest-over, play reads "go" like climbing.
            .tint(color(workout.manualClimbing ? WorkoutPhasePalette.phoneDanger : WorkoutPhasePalette.phoneSuccess))
            .fixedSize()
            .accessibilityLabel(workout.manualClimbing ? "Stop boulder" : "Start boulder")

            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(workout.activeKcal)) kcal")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(String(format: "%+.1fm", workout.relativeAltitude))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // CLIMBING count-up / RESTING countdown, inside the phase band. The phase
    // comes from the enclosing TimelineView, so "rest over" flips the label
    // and the band on the same tick — still no stored state. The text takes
    // the palette's label colour rather than the phase's hue: the band behind
    // it is already saying which phase this is.
    //
    // 34pt, not the old 40: the band's padding has to fit inside a 40mm
    // screen alongside the rest chips and the action row, and at this size the
    // countdown still fills most of the band's width.
    @ViewBuilder
    private func phaseTimer(phase: WorkoutPhase, fill: PhaseFill) -> some View {
        if phase == .climbing, let since = workout.climbingSince {
            phaseBand(phase: phase, fill: fill) {
                VStack(spacing: 0) {
                    Text("CLIMBING")
                        .font(.system(size: 11, weight: .bold))
                    Text(timerInterval: since...since.addingTimeInterval(3600), countsDown: false)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                }
            }
        } else if let rest = workout.restStartedAt {
            let end = rest.addingTimeInterval(Double(workout.restTargetS))
            VStack(spacing: 3) {
                phaseBand(phase: phase, fill: fill) {
                    VStack(spacing: 0) {
                        Text(phase == .restOver ? "REST OVER" : "RESTING")
                            .font(.system(size: 11, weight: .bold))
                        Text(timerInterval: rest...end, countsDown: true)
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                    }
                }
                // Rest-target chips (1/2/3/5m) — obvious selector like the
                // phone's; persisted + mirrored via the live heartbeat. They
                // stay OUTSIDE the band: it holds what the phase *is*, not the
                // controls that change it. The selected chip is neutral, not
                // blue, so it reads as chosen next to a blue RESTING band.
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

#if DEBUG
extension WorkoutManager {
    /// Preview-only: a manager posed mid-workout, so the live layout can be
    /// checked without HealthKit. `restTargetS` is deliberately left at its
    /// stored default — its `didSet` writes UserDefaults and fires a heartbeat.
    @MainActor
    static func posed(climbing: Bool, restStartedS: TimeInterval = 45) -> WorkoutManager {
        let m = WorkoutManager()
        m.isRunning = true
        m.heartRate = 148
        m.activeKcal = 327
        m.elapsed = 2_712
        m.relativeAltitude = -3.4
        m.liveAttempts = 12
        m.manualClimbing = climbing
        m.climbingSince = climbing ? Date().addingTimeInterval(-73) : nil
        m.restStartedAt = climbing ? nil : Date().addingTimeInterval(-restStartedS)
        return m
    }
}

/// The two screens the layout has to hold, in points: the smallest supported
/// watch and the largest. Pinned as a frame rather than a `previewDevice` —
/// the `#Preview` macro ignores `previewDevice` (it takes the device from the
/// Canvas picker), and a hard frame plus `clipped()` is what actually shows
/// overflow as overflow instead of quietly growing the canvas.
private enum PreviewScreen {
    /// Apple Watch SE / Series 4-6, 40mm.
    static let mm40 = CGSize(width: 162, height: 197)
    /// Apple Watch Ultra / Ultra 2, 49mm — the tighter of the two Ultra
    /// panels (Ultra 3 is 211x257).
    static let mm49 = CGSize(width: 205, height: 251)
}

private func workoutPreview(_ workout: WorkoutManager, _ size: CGSize) -> some View {
    NavigationStack { WorkoutLiveView(previewWorkout: workout) }
        .frame(width: size.width, height: size.height)
        .clipped()
}

// The layout that has to hold: everything visible at once on the smallest
// supported watch, still deliberate on the largest (#277). RESTING is the tall
// case — it adds the rest chips under the band — and REST OVER is RESTING past
// its target, so the same geometry covers it.
#Preview("Climbing · 40mm") {
    workoutPreview(.posed(climbing: true), PreviewScreen.mm40)
}

#Preview("Resting · 40mm") {
    workoutPreview(.posed(climbing: false), PreviewScreen.mm40)
}

#Preview("Rest over · 40mm") {
    // Past the default 3-minute target, so the band is red and the countdown
    // has flipped — the widest label ("REST OVER") on the smallest screen.
    workoutPreview(.posed(climbing: false, restStartedS: 240), PreviewScreen.mm40)
}

#Preview("Climbing · 49mm") {
    workoutPreview(.posed(climbing: true), PreviewScreen.mm49)
}

#Preview("Resting · 49mm") {
    workoutPreview(.posed(climbing: false), PreviewScreen.mm49)
}
#endif

import SendLogWatchCore
import SwiftUI

struct WorkoutLiveView: View {
    // App-scoped (#476) — see SendLogWatchApp's doc comment. This view can be
    // popped and recreated (a complication deep link, a signedOut auth relay
    // swapping the NavigationStack) while a workout, or a save it started,
    // is still in flight; reading the shared manager instead of owning
    // private @State means a freshly (re)created instance picks up the real
    // state instead of starting blank.
    @Environment(WorkoutManager.self) private var workout
    /// True in the always-on dimmed state. watchOS dims hard on its own, and a
    /// saturated colour block left at full value on top of that is a burn-in
    /// and battery liability — the palette has a reduced variant for it (#243).
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let restTargets = [60, 120, 180, 300]
    @State private var fixtureRestTargetS: Int? = ScreenshotFixtures.workoutRestTargetS
    @State private var showingFinishConfirmation = false

    private var fixtureVisual: ScreenshotWorkoutVisual? { ScreenshotFixtures.workout }
    private var visibleRestTargetS: Int { fixtureRestTargetS ?? workout.restTargetS }
    private var currentScreen: WorkoutScreen {
        ScreenshotFixtures.workoutScreen ?? Self.screen(for: workout)
    }

    // #476 review finding F1: `WorkoutScreenSelection` (SendLogWatchCore) is
    // the single, unit-tested source of this decision — this is a thin
    // pass-through, not a second copy of the logic. It fixes two bugs the
    // old inline `if failedBundle != nil { … } else if justSaved { … } else
    // if isRunning { … }` order had: (1) a running workout's render could be
    // covered by a PREVIOUS workout's save outcome (no End control reachable
    // — the exact bug #476 exists to fix), because `isRunning` was checked
    // last, and (2) `failedBundle` doesn't participate in this decision at
    // all any more — it's surfaced as a banner inside `startContent` (see
    // below) instead of gating a competing exclusive screen, which used to
    // make Start permanently unreachable once a save was `.lost`.
    var body: some View {
        Group {
            switch currentScreen {
            case .live: liveContent
            case .saved: savedContent
            case .start: startContent
            }
        }
        // No title while running. watchOS floats the nav bar OVER the content
        // rather than insetting it, so "Climb" was being drawn straight
        // through the elapsed-time readout — and once the band says RESTING
        // next to an End button, the title is telling nobody anything.
        .navigationTitle(currentScreen == .live ? "" : "Climb")
        .navigationBarBackButtonHidden(currentScreen == .live)
        .watchCanvas()
    }

    /// The exact decision `body` renders, as a testable seam (#476 R3a):
    /// `@Environment` can't be resolved outside a hosted view, so a test
    /// can't construct a `WorkoutLiveView` and read its `body` directly —
    /// this takes the manager explicitly instead, and `body` calls nothing
    /// else to make the choice. `WorkoutOwnershipTests
    /// .testFailedBundleNeverGatesTheScreen` (SendLogWatchTests) asserts a
    /// `failedBundle` never changes this result, through this exact
    /// function — not a parallel copy of it.
    static func screen(for workout: WorkoutManager) -> WorkoutScreen {
        WorkoutScreenSelection.screen(isRunning: workout.isRunning, justSaved: workout.justSaved)
    }

    /// A failed save from a PREVIOUS workout (#287's last in-memory copy of
    /// one that couldn't be persisted) — deliberately a banner inside
    /// `startContent`, not its own exclusive screen: an exclusive screen
    /// blocked Start for the rest of the app session whenever a save was
    /// `.lost` (#476 review finding F1, scenario B), with no way to clear it
    /// short of a successful retry.
    @ViewBuilder
    private var failedSaveBanner: some View {
        WatchStateBanner(
            state: .danger,
            title: "Last workout not saved",
            message: "Your workout stays on the watch until a retry succeeds.",
            actionTitle: workout.ending ? "Retrying…" : "Retry Save",
            action: { workout.retryFailedSave() },
            actionDisabled: workout.ending
        )
    }

    @ViewBuilder
    private var savedContent: some View {
        let queued = fixtureVisual?.stillQueued ?? workout.stillQueued
        // #529 F3: a fixture never models the held-for-another-account state
        // (no screenshot exercises an A → signed-out/B transition), so only
        // the real manager's flag can ever be true here.
        let heldForAnotherAccount = fixtureVisual == nil && workout.stillQueuedForAnotherAccount
        WatchCard(accent: WatchPalette.success) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WatchStateChip(state: .success, title: queued ? "Saved on watch" : "Saved")
                    Spacer(minLength: 0)
                }
                Text(
                    heldForAnotherAccount ? "Uploads when the account that started it signs in"
                    : queued ? "Uploads when signed in"
                    : "Set RPE on your phone"
                )
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(WatchPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var startContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            // #476 review finding F1: a failed save from a previous workout
            // is additive here, never blocking — see `failedSaveBanner`'s
            // doc comment.
            if workout.failedBundle != nil {
                failedSaveBanner
            }
            WatchCard(accent: WatchPalette.secondary) {
                VStack(alignment: .leading, spacing: 7) {
                    WatchStateChip(state: .ready, title: "Ready to climb", compact: true)
                    Text("Tracks heart rate, wrist motion and altitude to count your boulders automatically.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Start Workout") {
                Task { await workout.start() }
            }
            .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.secondary))
            if let msg = fixtureVisual?.errorMessage ?? workout.errorMsg {
                WatchStateBanner(state: .danger, title: "Workout could not start", message: msg)
            }
        }
    }

    // Same logic as the phone fullscreen: CLIMBING counts up from the boulder
    // start; stopping drops straight into a RESTING countdown toward the
    // persisted target. One screen, no scrolling — Finish lives in the
    // app-owned top row (#580): the old toolbar End button rendered as an
    // oversized square that dominated the header and competed with the
    // system clock, and a toolbar item's frame is watchOS's to clip.
    //
    // One TimelineView drives BOTH the phase band and the phase timer (#243)
    // so they flip on the same tick — a band that says RESTING behind a
    // countdown that says REST OVER would be worse than no colour at all. It
    // also replaces the timer's own per-second timeline rather than adding a
    // second one.
    @ViewBuilder
    private var liveContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = fixtureVisual?.phase ?? workout.livePhase(at: context.date)
            // Resolved once per tick and threaded down, so the band and the
            // text on it can never be read from two different resolutions.
            let fill = WorkoutPhasePalette.fill(for: phase, luminanceReduced: isLuminanceReduced)
            liveStack(phase: phase, fill: fill)
                .background(color(fill.screen).ignoresSafeArea())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-live-viewport")
        // This screen is a glanceable fixed-height dashboard: RESTING stacks
        // four rows with no scroll fallback, so uncapped accessibility
        // Dynamic Type would push the action row off a 40mm viewport with no
        // way to reach it. Cap the *visual* scale while every control keeps
        // its full VoiceOver label/hint and 44pt hit target; the screenshot
        // suite runs the accessibility-large launch argument against this cap.
        .dynamicTypeSize(.medium ... .large)
        .confirmationDialog(
            "Finish workout?",
            isPresented: $showingFinishConfirmation,
            titleVisibility: .visible
        ) {
            // The compact destructive control must never end a workout on a
            // single (possibly accidental) tap — `endAndSave()` runs only
            // after this explicit confirmation (#580 scope 1).
            Button("Finish Workout", role: .destructive) {
                workout.endAndSave()
            }
            .accessibilityIdentifier("finish-workout-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your climbing data will be saved on this watch.")
        }
    }

    /// Compact, icon-only finish action — the shared `WatchIconButton`
    /// primitive with the semantic danger tint. The checkered-flag glyph is
    /// deliberately not the in-row boulder stop glyph: the two controls end
    /// different scopes (see `WatchIconSymbol.finishWorkout`).
    private var finishWorkoutButton: some View {
        WatchIconButton(
            systemImage: workout.ending ? "ellipsis" : WatchIconSymbol.finishWorkout,
            accessibilityLabel: workout.ending ? "Finishing workout" : "Finish workout",
            accessibilityHint: workout.ending
                ? "Saving the workout"
                : "Shows a confirmation before saving and ending the workout",
            accessibilityIdentifier: "finish-workout",
            tint: WatchDesignTokens.danger,
            usesTintWhenUnselected: true,
            isDisabled: workout.ending
        ) {
            showingFinishConfirmation = true
        }
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
                    .fill(WatchPalette.phaseGradient(color(fill.band), luminanceReduced: isLuminanceReduced))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: WorkoutPhasePalette.transitionSeconds),
                        value: phase
                    )
            )
    }

    /// The height every control row *consumes* in layout. Each interactive
    /// primitive still carries its full 44pt hit frame (inside its button
    /// label — see `WatchIconButtonStyle`), centred in this shorter slot so
    /// the invisible margin overhangs adjacent non-interactive whitespace
    /// instead of spending 3 × 44pt of a ~160pt viewport on padding. This is
    /// what lets the HR row, the band, four rest pills AND the action row fit
    /// a 40mm screen with nothing clipped (#580).
    private static let controlRowHeight: CGFloat = 30

    @ViewBuilder
    private func liveStack(phase: WorkoutPhase, fill: PhaseFill) -> some View {
        let heartRate = fixtureVisual?.heartRate ?? workout.heartRate
        let elapsed = fixtureVisual?.elapsed ?? workout.elapsed
        VStack(spacing: 2) {
            // HR + total elapsed on ONE line at the LEFT, the compact finish
            // action at the RIGHT. The readouts used to be stacked, which
            // cost a whole footnote line of height RESTING does not have on
            // 40mm; the finish action now shares this row instead of
            // competing with the system clock in the toolbar.
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.footnote)
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.danger))
                    Text(heartRate.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.body).monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(timeString(elapsed))
                    .font(.footnote).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                finishWorkoutButton
                    .frame(height: Self.controlRowHeight)
            }
            .frame(height: Self.controlRowHeight)

            Spacer(minLength: 0)

            phaseTimer(phase: phase, fill: fill)

            Spacer(minLength: 0)

            actionRow
        }
        // The 44pt hit frames overhang their 30pt rows by 7pt on each edge;
        // this padding keeps the top (finish) and bottom (play/stop) overhang
        // inside the viewport instead of poking into the clock or past the
        // bottom edge — the exact clip #580 exists to fix.
        .padding(.top, 7)
        .padding(.bottom, 7)
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
        let attempts = fixtureVisual?.attempts ?? workout.liveAttempts
        let isClimbing = fixtureVisual?.phase == .climbing || (fixtureVisual == nil && workout.manualClimbing)
        let kcal = fixtureVisual?.activeKcal ?? workout.activeKcal
        let altitude = fixtureVisual?.altitude ?? workout.relativeAltitude
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("BOULDERS")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(attempts)")
                    // 18pt rounded, not .title3: the count shares its row
                    // with the 30pt play/stop slot and .title3's Dynamic
                    // Type growth is what used to push this row into the
                    // bottom edge on 40mm.
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Play = start a boulder, stop = drop off into the rest countdown
            // (phone-workout logic; icons instead of words). The shared icon
            // primitive keeps the visible circle compact while its label owns
            // the full 44pt hit target; the 30pt row slot lets the invisible
            // margin overhang the readouts either side instead of pushing the
            // whole row past the bottom edge on 40mm. Same hues as the phase
            // band (#277 follow-up): stop reads "act now" like rest-over,
            // play reads "go" like climbing.
            WatchIconButton(
                systemImage: isClimbing ? "stop.fill" : "play.fill",
                accessibilityLabel: isClimbing ? "Stop boulder" : "Start boulder",
                accessibilityHint: isClimbing
                    ? "Ends this boulder and starts the rest timer"
                    : "Starts a manual boulder attempt",
                accessibilityIdentifier: "workout-boulder-toggle",
                isSelected: isClimbing,
                tint: isClimbing ? WorkoutPhasePalette.phoneDanger : WorkoutPhasePalette.phoneSuccess,
                usesTintWhenUnselected: true
            ) {
                workout.toggleManualAttempt()
            }
            .frame(height: Self.controlRowHeight)

            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(kcal)) kcal")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(String(format: "%.1fm", altitude))
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
        if let fixtureVisual {
            VStack(spacing: 3) {
                phaseBand(phase: phase, fill: fill) {
                    VStack(spacing: 0) {
                        Text(phase == .climbing ? "CLIMBING" : phase == .restOver ? "REST OVER" : "RESTING")
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                        Text(fixtureVisual.currentTimer)
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
                if fixtureVisual.phase == .resting {
                    restTargetControls
                }
            }
        } else if phase == .climbing, let since = workout.climbingSince {
            phaseBand(phase: phase, fill: fill) {
                VStack(spacing: 0) {
                    Text("CLIMBING")
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(timerInterval: since...since.addingTimeInterval(3600), countsDown: false)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(timerInterval: rest...end, countsDown: true)
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .multilineTextAlignment(.center)
                    }
                }
                restTargetControls
            }
        }
    }

    /// Rest target controls are shared by the real workout and the screenshot
    /// fixture. Keeping one production control path makes the fixture useful
    /// for catching small-screen clipping and selection regressions instead of
    /// merely drawing a row of labels.
    ///
    /// All four targets stay visible at once as compact colour-coded capsules
    /// (#580 scope 2): the old `WatchSecondaryButtonStyle` row asked for
    /// 4 × 44pt of visible chrome, which cannot fit 40mm — its horizontal
    /// ScrollView clipped the trailing option instead. The visible capsule is
    /// 28pt tall; each button's full-height slot is still the 44pt hit
    /// target, delivered inside the button label (`minHeight` + rectangular
    /// `contentShape`) so the tap area does not shrink with the artwork.
    @ViewBuilder
    private var restTargetControls: some View {
        HStack(spacing: 3) {
            ForEach(restTargets, id: \.self) { target in
                let selected = visibleRestTargetS == target
                let minutes = target / 60
                let accent = WatchPalette.accent(
                    restTargetTint(for: target),
                    reducedLuminance: isLuminanceReduced
                )
                Button {
                    workout.restTargetS = target
                    if ScreenshotFixtures.enabled, ScreenshotFixtures.state == .workoutRest {
                        fixtureRestTargetS = target
                    }
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 12, weight: selected ? .heavy : .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(
                            selected
                                ? WatchPalette.textPrimary
                                : WatchPalette.foreground(restTargetTint(for: target))
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            Capsule()
                                .fill(accent.opacity(selected ? 0.42 : 0.14))
                                .overlay {
                                    Capsule().stroke(
                                        accent.opacity(selected ? 0.9 : 0.38),
                                        lineWidth: selected ? 1.2 : 0.8
                                    )
                                }
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: CGFloat(WatchDesignTokens.minimumHitTarget)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rest-target-\(target)")
                .accessibilityLabel("Rest \(minutes) \(minutes == 1 ? "minute" : "minutes")")
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // 44pt hit slots in a 30pt layout row — the ±7pt overhang lands on
        // the band above and the action-row whitespace below, both
        // non-interactive at those coordinates.
        .frame(height: Self.controlRowHeight)
    }

    /// One hue per target so the selection reads at a glance (#580 scope 4's
    /// "more colorful, design-system aligned"): the ramp runs short → long
    /// through the shared semantic accents. `force` is deliberately absent —
    /// that token is reserved for the Home Force-card identity.
    private func restTargetTint(for target: Int) -> PhaseRGB {
        switch target {
        case 60: WatchDesignTokens.success
        case 120: WatchDesignTokens.secondary
        case 180: WatchDesignTokens.primary
        default: WatchDesignTokens.warning
        }
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
        m.relativeAltitude = 1.4
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
    // #476: WorkoutLiveView reads the manager from the environment now
    // (App-scoped in production), not a preview-only init.
    NavigationStack { WorkoutLiveView() }
        .environment(workout)
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

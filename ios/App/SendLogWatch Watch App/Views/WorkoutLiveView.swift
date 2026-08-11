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
    /// Read at the view boundary, so this sees the user's REAL size —
    /// deliberately before `liveStack`'s `.dynamicTypeSize` caps clamp what
    /// the rows render at.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        // While the compact confirmation is up, the screen behind it leaves
        // the accessibility tree entirely: the scrim already blocks touch
        // hit-testing, but VoiceOver focus (and XCUITest hittability) walk
        // the tree, not the scrim — without this, swiping VoiceOver focus
        // could still land on and activate the covered live controls.
        .accessibilityHidden(showingFinishConfirmation)
        // The compact in-design confirmation replaces the full-screen system
        // confirmationDialog (user decision after trying #582 on a 40mm
        // device: the system sheet was too big and the red destructive
        // treatment too alarming for what is a safe, expected action).
        // Attached here, outside every Dynamic Type cap the live screen
        // applies to its own rows (#582 review F7 still applies), and the
        // one-tap guarantee is unchanged: `endAndSave()` is reachable only
        // through the overlay's explicit Finish button.
        .overlay {
            if showingFinishConfirmation {
                finishConfirmationOverlay
            }
        }
        .watchCanvas()
    }

    /// Compact confirmation card in the watch design language: `WatchCard`
    /// chrome (accent hairline, Always-On-aware gradient) with the calmer
    /// shared secondary accent instead of a red destructive treatment —
    /// finishing is the expected end of every workout, not an emergency.
    /// The scrim blocks every live control underneath (a stray tap cannot
    /// toggle a boulder mid-confirmation) and tapping it cancels, which is
    /// always safe. Appears/disappears without animation, so there is no
    /// motion for Reduce Motion to reduce.
    private var finishConfirmationOverlay: some View {
        ZStack {
            // Deep enough that the live screen reads as background in both
            // full and reduced luminance; the card on top stays the focus.
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showingFinishConfirmation = false }
                .accessibilityHidden(true)
            WatchCard(accent: WatchPalette.secondary) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finish workout?")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Saves your climb to this watch.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Cancel") {
                            showingFinishConfirmation = false
                        }
                        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.textSecondary))
                        // Neither title may hyphenate-wrap in the tight
                        // side-by-side row on 40mm: one line each, scaling
                        // down a step instead when the width demands it.
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .accessibilityIdentifier("finish-workout-cancel")
                        .accessibilityHint("Keeps the workout running")
                        Button("Finish") {
                            showingFinishConfirmation = false
                            // Presentation-only fixture guard: the workout
                            // fixtures force the live screen while no real
                            // workout is running (production cannot reach
                            // that state — `.live` requires `isRunning`), so
                            // the real save path has nothing valid to end
                            // and would leave the fixture stuck mid-save.
                            // Fixtures never drive queues or saves, same as
                            // `fixtureRestTargetS` above.
                            if ScreenshotFixtures.enabled, ScreenshotFixtures.workout != nil {
                                return
                            }
                            workout.endAndSave()
                        }
                        .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier("finish-workout-confirm")
                        .accessibilityHint("Saves and ends the workout")
                    }
                }
            }
            .padding(.horizontal, 6)
            // VoiceOver treats the card as a modal so focus stays on the
            // confirmation instead of the dimmed live controls behind it.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        // Bounded like the HR readouts (#582 review F3's cap style): the
        // compact card plus two 44pt buttons must fit a 40mm viewport with
        // no scroll fallback, so the visual scale stops at .xxLarge while
        // the full VoiceOver labels and hints stay intact.
        .dynamicTypeSize(.medium ... .xxLarge)
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
            .padding(.vertical, 2)
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
    /// label — see `WatchIconButtonStyle`), fitted into this shorter slot so
    /// the invisible margin overhangs adjacent NON-INTERACTIVE surfaces only
    /// — never another control's visible pixels — instead of spending
    /// 3 × 44pt of a ~160pt viewport on padding. Where each overhang lands
    /// (#582 review F1, per-row):
    /// - finish: symmetric ±7pt over the HR readout text and the gap above
    ///   the band;
    /// - rest pills: the whole 16pt margin extends UPWARD over the phase
    ///   band (`alignment: .bottom` slot + top-padded label), so the pills'
    ///   hit slots end exactly at their visible bottom edge;
    /// - play/stop: symmetric ±7pt, kept clear of the pills by
    ///   `actionRow`'s explicit 7pt top padding (equal to the overhang) —
    ///   `assertWorkoutLiveControls` asserts the pill and play/stop hit
    ///   frames are disjoint, because the action row is the later sibling
    ///   and would otherwise silently win taps on visible pill pixels.
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(spacing: 4) {
                        // Dropped at accessibility sizes (ForceGaugeView's
                        // progressive-disclosure house style): the readouts
                        // are the row's information and the glyph is what
                        // makes them width-bound on 40mm — with it, the
                        // `.xxLarge` cap's growth was silently eaten by
                        // `minimumScaleFactor` and accessibility users got
                        // normal-size ink back (#582 review F3).
                        if !dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "heart.fill")
                                .font(.footnote)
                                .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.danger))
                        }
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
                }
                Spacer(minLength: 0)
                finishWorkoutButton
                    .frame(height: Self.controlRowHeight)
            }
            .frame(height: Self.controlRowHeight)

            Spacer(minLength: 0)

            // The band, pills and action row are the fixed glanceable core:
            // a no-scroll dashboard whose rows use fixed type sizes by
            // design, so accessibility Dynamic Type cannot push the action
            // row off a 40mm viewport with no way to reach it — the same
            // cap-the-fixed-core house style as `ForceGaugeView`'s primary
            // path (#582 review F3). Controls keep their full VoiceOver
            // labels/hints, 44pt-tall hit slots, and (for the four
            // shared-width pills) a ≥36pt-wide share of the row — four
            // literal 44pt widths cannot exist side by side on a 162pt panel.
            phaseTimer(phase: phase, fill: fill)
                .dynamicTypeSize(.medium ... .large)

            Spacer(minLength: 0)

            actionRow
                .dynamicTypeSize(.medium ... .large)
        }
        // The HR/elapsed readout line above is the screen's one Dynamic
        // Type-scalable run; it stops at .xxLarge, where the fixed 30pt row
        // stops fitting the glyphs. This looser screen-level bound (instead
        // of the old whole-screen .large cap) is what makes the
        // accessibility-large screenshot run render differently from the
        // normal one, so that test can fail on its own (#582 review F3).
        // Order matters: this outer range must be the widest, because an
        // outer clamp collapses the environment value before an inner range
        // could re-expand it.
        .dynamicTypeSize(.medium ... .xxLarge)
        // The finish and play/stop hit frames overhang their 30pt rows by
        // 7pt; this padding keeps the top (finish) and bottom (play/stop)
        // overhang inside the viewport instead of poking into the clock or
        // past the bottom edge — the exact clip #580 exists to fix.
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
            // whole row past the bottom edge on 40mm. The GLYPH takes the
            // phase hues (#277 follow-up: stop = rest-over orange "act now",
            // play = climbing blue "go") while unselected the circle keeps
            // the primitive's neutral fill; selected (climbing) fills the
            // circle with the orange outright.
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
        // Exactly the play/stop hit frame's 7pt upward overhang: with the
        // pills' hit slots ending at their visible bottom edge (see
        // `restTargetControls`), this guaranteed gap keeps the two hit
        // frames disjoint — the action row is the later sibling, so any
        // overlap would silently route taps on visible pill pixels to
        // Start/Stop boulder (#582 review F1). `assertWorkoutLiveControls`
        // asserts the disjointness.
        .padding(.top, 7)
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
                            .font(.system(size: 31, weight: .heavy, design: .rounded))
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
                        .font(.system(size: 31, weight: .heavy, design: .rounded))
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
                            .font(.system(size: 31, weight: .heavy, design: .rounded))
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
    /// 28pt tall; each button's slot is still 44pt tall, delivered inside the
    /// button label so the tap area does not shrink with the artwork. The
    /// slot is deliberately ASYMMETRIC (#582 review F1): all 16 extra points
    /// extend upward over the non-interactive phase band (`.padding(.top)` on
    /// the label + a bottom-aligned row), so each pill's hit frame ends
    /// exactly at its visible bottom edge and can never contest the play/stop
    /// control's upward overhang below.
    @ViewBuilder
    private var restTargetControls: some View {
        HStack(spacing: 3) {
            ForEach(restTargets, id: \.self) { target in
                let selected = visibleRestTargetS == target
                let minutes = target / 60
                let tint = Self.restTargetRamp(for: target)
                let accent = WatchPalette.accent(tint, reducedLuminance: isLuminanceReduced)
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
                                : WatchPalette.foreground(tint)
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
                        .padding(.top, CGFloat(WatchDesignTokens.minimumHitTarget) - 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rest-target-\(target)")
                .accessibilityLabel("Rest \(minutes) \(minutes == 1 ? "minute" : "minutes")")
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // 44pt-tall hit slots in a 30pt layout row, bottom-aligned so the
        // whole overhang lands on the band above (non-interactive) and none
        // of it extends below the visible capsules.
        .frame(height: Self.controlRowHeight, alignment: .bottom)
    }

    /// One hue per target so the selection reads at a glance (#580's "more
    /// colorful"): a DEDICATED decorative ramp, deliberately not aliased to
    /// the semantic state tokens (#582 review F10) — a five-minute rest is
    /// not a `warning` and a one-minute rest is not `success`, and coupling
    /// durations to state tokens would both dilute what those hues mean
    /// elsewhere on the watch and silently recolor this row if a state token
    /// is ever retuned. The values intentionally match the accent family's
    /// look (and `WatchPalette.accent`'s Always-On dimming applies the same
    /// way); only the *meaning* is decoupled.
    private static func restTargetRamp(for target: Int) -> PhaseRGB {
        switch target {
        case 60: PhaseRGB(0.30, 0.93, 0.68) // mint
        case 120: PhaseRGB(0.18, 0.84, 0.96) // cyan — the screenshot suite's selector pixel proof
        case 180: PhaseRGB(0.48, 0.40, 1.0) // indigo
        default: PhaseRGB(1.0, 0.76, 0.32) // amber
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

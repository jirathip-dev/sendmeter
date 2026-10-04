import Foundation
import SendmeterCore
import SwiftUI
import UIKit

/// Owns a guided run outside the fullscreen presentation.  The cover is only
/// a viewport: minimizing it must not stop BLE, reset the stage clock, or end
/// the durable gauge session.  Keeping the runner here also means a stage can
/// cross a minimize/background transition without relying on a view-owned
/// TimelineView tick.
private struct GuidedForceSaveKey: Hashable {
    let stageID: UUID
    let segment: Int
    let partial: Bool
}

@MainActor
final class GuidedForceProtocolSession: ObservableObject, Identifiable {
    let id: UUID
    let model: AppModel
    let preset: TindeqPreset
    let targetPlan: ForceTargetPlan
    let tag: String
    let fallbackSide: TindeqSide
    let selection: ForceProtocolSelection
    let references: ZoneCurveInput?
    let accountScope: NativeAccountScope

    @Published private(set) var run: ForceProtocolRun
    @Published private(set) var savedCount = 0
    @Published private(set) var interrupted = false
    @Published private(set) var isAdvancing = false
    @Published private(set) var isPausing = false
    @Published private(set) var isEnded = false

    private var ticker: Task<Void, Never>?
    private var observedStageID: UUID?
    private var hasObservedFirstStage = false
    private var hasBegun = false
    private var hasFiredCompletionHaptic = false
    private var lastHandsFreeHaptic: HandsFreeHapticState?
    private var saveClaims = Set<GuidedForceSaveKey>()
    private var workSegment = 0
    private var workMeasurementReady = false
    private var handsFreeMeasurementObserved = false
    private var sessionEndClaimed = false
    private var policy = GuidedForceSessionPolicy()
    private let terminalSettlement = GuidedForceTerminalSettlement()
    private var pauseClaim: UUID?

    private var ownsAccount: Bool {
        model.accountScope == accountScope
    }

    init(
        model: AppModel,
        preset: TindeqPreset,
        targetPlan: ForceTargetPlan,
        tag: String,
        startingSide: TindeqSide,
        fallbackSide: TindeqSide,
        selection: ForceProtocolSelection,
        references: ZoneCurveInput?,
        run: ForceProtocolRun? = nil
    ) {
        self.model = model
        self.preset = preset
        self.targetPlan = targetPlan
        self.tag = tag
        self.fallbackSide = fallbackSide
        self.selection = selection
        self.references = references
        self.accountScope = model.accountScope
        // #901: `fallbackSide` is the normalized side selection, so the run
        // is built with it as the SELECTED side — a Left/Right selection
        // never alternates, even for an `alternateSides` preset.
        let initialRun = run ?? ForceProtocolRun(
            preset: preset,
            startingSide: startingSide,
            selectedSide: fallbackSide
        )
        self.run = initialRun
        self.id = initialRun.runID
    }

    deinit {
        ticker?.cancel()
    }

    @discardableResult
    func begin() -> Bool {
        guard ownsAccount, !isEnded, !interrupted, !sessionEndClaimed, policy.canTick else { return false }
        let isFirstPresentation = !hasBegun
        if run.stageStartedAt == nil, !run.isComplete {
            run.start()
        }
        model.setGuidedProtocolActive(true)
        // #899: every guided work stage is load-triggered — the caller-owned
        // hands-free controller gates WHEN measurement starts (a real pull),
        // while this runner owns every stop/save. There is no non-hands-free
        // guided mode anymore.
        model.handsFree.stopPolicy = .callerOwned
        if hasBegun {
            refreshActivity(at: Date())
        } else {
            hasBegun = true
            model.guidedActivity.start(
                run: run,
                preset: preset,
                targetPlan: targetPlan,
                fallbackSide: fallbackSide
            )
        }
        startTickerIfNeeded()
        return isFirstPresentation
    }

    /// Pause is intentionally limited to the same static guided work surface
    /// as the Capacitor control. Hands-free/adaptive stages retain their own
    /// arm/release state machine rather than gaining a second pause semantic.
    func canPause(at _: Date) -> Bool {
        ownsAccount
            && !isEnded
            && !interrupted
            && !isPausing
            && policy.canPause
            && preset.protocolMode == .hold
            && run.currentStage.kind == .work
            && (
                run.isPaused
                    || model.tindeq.status == .measuring
                    || model.handsFree.isMeasuring
            )
    }

    var isWaitingForHandsFreePull: Bool {
        run.currentStage.kind == .work
            && GuidedForceHandsFreeTimingPolicy.isWaitingForPull(
                handsFreeEnabled: true,
                measurementObserved: handsFreeMeasurementObserved
            )
    }

    func elapsedSeconds(at date: Date) -> Double {
        isWaitingForHandsFreePull ? 0 : run.elapsedSeconds(at: date)
    }

    func remainingSeconds(at date: Date) -> Double {
        isWaitingForHandsFreePull
            ? run.currentStage.durationSeconds
            : run.remainingSeconds(at: date)
    }

    private func refreshActivity(at date: Date) {
        model.guidedActivity.refresh(
            run: run,
            at: date,
            paused: isWaitingForHandsFreePull
        )
    }

    func togglePause(at date: Date) {
        guard canPause(at: date) else { return }
        if run.isPaused {
            resume(at: date)
        } else {
            guard policy.claimPause() else { return }
            let stage = run.currentStage
            let segment = workSegment
            let claim = UUID()
            pauseClaim = claim
            isPausing = true
            workSegment += 1
            workMeasurementReady = false
            handsFreeMeasurementObserved = false
            let hasActiveRecording = model.tindeq.status == .measuring || model.handsFree.isMeasuring
            let summary = hasActiveRecording ? model.tindeq.stopMeasuring() : nil
            model.handsFree.disarm()
            // Claim and freeze the work stage before the first await. The
            // ticker therefore cannot advance the stage while its recording
            // is being made durable.
            run.pause(at: date)
            refreshActivity(at: date)
            guard let summary else {
                finishPauseClaim(claim)
                return
            }
            Task { [weak self] in
                await self?.persistPause(
                    summary,
                    stage: stage,
                    segment: segment,
                    claim: claim
                )
            }
        }
    }

    private func persistPause(
        _ summary: ForceSummary,
        stage: ForceProtocolStage,
        segment: Int,
        claim: UUID
    ) async {
        let enqueued = await preserve(
            summary,
            stage: stage,
            partial: true,
            segment: segment
        )
        if enqueued, ownsAccount {
            model.tindeq.clearCompletedRecording()
        }

        guard pauseClaim == claim else {
            if terminalSettlement.isClaimed {
                await terminalSettlement.wait()
            }
            return
        }
        guard ownsAccount, run.isPaused, run.currentStage.id == stage.id
        else {
            finishPauseClaim(claim)
            if terminalSettlement.isClaimed {
                await terminalSettlement.wait()
            }
            return
        }
        guard enqueued else {
            model.errorMessage = UserFacingError.message(for: .saveFailed)
            interrupted = true
            // The save failure is terminal. Claim that state before the
            // cleanup await so a ticker continuation cannot advance the work
            // stage while this pause path is ending the gauge session.
            finishPauseClaim(claim)
            guard claimTerminal() else {
                await terminalSettlement.wait()
                return
            }
            let settlement = terminalSettlement.start { [self] in
                await finishGaugeSession()
            }
            await settlement.value
            return
        }
        finishPauseClaim(claim)
    }

    private func finishPauseClaim(_ claim: UUID) {
        guard pauseClaim == claim else { return }
        pauseClaim = nil
        policy.finishPause()
        isPausing = false
    }

    private func resume(at date: Date) {
        guard ownsAccount, !sessionEndClaimed, !isEnded, run.isPaused,
              run.currentStage.kind == .work,
              preset.protocolMode == .hold,
              policy.canResume
        else { return }
        run.resume(at: date)
        workMeasurementReady = false
        // A resumed arm is not a new protocol hold: retain the elapsed work
        // already banked by ForceProtocolRun.pause/resume, and let the
        // scheduled stage continue even before another pull is detected.
        // #899: guided measurement is always load-triggered hands-free, so
        // the resumed stage continues as a hands-free arm.
        handsFreeMeasurementObserved = true
        guard startWorkMeasurement() else {
            run.pause(at: date)
            handsFreeMeasurementObserved = false
            return
        }
        refreshActivity(at: date)
    }

    private func startTickerIfNeeded() {
        guard ticker == nil, !sessionEndClaimed, !isEnded else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(at: Date())
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func tick(at date: Date) async {
        guard ownsAccount, !isEnded, !interrupted, !sessionEndClaimed, policy.canTick else { return }

        if case .interrupted = model.tindeq.status {
            await preserveInterruption(at: date)
            return
        }

        updateHandsFreeHaptic()
        guard !run.isPaused, !run.isComplete else { return }
        observeStage(at: date)
        guard !isAdvancing, !sessionEndClaimed else { return }
        let stage = run.currentStage
        if stage.kind == .work, !handsFreeMeasurementObserved {
            // The caller-owned hands-free controller may move to its release
            // state before the BLE recording is stopped. The transport's
            // measuring status is therefore also evidence that a real pull
            // was observed; otherwise an early release could leave this
            // ticker waiting forever on `isMeasuring`.
            let measurementObserved = model.handsFree.isMeasuring
                || model.tindeq.status == .measuring
            guard measurementObserved else {
                // An armed hands-free stage is load-triggered, not a blind
                // countdown. Keep the stage waiting until the controller has
                // promoted a real pull to recording.
                return
            }
            if GuidedForceHandsFreeTimingPolicy.shouldReanchor(
                handsFreeEnabled: true,
                isMeasuring: measurementObserved,
                measurementObserved: handsFreeMeasurementObserved
            ) {
                run.restartCurrentStage(at: date)
                handsFreeMeasurementObserved = true
                refreshActivity(at: date)
            }
        }
        guard run.remainingSeconds(at: date) <= 0 else { return }
        let boundary = run.stageStartedAt?.addingTimeInterval(stage.durationSeconds) ?? date
        await advanceCurrentStage(at: boundary)
    }

    private func updateHandsFreeHaptic() {
        let next: HandsFreeHapticState?
        if model.handsFree.isMeasuring {
            next = .measuring
        } else if model.handsFree.isArmed {
            next = .armed
        } else {
            next = nil
        }
        guard next != lastHandsFreeHaptic else { return }
        lastHandsFreeHaptic = next
        if let next {
            Haptics.shared.play(HandsFreeHaptics.cue(for: next))
        }
    }

    /// #940: the completion cue fires exactly once per run. The claim is
    /// taken with the `.complete` transition, so a reopened (minimized)
    /// presentation, a re-render of the complete stage, or any later
    /// observation of the finished run cannot repeat it. `advance` can only
    /// enter `.complete` once and the ticker stops observing it, so this
    /// claim is the explicit statement of that rule.
    private func fireCompletionHapticIfNeeded() {
        guard !hasFiredCompletionHaptic else { return }
        hasFiredCompletionHaptic = true
        Haptics.shared.play(.success)
    }

    private func observeStage(at date: Date) {
        guard ownsAccount, !sessionEndClaimed, !isEnded else { return }
        guard observedStageID != run.currentStage.id else { return }
        observedStageID = run.currentStage.id
        workSegment = 0
        workMeasurementReady = false
        handsFreeMeasurementObserved = false
        if hasObservedFirstStage {
            Haptics.shared.play(GuidedTransitionHaptics.cue(entering: run.currentStage.kind))
        } else {
            hasObservedFirstStage = true
        }

        if run.currentStage.kind == .work, !startWorkMeasurement() {
            return
        }
        refreshActivity(at: date)
    }

    @discardableResult
    private func startWorkMeasurement() -> Bool {
        guard ownsAccount, !sessionEndClaimed, !isEnded else { return false }
        guard !workMeasurementReady else { return true }
        // #899: every guided rep starts from the pull. A work stage arms the
        // caller-owned hands-free stream and waits for load — the blind
        // countdown that auto-started `tindeq.startMeasuring()` without a
        // pull is gone.
        model.handsFree.arm()
        workMeasurementReady = true
        return true
    }

    private func advanceCurrentStage(
        at date: Date,
        intent: GuidedForceAdvanceIntent = .scheduled
    ) async {
        guard ownsAccount, !isEnded, !interrupted, !sessionEndClaimed, !run.isComplete,
              policy.claimAdvance()
        else { return }
        isAdvancing = true
        let stage = run.currentStage
        let hasActiveRecording = model.tindeq.status == .measuring || model.handsFree.isMeasuring
        if stage.kind == .work, hasActiveRecording, let summary = model.tindeq.stopMeasuring() {
            model.guidedActivity.updatePeak(summary.peakKilograms, run: run, at: date)
            let enqueued = await preserve(
                summary,
                stage: stage,
                partial: GuidedForceSessionPolicy.recordingIsPartial(for: intent)
            )
            guard enqueued else {
                interrupted = true
                model.guidedActivity.end(immediate: true)
                policy.finishAdvance()
                isAdvancing = false
                Task { [weak self] in await self?.teardown() }
                return
            }
            model.tindeq.clearCompletedRecording()
        }

        guard !sessionEndClaimed, !isEnded else {
            policy.finishAdvance()
            isAdvancing = false
            return
        }

        run.advance(at: date)
        observedStageID = nil
        if run.currentStage.kind == .complete {
            fireCompletionHapticIfNeeded()
            refreshActivity(at: date)
        }
        if stage.kind == .work {
            model.handsFree.disarm()
        }
        workMeasurementReady = false
        handsFreeMeasurementObserved = false
        workSegment = 0
        policy.finishAdvance()
        isAdvancing = false
    }

    func skip(at date: Date) async {
        guard !run.isPaused else { return }
        await advanceCurrentStage(at: date, intent: .skip)
    }

    private func preserveInterruption(at _: Date) async {
        if terminalSettlement.isClaimed {
            await terminalSettlement.wait()
            return
        }
        guard !interrupted else {
            await terminalSettlement.wait()
            return
        }
        interrupted = true
        guard claimTerminal(disarmMeasurement: false) else {
            await terminalSettlement.wait()
            return
        }
        let stage = run.currentStage
        let summary = model.tindeq.interruptedRecording
        model.handsFree.stopPolicy = .automatic
        model.handsFree.disarm()
        let settlement = terminalSettlement.start { [self] in
            if let summary {
                let enqueued = await preserve(summary, stage: stage, partial: true)
                if enqueued {
                    model.tindeq.clearInterruptedRecording()
                }
            }
            await finishGaugeSession()
        }
        await settlement.value
    }

    func endAndSavePartial() async {
        if terminalSettlement.isClaimed {
            await terminalSettlement.wait()
            return
        }
        guard ownsAccount, !isAdvancing, !isPausing else { return }
        guard !isEnded, !sessionEndClaimed else {
            await terminalSettlement.wait()
            return
        }
        guard claimTerminal(disarmMeasurement: false) else {
            await terminalSettlement.wait()
            return
        }
        isAdvancing = true
        let stage = run.currentStage
        let hasActiveRecording = model.tindeq.status == .measuring || model.handsFree.isMeasuring
        let summary = stage.kind == .work && hasActiveRecording
            ? model.tindeq.stopMeasuring()
            : nil
        model.handsFree.stopPolicy = .automatic
        model.handsFree.disarm()
        let settlement = terminalSettlement.start { [self] in
            if let summary {
                let enqueued = await preserve(summary, stage: stage, partial: true)
                if enqueued {
                    model.tindeq.clearCompletedRecording()
                } else {
                    model.errorMessage = UserFacingError.message(for: .saveFailed)
                    interrupted = true
                }
            }
            isAdvancing = false
            endGuidedProtocolOnly()
        }
        await settlement.value
    }

    func finish() async {
        if terminalSettlement.isClaimed {
            await terminalSettlement.wait()
            return
        }
        await endSession()
    }

    func stopOrFinish() async {
        // A terminal claim wins over the caller's current run snapshot. Join
        // its durable preserve/session-end flight before looking at
        // `isComplete` or `interrupted`; those flags are set synchronously by
        // the first claimant and would otherwise make a later Stop return.
        if terminalSettlement.isClaimed {
            await terminalSettlement.wait()
            return
        }
        if run.isComplete || interrupted {
            await finish()
        } else {
            await endAndSavePartial()
        }
    }

    /// Explicit owner-lifecycle teardown. This is intentionally separate from
    /// `deinit`: a Force tab can disappear while the app model remains alive.
    /// The terminal claim/cancel happens synchronously, then the active pull
    /// is salvaged against this account when it is still safe to do so.
    func teardown() async {
        if terminalSettlement.isClaimed {
            await terminalSettlement.wait()
            return
        }
        guard claimTerminal(disarmMeasurement: false) else {
            await terminalSettlement.wait()
            return
        }
        let stage = run.currentStage
        let hasActiveRecording = model.tindeq.status == .measuring || model.handsFree.isMeasuring
        let summary = stage.kind == .work && hasActiveRecording
            ? model.tindeq.stopMeasuring()
            : nil
        workMeasurementReady = false
        model.handsFree.stopPolicy = .automatic
        model.handsFree.disarm()
        let settlement = terminalSettlement.start { [self] in
            if let summary {
                let enqueued = await preserve(
                    summary,
                    stage: stage,
                    partial: true,
                    segment: workSegment
                )
                if enqueued {
                    model.tindeq.clearCompletedRecording()
                } else {
                    // An account transition invalidates the old save scope.
                    // Do not leave that account's completed pull available to
                    // the next account's Force surface.
                    model.tindeq.clearCompletedRecording()
                }
            }
            await finishGaugeSession()
        }
        await settlement.value
    }

    private func endSession() async {
        if terminalSettlement.isClaimed {
            await terminalSettlement.wait()
            return
        }
        guard claimTerminal() else {
            await terminalSettlement.wait()
            return
        }
        let settlement = terminalSettlement.start { [self] in
            endGuidedProtocolOnly()
        }
        await settlement.value
    }

    /// The guided protocol's own finish (#940/#941): the run ends and the
    /// Force tab gets the still-live gauge session back. The protocol's
    /// recordings were already durably queued into the ACTIVE group as each
    /// stage advanced, so finishing neither logs a History entry nor ends the
    /// session — that stays the explicit Finish pill (#627), a disconnect, or
    /// account teardown. Manual pulls and a further protocol join the same
    /// group, which is what makes one Tindeq entry per gauge session.
    private func endGuidedProtocolOnly() {
        guard model.accountScope == accountScope else { return }
        model.setGuidedProtocolActive(false)
    }

    private func finishGaugeSession() async {
        await model.endGaugeSession(ifCurrentAccountScope: accountScope)
        guard model.accountScope == accountScope else { return }
        model.setGuidedProtocolActive(false)
    }

    @discardableResult
    private func claimTerminal(disarmMeasurement: Bool = true) -> Bool {
        guard !sessionEndClaimed, policy.claimTerminal() else { return false }
        sessionEndClaimed = true
        isEnded = true
        isPausing = false
        ticker?.cancel()
        ticker = nil
        model.guidedActivity.end(immediate: true)
        if disarmMeasurement {
            model.handsFree.stopPolicy = .automatic
            model.handsFree.disarm()
        }
        workMeasurementReady = false
        handsFreeMeasurementObserved = false
        return true
    }

    private func preserve(
        _ summary: ForceSummary,
        stage: ForceProtocolStage,
        partial: Bool,
        segment: Int? = nil
    ) async -> Bool {
        guard model.accountScope == accountScope else { return false }
        let saveKey = GuidedForceSaveKey(
            stageID: stage.id,
            segment: segment ?? workSegment,
            partial: partial
        )
        guard saveClaims.insert(saveKey).inserted else { return true }
        let savedSide = stage.side == .unspecified ? fallbackSide : stage.side
        let savedTag: String
        if partial {
            savedTag = tag.isEmpty ? "\(preset.name) · Partial" : "\(tag) · Partial"
        } else {
            savedTag = tag.isEmpty ? preset.name : tag
        }
        let stageBand = targetPlan.band(forSet: stage.setNumber, side: savedSide)
        // #750: derive the zone at each save boundary from THIS set's hold and
        // resolved target, not the set-1 value computed at launch — a per-set
        // ramp or varying hold list can classify later sets differently (web
        // `performedQuality(..., seg.set)`).
        let stageZone = ZoneMix.recordingZone(
            for: selection,
            preset: preset,
            targetBand: stageBand,
            references: references,
            setNumber: stage.setNumber
        )
        let enqueued = await model.saveForceSummary(
            summary,
            tag: savedTag,
            side: savedSide,
            zone: stageZone,
            preset: preset,
            targetBand: stageBand,
            protocolRunID: run.runID,
            setNumber: stage.setNumber,
            repetitionNumber: stage.repetitionNumber,
            partial: partial
        )
        guard model.accountScope == accountScope else {
            saveClaims.remove(saveKey)
            return false
        }
        if enqueued {
            savedCount += 1
        } else {
            saveClaims.remove(saveKey)
        }
        return enqueued
    }
}

private struct GuidedGlassButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.shared.playGesture(StructuralHaptics.cue(level: structuralHapticLevel))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                tint.opacity(configuration.isPressed ? 0.24 : 0.12),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension GuidedGlassButtonStyle: StructuralHapticStyle {
    var structuralHapticLevel: HapticTapLevel { .normal }
}

private struct GuidedForceProtocolView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    @ObservedObject var session: GuidedForceProtocolSession
    let onMinimize: () -> Void
    let onClose: () -> Void

    /// #993: the rendered sizes of the parts the layout's static budget used
    /// to guess. They take over the fit decision as soon as the first layout
    /// pass reports them, so the chart only grows when the screen really has
    /// the room and never spends the controls' space.
    @State private var measuredScrollContentHeight: Double?
    @State private var measuredChartHeight: Double?
    @State private var measuredControlsBarHeight: Double?

    private var layoutMeasurement: GuidedForceLayoutMeasurement? {
        guard let scrollContent = measuredScrollContentHeight,
              let chart = measuredChartHeight,
              let controlsBar = measuredControlsBarHeight
        else { return nil }
        return GuidedForceLayoutMeasurement(
            scrollContentHeight: scrollContent,
            chartHeight: chart,
            controlsBarHeight: controlsBar
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let stage = session.run.currentStage
            let elapsed = session.elapsedSeconds(at: context.date)
            let presentation = GuidedForceFullscreenPresentation.stage(
                stage,
                preset: session.preset,
                elapsedSeconds: elapsed,
                isPaused: session.run.isPaused
            )
            let accent = color(for: presentation.accent)
            GeometryReader { geometry in
                let layout = GuidedForceLayout.resolve(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    textScale: Double(textScale),
                    measurement: layoutMeasurement
                )

                protocolContent(
                    geometry: geometry,
                    date: context.date,
                    elapsed: elapsed,
                    presentation: presentation,
                    accent: accent,
                    layout: layout
                )
                .modifier(LayoutProbe(line: layoutProbeLine(geometry: geometry, layout: layout)))
            }
            // #938: the cover's fills belong at the ROOT of the cover content,
            // outside `GeometryReader` — whose frame is the cover's safe-area
            // rect, so the `.ignoresSafeArea()` fills nested inside it stopped
            // at a hard edge and the cover's black container showed through
            // above them on a notch/Dynamic Island device.
            .background {
                ZStack {
                    Color(uiColor: .systemGroupedBackground)
                    accent.opacity(0.14)
                }
                .ignoresSafeArea()
            }
            .animation(
                reduceMotion
                    ? nil
                    : .spring(
                        response: ForceMotionPolicy.phaseResponseSeconds,
                        dampingFraction: ForceMotionPolicy.phaseDampingFraction,
                        blendDuration: 0
                    ),
                value: presentation.phase
            )
        }
        .onAppear {
            // The library Run tap arms this presentation cue. Reopening the
            // minimized session only refreshes the existing run and does not
            // duplicate the presentation haptic.
            if session.begin() {
                Haptics.shared.sheetPresented()
            }
        }
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    private func protocolContent(
        geometry: GeometryProxy,
        date: Date,
        elapsed: Double,
        presentation: GuidedForceStagePresentation,
        accent: Color,
        layout: GuidedForceLayout
    ) -> some View {
        VStack(spacing: 0) {
            // #938: ONE scroll container for both branches. The fit estimate
            // is approximate, so a layout that claims to fit but actually
            // overflows must still be reachable — without this the live chart's
            // bottom edge sat past the screen edge and could not be scrolled
            // into view. A layout that genuinely fits stays top-aligned in an
            // unscrollable viewport.
            ScrollView(showsIndicators: false) {
                protocolSections(
                    date: date,
                    elapsed: elapsed,
                    presentation: presentation,
                    accent: accent,
                    layout: layout,
                    chartHeight: CGFloat(layout.flexibleChartHeight)
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(0, geometry.size.height - (measuredControlsBarHeight ?? 0)),
                    alignment: .top
                )
            }
            // #993: the pause/skip row is pinned UNDER the scroll view instead
            // of scrolling with it, so the primary control is on screen at
            // every chart height while the top bar (session timer + End) stays
            // at the top of the stack — the two can no longer be split across
            // two scroll positions. #899's shape is preserved: no bottom action
            // inset and no STOP/FINISH circle; this is the same controls row,
            // moved out of the scrollable content.
            controls(date: date)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                    measuredControlsBarHeight = height
                }
        }
    }

    private func protocolSections(
        date: Date,
        elapsed: Double,
        presentation: GuidedForceStagePresentation,
        accent: Color,
        layout: GuidedForceLayout,
        chartHeight: CGFloat
    ) -> some View {
        VStack(spacing: layout.sectionGap) {
            topBar(elapsed: elapsed)
            protocolIdentityHeader
            phaseBanner(
                presentation,
                remaining: session.remainingSeconds(at: date),
                accent: accent
            )
            statusRow(accent: accent)
            targetCoach
            liveChart(chartHeight: chartHeight)
        }
        // #993: the presented cover's frame IS the safe-area rect — measured
        // 375×647 on the SE's 375×667 screen and 402×778 on the iPhone 17
        // Pro's 402×874 screen, while `geometry.safeAreaInsets` still reports
        // the screen's 20/62 pt top inset. Padding by those insets again
        // double-counted them: the dead gap above the first card in the
        // owner's screenshot (measured: the top bar started 40 pt into a
        // 647-pt SE frame and 124 pt into a 778-pt 17 Pro frame). The stack
        // keeps a fixed breathing pad instead.
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 620)
        // #993: report the stack's rendered height back to the layout. This
        // sits BEFORE the viewport-filling frame, so it is the natural height
        // the fit decision needs, not the stretched one.
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
            measuredScrollContentHeight = height
        }
    }

    private var protocolIdentityHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.preset.name).font(.headline)
                Spacer(minLength: 8)
                StatusPill(session.preset.protocolMode == .reverseAction ? "MOVEMENT" : "STATIC", color: SendmeterStyle.primary)
            }
            Text(protocolSummary(session.preset))
                .font(.caption)
                .foregroundStyle(.secondary)
            targetContext(session.targetPlan.referenceBand(
                forSet: session.run.currentStage.setNumber,
                selectedSide: session.run.currentStage.side,
                fallbackSide: session.fallbackSide
            ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func protocolSummary(_ preset: TindeqPreset) -> String {
        let repsAndSets = "\(preset.repetitions) rep\(preset.repetitions == 1 ? "" : "s") × \(preset.sets) set\(preset.sets == 1 ? "" : "s")"
        if preset.protocolMode == .reverseAction {
            return "\(preset.cadenceOutSeconds.formatted())s out · \(preset.cadenceReturnSeconds.formatted())s return · \(repsAndSets) · \(preset.restBetweenSetsSeconds)s set rest"
        }
        return "\(preset.holdScheduleSummary) · \(repsAndSets) · \(preset.restBetweenRepetitionsSeconds)s rep rest · \(preset.restBetweenSetsSeconds)s set rest"
    }

    @ViewBuilder
    private func targetContext(_ band: ForceTargetBand?) -> some View {
        if let band {
            Text("Target \(band.kilograms.formatted(.number.precision(.fractionLength(1)))) kg · range \(band.lowKilograms.formatted(.number.precision(.fractionLength(1))))–\(band.highKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(SendmeterStyle.caution)
        } else {
            Label("No target configured for this protocol", systemImage: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func topBar(elapsed: Double) -> some View {
        HStack(spacing: 8) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
            }
            .hapticButtonStyle(GuidedGlassButtonStyle(tint: .primary))
            .accessibilityLabel("Minimize guided protocol")
            .accessibilityHint("The protocol keeps running and can be resumed from the Force tab")

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                Text("GUIDED FORCE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .lineLimit(1)
                Text(formatElapsed(elapsed))
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel("Elapsed time \(formatElapsed(elapsed))")
            }

            Spacer(minLength: 4)

            Button("End", action: endSession)
                .hapticButtonStyle(GuidedGlassButtonStyle(tint: SendmeterStyle.alert))
                .accessibilityHint("Save the current pull if needed and end this protocol")
                .disabled(session.isAdvancing || session.isPausing)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    /// #940: the completed protocol is its own panel. The stage banner's dead
    /// `00:00 · Protocol complete` line is replaced by the explicit next step
    /// and its action, so the finish control is INSIDE the panel — above the
    /// fold — instead of only in the bottom inset the user has to scroll to.
    /// The action runs the same save/close path as the top-bar End
    /// (`endSession`), and per #941 that path ends the PROTOCOL: the gauge
    /// session stays live and its explicit end remains the Force tab's
    /// Finish pill.
    @ViewBuilder
    private func phaseBanner(
        _ presentation: GuidedForceStagePresentation,
        remaining: Double,
        accent: Color
    ) -> some View {
        if presentation.phase == .complete {
            // No combined accessibility element here: the Done action is a
            // real control and must stay individually focusable.
            bannerSurface(accent: accent) {
                VStack(spacing: 8) {
                    bannerHeader(presentation, accent: accent)
                    completionPanel(presentation, accent: accent)
                }
            }
        } else {
            bannerSurface(accent: accent) {
                VStack(spacing: 8) {
                    bannerHeader(presentation, accent: accent)
                    stagePanel(presentation, remaining: remaining, accent: accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(presentation.label). "
                        + (handsFreeWaitingForPull ? "Pull to start. " : "")
                        + presentation.detail
                )
                .accessibilityValue(
                    "\(formatCountdown(remaining)) remaining, "
                        + "\(Int((presentation.progress * 100).rounded())) percent complete"
                )
            }
        }
    }

    private func bannerHeader(
        _ presentation: GuidedForceStagePresentation,
        accent: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.symbol)
                .font(.title3.weight(.bold))
            Text(presentation.label)
                .font(.title2.weight(.black))
                .tracking(2.2)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .foregroundStyle(accent)
    }

    private func bannerSurface<Content: View>(
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(accent.opacity(0.72), lineWidth: 2)
            }
    }

    @ViewBuilder
    private func stagePanel(
        _ presentation: GuidedForceStagePresentation,
        remaining: Double,
        accent: Color
    ) -> some View {
        Text(formatCountdown(remaining))
            .modifier(SendmeterStyle.countdownMetric(baseSize: 68))
            .accessibilityLabel("\(formatCountdown(remaining)) remaining")

        Text(handsFreeWaitingForPull ? "PULL TO START · \(presentation.detail)" : presentation.detail)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)

        ProgressView(value: presentation.progress)
            .tint(accent)
            .accessibilityLabel("Phase progress")
    }

    @ViewBuilder
    private func completionPanel(
        _ presentation: GuidedForceStagePresentation,
        accent: Color
    ) -> some View {
        Text(presentation.detail)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)

        Button("Done", action: endSession)
            .hapticButtonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accent)
            .disabled(session.isAdvancing || session.isPausing)
            .accessibilityHint("Saves this protocol into the live gauge session and returns to the Force tab")

        Text("Gauge session stays live — end it from the Force tab")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }

    private func statusRow(accent: Color) -> some View {
        HStack(spacing: 8) {
            StatusPill(
                session.preset.protocolMode == .reverseAction
                    ? (session.preset.capacityEvidence == true ? "Capacity evidence" : "Execution quality")
                    : "Protocol quality",
                color: accent
            )
            // #899: every guided run is hands-free/load-triggered, so the
            // hands-free status pill is unconditional.
            StatusPill(
                handsFreeStatus.label,
                color: handsFreeStatus.color
            )
            Spacer(minLength: 4)
            Text("\(session.savedCount) queued")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(session.savedCount) pulls durably queued")
        }
    }

    private var handsFreeStatus: (label: String, color: Color) {
        if session.model.handsFree.isMeasuring {
            return ("Hands-free · measuring", SendmeterStyle.optimal)
        }
        if session.model.handsFree.isArmed {
            return ("Hands-free · pull to start", SendmeterStyle.caution)
        }
        return ("Hands-free · ready", SendmeterStyle.caution)
    }

    @ViewBuilder
    private var targetCoach: some View {
        if let band = currentTargetBand {
            let inTarget = band.range.contains(session.model.tindeq.currentKilograms)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TARGET COACH")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Text("\(band.kilograms.formatted(.number.precision(.fractionLength(1))) ) kg")
                        .font(.headline.monospacedDigit())
                    Text("Range \(band.lowKilograms.formatted(.number.precision(.fractionLength(1))) )–\(band.highKilograms.formatted(.number.precision(.fractionLength(1))) ) kg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: inTarget ? "checkmark.circle.fill" : "scope")
                        .font(.title2)
                        .foregroundStyle(inTarget ? SendmeterStyle.optimal : SendmeterStyle.caution)
                    Text(inTarget ? "ON TARGET" : "MOVE TOWARD TARGET")
                        .font(.caption2.weight(.bold))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(inTarget ? SendmeterStyle.optimal : SendmeterStyle.caution)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Target \(band.kilograms.formatted(.number.precision(.fractionLength(1)))) kilograms. "
                    + (inTarget ? "On target" : "Move toward target")
            )
        } else {
            Label("No target configured for this protocol", systemImage: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func liveChart(chartHeight: CGFloat) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LIVE FORCE")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(.secondary)
                        MetricValue(
                            session.model.tindeq.currentKilograms.formatted(.number.precision(.fractionLength(1))),
                            unit: "kg",
                            color: currentTargetBand?.range.contains(session.model.tindeq.currentKilograms) == true
                                ? SendmeterStyle.optimal
                                : .primary
                        )
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Peak \(session.model.tindeq.peakKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                        Text("Avg \(session.model.tindeq.averageKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                ForceTraceChart(
                    buffer: session.model.tindeq.sampleBuffer,
                    range: session.model.tindeq.visibleSampleRange,
                    targetRange: currentTargetBand?.range,
                    target: currentTargetBand?.kilograms
                )
                .frame(height: chartHeight)
                .layoutPriority(1)
                // #993: the chart's own rendered height, so the layout can
                // subtract it from the stack measurement and keep only the
                // fixed sections (plus the chart's floor) in the fit decision.
                .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                    measuredChartHeight = height
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ForceTraceAccessibility.liveSummary(
                        peakKilograms: session.model.tindeq.peakKilograms
                    )
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func controls(
        date: Date
    ) -> some View {
        HStack(spacing: 10) {
            if session.canPause(at: date) || session.run.isPaused {
                Button {
                    session.togglePause(at: date)
                } label: {
                    Label(
                        session.isPausing ? "Saving…" : (session.run.isPaused ? "Resume" : "Pause"),
                        systemImage: session.isPausing
                            ? "clock.arrow.circlepath"
                            : (session.run.isPaused ? "play.fill" : "pause.fill")
                    )
                }
                .hapticButtonStyle(GuidedGlassButtonStyle(tint: SendmeterStyle.caution))
                .disabled(session.isPausing)
                .accessibilityHint(session.run.isPaused ? "Resume the hold timer" : "Pause and save the active pull")
            }

            if !session.run.isComplete, !session.interrupted, !session.run.isPaused {
                Button {
                    Task { await session.skip(at: date) }
                } label: {
                    Label("Skip", systemImage: "forward.fill")
                }
                .hapticButtonStyle(GuidedGlassButtonStyle(tint: .primary))
                .disabled(session.isAdvancing || session.isPausing)
                .accessibilityHint("Skip this guided phase")
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var currentTargetBand: ForceTargetBand? {
        let side = session.run.currentStage.side == .unspecified
            ? session.fallbackSide
            : session.run.currentStage.side
        return session.targetPlan.band(forSet: session.run.currentStage.setNumber, side: side)
    }

    private var handsFreeWaitingForPull: Bool {
        session.isWaitingForHandsFreePull
    }

    private func endSession() {
        Task {
            await session.stopOrFinish()
            if session.isEnded {
                onClose()
            }
        }
    }

    private func color(for accent: GuidedForceAccent) -> Color {
        switch accent {
        case .primary: return SendmeterStyle.primary
        case .optimal: return SendmeterStyle.optimal
        case .caution: return SendmeterStyle.caution
        case .alert: return SendmeterStyle.alert
        case .execution: return SendmeterStyle.execution
        }
    }

    private func formatCountdown(_ seconds: Double) -> String {
        formatClock(max(0, Int(ceil(seconds))))
    }

    private func formatElapsed(_ seconds: Double) -> String {
        formatClock(max(0, Int(floor(seconds))))
    }

    private func formatClock(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    /// #993 measurement leg (harness only): with
    /// `--guided-force-fixture-measure` the container reports the rendered
    /// sizes its fit decision was made from, so a simulator capture carries
    /// numbers and not just pixels. Compiled out of release builds, and it
    /// never influences layout.
    private func layoutProbeLine(geometry: GeometryProxy, layout: GuidedForceLayout) -> String {
        #if DEBUG
        guard CommandLine.arguments.contains("--guided-force-fixture-measure") else { return "" }
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.1f", $0) } ?? "nil"
        }
        return "[impl993] viewport=\(Int(geometry.size.width))x\(Int(geometry.size.height))"
            + " insets.top=\(String(format: "%.1f", geometry.safeAreaInsets.top))"
            + " insets.bottom=\(String(format: "%.1f", geometry.safeAreaInsets.bottom))"
            + " scrollContent=\(number(measuredScrollContentHeight))"
            + " chart=\(number(measuredChartHeight))"
            + " controlsBar=\(number(measuredControlsBarHeight))"
            + " staticBudget=\(String(format: "%.1f", layout.essentialContentHeight))"
            + " measuredEssential=\(number(layout.measuredEssentialHeight))"
            + " resolvedChart=\(String(format: "%.1f", layout.flexibleChartHeight))"
            + " fits=\(layout.essentialContentFits)"
        #else
        return ""
        #endif
    }

    /// #993 measurement leg: prints the probe line whenever it changes. A
    /// no-op in release builds and whenever the fixture flag is absent.
    private struct LayoutProbe: ViewModifier {
        let line: String

        @ViewBuilder
        func body(content: Content) -> some View {
            #if DEBUG
            content.onChange(of: line) { _, newLine in
                guard !newLine.isEmpty else { return }
                print(newLine)
            }
            #else
            content
            #endif
        }
    }
}

struct ForceView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var forceModel: ForceModel
    @AppStorage("sendmeter.native.force.tag") private var tag = ""
    @AppStorage("sendmeter.native.force.side") private var sideValue = ""
    /// #628: the persisted hands-free toggle — the web's
    /// `sendmeter:gauge-hands-free` AppStorage equivalent.
    @AppStorage("sendmeter.native.force.hands-free") private var handsFreeEnabled = false
    @State private var selectedPresetID: UUID?
    @State private var editingPreset: TindeqPreset?
    @State private var creatingPreset = false
    @State private var guidedSession: GuidedForceProtocolSession?
    @State private var guidedFullscreenPresented = false
    @State private var guidedMinimizeRequested = false
    /// #1004: the launch attempt's own identity owns the in-flight flag — a
    /// resolution that never settles can no longer leave Start locked.
    @State private var guidedLaunch = GuidedLaunchLifecycle()
    /// #1004: the last save attempt for the currently held pull failed, so the
    /// recovery card offers discard explicitly instead of leaving the user to
    /// guess that it is still available.
    @State private var recoverySaveFailed = false
    @State private var selectedTargetPlan = ForceTargetPlan.empty
    @State private var resolvingTargets = false
    @State private var savingSummary = false
    @State private var savingSummaryFlightID: UUID?
    /// The progress detail's curve must follow the selected side. The regular
    /// Force card keeps using the all-sides cache for RPE and Focus Next.
    @State private var sideScopedForceCurve: ForceCurveModel?
    /// Small identity for the side-scoped fit. The fitted samples themselves
    /// stay out of the progress render boundary's equality check.
    @State private var sideScopedForceCurveRevision: UInt64 = 0
    /// #653: the recommended zone's preset + the quality it arms, kept in
    /// ForceView state rather than persisted with the user's own presets —
    /// arming Focus Next is a temporary guided-protocol selection, the same
    /// way the web's `zoneSel` is transient. Armed zone and user preset are
    /// mutually exclusive (#653 review finding 3). The quality is stored
    /// explicitly (not re-derived from the preset name) so the save-time zone
    /// stamp stays exact.
    @State private var zoneArmedPreset: TindeqPreset?
    @State private var armedZoneQuality: ZoneQuality?
    /// #902: the SL-97 session intensity dial (60–110, step 5, default 100)
    /// — persisted across sessions like the web's `loadIntensity`/`saveIntensity`
    /// AppStorage pair, applied to every suggested-zone arm.
    @AppStorage("sendmeter.native.force.zone-intensity") private var zoneIntensityPercent = ZoneMix.zoneIntensityDefault
    /// #903: the combined movement + side full-screen picker presentation.
    @State private var movementPickerPresented = false
    /// #710: a maintenance suggestion (Warm-up / Prehab) arms its own guided
    /// preset but is NOT a `ZoneQuality` — it records under a maintenance zone
    /// and never feeds training balance. Kept parallel to `armedZoneQuality`
    /// so exactly one suggested mode (zone quality OR maintenance) can be
    /// armed at a time, mutually exclusive with a saved preset.
    @State private var armedMaintenanceZone: RecordedZone?
    /// #711: the transient resisted-movement (reverse-action) preset armed by
    /// the recording context's MOVEMENT choice. Built by `ZoneMix.movementPreset`
    /// and never persisted — it is mutually exclusive with Free / Suggested /
    /// Saved, exactly like the web's "Movement Starter" selection.
    @State private var movementArmedPreset: TindeqPreset?

    private var side: TindeqSide {
        get { TindeqSide(rawValue: sideValue) ?? .unspecified }
        nonmutating set { sideValue = newValue.rawValue }
    }

    private var activeTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// #720: the side-applicability policy for the active exercise. The single
    /// source of truth is `ExerciseSidePolicy`; views never hardcode options.
    private var sideMode: ExerciseSideMode {
        model.sideMode(for: activeTag)
    }

    /// The canonical side to stamp on a NEW recording under the active mode.
    private var recordedSide: TindeqSide {
        ExerciseSidePolicy.recordedSide(sideMode, side)
    }

    /// Nudge a stale/legacy remembered side onto the active mode's valid set.
    /// A historical empty side stays empty (never reinterpreted as `both`).
    private func normalizeSideForMode() {
        let normalized = ExerciseSidePolicy.normalizeSide(sideMode, side)
        if normalized != side { side = normalized }
    }

    private var selectedPreset: TindeqPreset? {
        if let selectedPresetID {
            return model.presets.first(where: { $0.id == selectedPresetID })
        }
        return zoneArmedPreset ?? movementArmedPreset
    }

    /// The single-armed selection for the recording-context card (#710/#711):
    /// free hold, a suggested zone/maintenance protocol, the resisted-movement
    /// suggestion, or a saved user preset. Exactly one mode is armed at a time
    /// (web `withZoneSelected`/`withPresetSelected`).
    private var selectedSelection: ForceProtocolSelection {
        if let selectedPresetID {
            return .savedPreset(selectedPresetID)
        }
        if let armedZoneQuality {
            return .suggestedZone(armedZoneQuality)
        }
        if let armedMaintenanceZone {
            return .suggestedMaintenance(armedMaintenanceZone)
        }
        if movementArmedPreset != nil {
            return .movement
        }
        return .free
    }

    /// True when the selected guided target is a reverse-action (movement)
    /// preset — the training-balance card offers only static-hold protocols,
    /// so it hides while one is selected (#653 review finding 13, web
    /// `capacityModality === "static"`).
    private var isReverseActionTarget: Bool {
        guard let preset = selectedPreset else { return false }
        return preset.protocolMode == .reverseAction
    }

    /// #627: the active gauge session's recording count (for the Finish pill
    /// on the device card).
    private var gaugeSessionCount: Int {
        guard model.gaugeSessionTracker.isActive else { return 0 }
        let groupID = model.gaugeSessionTracker.active?.groupID
        return model.recordings.filter { $0.groupID == groupID }.count
    }

    /// The force-curve signal for the Focus-Next tie-break and saved-preset
    /// zone derivation: the cached static fit for the active tag, if any.
    /// Scoped to the tag (both sides) like the card.
    private var zoneCurve: ZoneCurveInput? {
        ForceModel.zoneCurveInput(in: forceModel.tagCurves, tag: tag)
    }

    /// The set-1 target band used for the save-time zone (#750). Prefer the
    /// effective recorded side; if the plan only carries per-hand targets
    /// (alternating with no raw hand chosen), fall back to the first hand.
    private var recordingZoneTargetBand: ForceTargetBand? {
        selectedTargetPlan.referenceBand(
            forSet: 1,
            selectedSide: recordedSide,
            fallbackSide: side
        )
    }

    /// The same resolved set-1 band drives the live gauge, the fullscreen,
    /// and history/duration charts. This is a lookup on `selectedTargetPlan`,
    /// never a second target calculation.
    private var selectedTargetReferenceBand: ForceTargetBand? {
        selectedTargetPlan.referenceBand(
            forSet: 1,
            selectedSide: recordedSide,
            fallbackSide: side
        )
    }

    /// The native analysis card uses the same all-sides static curve that is
    /// warmed for the session-end RPE prediction. It is intentionally read
    /// from the published cache rather than fitting in the view body.
    private var forceCurve: ForceCurveModel? {
        ForceModel.cachedStaticCurve(in: forceModel.tagCurves, tag: tag)?.forceCurveModel
    }

    private var progressTag: String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var forceEmptyActionTitle: String {
        switch model.tindeq.status {
        case .connected:
            if model.handsFree.isArmed {
                return "Cancel hands-free arm"
            }
            // #899: nothing armed — the only free-pull start is the
            // hands-free arm (the toggle is adopted by the action).
            if selectedPreset == nil {
                return "Arm Hands-free"
            }
            return "Start guided pull"
        case .measuring: return "Stop & save"
        case .unavailable: return "Open Bluetooth Settings"
        case .idle: return "Connect Progressor"
        case .scanning, .connecting: return "Cancel connection"
        case .interrupted: return "Reconnect Progressor"
        }
    }

    private var forceDeviceEmptyActionTitle: String {
        switch model.tindeq.status {
        case .connected:
            if model.handsFree.isArmed {
                return "Cancel hands-free arm"
            }
            // #899: nothing armed — the only free-pull start is the
            // hands-free arm (the toggle is adopted by the action).
            if selectedPreset == nil {
                return "Arm Hands-free"
            }
            return "Start guided pull"
        case .measuring: return "Stop & save"
        case .unavailable: return "Open Bluetooth Settings"
        case .scanning, .connecting: return "Cancel connection"
        case .interrupted: return "Reconnect Progressor"
        case .idle:
            return model.recordings.isEmpty ? "Connect Progressor" : "Reconnect Progressor"
        }
    }

    private var forceConnectionPending: Bool {
        switch model.tindeq.status {
        case .scanning, .connecting: return true
        default: return false
        }
    }

    private var showsForceAnalysisCards: Bool {
        // Analysis is independent of transport state. Returning users need
        // progress and detail-sheet entry points while the Progressor is idle,
        // unavailable, or interrupted. Only a not-yet-authoritative empty
        // recording collection suppresses this contextual layer.
        !forceModel.hasLoadedRecordings || !model.recordings.isEmpty
    }

    private func startPrimaryForceAction() {
        guard let preset = selectedPreset else {
            // #899: there is no direct-measure "Start Pull" anymore — the
            // Force card renders this action only when a guided protocol is
            // armed; without one the honest route is arming a protocol above
            // or arming hands-free.
            refuseAction("Arm a guided protocol above or arm Hands-free to record a pull.")
            return
        }
        launch(preset)
    }

    private func performForceEmptyAction() {
        switch model.tindeq.status {
        case .connected:
            if model.handsFree.isArmed {
                cancelHandsFreeArm()
            } else if selectedPreset == nil {
                // #899: empty surfaces route to hands-free (adopting the
                // toggle preference the same way the arm button requires it).
                if !handsFreeEnabled { handsFreeEnabled = true }
                armHandsFree()
            } else {
                startPrimaryForceAction()
            }
        case .measuring:
            stopAndSave()
        case .unavailable:
            openBluetoothSettings()
        case .idle, .interrupted:
            model.requestConnect()
        case .scanning, .connecting:
            // Keep the action contract honest for any future consumer even
            // though the current cards render a progress indicator instead.
            model.tindeq.disconnect()
        }
    }

    private func openBluetoothSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var progressSide: TindeqSide? {
        side == .unspecified ? nil : side
    }

    private var progressForceCurve: ForceCurveModel? {
        progressSide == nil ? forceCurve : sideScopedForceCurve
    }

    /// The zone stamped onto recordings saved under the current selection
    /// (#750). The armed protocol is the only source: a suggested quality or
    /// maintenance protocol states its zone outright, a saved/movement preset
    /// is classified from its set-1 resolved protocol (duration-only when no
    /// load/reference exists), and a free pull records nil. There is no
    /// persisted or standalone zone fallback.
    private var recordingZone: RecordedZone? {
        ZoneMix.recordingZone(
            for: selectedSelection,
            preset: selectedPreset,
            targetBand: recordingZoneTargetBand,
            references: zoneCurve,
            setNumber: 1
        )
    }

    private var guidedSessionIsActive: Bool {
        guidedSession != nil
    }

    private var guidedControlsLocked: Bool {
        guidedSessionIsActive || guidedLaunch.inFlight
    }

    /// #1004 (session-lock): who the guided lock belongs to, attributed from
    /// what this surface can read. An ended session is the orphan — it can
    /// neither resume nor end again, yet it still holds every control below.
    private var guidedLockOwner: ForceGuidedLockOwner {
        ForceLockOrphanPolicy.owner(
            ForceGuidedLockReadState(
                sessionPresent: guidedSessionIsActive,
                sessionEnded: guidedSession?.isEnded == true,
                launchInFlight: guidedLaunch.inFlight
            )
        )
    }

    /// #1004 (session-lock): true exactly when the lock has no live owner.
    /// The release affordance renders on this and nothing else, so "locked
    /// with no live owner" always has a way out on screen.
    private var guidedLockOrphaned: Bool {
        ForceLockOrphanPolicy.requiresRelease(guidedLockOwner)
    }

    /// The best single-pull peak for the active tag/side (web `maxF`) — the
    /// fallback reference for the Prehab protocol and the gate for the
    /// maintenance chips when no static fit is cached (#710).
    private var personalRecordForTag: Double? {
        ZoneMix.personalRecordKilograms(recordings: model.recordings, tag: tag, side: side)
    }

    /// #710: the maintenance zones (Warm-up/Prehab) whose guided protocol has a
    /// usable reference right now — passed to the recording-context card so an
    /// unavailable chip is disabled (web `!warmupT`/`!prehabT`).
    private var armableMaintenanceZones: Set<RecordedZone> {
        Set([RecordedZone.warmup, .prehab].filter {
            ZoneMix.maintenancePreset(for: $0, model: zoneCurve, personalRecord: personalRecordForTag) != nil
        })
    }

    /// #653/#710/#711: apply a single-armed selection. Focus Next (recommended
    /// zone) and the recording-context selection both route through here, so
    /// the mutually-exclusive Free / Suggested / Movement / Saved invariant is
    /// decided by the pure reducer `ForceProtocolPicker.next` and applied in
    /// one place. Arming is just a selection — the connection/unsaved-recording
    /// guard belongs to Start, not the pick.
    private func applySelection(_ selection: ForceProtocolSelection) {
        guard !guidedSessionIsActive, !guidedLaunch.inFlight else { return }
        switch selection {
        case .free:
            selectedPresetID = nil
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
            movementArmedPreset = nil
        case .suggestedZone(let quality):
            zoneArmedPreset = zonePreset(
                forZone: quality,
                intensityPercent: clampedZoneIntensity
            )
            armedZoneQuality = quality
            movementArmedPreset = nil
            armedMaintenanceZone = nil
            selectedPresetID = nil
        case .suggestedMaintenance(let zone):
            // Guard so a maintenance zone with no usable CF/PR never arms a
            // suggested mode with no preset to launch. The chip is also
            // disabled when `maintenancePreset` returns nil.
            guard let preset = ZoneMix.maintenancePreset(
                for: zone,
                model: zoneCurve,
                personalRecord: personalRecordForTag
            ) else { return }
            zoneArmedPreset = preset
            armedZoneQuality = nil
            armedMaintenanceZone = zone
            movementArmedPreset = nil
            selectedPresetID = nil
        case .movement:
            // #711: arming MOVEMENT builds the transient reverse-action
            // "Movement Starter" preset, which `launch` runs as a
            // reverse-action guided set (web `forceProtocolMode("movement")`).
            movementArmedPreset = ZoneMix.movementPreset()
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
            selectedPresetID = nil
        case .savedPreset(let id):
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
            movementArmedPreset = nil
            selectedPresetID = id
        }
    }

    /// #653: arm the recommended zone's guided protocol for the active tag —
    /// the web's Focus-Next pick path. Routes through `applySelection` so a
    /// recommended zone and any saved preset are mutually exclusive.
    private func armRecommendedZone(_ zone: ZoneQuality) {
        applySelection(.suggestedZone(zone))
    }

    /// #711: the recording-context target-tap. Extracted out of the SwiftUI
    /// `onSelectTarget` closure — the combined type-check of that modifier
    /// chain was too expensive to compile in reasonable time on CI. Applies
    /// the pure single-armed reducer (`ForceProtocolPicker.next`) then
    /// republishes the free-pull context, exactly as the previous inline
    /// closure did.
    private func handleSelectTarget(_ tapped: ForceProtocolSelection) {
        applySelection(
            ForceProtocolPicker.next(
                current: selectedSelection,
                tapped: tapped
            )
        )
        publishFreePullContext()
    }

    /// #902: clamp the persisted intensity dial to the web's [60, 110] range.
    private var clampedZoneIntensity: Int {
        ZoneMix.clampZoneIntensity(zoneIntensityPercent)
    }

    /// #902: the transient suggested-zone preset armed at the current
    /// intensity. At 100% the timing is exactly the zone protocol table
    /// (unchanged from pre-#902); a non-100% intensity with a usable
    /// tag-level curve adjusts hold (and endurance sets) so the executed
    /// engine schedule matches the web's dose math.
    private func zonePreset(
        forZone quality: ZoneQuality,
        intensityPercent: Int
    ) -> TindeqPreset {
        ZoneMix.zonePreset(
            for: quality,
            intensityPercent: intensityPercent,
            references: zoneCurve
        )
    }

    /// The tag-level zone target for the armed suggested zone at the current
    /// intensity — the immediate module numbers while the per-side plan is
    /// resolving, plus the basis / source-note copy.
    private var armedZoneTarget: ZoneQualityTarget? {
        guard let quality = armedZoneQuality, let curve = zoneCurve else { return nil }
        return ZoneMix.zoneTarget(
            for: quality,
            references: curve,
            intensityPercent: clampedZoneIntensity
        )
    }

    /// #902: rebuild the armed zone preset when the slider moves so the
    /// executed engine schedule follows the dose math (the target-band
    /// re-resolution runs through the target-plan task key).
    private func rebuildArmedZonePreset() {
        guard let quality = armedZoneQuality else { return }
        zoneArmedPreset = zonePreset(
            forZone: quality,
            intensityPercent: clampedZoneIntensity
        )
        publishFreePullContext()
    }

    /// #903: the redesigned recording-context card. Extracted from the `body`
    /// builder so the constraint solver type-checks it as its own
    /// `@ViewBuilder` sub-expression; heavy arguments are hoisted into
    /// distinct typed `let`s (CI "unable to type-check this expression in
    /// reasonable time").
    @ViewBuilder
    private var recordingContextCard: some View {
        let sideBinding: Binding<TindeqSide> =
            Binding(get: { side }, set: { side = $0 })
        let intensityBinding: Binding<Int>? =
            armedZoneQuality != nil
                ? Binding(
                    get: { clampedZoneIntensity },
                    set: { zoneIntensityPercent = ZoneMix.clampZoneIntensity($0) }
                )
                : nil

        ForceRecordingContextCard(
            tag: $tag,
            side: sideBinding,
            sideMode: sideMode,
            locked: recordingContextLocked,
            selectedTarget: selectedSelection,
            onSelectTarget: handleSelectTarget,
            selectedPreset: selectedPreset,
            presets: model.presets,
            knownTags: model.visibleTagNames,
            maintenanceAvailable: armableMaintenanceZones,
            curveInput: zoneCurve,
            personalRecord: personalRecordForTag,
            targetBand: selectedTargetReferenceBand,
            zoneTarget: armedZoneTarget,
            intensityPercent: intensityBinding,
            deviceConnected: model.tindeq.status == .connected,
            deviceStatusText: forceDeviceStatusText,
            movementSummary: movementContextSummary,
            onOpenPicker: { movementPickerPresented = true }
        )
        .disabled(recordingContextLocked)
    }

    /// #750: lock the whole recording context for the same run window the web
    /// uses (`runActive`): a live pull, an armed/measuring hands-free
    /// loop, an interrupted rep awaiting recovery, or a guided session. The
    /// focused chip/input `.disabled` calls then report that lock to
    /// VoiceOver instead of relying only on the parent modifier.
    private var recordingContextLocked: Bool {
        ForceContextLockPolicy.isLocked(
            ForceContextLockState(
                liveRecording: model.tindeq.status == .measuring,
                interruptedRecording: model.tindeq.interruptedRecording != nil,
                handsFreeArmed: model.handsFree.isArmed,
                handsFreeMeasuring: model.handsFree.isMeasuring,
                guidedSessionActive: guidedControlsLocked
            )
        )
    }

    /// #903: the collapsed decision row's value — "FDP · Side Left" (the side
    /// segment is omitted until one is chosen; a missing exercise reads
    /// honestly as "No exercise").
    private var movementContextSummary: String {
        let exercise = activeTag.isEmpty ? "No exercise" : activeTag
        guard !activeTag.isEmpty, side != .unspecified else { return exercise }
        return exercise + " · Side " + side.label
    }

    /// The recording-context card's device-row status text.
    private var forceDeviceStatusText: String {
        switch model.tindeq.status {
        case .connected: return "Connected"
        case .measuring: return "Measuring"
        case .scanning, .connecting: return "Connecting…"
        case .unavailable: return "Bluetooth off"
        case .interrupted: return "Reconnect"
        case .idle: return "Disconnected"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let guidedSession, !guidedSession.isEnded {
                        GuidedForceResumeCard(session: guidedSession) {
                            Haptics.shared.tap()
                            guidedMinimizeRequested = false
                            guidedFullscreenPresented = true
                        } onEnd: {
                            endGuidedSession(guidedSession)
                        }
                    }

                    // #1004: a launch that did not start says WHY and offers
                    // the retry that re-runs it — never a disabled control
                    // with no explanation.
                    if let failure = guidedLaunch.failure {
                        GuidedLaunchFailureCard(failure: failure) {
                            Haptics.shared.tap()
                            retryGuidedLaunch()
                        }
                    }

                    // #1004 (session-lock): the orphaned guided lock. The
                    // resume card above hides once its session has ENDED
                    // (nothing left to resume or end), but the session object
                    // still holds `guidedControlsLocked` — so this is the one
                    // affordance that clears it, rendered exactly when no
                    // live owner remains.
                    if guidedLockOrphaned {
                        GuidedSessionReleaseCard {
                            Haptics.shared.tap()
                            releaseFinishedGuidedSession()
                        }
                    }

                    // #903: the redesigned Configure → Operate order — the
                    // recording-context card (movement & side decision row,
                    // protocol list / armed hero + bound load module) leads
                    // the stack; the Progressor operate card follows it.
                    recordingContextCard

                    ForceDeviceCard(
                        device: model.tindeq,
                        handsFreeEnabled: $handsFreeEnabled,
                        handsFreeArmed: model.handsFree.isArmed,
                        handsFreeMeasuring: model.handsFree.isMeasuring,
                        protocolArmed: selectedPreset != nil,
                        guidedSessionActive: guidedControlsLocked,
                        guidedLockOrphaned: guidedLockOrphaned,
                        recoveryControls: ForceRecoveryActionPolicy.controls(
                            state: ForceRecoveryControlsState(
                                hasUnsavedRecording: model.tindeq.hasUnsavedRecording,
                                saving: savingSummary,
                                sessionActive: guidedControlsLocked,
                                saveFailed: recoverySaveFailed
                            )
                        ),
                        targetBand: selectedTargetReferenceBand,
                        resolvingTarget: resolvingTargets,
                        savingSummary: savingSummary,
                        gaugeSessionCount: gaugeSessionCount,
                        hasLoadedRecordings: forceModel.hasLoadedRecordings,
                        hasForceRecordings: !model.recordings.isEmpty,
                        emptyActionTitle: forceDeviceEmptyActionTitle,
                        emptyAction: performForceEmptyAction,
                        // #653/#710/#899: an armed suggested protocol (Focus-
                        // Next zone or maintenance) OR a selected saved preset
                        // makes the main Start button launch that guided
                        // protocol — the native equivalent of the web's
                        // Start-with-an-armed-protocol opening the guided
                        // timer. #899 removed the nothing-armed free-pull
                        // start: with nothing armed the card routes to the
                        // hands-free arm instead. `launch` correctly keeps
                        // the recording-context selection in sync for a user
                        // preset and clears a suggested arm for a saved one.
                        start: startPrimaryForceAction,
                        refuseAction: { message in refuseAction(message) },
                        connect: { model.requestConnect() },
                        armHandsFree: armHandsFree,
                        stopAndSave: stopAndSave,
                        cancelArm: cancelHandsFreeArm,
                        finishSession: {
                            guard !guidedControlsLocked else { return }
                            Task { await model.endGaugeSession() }
                        },
                        saveCompleted: saveCompleted,
                        saveRecovered: saveRecovered,
                        discardCompleted: {
                            model.tindeq.clearCompletedRecording()
                            // #1004: the held pull is gone, so its failed-save
                            // notice must not outlive it into the next pull.
                            recoverySaveFailed = false
                        },
                        discardRecovered: {
                            model.tindeq.clearInterruptedRecording()
                            recoverySaveFailed = false
                        }
                    )

                    // #903: Focus Next (training balance) leaves the
                    // recording-context card — the redesigned card carries
                    // only movement/side + protocol configure + device row.
                    // It stands as its own recommendation card under the
                    // operate surface, using the same tag-scoped inputs.
                    if !activeTag.isEmpty, !isReverseActionTarget {
                        ZoneFocusCard(
                            recordings: model.recordings.filter { $0.tag == tag },
                            exercise: tag,
                            curveInput: zoneCurve,
                            onPick: armRecommendedZone,
                            locked: recordingContextLocked
                        )
                    }

                    if showsForceAnalysisCards {
                        ForceProgressCardBoundary(
                            recordings: model.recordings,
                            selectedTag: progressTag,
                            selectedSide: progressSide,
                            forceCurve: progressForceCurve,
                            hasLoadedRecordings: forceModel.hasLoadedRecordings,
                            progressRevision: forceModel.forceProgressRevision,
                            curveRevision: sideScopedForceCurveRevision,
                            targetBand: selectedTargetReferenceBand,
                            connectionPending: forceConnectionPending
                        )
                        .equatable()

                        ForceConsistencyCard(
                            recordings: model.recordings,
                            hiddenTags: model.hiddenTagNames,
                            hasLoadedRecordings: forceModel.hasLoadedRecordings,
                            connectionPending: forceConnectionPending
                        )

                        if !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            NativeForceCurveCard(
                                tag: tag,
                                model: forceCurve,
                                hasLoadedRecordings: forceModel.hasLoadedRecordings,
                                targetBand: selectedTargetReferenceBand,
                                connectionPending: forceConnectionPending,
                                showsPrimaryEmptyState: false,
                                emptyActionTitle: forceEmptyActionTitle,
                                emptyAction: performForceEmptyAction
                            )
                        }
                    }

                    if let live = model.watch.liveForce,
                       live.accountUserID == model.currentUserID {
                        WatchForceMirrorCard(force: live)
                    }

                    ForceProtocolLibraryCard(
                        presets: model.presets,
                        run: { preset in
                            // #656: a tap opening the fullscreen arms the
                            // presentation tick (the guided protocol view
                            // spends it on appear).
                            Haptics.shared.tap()
                            launch(preset)
                        },
                        edit: {
                            // #656: see `run:` above.
                            Haptics.shared.tap()
                            editingPreset = $0
                        },
                        create: {
                            // #656: see `run:` above.
                            Haptics.shared.tap()
                            creatingPreset = true
                        },
                        delete: { preset in
                            // #656 (review F14): deleting a protocol preset is
                            // a confirm/destructive action — medium tick.
                            Haptics.shared.playGesture(.medium)
                            Task { await model.deletePreset(preset) }
                        },
                        disabled: guidedSessionIsActive || guidedLaunch.inFlight
                    )

                    RecentForceCard(recordings: Array(model.recordings.prefix(8)))
                }
                .padding()
                .padding(.bottom, 80)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 72)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Force")
            .refreshable { await model.refreshAll(showSpinner: false) }
            .task(id: targetResolutionKey) {
                await resolveSelectedTarget()
            }
            .task(id: progressCurveKey) {
                await loadProgressCurve()
            }
            .onAppear {
                // #720: a persisted side can be stale for the active exercise's
                // mode even on a fresh launch (not just on a tag switch).
                normalizeSideForMode()
                // #720: re-stamp the armed hands-free context from the current
                // (normalized) recorded side — normalize must run before this.
                publishFreePullContext()
                if let guidedSession {
                    registerGuidedTeardown(for: guidedSession)
                }
            }
            // #628: the hands-free save path snapshots the recording context
            // (tag/side/zone/preset/target) at arm time.
            .onChange(of: tag) { _ in
                // #720: a remembered side may be invalid under the newly
                // selected exercise's mode — fall back deterministically.
                normalizeSideForMode()
                publishFreePullContext()
            }
            .onChange(of: sideMode) { _ in normalizeSideForMode() }
            // #720 review (blocker): the free-pull context stamps `recordedSide`,
            // which can change when the exercise's side MODE changes without the
            // raw `side` changing (e.g. bilateral_only→not_applicable with an
            // unspecified side). Re-publish on the EFFECTIVE side so the armed
            // hands-free loop can never persist a stale/forbidden side.
            .onChange(of: recordedSide) { _ in publishFreePullContext() }
            .onChange(of: side) { _ in publishFreePullContext() }
            .onChange(of: selectedPresetID) { _ in publishFreePullContext() }
            .onChange(of: zoneArmedPreset) { _ in publishFreePullContext() }
            .onChange(of: movementArmedPreset) { _ in publishFreePullContext() }
            // #902: moving the intensity dial rebuilds the armed zone preset
            // so the executed schedule (hold / sets) follows the dose math;
            // the target-plan task key re-resolves the scaled band.
            .onChange(of: zoneIntensityPercent) { _ in
                guard armedZoneQuality != nil else { return }
                rebuildArmedZonePreset()
            }
            .onChange(of: selectedTargetPlan) { _ in publishFreePullContext() }
            .onChange(of: handsFreeEnabled) { enabled in
                if !enabled, !guidedControlsLocked { model.handsFree.disarm() }
                model.updateKeepAwake()
            }
            .onChange(of: model.currentUserID) { _ in
                teardownGuidedSessionIfNeeded()
            }
            .onChange(of: model.accountEpoch) { _ in
                teardownGuidedSessionIfNeeded()
            }
            .onDisappear {
                // Dismissing the cover is a minimize operation and leaves
                // this owner alive. Only the explicit minimize gesture opts
                // into that preservation; a real ForceView disappearance
                // tears the runner down rather than relying on deinit.
                guard !guidedMinimizeRequested else { return }
                teardownGuidedSessionIfNeeded()
            }
            .sheet(item: $editingPreset) { preset in
                ForcePresetEditor(preset: preset, isNew: false)
                    .sendmeterSheetPresentation(id: preset.id.uuidString)
            }
            .sheet(isPresented: $creatingPreset) {
                ForcePresetEditor(preset: Self.defaultPreset(), isNew: true)
                    .sendmeterSheetPresentation()
            }
            .fullScreenCover(isPresented: $guidedFullscreenPresented, onDismiss: { Haptics.shared.sheetDismissed() }) {
                if let guidedSession {
                    GuidedForceProtocolView(
                        session: guidedSession,
                        onMinimize: {
                            guidedMinimizeRequested = true
                            guidedFullscreenPresented = false
                        },
                        onClose: {
                            clearGuidedSession(guidedSession)
                        }
                    )
                    .onAppear { Haptics.shared.sheetPresented() }
                } else {
                    Color.clear
                }
            }
            // #899: the standalone manual Force fullscreen (its own
            // CANCEL/STOP/SAVE phase machine) is removed — hands-free free
            // pulls live on the Force card, guided protocols own the guided
            // fullscreen above.
            // #903: the combined movement + side picker — a true full-screen
            // modal with its own 44px Close control and no app tab bar.
            .fullScreenCover(isPresented: $movementPickerPresented, onDismiss: {
                Haptics.shared.sheetDismissed()
                publishFreePullContext()
            }) {
                ForceMovementSidePicker(
                    tag: $tag,
                    side: Binding(
                        get: { side },
                        set: { side = $0 }
                    ),
                    knownTags: model.visibleTagNames,
                    modeProvider: { model.sideMode(for: $0) },
                    onClose: { movementPickerPresented = false }
                )
                .onAppear { Haptics.shared.sheetPresented() }
            }
        }
    }

    /// #656: a refused gauge action fires the warning pattern, never the
    /// accepted tick (#222). The live surfaces are the guided-protocol Run
    /// button (not connected / pull owed — those two buttons carry no
    /// `.disabled`, so the tap is how the user learns why) and a Stop & Save
    /// with no samples. The Force tab's Start/Arm buttons use hard `.disabled`
    /// for the same conditions and therefore fire nothing — matching the web's
    /// #222 rule, where a genuinely disabled control gets no cue at all.
    private func refuseAction(_ message: String) {
        model.errorMessage = message
        Haptics.shared.playGesture(RefusedActionHaptics.cue(tappableAndRefused: true))
    }

    private var forceRecordingIsLive: Bool {
        model.tindeq.status == .measuring || model.handsFree.isMeasuring
    }

    private func forceRecordingDecision(
        for action: ForceRecordingAction
    ) -> ForceRecordingStartDecision {
        ForceRecordingContextPolicy.decision(
            for: action,
            state: ForceRecordingContextState(
                liveRecording: forceRecordingIsLive,
                handsFreeArmed: model.handsFree.isArmed,
                protocolArmed: selectedPreset != nil
            )
        )
    }

    private func refuseActiveForceRecording(for action: ForceRecordingAction) {
        let message: String
        switch action {
        case .handsFree:
            message = "Finish the active pull before arming hands-free."
        case .guidedProtocol:
            message = "Finish the active pull before starting a guided protocol."
        }
        refuseAction(message)
    }

    private func registerGuidedTeardown(for session: GuidedForceProtocolSession) {
        model.setGuidedProtocolTeardown(ownerID: session.id) { [weak session] in
            await session?.teardown()
            guard let session else { return }
            // Auth teardown must release the same presentation owner after
            // the durable terminal flight, but an old callback may finish
            // after a replacement session has already been installed.
            self.clearGuidedSession(session)
        }
    }

    private func clearGuidedSession(_ session: GuidedForceProtocolSession?) {
        guard let session,
              GuidedForceAuthTransitionPolicy.canClearGuidedOwner(
                  currentOwnerID: guidedSession?.id,
                  settledOwnerID: session.id
              )
        else { return }
        model.clearGuidedProtocolTeardown(ownerID: session.id)
        guidedMinimizeRequested = false
        guidedFullscreenPresented = false
        guidedSession = nil
    }

    /// #1004 (session-lock): the user's release for an orphaned guided lock.
    ///
    /// Only an ENDED session may be released — a live one keeps its own
    /// resume/end affordances — and the release only JOINS the durable
    /// terminal flight that session already ran, then clears the view state
    /// that was holding the screen. It never writes, deletes or cursor-resets
    /// anything: an un-synced pull stays in the durable queue, a pull still
    /// held by the device stays on its own recovery card, and the session's
    /// completed/partial salvage was already decided when it claimed its
    /// terminal outcome.
    private func releaseFinishedGuidedSession() {
        guard let session = guidedSession, session.isEnded else { return }
        Task {
            await session.teardown()
            guard session.isEnded, guidedSession?.id == session.id else { return }
            clearGuidedSession(session)
        }
    }

    private func teardownGuidedSessionIfNeeded() {
        guard let session = guidedSession else { return }
        if session.isEnded {
            // A terminal claim cancels the ticker/activity synchronously, but
            // the owner callback must remain registered until its durable
            // flight settles so an auth reset can still join that flight.
            // #1004 (session-lock): the user's own release runs the SAME
            // path, so an orphaned lock has exactly one implementation.
            releaseFinishedGuidedSession()
            return
        }
        Task {
            await session.teardown()
            guard session.isEnded, guidedSession?.id == session.id else { return }
            clearGuidedSession(session)
        }
    }

    /// #628/#899: with nothing guided armed, arming the hands-free stream is
    /// the only free-pull start — measurement begins when the athlete pulls
    /// and saves on release (the Force card renders the armed/measuring
    /// states; the standalone manual fullscreen is gone).
    private func armHandsFree() {
        guard !guidedControlsLocked else {
            refuseAction("Resume or end the active guided protocol before arming hands-free.")
            return
        }
        switch forceRecordingDecision(for: .handsFree) {
        case .refusedActiveRecording:
            refuseActiveForceRecording(for: .handsFree)
            return
        case .safeHandoffFromArmedStream:
            model.handsFree.cancelArm()
        case .allowed:
            break
        }
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction(UserFacingError.message(for: .previousRecordingUnfinished))
            return
        }
        guard model.tindeq.status == .connected else {
            refuseAction(UserFacingError.message(for: .progressorNotConnected))
            return
        }
        publishFreePullContext()
        // #678: lock at arm time (recording start for the hands-free loop),
        // same as a manual Start, so a mid-rep disconnect salvage persists the
        // tag/side the user actually set.
        model.lockForceRecordingContext(model.freePullContext)
        model.handsFree.arm()
        guard model.handsFree.isArmed else { return }
        model.updateKeepAwake()
    }

    private func stopAndSave() {
        guard !guidedControlsLocked else {
            refuseAction("Resume or end the active guided protocol before stopping a free pull.")
            return
        }
        // A Stop & Save while the hands-free loop owns the rep must go
        // through the loop (its claim + re-arm bookkeeping), not the direct
        // path — otherwise the machine still thinks it is recording.
        if model.handsFree.isMeasuring {
            model.handsFree.stopManually()
            return
        }
        // Defensive: an armed-but-not-measuring stream has no rep to save.
        if model.handsFree.isArmed {
            model.handsFree.cancelArm()
            return
        }
        guard let summary = model.tindeq.stopMeasuring() else {
            refuseAction("No force samples were received.")
            return
        }
        save(summary, recovered: false)
    }

    private func publishFreePullContext() {
        model.freePullContext = FreePullContext(
            tag: tag,
            side: recordedSide,
            zone: recordingZone,
            preset: selectedPreset,
            targetBand: recordingZoneTargetBand
        )
    }

    private func saveCompleted() {
        guard let summary = model.tindeq.completedSummary else { return }
        save(summary, recovered: false)
    }

    private func saveRecovered() {
        guard let summary = model.tindeq.interruptedRecording else { return }
        save(summary, recovered: true)
    }

    private func cancelHandsFreeArm() {
        model.handsFree.cancelArm()
        model.updateKeepAwake()
    }

    private func save(
        _ summary: ForceSummary,
        recovered: Bool
    ) {
        guard !savingSummary else { return }
        let saveFlightID = UUID()
        let saveAccountScope = model.accountScope
        savingSummary = true
        savingSummaryFlightID = saveFlightID
        // #1004: a fresh attempt clears the previous failure notice; a failure
        // below re-arms it so the card can offer discard explicitly.
        recoverySaveFailed = false
        // #678: a recovered/salvaged rep persists the tag/side LOCKED at
        // recording start (web #298) and carries the recovered note, not a
        // "· Recovered" suffix on the tag — the note is what History shows,
        // matching the watch's `salvageInterruptedRecording`. When no lock
        // exists the recovery is saved honestly untagged/unspecified — never
        // re-derived from the live tag/side controls (web #298 "never a
        // fallback").
        let attribution = model.forceRecordingLock.map {
            ForceDisconnectSalvage.Attribution(tag: $0.tag, side: $0.side)
        } ?? .empty
        let savedTag = recovered ? attribution.tag : tag
        let savedSide = recovered ? attribution.side : recordedSide
        let note = recovered ? ForceDisconnectSalvage.recoveredNote : ""
        let lossReason = recovered ? ForceDisconnectSalvage.lossReason : "recording"
        // #720: snapshot the recording context before the await so a stale
        // closure can never write a side invalid under the active mode (repo
        // rule: a decision never reads captured state after an `await`).
        let savedZone = recordingZone
        let savedPreset = selectedPreset
        let savedTargetBand = recordingZoneTargetBand
        Task {
            let enqueued = await model.saveForceSummary(
                summary,
                tag: savedTag,
                side: savedSide,
                zone: savedZone,
                preset: savedPreset,
                targetBand: savedTargetBand,
                note: note,
                lossReason: lossReason
            )
            guard savingSummaryFlightID == saveFlightID else { return }
            guard model.accountScope == saveAccountScope else {
                savingSummary = false
                savingSummaryFlightID = nil
                return
            }
            if enqueued {
                recoverySaveFailed = false
                model.tindeq.clearCompletedRecording()
                if recovered {
                    model.tindeq.clearInterruptedRecording()
                    // #678: clear the lock so a stale attribution can't leak
                    // into the next Start/Arm.
                    model.clearForceRecordingLock()
                }
            } else {
                // #1004: the pull is still held (a failed save leaves the
                // summary with the device), so the card must OFFER discard
                // rather than leave the user to infer it.
                recoverySaveFailed = true
            }
            savingSummary = false
            savingSummaryFlightID = nil
        }
    }


    private var targetResolutionKey: String {
        let recordingFingerprint = model.recordings.prefix(24).map {
            "\($0.id.uuidString):\($0.sampleCount):\($0.recordedAt.timeIntervalSince1970)"
        }.joined(separator: "|")
        // #653 review finding 4: the key includes the armed zone preset (not
        // just `selectedPresetID`), so `.task(id:)` re-resolves the target
        // band the moment Focus Next is armed — the web resolves and displays
        // the zone's target as soon as it is picked, not after Start.
        let presetKey = selectedPresetID?.uuidString
            ?? zoneArmedPreset.map { "zone:\($0.name)@\(clampedZoneIntensity)" }
            ?? (movementArmedPreset != nil ? "movement" : nil)
            ?? "free"
        return "\(presetKey)|\(tag)|\(side.rawValue)|\(recordingFingerprint)"
    }

    private var progressCurveKey: ForceProgressCurveInputKey {
        model.forceProgressCurveInputKey(
            tag: progressTag,
            side: progressSide
        )
    }

    @MainActor
    private func loadProgressCurve() async {
        let requestKey = progressCurveKey
        guard let tag = progressTag, let side = progressSide else {
            if sideScopedForceCurve != nil {
                sideScopedForceCurve = nil
                sideScopedForceCurveRevision &+= 1
            }
            return
        }
        sideScopedForceCurve = nil
        sideScopedForceCurveRevision &+= 1
        let curve = await model.forceCurveModel(
            tag: tag,
            side: side,
            inputKey: requestKey
        )
        guard !Task.isCancelled, progressCurveKey == requestKey else { return }
        sideScopedForceCurve = curve
        sideScopedForceCurveRevision &+= 1
    }

    @MainActor
    private func resolveSelectedTarget() async {
        let requestKey = targetResolutionKey
        let accountScope = model.accountScope
        guard let preset = selectedPreset else {
            selectedTargetPlan = .empty
            resolvingTargets = false
            return
        }
        resolvingTargets = true
        selectedTargetPlan = .empty
        // #901: resolve from the NORMALIZED selection (the same value the
        // launch boundary derives) so the context-card plan mirrors the
        // executed run's plan — a Left/Right selection resolves only that
        // side's bands, never the alternating pair.
        let resolvedSide = ExerciseSidePolicy.normalizeSide(sideMode, side)
        let startSide: TindeqSide = resolvedSide == .right ? .right : .left
        let plan = await model.resolveForceTargetPlan(
            preset: preset,
            tag: tag,
            startingSide: startSide,
            fallbackSide: resolvedSide
        )
        guard !Task.isCancelled else { return }
        guard targetResolutionKey == requestKey,
              model.accountScope == accountScope,
              selectedPreset?.id == preset.id
        else {
            // A changed task key will have its own resolver. If the account
            // changed without changing the visible key, release the spinner
            // but never publish the stale plan into the new account.
            if targetResolutionKey == requestKey {
                resolvingTargets = false
            }
            return
        }
        selectedTargetPlan = plan
        resolvingTargets = false
    }

    private func launch(_ preset: TindeqPreset) {
        guard !guidedSessionIsActive, !guidedLaunch.inFlight else {
            refuseAction("Resume or end the active guided protocol before starting another.")
            return
        }
        switch forceRecordingDecision(for: .guidedProtocol) {
        case .refusedActiveRecording:
            refuseActiveForceRecording(for: .guidedProtocol)
            return
        case .safeHandoffFromArmedStream:
            // Hands-free owns a live transport stream while waiting for load,
            // but no recording is active. Release that owner synchronously so
            // the guided runner is the only stream owner before its first
            // await/arm boundary.
            model.handsFree.cancelArm()
        case .allowed:
            break
        }
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction(UserFacingError.message(for: .previousRecordingUnfinished))
            return
        }
        guard model.tindeq.status == .connected else {
            refuseAction(UserFacingError.message(for: .progressorNotConnected))
            return
        }
        // #653: only a persisted user preset keeps the recording-context
        // selection in sync; a transient Focus-Next zone preset is not in
        // `model.presets`, so it must not clobber `selectedPresetID` (which
        // would read back as "Free pull" and clear the zone arm).
        if model.presets.contains(where: { $0.id == preset.id }) {
            // A user preset and a suggested arm are mutually exclusive
            // (#653 review finding 3, #710): launching a user preset clears
            // the armed zone/maintenance suggestion.
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
            selectedPresetID = preset.id
        }
        let launchResolutionKey = targetResolutionKey
        let launchTag = tag
        let launchSideMode = sideMode
        let launchSide = side
        let launchSelection = selectedSelection
        let launchZoneCurve = zoneCurve
        let launchAccountScope = model.accountScope
        // #1004: the attempt owns the flag. Every exit below settles it —
        // including the deadline — so no path can leave Start locked, and the
        // only path that shows a failure is the one that has a retry.
        recoverySaveFailed = false
        let attemptID = guidedLaunch.begin(preset: preset)
        resolvingTargets = true
        Task {
            let resolution = await Self.resolveGuidedLaunch(
                model: model,
                preset: preset,
                tag: launchTag,
                sideMode: launchSideMode,
                side: launchSide,
                selection: launchSelection,
                zoneCurve: launchZoneCurve
            )
            guard guidedLaunch.owns(attemptID) else { return }
            guard !Task.isCancelled,
                  model.accountScope == launchAccountScope,
                  targetResolutionKey == launchResolutionKey,
                  selectedPreset?.id == preset.id,
                  !guidedSessionIsActive,
                  guidedSession == nil
            else {
                guidedLaunch.settle(attemptID, outcome: .superseded)
                if targetResolutionKey == launchResolutionKey {
                    resolvingTargets = false
                }
                return
            }
            guard case .resolved(let session) = resolution else {
                // The awaited resolution never settled. The attempt is over,
                // the reason is on screen, and the retry re-runs it.
                guidedLaunch.settle(
                    attemptID,
                    outcome: .timedOut(
                        loadFailureClass: model.dashboardLoadFailureClass
                    )
                )
                resolvingTargets = false
                return
            }
            switch forceRecordingDecision(for: .guidedProtocol) {
            case .refusedActiveRecording:
                guidedLaunch.settle(attemptID, outcome: .superseded)
                resolvingTargets = false
                refuseActiveForceRecording(for: .guidedProtocol)
                return
            case .safeHandoffFromArmedStream:
                model.handsFree.cancelArm()
            case .allowed:
                break
            }
            selectedTargetPlan = session.targetPlan
            resolvingTargets = false
            guidedSession = session
            registerGuidedTeardown(for: session)
            guidedMinimizeRequested = false
            guidedLaunch.settle(attemptID, outcome: .launched)
            guidedFullscreenPresented = true
        }
    }

    /// #1004: how long one guided-launch attempt may await target resolution.
    /// Generous enough for a cold cache plus the reference fetch, short enough
    /// that a resolution which never settles cannot keep the primary action
    /// disabled for the life of the process.
    static let guidedLaunchTimeout: TimeInterval = 12

    /// The bounded launch-resolution seam.
    enum GuidedLaunchResolution {
        case resolved(GuidedForceProtocolSession)
        case timedOut
    }

    /// The REAL launch-resolution chain (`makeGuidedLaunchSession` — the same
    /// producer → async resolution → session construction boundary `launch()`
    /// runs) wrapped in ONE deadline. Extracted so a test can drive the real
    /// path with a resolution that never settles and assert the attempt
    /// settles with a retryable failure instead of leaking the flag.
    @MainActor
    static func resolveGuidedLaunch(
        model: AppModel,
        preset: TindeqPreset,
        tag: String,
        sideMode: ExerciseSideMode,
        side: TindeqSide,
        selection: ForceProtocolSelection,
        zoneCurve: ZoneCurveInput?,
        timeout: TimeInterval = ForceView.guidedLaunchTimeout
    ) async -> GuidedLaunchResolution {
        let raced = await AsyncDeadline.race(
            timeout: timeout,
            fallback: Optional<GuidedForceProtocolSession>.none
        ) {
            await makeGuidedLaunchSession(
                model: model,
                preset: preset,
                tag: tag,
                sideMode: sideMode,
                side: side,
                selection: selection,
                zoneCurve: zoneCurve
            )
        }
        guard let session = raced.value else { return .timedOut }
        return .resolved(session)
    }

    /// Re-runs the attempt that failed. It is the same `launch` entry point —
    /// including its guards — with the preset the attempt was for, not
    /// whatever happens to be selected now.
    private func retryGuidedLaunch() {
        guard let preset = guidedLaunch.retryPreset else { return }
        launch(preset)
    }

    /// The guided-launch boundary chain (#874/#899): normalize the picker's
    /// side under the active exercise mode (the producer snapshot), derive
    /// the starting side, resolve the target plan through the real async
    /// resolver, and construct the session. Every guided session is
    /// hands-free/load-triggered (#899), so no hands-free preference is
    /// threaded through — the runner always arms the caller-owned stream for
    /// each work stage. Extracted from `launch()` so the AC1 regression test
    /// drives the REAL producer → async resolution → session construction
    /// boundary — a `.both` coercion at the producer is exactly the reported
    /// Left→Both failure.
    @MainActor
    static func makeGuidedLaunchSession(
        model: AppModel,
        preset: TindeqPreset,
        tag: String,
        sideMode: ExerciseSideMode,
        side: TindeqSide,
        selection: ForceProtocolSelection,
        zoneCurve: ZoneCurveInput?
    ) async -> GuidedForceProtocolSession {
        let launchSide = ExerciseSidePolicy.normalizeSide(sideMode, side)
        let startSide: TindeqSide = launchSide == .right ? .right : .left
        let plan = await model.resolveForceTargetPlan(
            preset: preset,
            tag: tag,
            startingSide: startSide,
            fallbackSide: launchSide
        )
        return GuidedForceProtocolSession(
            model: model,
            preset: preset,
            targetPlan: plan,
            tag: tag,
            startingSide: startSide,
            fallbackSide: launchSide,
            selection: selection,
            references: zoneCurve
        )
    }

    private func endGuidedSession(_ session: GuidedForceProtocolSession) {
        Task {
            await session.stopOrFinish()
            guard session.isEnded, guidedSession?.id == session.id else { return }
            clearGuidedSession(session)
        }
    }

    private static func defaultPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Max Hangs",
            holdSeconds: 10,
            repetitions: 3,
            sets: 3,
            restBetweenRepetitionsSeconds: 120,
            restBetweenSetsSeconds: 180,
            prepareSeconds: 5
        )
    }
}

/// #1004: one guided launch that did not start. The requirement is exactly
/// this pair — the user sees WHY, and the retry re-runs the attempt.
///
/// Internal (not `private`) so the render-evidence test can capture THIS
/// component — the recovery affordance the issue asks for a screenshot of —
/// instead of a copy of its copy.
struct GuidedLaunchFailureCard: View {
    let failure: GuidedLaunchFailure
    let onRetry: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Guided protocol didn\u{2019}t start", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SendmeterStyle.caution)
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRetry) {
                    Label(ForceRecoveryActionPolicy.guidedLaunchRetryTitle, systemImage: "arrow.clockwise")
                }
                .hapticButtonStyle(.bordered)
                .disabled(!failure.isRetryable)
                .accessibilityIdentifier("guided-launch-retry")
                .accessibilityHint("Runs the guided protocol launch again")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// #1004 (session-lock): the release for a guided lock whose owner has
/// already ended — the one affordance that clears a Force surface held by a
/// session that can neither resume nor end. Internal (not `private`) for the
/// same reason as `GuidedLaunchFailureCard`: the render-evidence test
/// captures THIS component rather than a copy of its copy.
struct GuidedSessionReleaseCard: View {
    let onRelease: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(ForceLockOrphanPolicy.releaseHeading, systemImage: "lock.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SendmeterStyle.caution)
                Text(ForceLockOrphanPolicy.releaseNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRelease) {
                    Label(ForceLockOrphanPolicy.releaseTitle, systemImage: "lock.open")
                }
                .hapticButtonStyle(.bordered)
                .accessibilityIdentifier("guided-session-release")
                .accessibilityHint(ForceLockOrphanPolicy.releaseHint)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct GuidedForceResumeCard: View {
    @ObservedObject var session: GuidedForceProtocolSession
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        SurfaceCard {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(SendmeterStyle.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided protocol paused")
                        .font(.headline)
                    Text("\(session.preset.name) · \(session.run.currentStage.label)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(session.savedCount) pull\(session.savedCount == 1 ? "" : "s") durably queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Resume", action: onResume)
                    .hapticButtonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(session.isAdvancing || session.isPausing)
                    .accessibilityHint("Reopen the guided protocol without stopping it")
                Button("End", role: .destructive, action: onEnd)
                    .hapticButtonStyle(.bordered)
                    .disabled(session.isAdvancing || session.isPausing)
                    .accessibilityHint("Save the current pull if needed and end this protocol")
            }
        }
        .accessibilityElement(children: .contain)
    }
}



private struct ForceDeviceCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let device: TindeqBluetooth
    @Binding var handsFreeEnabled: Bool
    /// #628: the hands-free loop's state, mirrored from AppModel (the loop
    /// re-renders through the device's observed sample/status changes).
    let handsFreeArmed: Bool
    let handsFreeMeasuring: Bool
    let protocolArmed: Bool
    let guidedSessionActive: Bool
    /// #1004 (session-lock): true when that session has already ENDED — the
    /// lock has no live owner, so the row names the release instead of a
    /// resume/end that no longer exists.
    let guidedLockOrphaned: Bool
    /// #1004: the held-pull recovery controls, decided by one policy so Save
    /// and Discard can never be disabled at the same time as Start.
    let recoveryControls: ForceRecoveryControls
    let targetBand: ForceTargetBand?
    let resolvingTarget: Bool
    let savingSummary: Bool
    let gaugeSessionCount: Int
    let hasLoadedRecordings: Bool
    let hasForceRecordings: Bool
    let emptyActionTitle: String
    let emptyAction: () -> Void
    let start: () -> Void
    let refuseAction: (String) -> Void
    let connect: () -> Void
    let armHandsFree: () -> Void
    let stopAndSave: () -> Void
    let cancelArm: () -> Void
    let finishSession: () -> Void
    let saveCompleted: () -> Void
    let saveRecovered: () -> Void
    let discardCompleted: () -> Void
    let discardRecovered: () -> Void
    @State private var showingDiscardConfirmation = false
    @State private var discardIsRecovered = false

    private var targetRange: ClosedRange<Double>? { targetBand?.range }

    /// #1004: a failed save falls back to OFFERING discard. The pull is still
    /// held locally, so the honest next step is the user's, with what it costs
    /// stated.
    @ViewBuilder
    private var recoveryFallbackNotice: some View {
        if recoveryControls.offersDiscardFallback {
            Text(ForceRecoveryActionPolicy.discardFallbackNotice)
                .font(.caption)
                .foregroundStyle(SendmeterStyle.caution)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recovery-discard-fallback")
        }
    }

    private var showsDisconnectedEmptyState: Bool {
        guard !device.hasUnsavedRecording,
              device.interruptedRecording == nil,
              device.completedSummary == nil
        else { return false }

        switch device.status {
        case .idle, .unavailable, .interrupted:
            return true
        default:
            return false
        }
    }

    private var showsForceDataEmptyState: Bool {
        guard hasLoadedRecordings,
              !hasForceRecordings,
              device.interruptedRecording == nil,
              device.completedSummary == nil,
              !device.hasUnsavedRecording,
              !handsFreeArmed
        else { return false }

        switch device.status {
        case .connected:
            return true
        default:
            return false
        }
    }

    private var showsPrimaryEmptyState: Bool {
        showsDisconnectedEmptyState || showsForceDataEmptyState
    }

    private var primaryEmptyMessage: String {
        switch device.status {
        case .unavailable:
            return hasForceRecordings
                ? "Your saved force history is safe. Turn Bluetooth back on in iOS Settings to reconnect."
                : "Turn Bluetooth back on in iOS Settings to connect your Progressor."
        case .idle where hasForceRecordings:
            return "Reconnect your Progressor to continue recording and extend your force history."
        case .interrupted where hasForceRecordings:
            return "Your saved force history is safe. Reconnect your Progressor to continue recording."
        case .interrupted:
            return "Reconnect your Progressor to turn a pull into a force curve."
        case .connected:
            return "Record with Hands-free, or run a guided protocol above, to turn your first pull into a force curve."
        default:
            return "Connect your Progressor to turn a pull into a force curve."
        }
    }

    var body: some View {
        SurfaceCard {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel("Progressor", systemImage: "dot.radiowaves.left.and.right")
                        Text(statusLabel)
                            .font(.headline)
                    }
                    Spacer()
                    StatusPill(statusPill.text, color: statusPill.color)
                }

                if showsPrimaryEmptyState {
                    ProductEmptyState(
                        title: hasForceRecordings
                            ? "Reconnect to your force progress"
                            : "Your first pull starts here",
                        message: primaryEmptyMessage,
                        actionTitle: emptyActionTitle,
                        artwork: .forceMascot,
                        action: emptyAction
                    )
                } else if device.status == .measuring || device.handsFreeArmed || !device.visibleSampleRange.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        MetricValue(
                            device.currentKilograms.formatted(.number.precision(.fractionLength(1))),
                            unit: "kg",
                            color: inTarget ? SendmeterStyle.optimal : .primary
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Current force \(device.currentKilograms.formatted(.number.precision(.fractionLength(1)))) kilograms"
                        )
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("Peak \(device.peakKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                                .accessibilityLabel(
                                    "Peak \(device.peakKilograms.formatted(.number.precision(.fractionLength(1)))) kilograms"
                                )
                            Text("Average \(device.averageKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                            Text((device.elapsedMilliseconds / 1_000).formatted(.number.precision(.fractionLength(1))) + " s")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    ForceTraceChart(
                        buffer: device.sampleBuffer,
                        range: device.visibleSampleRange,
                        targetRange: targetRange,
                        target: targetBand?.kilograms
                    )
                    .frame(height: 190)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        ForceTraceAccessibility.liveSummary(
                            peakKilograms: device.peakKilograms
                        )
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Text("Ready to measure")
                            .font(.title3.bold())
                        Text("Connect a Tindeq Progressor, tare it, then arm Hands-free or start a guided protocol.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }

                if resolvingTarget {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Resolving the protocol target from this exercise's force history…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if device.lowBattery {
                    Label("Progressor battery is low", systemImage: "battery.25percent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SendmeterStyle.alert)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if guidedSessionActive {
                    Label(
                        guidedLockOrphaned
                            ? ForceLockOrphanPolicy.orphanedLockLabel
                            : ForceLockOrphanPolicy.activeLockLabel,
                        systemImage: "lock.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SendmeterStyle.caution)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                controls
                    .disabled(guidedSessionActive)

                if gaugeSessionCount > 0, device.status == .connected {
                    HStack {
                        Label("Gauge session · \(gaugeSessionCount) recording\(gaugeSessionCount == 1 ? "" : "s")", systemImage: "waveform.path.ecg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Finish", action: finishSession)
                            .font(.subheadline.weight(.semibold))
                            .disabled(guidedSessionActive)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SendmeterStyle.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                if device.interruptedRecording != nil, recoveryControls.showsRecoveryCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Unsaved pull recovered after disconnect", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Button("Save Recovered Pull", action: saveRecovered)
                                .hapticButtonStyle(.borderedProminent)
                                // #1004: a held pull is always settleable. The
                                // old condition also greys these while a guided
                                // session is active, which is exactly the
                                // deadlock against Start's `.disabled(device.hasUnsavedRecording)`.
                                .disabled(!recoveryControls.canSave)
                            Button("Discard", role: .destructive) {
                                discardIsRecovered = true
                                showingDiscardConfirmation = true
                            }
                            .hapticButtonStyle(.bordered)
                            .disabled(!recoveryControls.canDiscard)
                        }
                        recoveryFallbackNotice
                    }
                    .padding(12)
                    .background(SendmeterStyle.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                } else if device.completedSummary != nil, device.status != .measuring, recoveryControls.showsRecoveryCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Completed pull is ready for a durable save", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Button("Save Completed Pull", action: saveCompleted)
                                .hapticButtonStyle(.borderedProminent)
                                .disabled(!recoveryControls.canSave)
                            Button("Discard", role: .destructive) {
                                discardIsRecovered = false
                                showingDiscardConfirmation = true
                            }
                            .hapticButtonStyle(.bordered)
                            .disabled(!recoveryControls.canDiscard)
                        }
                        recoveryFallbackNotice
                    }
                    .padding(12)
                    .background(SendmeterStyle.optimal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .animation(
            reduceMotion
                ? nil
                : .spring(
                    response: ForceMotionPolicy.phaseResponseSeconds,
                    dampingFraction: ForceMotionPolicy.phaseDampingFraction,
                    blendDuration: 0
                ),
            value: device.status
        )
        .alert("Discard unsaved pull?", isPresented: $showingDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                // #656: a confirmed destructive action fires the medium tick
                // once per gesture.
                Haptics.shared.playGesture(.medium)
                if discardIsRecovered { discardRecovered() }
                else { discardCompleted() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This pull has not been placed in the durable on-device queue and cannot be recovered after it is discarded.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if showsPrimaryEmptyState, device.status != .connected {
            EmptyView()
        } else {
            switch device.status {
        case .unavailable:
            Label("Bluetooth is not available for this app.", systemImage: "bluetooth.slash")
                .foregroundStyle(.secondary)
        case .idle, .interrupted:
            if showsDisconnectedEmptyState {
                EmptyView()
            } else {
                Button {
                    // #656 (review F1): user-initiated — arms the transport's
                    // success/error haptics for this launch.
                    connect()
                } label: {
                    Label("Connect Progressor", systemImage: "antenna.radiowaves.left.and.right")
                }
                .hapticButtonStyle(PrimaryActionButtonStyle())
            }
        case .scanning, .connecting:
            HStack {
                ProgressView()
                Text(device.status == .scanning ? "Searching for Progressor…" : "Connecting…")
                Spacer()
                Button("Cancel") { device.disconnect() }
            }
        case .connected:
            VStack(spacing: 10) {
                if handsFreeMeasuring {
                    VStack(spacing: 8) {
                        Label(
                            "Measuring — release to save",
                            systemImage: "record.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SendmeterStyle.primary)
                        Button(action: stopAndSave) {
                            Label("Stop & Save", systemImage: "stop.fill")
                        }
                        .hapticButtonStyle(PrimaryActionButtonStyle())
                    }
                } else if handsFreeArmed, protocolArmed {
                    VStack(spacing: 8) {
                        if !showsPrimaryEmptyState {
                            Button(action: start) {
                                Label("Start Guided Protocol", systemImage: "play.fill")
                            }
                            .hapticButtonStyle(PrimaryActionButtonStyle())
                        }
                        Button("Cancel hands-free arm", role: .destructive, action: cancelArm)
                            .hapticButtonStyle(.bordered)
                    }
                } else if handsFreeArmed {
                    VStack(spacing: 8) {
                        Label("Armed — pull to measure", systemImage: "scope")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Button("Cancel", role: .destructive) {
                            // #656 (review F14): disarming hands-free is a
                            // destructive action — medium tick.
                            Haptics.shared.playGesture(.medium)
                            cancelArm()
                        }
                        .hapticButtonStyle(.bordered)
                    }
                } else if handsFreeEnabled, !protocolArmed {
                    if showsPrimaryEmptyState {
                        Label(
                            "Hands-free is ready — use the action above to arm it",
                            systemImage: "scope"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    } else {
                        Button(action: armHandsFree) {
                            Label("Arm Hands-free", systemImage: "scope")
                        }
                        .hapticButtonStyle(PrimaryActionButtonStyle())
                        .disabled(device.hasUnsavedRecording)
                    }
                } else if protocolArmed {
                    Button(action: start) {
                        Label("Start Guided Protocol", systemImage: "play.fill")
                    }
                    .hapticButtonStyle(PrimaryActionButtonStyle())
                    .disabled(device.hasUnsavedRecording)
                } else if !showsPrimaryEmptyState {
                    // #899: no direct-measure "Start Pull" remains — with
                    // nothing armed the honest route is arming a guided
                    // protocol above or turning on Hands-free below.
                    Label(
                        "Pick a guided protocol above, or turn on Hands-free to record a pull",
                        systemImage: "scope"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                if device.hasUnsavedRecording {
                    Text(UserFacingError.message(for: .previousRecordingUnfinished))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button {
                        do {
                            try device.tare()
                        } catch {
                            refuseAction(UserFacingError.message(for: error))
                        }
                    } label: {
                        Label("Tare", systemImage: "scalemass")
                    }
                    .hapticButtonStyle(.bordered)
                    Button {
                        do {
                            try device.refreshBattery()
                        } catch {
                            refuseAction(UserFacingError.message(for: error))
                        }
                    } label: {
                        Label("Battery", systemImage: "battery.100percent")
                    }
                    .hapticButtonStyle(.bordered)
                    Spacer()
                    Button("Disconnect", role: .destructive) { device.disconnect() }
                        .hapticButtonStyle(.borderless)
                }

                Toggle(isOn: $handsFreeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hands-free")
                            .font(.subheadline.weight(.medium))
                        Text("Measurement starts when you pull and saves when you release.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        case .measuring:
            Button(action: stopAndSave) {
                HStack {
                    if savingSummary { ProgressView().tint(.white) }
                    Label("Stop & Save", systemImage: "stop.fill")
                }
            }
            .hapticButtonStyle(PrimaryActionButtonStyle())
            .disabled(savingSummary)
            }
        }
    }

    private var statusLabel: String {
        switch device.status {
        case .unavailable: return "Unavailable"
        case .idle: return "Not connected"
        case .scanning: return "Searching"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .measuring: return "Measuring"
        case let .interrupted(message): return message
        }
    }

    private var statusPill: (text: String, color: Color) {
        switch device.status {
        case .connected: return ("Ready", SendmeterStyle.optimal)
        case .measuring: return ("Live", SendmeterStyle.primary)
        case .scanning, .connecting: return ("Working", SendmeterStyle.caution)
        case .interrupted: return ("Interrupted", SendmeterStyle.alert)
        case .unavailable: return ("Unavailable", SendmeterStyle.alert)
        case .idle: return ("Offline", .secondary)
        }
    }

    private var inTarget: Bool {
        guard let targetRange else { return false }
        return targetRange.contains(device.currentKilograms)
    }
}





struct ForceTraceChart: View {
    private enum SampleSource {
        case array([TindeqSample])
        case buffer(ForceSampleBuffer, Range<Int>)
    }

    private let source: SampleSource
    let targetRange: ClosedRange<Double>?
    let target: Double?
    @Environment(\.colorScheme) private var scheme
    /// #900: rep-boundary hysteresis — the held peak lives here so a rep
    /// boundary that empties the visible window cannot collapse the scale
    /// under the stage band (see `ForceChartYDomain`/`ForceChartYDomainTracker`).
    @State private var domainTracker = ForceChartYDomainTracker()

    init(
        samples: [TindeqSample],
        targetRange: ClosedRange<Double>?,
        target: Double?
    ) {
        self.source = .array(samples)
        self.targetRange = targetRange
        self.target = target
    }

    init(
        buffer: ForceSampleBuffer,
        range: Range<Int>,
        targetRange: ClosedRange<Double>?,
        target: Double?
    ) {
        self.source = .buffer(buffer, range)
        self.targetRange = targetRange
        self.target = target
    }

    private var sampleRange: Range<Int> {
        switch source {
        case let .array(samples):
            return 0..<samples.count
        case let .buffer(buffer, range):
            let lower = max(0, min(range.lowerBound, buffer.count))
            let upper = max(lower, min(range.upperBound, buffer.count))
            return lower..<upper
        }
    }

    private func sample(at index: Int) -> TindeqSample {
        switch source {
        case let .array(samples): return samples[index]
        case let .buffer(buffer, _): return buffer[index]
        }
    }

    var body: some View {
        Canvas { context, size in
            let sampleRange = self.sampleRange
            let maxValue = ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: targetRange?.upperBound,
                windowPeakKilograms: windowPeakKilograms,
                heldPeakKilograms: domainTracker.heldPeakKilograms
            )
            let firstSample = sampleRange.first.map(self.sample(at:))
            let lastSample = sampleRange.last.map(self.sample(at:))
            let firstTime = firstSample?.milliseconds ?? 0
            let lastTime = max(firstTime + 1, lastSample?.milliseconds ?? firstTime + 1)
            let gridColor = ChartToken.forceTraceGridColor(scheme)
            let optimalColor = ChartToken.optimal.color(scheme)

            func y(_ kilograms: Double) -> CGFloat {
                size.height - CGFloat(max(0, kilograms) / maxValue) * size.height
            }
            func x(_ milliseconds: Double) -> CGFloat {
                CGFloat((milliseconds - firstTime) / (lastTime - firstTime)) * size.width
            }

            for index in 1..<4 {
                var grid = Path()
                let lineY = size.height * CGFloat(index) / 4
                grid.move(to: CGPoint(x: 0, y: lineY))
                grid.addLine(to: CGPoint(x: size.width, y: lineY))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)
            }

            if let targetRange {
                let upperY = y(targetRange.upperBound)
                let lowerY = y(targetRange.lowerBound)
                context.fill(
                    Path(CGRect(x: 0, y: upperY, width: size.width, height: max(1, lowerY - upperY))),
                    with: .color(optimalColor.opacity(ChartToken.forceTraceBandOpacity(scheme)))
                )
            }
            if let target {
                var targetPath = Path()
                targetPath.move(to: CGPoint(x: 0, y: y(target)))
                targetPath.addLine(to: CGPoint(x: size.width, y: y(target)))
                context.stroke(
                    targetPath,
                    with: .color(optimalColor.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
            }

            guard sampleRange.count > 1 else { return }
            var trace = Path()
            var pointIndex = 0
            for index in sampleRange {
                let sample = self.sample(at: index)
                let point = CGPoint(x: x(sample.milliseconds), y: y(sample.kilograms))
                if pointIndex == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                pointIndex += 1
            }
            context.stroke(
                trace,
                with: .color(ChartToken.force.color(scheme)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
        .background(ChartToken.forceTraceBackground(scheme), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // #900: feed the domain tracker whenever the live window changes
        // (buffer appends move the published range; a rep boundary resets
        // the shared buffer, which the content count catches even before
        // the next flush publishes an empty range). Array sources render a
        // complete, static window and never need the hold.
        .onChange(of: domainFeedStamp) { _ in
            feedDomainTracker()
        }
    }

    /// The strongest sample in the current visible window (0 when empty).
    private var windowPeakKilograms: Double {
        var peak = 0.0
        for index in sampleRange {
            peak = max(peak, self.sample(at: index).kilograms)
        }
        return peak
    }

    /// The live window's change identity: published range plus buffer content
    /// count, so both a window advance and a rep-boundary buffer reset feed
    /// the tracker. Nil for array sources, which never need the hold.
    private var domainFeedStamp: DomainFeedStamp? {
        guard case let .buffer(buffer, range) = source else { return nil }
        return DomainFeedStamp(
            lower: range.lowerBound,
            upper: range.upperBound,
            contentCount: buffer.count
        )
    }

    private func feedDomainTracker() {
        guard case .buffer = source else { return }
        domainTracker.frame(
            bandUpperBoundKilograms: targetRange?.upperBound,
            windowPeakKilograms: windowPeakKilograms
        )
    }

    private struct DomainFeedStamp: Equatable {
        let lower: Int
        let upper: Int
        let contentCount: Int
    }
}

private struct WatchForceMirrorCard: View {
    let force: WatchLiveForce

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Apple Watch Force", systemImage: "applewatch")
                        .font(.headline)
                    Spacer()
                    StatusPill(force.status.capitalized, color: force.status == "measuring" ? SendmeterStyle.primary : SendmeterStyle.optimal)
                }
                HStack(alignment: .firstTextBaseline) {
                    MetricValue(
                        (force.kilograms ?? 0).formatted(.number.precision(.fractionLength(1))),
                        unit: "kg"
                    )
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Peak \((force.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1)))) kg")
                        if let tag = force.tag, !tag.isEmpty { Text(tag) }
                        if force.side != .unspecified { Text(force.side.label) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !force.spark.isEmpty {
                    ForceTraceChart(samples: force.spark, targetRange: nil, target: nil)
                        .frame(height: 100)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            ForceTraceAccessibility.liveSummary(
                                peakKilograms: force.peakKilograms
                            )
                        )
                }
                Text("Direct WatchConnectivity · updated \(force.updatedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ForceProtocolLibraryCard: View {
    let presets: [TindeqPreset]
    let run: (TindeqPreset) -> Void
    let edit: (TindeqPreset) -> Void
    let create: () -> Void
    let delete: (TindeqPreset) -> Void
    let disabled: Bool

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Guided protocols", systemImage: "list.bullet.rectangle.portrait")
                    Spacer()
                    Button(action: create) { Label("New", systemImage: "plus") }
                        .labelStyle(.iconOnly)
                }
                if presets.isEmpty {
                    Text("Create repeaters, max hangs, capacity holds, or reverse-action cadence protocols.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Create Protocol", action: create)
                        .hapticButtonStyle(.bordered)
                } else {
                    ForEach(presets) { preset in
                        HStack(spacing: 12) {
                            Button { run(preset) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.headline)
                                    Text(protocolSummary(preset))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .hapticButtonStyle(.plain)
                            Menu {
                                Button {
                                    Haptics.shared.playGesture(.light)
                                    run(preset)
                                } label: { Label("Run", systemImage: "play.fill") }
                                Button {
                                    Haptics.shared.playGesture(.light)
                                    edit(preset)
                                } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    Haptics.shared.playGesture(.medium)
                                    delete(preset)
                                } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .onTapGesture {
                                        Haptics.shared.playGesture(.light)
                                    }
                            }
                        }
                        if preset.id != presets.last?.id { Divider() }
                    }
                }
            }
        }
        .disabled(disabled)
    }

    private func protocolSummary(_ preset: TindeqPreset) -> String {
        if preset.protocolMode == .reverseAction {
            return "\(preset.sets) sets · \(preset.repetitions) reps · \(preset.cadenceOutSeconds.formatted())/\(preset.cadenceReturnSeconds.formatted()) s cadence"
        }
        return "\(preset.sets) × \(preset.repetitions) · \(preset.holdSeconds)s hold · \(preset.restBetweenRepetitionsSeconds)s rest"
    }
}

private struct RecentForceCard: View {
    let recordings: [TindeqRecording]

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Recent recordings", systemImage: "clock")
                if recordings.isEmpty {
                    Text("Completed pulls will appear here after their durable local save is queued.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recordings) { recording in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text(recording.tag.isEmpty ? "Untitled pull" : recording.tag)
                                        .font(.headline)
                                    // #675 F1: a restored quarantined
                                    // placeholder reads "Rejected" — it won't
                                    // upload on its own.
                                    if recording.rejected {
                                        StatusPill("Rejected", color: SendmeterStyle.alert)
                                    }
                                }
                                Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((recording.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1))) + " kg")
                                .font(.headline.monospacedDigit())
                        }
                        if recording.id != recordings.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private enum ForceTargetMode: String, CaseIterable, Identifiable {
    case none
    case fixed
    case percentagePR
    case percentageCF
    case curve

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .fixed: return "Fixed kg"
        case .percentagePR: return "% of PR"
        case .percentageCF: return "% of CF"
        case .curve: return "Auto curve"
        }
    }
}

private struct ForcePresetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TindeqPreset
    @State private var targetMode: ForceTargetMode
    @State private var varyHolds: Bool
    @State private var isSaving = false
    let isNew: Bool

    init(preset: TindeqPreset, isNew: Bool) {
        self._draft = State(initialValue: preset)
        let mode: ForceTargetMode
        if preset.targetFromCurve {
            mode = .curve
        } else if preset.targetPercentage != nil {
            mode = preset.percentageBasis == .criticalForce ? .percentageCF : .percentagePR
        } else if preset.targetKilograms != nil {
            mode = .fixed
        } else {
            mode = .none
        }
        self._targetMode = State(initialValue: mode)
        self._varyHolds = State(initialValue: preset.holdSecondsBySet != nil)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Protocol") {
                    TextField("Name", text: $draft.name)
                    Picker("Mode", selection: $draft.protocolMode) {
                        Text("Hold").tag(ForceProtocolMode.hold)
                        Text("Reverse Action").tag(ForceProtocolMode.reverseAction)
                    }
                    Stepper("Sets: \(draft.sets)", value: $draft.sets, in: 1...20)
                    Stepper("Repetitions: \(draft.repetitions)", value: $draft.repetitions, in: 1...50)
                    if draft.protocolMode == .hold {
                        Stepper("Base hold: \(draft.holdSeconds) s", value: $draft.holdSeconds, in: 1...600)
                        Toggle("Vary hold by set", isOn: $varyHolds)
                        if varyHolds {
                            ForEach(1...max(1, draft.sets), id: \.self) { setNumber in
                                HStack {
                                    Text("Set \(setNumber)")
                                    Spacer()
                                    TextField(
                                        "seconds",
                                        value: holdBinding(setNumber: setNumber),
                                        format: .number
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                    Text("s").foregroundStyle(.secondary)
                                }
                            }
                        }
                        Stepper(
                            "Rest between reps: \(draft.restBetweenRepetitionsSeconds) s",
                            value: $draft.restBetweenRepetitionsSeconds,
                            in: 0...900,
                            step: 5
                        )
                    } else {
                        HStack {
                            Text("Pull out")
                            Spacer()
                            TextField("seconds", value: $draft.cadenceOutSeconds, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                            Text("s").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Return")
                            Spacer()
                            TextField("seconds", value: $draft.cadenceReturnSeconds, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                            Text("s").foregroundStyle(.secondary)
                        }
                    }
                    Stepper(
                        "Rest between sets: \(draft.restBetweenSetsSeconds) s",
                        value: $draft.restBetweenSetsSeconds,
                        in: 0...1_800,
                        step: 5
                    )
                    Stepper("Prepare: \(draft.prepareSeconds) s", value: $draft.prepareSeconds, in: 0...60)
                    Toggle("Alternate sides", isOn: $draft.alternateSides)
                    // #901: the toggle is a Both-mode declaration — a
                    // Left/Right side selection overrides it and runs that
                    // side only, with no switch-hands stages.
                    Text("Alternation applies when you record Both sides; a Left or Right selection runs that side only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Target") {
                    Picker("Target mode", selection: $targetMode) {
                        ForEach(ForceTargetMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    switch targetMode {
                    case .none:
                        Text("No target band will be shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .fixed:
                        kilogramsField
                    case .percentagePR, .percentageCF:
                        HStack {
                            Text(targetMode == .percentageCF ? "Percent of CF" : "Percent of PR")
                            Spacer()
                            TextField(
                                "percent",
                                value: Binding(
                                    get: { draft.targetPercentage ?? 80 },
                                    set: { draft.targetPercentage = min(150, max(1, $0)) }
                                ),
                                format: .number
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            Text("%").foregroundStyle(.secondary)
                        }
                        if draft.sets > 1 {
                            HStack {
                                Text("Increase each set")
                                Spacer()
                                TextField("step", value: $draft.percentageStep, format: .number)
                                    .keyboardType(.numbersAndPunctuation)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text("%").foregroundStyle(.secondary)
                            }
                        }
                        Text(targetMode == .percentageCF
                             ? "Uses this exercise and side's critical-force estimate."
                             : "Uses this exercise and side's best recorded peak.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .curve:
                        Text("Each set resolves against the exercise's Hill force-duration curve at that set's prescribed work duration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if targetMode != .none {
                        Picker("Tolerance", selection: $draft.toleranceMode) {
                            Text("Percent").tag("percent")
                            Text("Kilograms").tag("kg")
                        }
                        HStack {
                            Text("Tolerance value")
                            Spacer()
                            TextField("value", value: $draft.toleranceValue, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text(draft.toleranceMode == "kg" ? "kg" : "%")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Coaching") {
                    TextField("Setup note", text: $draft.setupNote, axis: .vertical)
                    Toggle("Counts as capacity evidence", isOn: $draft.capacityEvidence)
                }
            }
            .navigationTitle(isNew ? "New Protocol" : "Edit Protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .onChange(of: draft.sets) { _ in
                normalizeHoldOverrides()
            }
            .onChange(of: varyHolds) { enabled in
                if enabled { normalizeHoldOverrides() }
            }
        }
    }

    @ViewBuilder
    private var kilogramsField: some View {
        HStack {
            Text("Target")
            Spacer()
            TextField(
                "kg",
                value: Binding(
                    get: { draft.targetKilograms ?? 0 },
                    set: { draft.targetKilograms = max(0, $0) }
                ),
                format: .number
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            Text("kg").foregroundStyle(.secondary)
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.sets > 0
            && draft.repetitions > 0
            && (draft.protocolMode == .hold
                || (draft.cadenceOutSeconds >= 0.25 && draft.cadenceReturnSeconds >= 0.25))
            && (targetMode != .fixed || (draft.targetKilograms ?? 0) > 0)
            && ((targetMode != .percentagePR && targetMode != .percentageCF)
                || (draft.targetPercentage ?? 0) > 0)
    }

    private func holdBinding(setNumber: Int) -> Binding<Int> {
        Binding(
            get: {
                guard let values = draft.holdSecondsBySet,
                      values.indices.contains(setNumber - 1)
                else { return draft.holdSeconds }
                return values[setNumber - 1]
            },
            set: { value in
                normalizeHoldOverrides()
                draft.holdSecondsBySet?[setNumber - 1] = min(600, max(1, value))
            }
        )
    }

    private func normalizeHoldOverrides() {
        guard varyHolds else { return }
        var values = draft.holdSecondsBySet ?? []
        if values.count < draft.sets {
            values.append(contentsOf: Array(repeating: draft.holdSeconds, count: draft.sets - values.count))
        } else if values.count > draft.sets {
            values = Array(values.prefix(draft.sets))
        }
        draft.holdSecondsBySet = values.map { min(600, max(1, $0)) }
    }

    private func save() {
        isSaving = true
        if varyHolds {
            normalizeHoldOverrides()
        } else {
            draft.holdSecondsBySet = nil
        }
        switch targetMode {
        case .none:
            draft.targetKilograms = nil
            draft.targetPercentage = nil
            draft.targetFromCurve = false
        case .fixed:
            draft.targetKilograms = max(0.1, draft.targetKilograms ?? 0.1)
            draft.targetPercentage = nil
            draft.targetFromCurve = false
        case .percentagePR:
            draft.targetKilograms = nil
            draft.targetPercentage = min(150, max(1, draft.targetPercentage ?? 80))
            draft.percentageBasis = .personalRecord
            draft.targetFromCurve = false
        case .percentageCF:
            draft.targetKilograms = nil
            draft.targetPercentage = min(150, max(1, draft.targetPercentage ?? 80))
            draft.percentageBasis = .criticalForce
            draft.targetFromCurve = false
        case .curve:
            draft.targetKilograms = nil
            draft.targetPercentage = nil
            draft.targetFromCurve = true
        }
        draft.cadenceOutSeconds = max(0.25, draft.cadenceOutSeconds)
        draft.cadenceReturnSeconds = max(0.25, draft.cadenceReturnSeconds)
        draft.toleranceValue = max(0, draft.toleranceValue)
        draft.setupNote = String(draft.setupNote.prefix(500))
        Task {
            await model.savePreset(draft, isNew: isNew)
            isSaving = false
            dismiss()
        }
    }
}

#if DEBUG
/// #938 AC7 evidence: with `--guided-force-fixture-scrolled` the cover's
/// scroll view is driven to its bottom (nothing else in this harness scrolls),
/// so the capture shows the end of the guided content — the live chart's
/// bottom edge and the pause/skip controls. Retries a few times because the
/// scroll view is created after the cover appears.
enum GuidedForceFixtureScroll {
    static func scrollToBottomIfRequested() {
        guard CommandLine.arguments.contains("--guided-force-fixture-scrolled") else { return }
        func scroll() {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return }
            var deepest: UIScrollView?
            var queue = window.subviews
            while let view = queue.popLast() {
                if let scroll = view as? UIScrollView,
                   scroll.contentSize.height > (deepest?.contentSize.height ?? -1) {
                    deepest = scroll
                }
                queue.append(contentsOf: view.subviews)
            }
            guard let scroll = deepest else { return }
            let bottom = max(
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom,
                0
            )
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
        for delay in [1.0, 2.0, 3.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scroll() }
        }
    }
}

/// #938 evidence harness: presents the REAL `GuidedForceProtocolView` cover
/// through the same `fullScreenCover` container `ForceView` uses, without a
/// signed-in session or a connected gauge, so simulator screenshots can prove
/// the cover paints edge-to-edge behind the status bar and that its scroll
/// content clears the bottom controls. DEBUG-only and launch-argument gated;
/// the app's normal signed-in flow never reaches this view.
///
/// `--guided-force-fixture=rest` (default) captures a SET REST stage,
/// `--guided-force-fixture=work` a HOLD stage, and
/// `--guided-force-fixture=complete` the finished run's DONE panel (#940:
/// the next-step prompt and its inline Done action, which must be reachable
/// without scrolling). The work stage is load triggered, so with no gauge
/// attached it holds the "pull to start" state instead of counting down —
/// deterministic for capture either way.
struct GuidedForceFixtureView: View {
    private let stageKind: ForceProtocolStageKind
    @State private var presented = false

    init(arguments: [String]) {
        let flag = "--guided-force-fixture="
        let raw = arguments.first { $0.hasPrefix(flag) }?.dropFirst(flag.count)
        switch raw {
        case "work": stageKind = .work
        case "complete": stageKind = .complete
        default: stageKind = .restBetweenSets
        }
    }

    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            // The cover content takes only the constant stage: a standalone
            // view owning its own session state, so the presented tree is
            // built from values that cannot change between the presentation
            // request and the content build.
            .fullScreenCover(isPresented: $presented) {
                GuidedForceFixtureCover(stageKind: stageKind)
            }
            .onAppear { presented = true }
    }
}

/// The presented half of the #938 harness: it owns the fixture session and
/// renders the real cover. The session is built in this view's own
/// `onAppear`, so the guided content appears through this view's state, not
/// through the presenter's.
private struct GuidedForceFixtureCover: View {
    @Environment(AppModel.self) private var model
    let stageKind: ForceProtocolStageKind
    @State private var session: GuidedForceProtocolSession?

    var body: some View {
        Group {
            if let session {
                GuidedForceProtocolView(
                    session: session,
                    onMinimize: {},
                    onClose: {}
                )
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
        .onAppear {
            GuidedForceFixtureScroll.scrollToBottomIfRequested()
            guard session == nil else { return }
            session = GuidedForceProtocolSession(
                model: model,
                preset: Self.preset,
                targetPlan: Self.targetPlan,
                tag: "FDP",
                startingSide: .left,
                fallbackSide: .left,
                selection: .free,
                references: nil,
                run: Self.run(stageKind: stageKind)
            )
        }
    }

    private static let preset = TindeqPreset(
        name: "Max Hangs",
        holdSeconds: 10,
        repetitions: 3,
        sets: 3,
        restBetweenRepetitionsSeconds: 120,
        restBetweenSetsSeconds: 180,
        prepareSeconds: 5
    )

    /// One representative reference band per set, so the live chart draws its
    /// target band the way a resolved real plan does.
    private static let targetPlan = ForceTargetPlan(
        targets: Dictionary(
            uniqueKeysWithValues: (1...3).map { setNumber in
                (
                    ForceTargetKey(setNumber: setNumber, side: .unspecified),
                    ForceTargetBand(kilograms: 30, lowKilograms: 27, highKilograms: 33)
                )
            }
        )
    )

    private static func run(stageKind: ForceProtocolStageKind) -> ForceProtocolRun {
        var run = ForceProtocolRun(preset: preset, startingSide: .left, selectedSide: .left)
        while run.currentStage.kind != stageKind, !run.isComplete {
            run.advance()
        }
        return run
    }
}
#endif

import Foundation
import SendmeterCore
import SwiftUI

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
private final class GuidedForceProtocolSession: ObservableObject, Identifiable {
    let id: UUID
    let model: AppModel
    let preset: TindeqPreset
    let targetPlan: ForceTargetPlan
    let tag: String
    let fallbackSide: TindeqSide
    let zone: RecordedZone?
    let handsFreeEnabled: Bool
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
        zone: RecordedZone?,
        handsFreeEnabled: Bool,
        run: ForceProtocolRun? = nil
    ) {
        self.model = model
        self.preset = preset
        self.targetPlan = targetPlan
        self.tag = tag
        self.fallbackSide = fallbackSide
        self.zone = zone
        self.handsFreeEnabled = handsFreeEnabled
        self.accountScope = model.accountScope
        let initialRun = run ?? ForceProtocolRun(preset: preset, startingSide: startingSide)
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
        if handsFreeEnabled {
            model.handsFree.stopPolicy = .callerOwned
        }
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
        handsFreeEnabled
            && run.currentStage.kind == .work
            && GuidedForceHandsFreeTimingPolicy.isWaitingForPull(
                handsFreeEnabled: handsFreeEnabled,
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
            model.errorMessage = "Could not save the partial pull before pausing."
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
        handsFreeMeasurementObserved = handsFreeEnabled
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
        if stage.kind == .work, handsFreeEnabled, !handsFreeMeasurementObserved {
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
                handsFreeEnabled: handsFreeEnabled,
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
        guard handsFreeEnabled else {
            lastHandsFreeHaptic = nil
            return
        }
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
        if handsFreeEnabled {
            model.handsFree.arm()
            workMeasurementReady = true
            return true
        }
        do {
            try model.tindeq.startMeasuring()
            workMeasurementReady = true
            return true
        } catch {
            model.errorMessage = error.localizedDescription
            interrupted = true
            model.guidedActivity.end(immediate: true)
            Task { [weak self] in await self?.teardown() }
            return false
        }
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
            Haptics.shared.play(GuidedTransitionHaptics.cue(entering: .complete))
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
                    model.errorMessage = "Could not save the partial pull."
                    interrupted = true
                }
            }
            isAdvancing = false
            await finishGaugeSession()
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
            await finishGaugeSession()
        }
        await settlement.value
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
        let enqueued = await model.saveForceSummary(
            summary,
            tag: savedTag,
            side: savedSide,
            zone: zone,
            preset: preset,
            targetBand: targetPlan.band(forSet: stage.setNumber, side: savedSide),
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

private struct GuidedForceProtocolView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    @ObservedObject var session: GuidedForceProtocolSession
    let onMinimize: () -> Void
    let onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            GeometryReader { geometry in
                let stage = session.run.currentStage
                let elapsed = session.elapsedSeconds(at: context.date)
                let presentation = GuidedForceFullscreenPresentation.stage(
                    stage,
                    preset: session.preset,
                    elapsedSeconds: elapsed,
                    isPaused: session.run.isPaused
                )
                let layout = GuidedForceLayout.resolve(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    textScale: Double(textScale)
                )
                let accent = color(for: presentation.accent)

                ZStack {
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                    accent.opacity(0.14).ignoresSafeArea()
                    protocolContent(
                        geometry: geometry,
                        date: context.date,
                        elapsed: elapsed,
                        presentation: presentation,
                        accent: accent,
                        layout: layout
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    primaryControl(layout: layout, accent: accent)
                        .padding(.horizontal, layout.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, max(8, geometry.safeAreaInsets.bottom))
                        .background(.ultraThinMaterial)
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: presentation.phase
                )
            }
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
        if layout.essentialContentFits {
            protocolSections(
                geometry: geometry,
                date: date,
                elapsed: elapsed,
                presentation: presentation,
                accent: accent,
                layout: layout,
                chartHeight: CGFloat(layout.flexibleChartHeight)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(showsIndicators: false) {
                protocolSections(
                    geometry: geometry,
                    date: date,
                    elapsed: elapsed,
                    presentation: presentation,
                    accent: accent,
                    layout: layout,
                    chartHeight: CGFloat(layout.chartMinimumHeight)
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .top
                )
            }
        }
    }

    private func protocolSections(
        geometry: GeometryProxy,
        date: Date,
        elapsed: Double,
        presentation: GuidedForceStagePresentation,
        accent: Color,
        layout: GuidedForceLayout,
        chartHeight: CGFloat
    ) -> some View {
        VStack(spacing: layout.sectionGap) {
            topBar(elapsed: elapsed)
            phaseBanner(
                presentation,
                remaining: session.remainingSeconds(at: date),
                accent: accent
            )
            statusRow(accent: accent)
            targetCoach
            liveChart(chartHeight: chartHeight)
            controls(date: date)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, max(8, geometry.safeAreaInsets.top))
        .padding(.bottom, max(12, geometry.safeAreaInsets.bottom))
        .frame(maxWidth: 620)
    }

    private func topBar(elapsed: Double) -> some View {
        HStack(spacing: 8) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
            }
            .buttonStyle(GuidedGlassButtonStyle(tint: .primary))
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
                .buttonStyle(GuidedGlassButtonStyle(tint: SendmeterStyle.alert))
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

    private func phaseBanner(
        _ presentation: GuidedForceStagePresentation,
        remaining: Double,
        accent: Color
    ) -> some View {
        VStack(spacing: 8) {
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

            Text(formatCountdown(remaining))
                .font(.system(size: 68, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(accent.opacity(0.72), lineWidth: 2)
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

    private func statusRow(accent: Color) -> some View {
        HStack(spacing: 8) {
            StatusPill(
                session.preset.protocolMode == .reverseAction
                    ? (session.preset.capacityEvidence == true ? "Capacity evidence" : "Execution quality")
                    : "Protocol quality",
                color: accent
            )
            if session.handsFreeEnabled {
                StatusPill(
                    handsFreeStatus.label,
                    color: handsFreeStatus.color
                )
            }
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
                    samples: session.model.tindeq.visibleSamples,
                    targetRange: currentTargetBand?.range,
                    target: currentTargetBand?.kilograms
                )
                .frame(height: chartHeight)
                .layoutPriority(1)
                .accessibilityLabel("Live force trace")
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
                .buttonStyle(GuidedGlassButtonStyle(tint: SendmeterStyle.caution))
                .disabled(session.isPausing)
                .accessibilityHint(session.run.isPaused ? "Resume the hold timer" : "Pause and save the active pull")
            }

            if !session.run.isComplete, !session.interrupted, !session.run.isPaused {
                Button {
                    Task { await session.skip(at: date) }
                } label: {
                    Label("Skip", systemImage: "forward.fill")
                }
                .buttonStyle(GuidedGlassButtonStyle(tint: .primary))
                .disabled(session.isAdvancing || session.isPausing)
                .accessibilityHint("Skip this guided phase")
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryControl(layout: GuidedForceLayout, accent: Color) -> some View {
        Button(action: primaryAction) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(accent.opacity(0.22))
                Circle()
                    .strokeBorder(accent, lineWidth: 3)
                VStack(spacing: 6) {
                    Image(systemName: session.run.isComplete || session.interrupted ? "checkmark" : "stop.fill")
                        .font(.title2.weight(.bold))
                    Text(session.run.isComplete || session.interrupted ? "FINISH" : "STOP")
                        .font(.caption.weight(.black))
                        .tracking(1.2)
                }
                .foregroundStyle(accent)
            }
            .frame(width: layout.actionDiameter, height: layout.actionDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(session.isAdvancing || session.isPausing)
        .accessibilityLabel(
            session.run.isComplete || session.interrupted
                ? "Finish guided protocol"
                : "Stop guided protocol"
        )
        .accessibilityHint("Save the current pull if needed and return to Force")
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

    private func primaryAction() {
        Task {
            await session.stopOrFinish()
            if session.isEnded {
                onClose()
            }
        }
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
}

struct ForceView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("sendmeter.native.force.tag") private var tag = ""
    @AppStorage("sendmeter.native.force.side") private var sideValue = ""
    @AppStorage("sendmeter.native.force.zone") private var zoneValue = ""
    /// #628: the persisted hands-free toggle — the web's
    /// `sendmeter:gauge-hands-free` AppStorage equivalent.
    @AppStorage("sendmeter.native.force.hands-free") private var handsFreeEnabled = false
    @State private var selectedPresetID: UUID?
    @State private var editingPreset: TindeqPreset?
    @State private var creatingPreset = false
    @State private var guidedSession: GuidedForceProtocolSession?
    @State private var guidedFullscreenPresented = false
    @State private var guidedMinimizeRequested = false
    @State private var guidedLaunchInFlight = false
    @State private var selectedTargetPlan = ForceTargetPlan.empty
    @State private var resolvingTargets = false
    @State private var savingSummary = false
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
    /// #710: a maintenance suggestion (Warm-up / Prehab) arms its own guided
    /// preset but is NOT a `ZoneQuality` — it records under a maintenance zone
    /// and never feeds training balance. Kept parallel to `armedZoneQuality`
    /// so exactly one suggested mode (zone quality OR maintenance) can be
    /// armed at a time, mutually exclusive with a saved preset.
    @State private var armedMaintenanceZone: RecordedZone?

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

    /// The persisted zone pick (the metadata card's "Zone" picker). Deliberately
    /// separate from the Focus-Next arm: arming a recommendation never writes
    /// this, so clearing the arm never leaves a stale persisted zone stamp on
    /// unrelated presets or free pulls (#653 review finding 5). The arm's own
    /// zone is derived from the armed preset at save time instead.
    private var zone: RecordedZone? {
        get { RecordedZone(rawValue: zoneValue) }
        nonmutating set { zoneValue = newValue?.rawValue ?? "" }
    }

    private var selectedPreset: TindeqPreset? {
        if let selectedPresetID {
            return model.presets.first(where: { $0.id == selectedPresetID })
        }
        return zoneArmedPreset
    }

    /// The single-armed selection for the metadata card (#710): free hold, a
    /// suggested zone/maintenance protocol, or a saved user preset. Exactly one
    /// mode is armed at a time (web `withZoneSelected`/`withPresetSelected`).
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

    /// The force-curve signal for the Focus-Next tie-break: the cached static
    /// fit for the active tag, if any. Scoped to the tag (both sides) like the
    /// card, matching the web's model for the zone pick.
    private var zoneCurve: ZoneCurveInput? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard let curve = model.tagCurves.first(where: {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                && $0.modality == "static"
        }) else { return nil }
        return ZoneCurveInput(curve)
    }

    /// The native analysis card uses the same all-sides static curve that is
    /// warmed for the session-end RPE prediction. It is intentionally read
    /// from the published cache rather than fitting in the view body.
    private var forceCurve: ForceCurveModel? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return model.tagCurves.first(where: {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                && $0.modality == "static"
        })?.forceCurveModel
    }

    private var progressTag: String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var progressSide: TindeqSide? {
        side == .unspecified ? nil : side
    }

    private var progressForceCurve: ForceCurveModel? {
        progressSide == nil ? forceCurve : sideScopedForceCurve
    }

    /// The zone stamped onto recordings saved under the current selection:
    /// the armed suggestion wins (a guided run's holds carry the zone they
    /// were performed under as a fact — #653 review finding 1), otherwise the
    /// persisted metadata picker's zone. Never persisted itself.
    private var recordingZone: RecordedZone? {
        if let armedZoneQuality {
            return ZoneMix.recordedZone(for: armedZoneQuality)
        }
        if let armedMaintenanceZone {
            return armedMaintenanceZone
        }
        return zone
    }

    private var guidedSessionIsActive: Bool {
        guidedSession != nil
    }

    private var guidedControlsLocked: Bool {
        guidedSessionIsActive || guidedLaunchInFlight
    }

    /// The best single-pull peak for the active tag/side (web `maxF`) — the
    /// fallback reference for the Prehab protocol and the gate for the
    /// maintenance chips when no static fit is cached (#710).
    private var personalRecordForTag: Double? {
        ZoneMix.personalRecordKilograms(recordings: model.recordings, tag: tag, side: side)
    }

    /// #710: the maintenance zones (Warm-up/Prehab) whose guided protocol has a
    /// usable reference right now — passed to the picker so an unavailable chip
    /// is disabled (web `!warmupT`/`!prehabT`).
    private var armableMaintenanceZones: Set<RecordedZone> {
        Set([RecordedZone.warmup, .prehab].filter {
            ZoneMix.maintenancePreset(for: $0, model: zoneCurve, personalRecord: personalRecordForTag) != nil
        })
    }

    /// #653/#710: apply a single-armed selection. Focus Next (recommended
    /// zone) and the RECORDING CONTEXT picker both route through here, so the
    /// mutually-exclusive Free / Suggested / Saved invariant is decided by the
    /// pure reducer `ForceProtocolPicker.next` and applied in one place.
    /// Arming is just a selection — the connection/unsaved-recording guard
    /// belongs to Start, not the pick.
    private func applySelection(_ selection: ForceProtocolSelection) {
        guard !guidedSessionIsActive, !guidedLaunchInFlight else { return }
        switch selection {
        case .free:
            selectedPresetID = nil
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
        case .suggestedZone(let quality):
            zoneArmedPreset = ZoneMix.zonePreset(for: quality)
            armedZoneQuality = quality
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
            selectedPresetID = nil
        case .savedPreset(let id):
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
            selectedPresetID = id
        }
    }

    /// #653: arm the recommended zone's guided protocol for the active tag —
    /// the web's Focus-Next pick path. Routes through `applySelection` so a
    /// recommended zone and any saved preset are mutually exclusive.
    private func armRecommendedZone(_ zone: ZoneQuality) {
        applySelection(.suggestedZone(zone))
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

                    ForceDeviceCard(
                        device: model.tindeq,
                        handsFreeEnabled: $handsFreeEnabled,
                        handsFreeArmed: model.handsFree.isArmed,
                        handsFreeMeasuring: model.handsFree.isMeasuring,
                        guidedSessionActive: guidedControlsLocked,
                        targetBand: selectedTargetPlan.band(forSet: 1, side: side),
                        resolvingTarget: resolvingTargets,
                        savingSummary: savingSummary,
                        gaugeSessionCount: gaugeSessionCount,
                        // #653/#710: an armed suggested protocol (Focus-Next
                        // zone or maintenance) OR a selected saved preset makes
                        // the main Start button launch that guided protocol —
                        // the native equivalent of the web's Start-with-an-
                        // armed-protocol opening the guided timer. With nothing
                        // armed it stays a free pull. `launch` correctly keeps
                        // the picker in sync for a user preset and clears a
                        // suggested arm for a saved one.
                        start: {
                            if let preset = selectedPreset {
                                launch(preset)
                            } else {
                                startMeasurement()
                            }
                        },
                        connect: { model.requestConnect() },
                        armHandsFree: armHandsFree,
                        stopAndSave: stopAndSave,
                        cancelArm: { model.handsFree.cancelArm() },
                        finishSession: {
                            guard !guidedControlsLocked else { return }
                            Task { await model.endGaugeSession() }
                        },
                        saveCompleted: saveCompleted,
                        saveRecovered: saveRecovered,
                        discardCompleted: { model.tindeq.clearCompletedRecording() },
                        discardRecovered: { model.tindeq.clearInterruptedRecording() }
                    )

                    ForceMetadataCard(
                        tag: $tag,
                        side: Binding(get: { side }, set: { side = $0 }),
                        sideMode: sideMode,
                        zone: Binding(get: { zone }, set: { zone = $0 }),
                        selectedTarget: selectedSelection,
                        onSelectTarget: { tapped in
                            // #710: Free hold / suggested zone / suggested
                            // maintenance / saved preset are mutually
                            // exclusive (web `withZoneSelected` /
                            // `withPresetSelected`, #296). The pure reducer
                            // decides the single-armed result; `applySelection`
                            // writes it to the four selection `@State`s.
                            applySelection(
                                ForceProtocolPicker.next(
                                    current: selectedSelection,
                                    tapped: tapped
                                )
                            )
                            publishFreePullContext()
                        },
                        presets: model.presets,
                        knownTags: model.visibleTagNames,
                        selectedName: selectedPreset?.name,
                        maintenanceAvailable: armableMaintenanceZones,
                        recordings: model.recordings.filter { $0.tag == tag },
                        exercise: tag,
                        curveInput: zoneCurve,
                        showsBalance: !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isReverseActionTarget,
                        balanceLocked: model.tindeq.status == .measuring
                            || model.handsFree.isArmed
                            || model.handsFree.isMeasuring
                            || guidedControlsLocked,
                        onPickFocusNext: armRecommendedZone
                    )
                    .disabled(guidedControlsLocked)

                    ForceProgressCardBoundary(
                        recordings: model.recordings,
                        selectedTag: progressTag,
                        selectedSide: progressSide,
                        forceCurve: progressForceCurve,
                        hasLoadedRecordings: model.hasLoadedRecordings,
                        progressRevision: model.forceProgressRevision,
                        curveRevision: sideScopedForceCurveRevision
                    )
                    .equatable()

                    ForceConsistencyCard(
                        recordings: model.recordings,
                        hiddenTags: model.hiddenTagNames,
                        hasLoadedRecordings: model.hasLoadedRecordings
                    )

                    if !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        NativeForceCurveCard(
                            tag: tag,
                            model: forceCurve,
                            hasLoadedRecordings: model.hasLoadedRecordings
                        )
                    }

                    if let live = model.watch.liveForce,
                       live.accountUserID == nil || live.accountUserID == model.currentUserID {
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
                            Haptics.shared.play(.medium)
                            Task { await model.deletePreset(preset) }
                        },
                        disabled: guidedSessionIsActive || guidedLaunchInFlight
                    )

                    RecentForceCard(recordings: Array(model.recordings.prefix(8)))
                }
                .padding()
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
            .onChange(of: side) { _ in publishFreePullContext() }
            .onChange(of: zone) { _ in publishFreePullContext() }
            .onChange(of: selectedPresetID) { _ in publishFreePullContext() }
            .onChange(of: zoneArmedPreset) { _ in publishFreePullContext() }
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
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $creatingPreset) {
                ForcePresetEditor(preset: Self.defaultPreset(), isNew: true)
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .fullScreenCover(isPresented: $guidedFullscreenPresented) {
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
                } else {
                    Color.clear
                }
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
        Haptics.shared.play(RefusedActionHaptics.cue(tappableAndRefused: true))
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

    private func teardownGuidedSessionIfNeeded() {
        guard let session = guidedSession else { return }
        if session.isEnded {
            // A terminal claim cancels the ticker/activity synchronously, but
            // the owner callback must remain registered until its durable
            // flight settles so an auth reset can still join that flight.
            Task {
                await session.teardown()
                guard session.isEnded, guidedSession?.id == session.id else { return }
                clearGuidedSession(session)
            }
            return
        }
        Task {
            await session.teardown()
            guard session.isEnded, guidedSession?.id == session.id else { return }
            clearGuidedSession(session)
        }
    }

    private func startMeasurement() {
        guard !guidedControlsLocked else {
            refuseAction("Resume or end the active guided protocol before starting a free pull.")
            return
        }
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction("Save or discard the previous pull before starting another.")
            return
        }
        do {
            try model.tindeq.startMeasuring()
        } catch {
            refuseAction(error.localizedDescription)
        }
    }

    /// #628: with the hands-free toggle on, Start arms the load-triggered
    /// loop instead of recording immediately.
    private func armHandsFree() {
        guard !guidedControlsLocked else {
            refuseAction("Resume or end the active guided protocol before arming hands-free.")
            return
        }
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction("Save or discard the previous pull before starting another.")
            return
        }
        guard model.tindeq.status == .connected else {
            refuseAction("Connect the Progressor before arming hands-free.")
            return
        }
        publishFreePullContext()
        model.handsFree.arm()
    }

    private func stopAndSave() {
        guard !guidedControlsLocked else {
            refuseAction("Resume or end the active guided protocol before stopping a free pull.")
            return
        }
        // A manual Stop & Save while the hands-free loop owns the rep must go
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
            targetBand: selectedTargetPlan.band(forSet: 1, side: recordedSide)
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

    private func save(_ summary: ForceSummary, recovered: Bool) {
        savingSummary = true
        let savedTag = recovered && !tag.isEmpty ? "\(tag) · Recovered" : tag
        // #720: snapshot the recording context before the await so a stale
        // closure can never write a side invalid under the active mode (repo
        // rule: a decision never reads captured state after an `await`).
        let savedSide = recordedSide
        let savedZone = recordingZone
        let savedPreset = selectedPreset
        let savedTargetBand = selectedTargetPlan.band(forSet: 1, side: savedSide)
        Task {
            let enqueued = await model.saveForceSummary(
                summary,
                tag: savedTag,
                side: savedSide,
                zone: savedZone,
                preset: savedPreset,
                targetBand: savedTargetBand
            )
            if enqueued {
                model.tindeq.clearCompletedRecording()
                if recovered { model.tindeq.clearInterruptedRecording() }
            }
            savingSummary = false
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
            ?? zoneArmedPreset.map { "zone:\($0.name)" }
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
        guard let preset = selectedPreset else {
            selectedTargetPlan = .empty
            resolvingTargets = false
            return
        }
        resolvingTargets = true
        let startSide: TindeqSide = side == .right ? .right : .left
        selectedTargetPlan = await model.resolveForceTargetPlan(
            preset: preset,
            tag: tag,
            startingSide: startSide,
            fallbackSide: side
        )
        resolvingTargets = false
    }

    private func launch(_ preset: TindeqPreset) {
        guard !guidedSessionIsActive, !guidedLaunchInFlight else {
            refuseAction("Resume or end the active guided protocol before starting another.")
            return
        }
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction("Save or discard the previous pull before starting a guided protocol.")
            return
        }
        guard model.tindeq.status == .connected else {
            refuseAction("Connect the Progressor before starting a guided protocol.")
            return
        }
        // #653: only a persisted user preset keeps the metadata picker in
        // sync; a transient Focus-Next zone preset is not in `model.presets`,
        // so it must not clobber `selectedPresetID` (which would read back
        // as "Free pull" and clear the zone arm).
        if model.presets.contains(where: { $0.id == preset.id }) {
            // A user preset and a suggested arm are mutually exclusive
            // (#653 review finding 3, #710): launching a user preset clears
            // the armed zone/maintenance suggestion.
            zoneArmedPreset = nil
            armedZoneQuality = nil
            armedMaintenanceZone = nil
            selectedPresetID = preset.id
        }
        let launchTag = tag
        let launchSide = side
        let launchZone = recordingZone
        let launchHandsFreeEnabled = handsFreeEnabled
        let launchAccountScope = model.accountScope
        let startSide: TindeqSide = launchSide == .right ? .right : .left
        guidedLaunchInFlight = true
        resolvingTargets = true
        Task {
            let plan = await model.resolveForceTargetPlan(
                preset: preset,
                tag: launchTag,
                startingSide: startSide,
                fallbackSide: launchSide
            )
            guard model.accountScope == launchAccountScope,
                  !guidedSessionIsActive,
                  guidedSession == nil
            else {
                guidedLaunchInFlight = false
                resolvingTargets = false
                return
            }
            selectedTargetPlan = plan
            resolvingTargets = false
            let session = GuidedForceProtocolSession(
                model: model,
                preset: preset,
                targetPlan: plan,
                tag: launchTag,
                startingSide: startSide,
                fallbackSide: launchSide,
                zone: launchZone,
                handsFreeEnabled: launchHandsFreeEnabled
            )
            guidedSession = session
            registerGuidedTeardown(for: session)
            guidedMinimizeRequested = false
            guidedLaunchInFlight = false
            guidedFullscreenPresented = true
        }
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(session.isAdvancing || session.isPausing)
                    .accessibilityHint("Reopen the guided protocol without stopping it")
                Button("End", role: .destructive, action: onEnd)
                    .buttonStyle(.bordered)
                    .disabled(session.isAdvancing || session.isPausing)
                    .accessibilityHint("Save the current pull if needed and end this protocol")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ForceDeviceCard: View {
    @ObservedObject var device: TindeqBluetooth
    @Binding var handsFreeEnabled: Bool
    /// #628: the hands-free loop's state, mirrored from AppModel (the loop
    /// re-renders through the device's published sample/status changes).
    let handsFreeArmed: Bool
    let handsFreeMeasuring: Bool
    let guidedSessionActive: Bool
    let targetBand: ForceTargetBand?
    let resolvingTarget: Bool
    let savingSummary: Bool
    let gaugeSessionCount: Int
    let start: () -> Void
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

                if device.status == .measuring || device.handsFreeArmed || !device.visibleSamples.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        MetricValue(
                            device.currentKilograms.formatted(.number.precision(.fractionLength(1))),
                            unit: "kg",
                            color: inTarget ? SendmeterStyle.optimal : .primary
                        )
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("Peak \(device.peakKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                            Text("Average \(device.averageKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                            Text((device.elapsedMilliseconds / 1_000).formatted(.number.precision(.fractionLength(1))) + " s")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    ForceTraceChart(
                        samples: device.visibleSamples,
                        targetRange: targetRange,
                        target: targetBand?.kilograms
                    )
                    .frame(height: 190)
                    .accessibilityLabel("Live force trace")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Text("Ready to measure")
                            .font(.title3.bold())
                        Text("Connect a Tindeq Progressor, tare it, then start a pull.")
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
                        "Guided protocol active — resume or end it above",
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

                if device.interruptedRecording != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Unsaved pull recovered after disconnect", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Button("Save Recovered Pull", action: saveRecovered)
                                .buttonStyle(.borderedProminent)
                                .disabled(savingSummary || guidedSessionActive)
                            Button("Discard", role: .destructive) {
                                discardIsRecovered = true
                                showingDiscardConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(savingSummary || guidedSessionActive)
                        }
                    }
                    .padding(12)
                    .background(SendmeterStyle.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                } else if device.completedSummary != nil, device.status != .measuring {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Completed pull is ready for a durable save", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Button("Save Completed Pull", action: saveCompleted)
                                .buttonStyle(.borderedProminent)
                                .disabled(savingSummary || guidedSessionActive)
                            Button("Discard", role: .destructive) {
                                discardIsRecovered = false
                                showingDiscardConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(savingSummary || guidedSessionActive)
                        }
                    }
                    .padding(12)
                    .background(SendmeterStyle.optimal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert("Discard unsaved pull?", isPresented: $showingDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                // #656: a confirmed destructive action fires the medium tick
                // once per gesture.
                Haptics.shared.play(.medium)
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
        switch device.status {
        case .unavailable:
            Label("Bluetooth is not available for this app.", systemImage: "bluetooth.slash")
                .foregroundStyle(.secondary)
        case .idle, .interrupted:
            Button {
                // #656 (review F1): user-initiated — arms the transport's
                // success/error haptics for this launch.
                connect()
            } label: {
                Label("Connect Progressor", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(PrimaryActionButtonStyle())
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
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                } else if handsFreeArmed {
                    VStack(spacing: 8) {
                        Label("Armed — pull to measure", systemImage: "scope")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Button("Cancel", role: .destructive) {
                            // #656 (review F14): disarming hands-free is a
                            // destructive action — medium tick.
                            Haptics.shared.play(.medium)
                            cancelArm()
                        }
                        .buttonStyle(.bordered)
                    }
                } else if handsFreeEnabled {
                    Button(action: armHandsFree) {
                        Label("Arm Hands-free", systemImage: "scope")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(device.hasUnsavedRecording)
                } else {
                    Button(action: start) {
                        Label("Start Pull", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(device.hasUnsavedRecording)
                }
                if device.hasUnsavedRecording {
                    Text("Save or discard the previous pull before starting another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button {
                        do { try device.tare() } catch { }
                    } label: {
                        Label("Tare", systemImage: "scalemass")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        do { try device.refreshBattery() } catch { }
                    } label: {
                        Label("Battery", systemImage: "battery.100percent")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Disconnect", role: .destructive) { device.disconnect() }
                        .buttonStyle(.borderless)
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
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(savingSummary)
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

private struct ForceMetadataCard: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var tag: String
    @Binding var side: TindeqSide
    /// #720: the active exercise's side-applicability policy. The card only
    /// offers the sides the policy allows — never a hardcoded mode→options map.
    let sideMode: ExerciseSideMode
    @Binding var zone: RecordedZone?
    /// #710: the single-armed selection — `.free`, a suggested zone /
    /// maintenance protocol, or a saved user preset. Exactly one is active at a
    /// time (web `withZoneSelected`/`withPresetSelected`).
    let selectedTarget: ForceProtocolSelection
    /// Called with the tapped target; ForceView runs the pure reducer
    /// `ForceProtocolPicker.next` and applies the single-armed result.
    let onSelectTarget: (ForceProtocolSelection) -> Void
    let presets: [TindeqPreset]
    /// #631: pickable exercise names — distinct recording tags minus hidden
    /// (SL-92). Hidden tags' recordings still exist, they just leave the
    /// default pickers.
    let knownTags: [String]
    /// #710: the armed selection's display name (e.g. "Power" / "Warm-up" /
    /// a saved preset's name), shown as a "Selected:" line.
    let selectedName: String?
    /// #710: the maintenance zones whose guided protocol has a usable CF/PR
    /// right now — an unavailable chip is disabled (web `!warmupT`/`!prehabT`).
    let maintenanceAvailable: Set<RecordedZone>
    /// #710: training balance surfaced inside the protocol-selection context
    /// — tag-filtered recordings + the Focus-Next curve tie-break, mirroring
    /// Capacitor's `TRAINING BALANCE · FDP` card.
    let recordings: [TindeqRecording]
    let exercise: String
    let curveInput: ZoneCurveInput?
    let showsBalance: Bool
    let balanceLocked: Bool
    let onPickFocusNext: (ZoneQuality) -> Void

    private var isFree: Bool { selectedTarget == .free }

    /// The armed suggestion (zone quality or maintenance), if any.
    private var armedSuggestion: SuggestedProtocol? {
        selectedTarget.suggested
    }

    private func isActive(_ suggestion: SuggestedProtocol) -> Bool {
        armedSuggestion == suggestion
    }

    private func suggestionColor(_ suggestion: SuggestedProtocol) -> Color {
        switch suggestion {
        case .zone(let quality):
            return ChartToken.zoneQuality(quality).color(scheme)
        case .maintenance(let zone):
            return zone == .warmup
                ? ChartToken.focus.color(scheme)
                : ChartToken.reference.color(scheme)
        }
    }

    private var sideOptions: [TindeqSide] {
        ExerciseSidePolicy.allowedSides(sideMode)
    }

    /// Show the side selector only when the exercise offers more than one
    /// concrete side. Bilateral-only (one concrete side) and not-applicable
    /// (none) hide it — the save path stamps the canonical side instead.
    private var sidePickerShown: Bool {
        sideOptions.filter { $0 != .unspecified }.count > 1
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Recording context", systemImage: "tag")
                TextField("Exercise or grip, e.g. 20 mm half crimp", text: $tag)
                    .textInputAutocapitalization(.sentences)
                    .padding(11)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                if !knownTags.isEmpty {
                    Picker("Known exercises", selection: $tag) {
                        Text("Type your own").tag("")
                        ForEach(knownTags, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    if sidePickerShown {
                        Picker("Side", selection: $side) {
                            ForEach(sideOptions) { side in
                                Text(side.label).tag(side)
                            }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                    }
                    Picker("Zone", selection: $zone) {
                        Text("Not set").tag(Optional<RecordedZone>.none)
                        ForEach(RecordedZone.allCases, id: \.self) { zone in
                            Text(zone.displayLabel).tag(Optional(zone))
                        }
                    }
                    .pickerStyle(.menu)
                }

                protocolSection

                // #710: the training-balance surface lives in the protocol-
                // selection context (Capacitor `TRAINING BALANCE · FDP`) and
                // draws its own divider once it has a recommendation (no bare
                // Divider when `ZoneFocusCard` is empty).
                if showsBalance {
                    ZoneFocusCard(
                        recordings: recordings,
                        exercise: exercise,
                        curveInput: curveInput,
                        onPick: onPickFocusNext,
                        locked: balanceLocked
                    )
                }
            }
        }
    }

    /// #710: Free hold / Suggested (colored training-type chips) / Saved are
    /// mutually exclusive. Each chip reports the target it represents; the
    /// pure `ForceProtocolPicker.next` reducer in ForceView decides whether the
    /// tap deselects (tapping the active chip) or clears the other two. Rendered
    /// as native tinted chips, not web CSS, using the same hue families as
    /// Capacitor's `QUALITY_COLORS` (Power orange, Strength gold, Pow End
    /// lavender, Endurance blue, Warm-up purple, Prehab neutral).
    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protocol")
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)

            protocolChip(
                "Free hold",
                color: .secondary,
                active: isFree,
                action: { onSelectTarget(.free) }
            )

            Text("Suggested")
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            chipFlow {
                ForEach(ZoneQuality.allCases) { quality in
                    let suggestion = SuggestedProtocol.zone(quality)
                    protocolChip(
                        quality.label,
                        color: suggestionColor(suggestion),
                        active: isActive(suggestion),
                        action: { onSelectTarget(.suggestedZone(quality)) }
                    )
                }
            }

            chipFlow {
                ForEach([RecordedZone.warmup, .prehab], id: \.self) { zone in
                    let suggestion = SuggestedProtocol.maintenance(zone)
                    protocolChip(
                        zone.displayLabel,
                        color: suggestionColor(suggestion),
                        active: isActive(suggestion),
                        action: { onSelectTarget(.suggestedMaintenance(zone)) }
                    )
                    .disabled(!maintenanceAvailable.contains(zone))
                }
            }

            if let selectedName {
                Text("Selected: \(selectedName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !presets.isEmpty {
                Text("Saved")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                chipFlow {
                    ForEach(presets) { preset in
                        protocolChip(
                            preset.name,
                            color: SendmeterStyle.primary,
                            active: selectedTarget == .savedPreset(preset.id),
                            action: { onSelectTarget(.savedPreset(preset.id)) }
                        )
                    }
                }
            }
        }
    }

    /// A wrapping row of coloured protocol chips (#710).
    private func chipFlow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        FlowLayout(spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One coloured protocol chip. Active = solid hue fill, inactive =
    /// tinted surface with a coloured label — the native analogue of the web
    /// `BoxChip` selected/inactive fill states.
    private func protocolChip(
        _ label: String,
        color: Color,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(active ? Color.white : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    active ? color : color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(active ? 0 : 0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityLabel(label)
        .accessibilityValue(active ? "Selected" : "Not selected")
    }
}

/// #710: a minimal horizontal flow layout so the coloured protocol chips wrap
/// onto a new line instead of overflowing a narrow iPhone width — the native
/// analogue of the web's `flexWrap: "wrap"` BoxChip row. iOS 16+ (`Layout`
/// protocol).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for (itemOffset, subviewIndex) in row.items.enumerated() {
                let size = row.sizes[itemOffset]
                subviews[subviewIndex].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            if !current.items.isEmpty,
               current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            if current.items.isEmpty {
                current.height = size.height
            }
            current.items.append(index)
            current.sizes.append(size)
            current.width += (current.items.count == 1 ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

struct ForceTraceChart: View {
    let samples: [TindeqSample]
    let targetRange: ClosedRange<Double>?
    let target: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let maxSample = samples.map(\.kilograms).max() ?? 0
            let maxValue = max(10, max(maxSample, targetRange?.upperBound ?? 0)) * 1.15
            let firstTime = samples.first?.milliseconds ?? 0
            let lastTime = max(firstTime + 1, samples.last?.milliseconds ?? firstTime + 1)
            let gridColor = ChartToken.grid.color(scheme)
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
                    with: .color(optimalColor.opacity(ChartToken.optimal.bandOpacity(scheme)))
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

            guard samples.count > 1 else { return }
            var trace = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: x(sample.milliseconds), y: y(sample.kilograms))
                if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
            }
            context.stroke(
                trace,
                with: .color(ChartToken.force.color(scheme)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        .buttonStyle(.bordered)
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
                            .buttonStyle(.plain)
                            Menu {
                                Button { run(preset) } label: { Label("Run", systemImage: "play.fill") }
                                Button { edit(preset) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { delete(preset) } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
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
    @EnvironmentObject private var model: AppModel
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

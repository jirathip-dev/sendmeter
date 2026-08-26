import AudioToolbox
import Foundation
import SendmeterCore
import SwiftUI
#if canImport(AVFAudio)
import AVFAudio
#endif

struct WorkoutView: View {
    @Environment(AppModel.self) private var model
    @State private var engine: PhoneWorkoutEngine?
    @State private var showRoutineEditor = false
    @State private var runningRoutine: RoutineRunPresentation?
    @State private var isSaving = false
    @State private var activeSaveID: UUID?
    @State private var showManualWorkout = false
    @State private var hasResolvedPersistedRun = false
    @AppStorage(ManualWorkoutRest.restTargetKey)
    private var storedRestTarget = ManualWorkoutRest.defaultRestTarget

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let live = model.liveWorkout {
                        WatchWorkoutMirrorCard(workout: live)
                    }
                    if engine == nil {
                        StartWorkoutCard(start: startWorkout)
                        RoutineLibraryCard(
                            run: { preset in
                                // #656: a tap opening a sheet arms the
                                // presentation tick.
                                Haptics.shared.tap()
                                runningRoutine = RoutineRunPresentation(preset: preset, restored: nil)
                            },
                            edit: {
                                // #656: see `run:` above.
                                Haptics.shared.tap()
                                showRoutineEditor = true
                            }
                        )
                    } else {
                        ActiveWorkoutCard(
                            engine: $engine,
                            isSaving: isSaving,
                            finish: finishWorkout,
                            openFullscreen: resumeWorkout
                        )
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Workout")
            .sheet(isPresented: $showRoutineEditor) {
                RoutineEditorSheet()
                    .sendmeterSheetPresentation()
            }
            .sheet(item: $runningRoutine) { presentation in
                RoutineRunnerSheet(presentation: presentation)
                    .sendmeterSheetPresentation(
                        id: presentation.id.uuidString,
                        dragToDismiss: false
                    )
            }
            .fullScreenCover(isPresented: $showManualWorkout, onDismiss: { Haptics.shared.sheetDismissed() }) {
                ManualWorkoutFullscreen(
                    engine: $engine,
                    isSaving: isSaving,
                    restTarget: restTarget,
                    onRestTargetChange: { target in
                        storedRestTarget = ManualWorkoutRest.validatedTarget(target)
                    },
                    onMinimize: { showManualWorkout = false },
                    onEnd: finishWorkout
                )
                .environment(model)
                .onAppear { Haptics.shared.sheetPresented() }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .manualWorkoutActivityAction)
            ) { _ in
                drainManualWorkoutActions()
            }
            .onAppear {
                drainManualWorkoutActions()
                model.manualWorkoutRest.update(engine: engine, restTarget: restTarget)
            }
            .onChange(of: engine) { newEngine in
                model.manualWorkoutRest.update(engine: newEngine, restTarget: restTarget)
                model.manualWorkoutActivity.sync(engine: newEngine, restTarget: restTarget)
            }
            .onChange(of: storedRestTarget) { _ in
                model.manualWorkoutRest.update(engine: engine, restTarget: restTarget)
                model.manualWorkoutActivity.sync(engine: engine, restTarget: restTarget)
            }
            .task {
                guard !hasResolvedPersistedRun else { return }
                hasResolvedPersistedRun = true
                await resolvePersistedRoutineRun()
            }
        }
    }

    /// A routine to present: the preset to run plus the wall-clock state of
    /// an interrupted run to restore into it (nil for a fresh start). The
    /// pair is atomic — a stale restored record can never seed a fresh run.
    fileprivate struct RoutineRunPresentation: Identifiable {
        let preset: RoutinePreset
        let restored: PersistedRoutineRun?
        var id: UUID { preset.id }
    }

    /// The launch-time decision for a run left in progress when the app was
    /// last killed (#633) — mirrors the web's RoutineCard mount effect
    /// (resolveRoutineResume): auto-resume a genuinely in-progress run, log
    /// a completed/partial run the heartbeat confirms, and always surface a
    /// discard visibly rather than silently dropping training.
    @MainActor
    private func resolvePersistedRoutineRun() async {
        let store = RoutineRunStore()
        guard let persisted = store.load() else { return }
        // The resume decision needs the preset's stages to compute its total;
        // wait (bounded) for the routine presets to finish loading.
        let deadline = Date().addingTimeInterval(5)
        while model.routines.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let preset = model.routines.first(where: { $0.id == persisted.presetID }) else {
            // The preset the interrupted run belonged to was deleted. Only
            // resolve as deleted once the presets actually loaded — an
            // offline launch must keep the record (the web keeps a dangling
            // run until a successful fetch resolves it; the next launch
            // self-heals).
            guard !model.routines.isEmpty else { return }
            store.clear()
            model.toastMessage = "Interrupted routine's preset was deleted — nothing logged"
            return
        }
        // The user already started something — the persisted run is superseded.
        guard runningRoutine == nil else {
            store.clear()
            return
        }
        let totalS = RoutineEngine.stages(for: preset).reduce(0) { $0 + $1.durationSeconds }
        switch RoutineGate.resolveRoutineResume(
            run: persisted,
            totalSeconds: totalS,
            nowMs: Date().millisecondsSince1970
        ) {
        case .none:
            break
        case .resume:
            runningRoutine = RoutineRunPresentation(preset: preset, restored: persisted)
        case .logged(let outcome):
            store.clear()
            applyPersistedOutcome(outcome, preset: preset)
        }
    }

    /// Applies a resume-time RoutineLogOutcome (#633) — the web's
    /// applyLogOutcome: completed/partial auto-log with the web's notes, and
    /// a discarded outcome stays visible.
    private func applyPersistedOutcome(
        _ outcome: RoutineGate.RoutineLogOutcome,
        preset: RoutinePreset
    ) {
        switch outcome {
        case .completed(let durationMin):
            logRoutineSession(
                durationMin: durationMin,
                typeLabel: preset.name,
                note: "\(preset.name) (auto-logged)",
                offerUndo: true
            )
        case .partial(let durationMin):
            logRoutineSession(
                durationMin: durationMin,
                typeLabel: preset.name,
                note: "\(preset.name) (partial, interrupted)",
                offerUndo: true
            )
        case .discarded:
            model.toastMessage = "Routine interrupted — too little of it was confirmed to log"
        }
    }

    private func logRoutineSession(
        durationMin: Int,
        typeLabel: String,
        note: String,
        offerUndo: Bool = false
    ) {
        enqueueRoutineSession(
            model: model,
            durationMin: durationMin,
            typeLabel: typeLabel,
            note: note,
            offerUndo: offerUndo
        )
    }

    private func startWorkout() {
        guard !isSaving else { return }
        guard let userID = model.currentUserID else { return }
        Haptics.shared.tap()
        let newEngine = PhoneWorkoutEngine(
            accountUserID: userID,
            phase: model.settings.currentPhase,
            startedAt: Date()
        )
        engine = newEngine
        model.manualWorkoutActivity.start(engine: newEngine, restTarget: restTarget)
        model.manualWorkoutRest.update(engine: newEngine, restTarget: restTarget)
        showManualWorkout = true
        Task { await model.manualWorkoutRest.requestNotificationPermissionIfNeeded() }
    }

    private func resumeWorkout() {
        guard engine != nil, !isSaving else { return }
        Haptics.shared.tap()
        model.manualWorkoutRest.update(engine: engine, restTarget: restTarget)
        showManualWorkout = true
    }

    private func finishWorkout() {
        guard !isSaving else { return }
        guard var engine else { return }
        do {
            let draft = try engine.finish()
            // #656 (re-review): the accepted medium tick fires only once the
            // finish is real — an empty-workout refusal below must play the
            // warning pattern, never the accepted tick.
            Haptics.shared.playGesture(.medium)
            model.manualWorkoutRest.stop()
            model.manualWorkoutActivity.end(immediate: true)
            model.manualWorkoutActivity.discardPendingEvents()
            showManualWorkout = false
            self.engine = nil
            let saveID = UUID()
            activeSaveID = saveID
            isSaving = true
            Task { @MainActor in
                await model.saveWorkout(draft)
                guard activeSaveID == saveID else { return }
                activeSaveID = nil
                isSaving = false
            }
        } catch WorkoutEngineError.emptyWorkout {
            model.errorMessage = UserFacingError.message(for: .missingAttempt)
            // #222: the Finish button is deliberately kept clickable so the
            // tap can say why — a refused finish must not feel accepted.
            Haptics.shared.playGesture(RefusedActionHaptics.cue(tappableAndRefused: true))
        } catch {
            model.errorMessage = UserFacingError.message(for: error)
        }
    }

    private var restTarget: Int {
        ManualWorkoutRest.validatedTarget(storedRestTarget)
    }

    /// Replay lock-screen intent taps into the authoritative engine. The
    /// event identity keeps a stale event from replaying into a newer workout;
    /// the engine's own guards make duplicates/no-ops safe. If the workout is
    /// gone, the whole queue is discarded.
    private func drainManualWorkoutActions() {
        let events = model.manualWorkoutActivity.drainPendingEvents(
            forWorkoutStartedAt: engine?.draft.startedAt
        )
        guard let engine else { return }
        let current = ManualWorkoutActivityReplay.applying(events, to: engine)
        guard current != engine else { return }
        self.engine = current
        model.manualWorkoutActivity.refresh(engine: current, restTarget: restTarget)
    }
}

@MainActor
private func enqueueRoutineSession(
    model: AppModel,
    durationMin: Int,
    typeLabel: String,
    note: String,
    offerUndo: Bool
) {
    let draft = SessionDraft(
        date: LocalDateSupport.string(from: Date()),
        type: "routine",
        typeLabel: typeLabel,
        durationMinutes: durationMin,
        rpe: 4,
        note: note,
        phase: model.settings.currentPhase
    )
    let appModel = model
    Task { @MainActor in
        guard let receipt = await appModel.logSession(draft) else { return }
        appModel.toastMessage = "Routine logged · \(durationMin) min"
        guard offerUndo else { return }
        appModel.toastAction = AppToastAction(label: "Undo") {
            Task { @MainActor in
                await appModel.undoSession(receipt)
            }
        }
    }
}

private struct StartWorkoutCard: View {
    let start: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(spacing: 18) {
                Image(systemName: "figure.climbing")
                    .font(.system(size: 52))
                    .foregroundStyle(SendmeterStyle.primary)
                VStack(spacing: 6) {
                    Text("Manual workout")
                        .font(.title2.bold())
                    Text("Start once, tap for each attempt, then finish. The complete workout is written atomically and appears in History immediately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Start Manual workout", action: start)
                    .hapticButtonStyle(PrimaryActionButtonStyle())
            }
        }
    }
}

private struct ActiveWorkoutCard: View {
    @Environment(AppModel.self) private var model
    @Binding var engine: PhoneWorkoutEngine?
    let isSaving: Bool
    let finish: () -> Void
    let openFullscreen: () -> Void

    private var isAttempting: Bool { engine?.attemptStartedAt != nil }

    var body: some View {
        SurfaceCard {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 18) {
                    HStack {
                        SectionLabel("Manual workout", systemImage: "timer")
                        Spacer()
                        StatusPill(isAttempting ? "Climbing" : "Resting", color: isAttempting ? SendmeterStyle.power : SendmeterStyle.optimal)
                    }

                    if let engine {
                        Text(durationString(context.date.timeIntervalSince(engine.draft.startedAt)))
                            .modifier(SendmeterStyle.countdownMetric(baseSize: 52))
                        HStack(spacing: 28) {
                            metric("Attempts", "\(engine.draft.attempts.count)")
                            metric("RPE", engine.draft.rpe.formatted(.number.precision(.fractionLength(0...1))))
                            metric("Block", PhaseCatalog.definition(for: engine.draft.phase).name)
                        }

                        Button(action: openFullscreen) {
                            Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .hapticButtonStyle(.bordered)
                        .accessibilityHint("Resume the immersive Manual workout timer")

                        Button {
                            var copy = engine
                            do {
                                if copy.attemptStartedAt == nil {
                                    try copy.startAttempt()
                                } else {
                                    _ = try copy.endAttempt()
                                }
                                self.engine = copy
                            } catch {
                                model.errorMessage = UserFacingError.message(for: error)
                            }
                        } label: {
                            Label(
                                isAttempting ? "End Attempt" : "Start Attempt",
                                systemImage: isAttempting ? "stop.fill" : "play.fill"
                            )
                        }
                        .hapticButtonStyle(PrimaryActionButtonStyle())
                        .tint(isAttempting ? SendmeterStyle.alert : SendmeterStyle.primary)

                        HStack {
                            Text("Session RPE")
                            Slider(
                                value: Binding(
                                    get: { self.engine?.draft.rpe ?? 7 },
                                    set: { value in
                                        guard var copy = self.engine else { return }
                                        copy.setRPE(value)
                                        self.engine = copy
                                    }
                                ),
                                in: 1...10,
                                step: 0.5
                            )
                        }

                        Button(role: .destructive, action: finish) {
                            HStack {
                                if isSaving { ProgressView() }
                                Text("Finish Manual workout")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .hapticButtonStyle(.bordered)
                        .disabled(isSaving)
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct WatchWorkoutMirrorCard: View {
    @Environment(AppModel.self) private var model
    let workout: LiveWorkout

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Apple Watch Workout", systemImage: "applewatch")
                        .font(.headline)
                    Spacer()
                    StatusPill(workout.climbing ? "Climbing" : "Live", color: SendmeterStyle.optimal)
                }
                HStack(spacing: 26) {
                    value("Attempts", "\(workout.attemptCount)")
                    value("Heart rate", workout.heartRate.map { "\(Int($0)) bpm" } ?? "—")
                    value("Energy", workout.activeKilocalories.map { "\(Int($0)) kcal" } ?? "—")
                }
                Text("\(transportLabel) · updated \(workout.updatedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transportLabel: String {
        switch model.liveWorkoutSyncState {
        case .watchDirect: return "Direct WatchConnectivity mirror"
        case .serverFallback: return "Server mirror"
        case .temporarilyUnreachable: return "Link paused"
        case .unknown: return "Mirror"
        }
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RoutineLibraryCard: View {
    @Environment(AppModel.self) private var model
    let run: (RoutinePreset) -> Void
    let edit: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Routines", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Button(action: edit) { Image(systemName: "plus.circle") }
                }
                if model.routines.isEmpty {
                    Text("Create a guided warm-up, rehab, or conditioning timer.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Create Routine", action: edit)
                        .hapticButtonStyle(.bordered)
                } else {
                    ForEach(model.routines) { routine in
                        Button { run(routine) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(routine.name).font(.headline)
                                    Text("\(routine.steps.count) step\(routine.steps.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                            }
                        }
                        .hapticButtonStyle(.plain)
                        if routine.id != model.routines.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct RoutineRunnerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let routine: RoutinePreset
    private let restored: PersistedRoutineRun?
    private let store = RoutineRunStore()
    @State private var run: RoutineRun
    /// Wall-clock record of the run (#633) — the persistence shape mirrored
    /// from the web's `sendmeter:routine-run` (startedMs + pause bookkeeping
    /// + lastSeenMs heartbeat). Written on every structural change and every
    /// ~5s heartbeat while ticking, so a killed app can resume the run; read
    /// at log time for the honest elapsed the ≥60s gate and partial-minute
    /// clamping operate on.
    @State private var wallClock: PersistedRoutineRun
    @State private var exitGate = RoutineGate.ExitGate()
    @State private var audioCues = RoutineAudioCueController()
    @State private var audioMuted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(presentation: WorkoutView.RoutineRunPresentation) {
        self.routine = presentation.preset
        self.restored = presentation.restored
        let now = Date()
        self._run = State(initialValue: RoutineRun(
            preset: presentation.preset,
            restoring: presentation.restored,
            at: now
        ))
        self._wallClock = State(initialValue: presentation.restored ?? PersistedRoutineRun(
            presetID: presentation.preset.id,
            startedMs: now.millisecondsSince1970,
            skippedS: 0,
            pausedAtMs: nil,
            pausedTotalMs: 0,
            lastSeenMs: now.millisecondsSince1970
        ))
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                GeometryReader { geometry in
                    let snapshot = RoutineRunnerSnapshot(
                        run: run,
                        preset: routine,
                        wallClock: wallClock,
                        at: context.date
                    )
                    runnerScreen(snapshot: snapshot, viewport: geometry.size, date: context.date)
                        .task(id: Int(context.date.timeIntervalSince1970 * 4)) {
                            processTimeline(at: context.date)
                        }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // A routine must leave through the classified Close path. A
            // swipe-dismiss otherwise skips the >=60s partial/discard
            // decision and can clear a real run without telling the user.
            .interactiveDismissDisabled()
            .onAppear {
                let now = Date()
                if restored == nil { run.start(at: now) }
                wallClock = wallClock.heartbeat(atMs: now.millisecondsSince1970)
                store.save(wallClock)
                audioCues.reanchor(
                    stage: run.currentStage,
                    remainingSeconds: run.remainingSeconds(at: now)
                )
            }
            .onDisappear {
                audioCues.suspend()
                // An unclaimed system/parent disappearance must leave the
                // durable run intact. The classified paths clear before
                // dismissing; this is only a guarded backstop.
                guard exitGate.shouldClearPersistenceOnDisappear else { return }
                store.clear()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    audioCues.reanchor(
                        stage: run.currentStage,
                        remainingSeconds: run.remainingSeconds(at: Date())
                    )
                case .inactive, .background:
                    audioCues.suspend()
                @unknown default:
                    audioCues.suspend()
                }
            }
        }
    }

    @ViewBuilder
    private func runnerScreen(
        snapshot: RoutineRunnerSnapshot,
        viewport: CGSize,
        date: Date
    ) -> some View {
        ZStack {
            snapshot.visualState.backgroundColor
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    topContext(snapshot: snapshot)
                    phaseHeader(snapshot: snapshot)
                    countdownDisc(snapshot: snapshot, viewport: viewport)
                    progressContext(snapshot: snapshot)
                    nextPhase(snapshot: snapshot)
                    audioControl
                    controls(snapshot: snapshot, date: date)
                }
                .padding(.horizontal, 16)
                .padding(.top, max(10, viewport.height * 0.025))
                .padding(.bottom, max(18, viewport.height * 0.035))
                .frame(minHeight: viewport.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: snapshot.visualState
        )
    }

    private func topContext(snapshot: RoutineRunnerSnapshot) -> some View {
        HStack(spacing: 12) {
            Button {
                closeRoutine()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .hapticButtonStyle(RoutineRunnerGlassButtonStyle(tint: SendmeterStyle.alert))
            .accessibilityHint("Close the routine and classify the run")

            VStack(alignment: .trailing, spacing: 2) {
                Text(routine.name)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text("Elapsed \(formatTime(snapshot.actualElapsedSeconds))")
                    .font(.caption.monospacedDigit())
                    .opacity(0.78)
            }
            .foregroundStyle(snapshot.visualState.foregroundColor)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(snapshot.visualState.foregroundColor.opacity(0.2), lineWidth: 1)
        }
    }

    private func phaseHeader(snapshot: RoutineRunnerSnapshot) -> some View {
        VStack(spacing: 4) {
            Text(snapshot.visualState.title)
                .font(.title2.weight(.black))
                .tracking(2.2)
                .foregroundStyle(snapshot.visualState.foregroundColor)

            if !snapshot.isComplete {
                Text(snapshot.current.stage.label)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.9))
                    .lineLimit(1)
                if let detail = snapshot.current.stage.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.72))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("Routine complete")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.9))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            snapshot.visualState.title + ". "
                + (snapshot.isComplete ? "Routine complete" : snapshot.current.stage.label)
        )
    }

    private func countdownDisc(
        snapshot: RoutineRunnerSnapshot,
        viewport: CGSize
    ) -> some View {
        let widthBound = max(190, min(292, viewport.width - 48))
        let heightBound = max(190, min(292, viewport.height * 0.38))
        let diameter = min(widthBound, heightBound)
        let remainingFraction = snapshot.isComplete ? 1 : snapshot.currentRemainingFraction

        return ZStack {
            Circle()
                .fill(snapshot.visualState.backgroundColor.opacity(0.32))
                .blur(radius: 24)
                .frame(width: diameter * 0.88, height: diameter * 0.88)

            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle().fill(snapshot.visualState.backgroundColor.opacity(0.18))
                }

            Circle()
                .stroke(snapshot.visualState.foregroundColor.opacity(0.18), lineWidth: 7)

            Circle()
                .trim(from: 0, to: remainingFraction)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: snapshot.visualState.ringColors),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 5) {
                Text(snapshot.isComplete ? "DONE" : formatTime(snapshot.currentRemainingSeconds))
                    .modifier(SendmeterStyle.countdownMetric(baseSize: 80))
                    .foregroundStyle(snapshot.visualState.foregroundColor)
                    .accessibilityLabel(
                        snapshot.isComplete
                            ? "Routine complete"
                            : "\(formatTime(snapshot.currentRemainingSeconds)) remaining"
                    )
                if !snapshot.isComplete {
                    Text(snapshot.isPaused ? "Timer paused" : "Remaining")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.72))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
    }

    private func progressContext(snapshot: RoutineRunnerSnapshot) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                contextMetric(
                    "Step",
                    snapshot.stageCount == 0 || snapshot.current.stepNumber == 0
                        ? "—"
                        : "\(snapshot.current.stepNumber)/\(snapshot.current.stepCount)",
                    color: snapshot.visualState.foregroundColor
                )
                contextMetric(
                    "Rep",
                    snapshot.current.repetitionCount == 0
                        ? "—"
                        : "\(snapshot.current.repetitionNumber)/\(snapshot.current.repetitionCount)",
                    color: snapshot.visualState.foregroundColor
                )
                contextMetric(
                    "To go",
                    snapshot.current.repetitionCount == 0 ? "—" : "\(snapshot.current.repetitionsRemaining)",
                    color: snapshot.visualState.foregroundColor
                )
            }

            HStack {
                Text("Elapsed \(formatTime(snapshot.actualElapsedSeconds))")
                Spacer(minLength: 8)
                Text("\(formatTime(snapshot.timelineRemainingSeconds)) remaining")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.78))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(snapshot.visualState.foregroundColor.opacity(0.16), lineWidth: 1)
        }
    }

    private func contextMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .opacity(0.68)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func nextPhase(snapshot: RoutineRunnerSnapshot) -> some View {
        if let next = snapshot.next {
            let nextColor = next.stage.kind == .rest ? SendmeterStyle.caution : SendmeterStyle.primary
            let nextText = next.stage.kind == .rest ? Color(hex: "#1A1A1A") : Color.white
            HStack(spacing: 8) {
                Text("NEXT")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.68))
                Text(next.stage.kind == .rest ? "Rest" : next.stage.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(nextText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(nextColor, in: Capsule())
                Text(nextDetail(next))
                    .font(.caption)
                    .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(snapshot.visualState.foregroundColor.opacity(0.14), lineWidth: 1)
            }
        } else if !snapshot.isComplete {
            Text("NEXT · Finish routine")
                .font(.caption.weight(.medium))
                .foregroundStyle(snapshot.visualState.foregroundColor.opacity(0.66))
        }
    }

    private func nextDetail(_ next: RoutineRunnerStageContext) -> String {
        if next.stage.kind == .rest {
            return next.stage.detail ?? "Recover before the next rep"
        }
        return "Rep \(next.repetitionNumber) of \(next.repetitionCount)"
    }

    private var audioControl: some View {
        let status = audioStatus
        return Button {
            guard status != .unavailable else { return }
            audioMuted.toggle()
            audioCues.reanchor(
                stage: run.currentStage,
                remainingSeconds: run.remainingSeconds(at: Date())
            )
        } label: {
            Label(status.label, systemImage: status.systemImage)
        }
        .hapticButtonStyle(RoutineRunnerGlassButtonStyle(tint: currentForeground))
        .disabled(status == .unavailable)
        .accessibilityLabel(status.label)
        .accessibilityHint(status == .unavailable ? "Audio is not available right now" : "Toggle routine audio cues")
    }

    @ViewBuilder
    private func controls(
        snapshot: RoutineRunnerSnapshot,
        date: Date
    ) -> some View {
        if snapshot.isComplete {
            Button {
                closeRoutine()
            } label: {
                Label("Log Routine", systemImage: "checkmark.circle.fill")
            }
            .hapticButtonStyle(RoutineRunnerGlassButtonStyle(tint: snapshot.visualState.foregroundColor))
            .accessibilityHint("Log the completed routine and close")
        } else {
            HStack(spacing: 10) {
                Button {
                    togglePause(at: date)
                } label: {
                    Label(
                        snapshot.isPaused ? "Resume" : "Pause",
                        systemImage: snapshot.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .hapticButtonStyle(RoutineRunnerGlassButtonStyle(tint: snapshot.visualState.foregroundColor))

                Button {
                    skip(at: date)
                } label: {
                    Label("Skip", systemImage: "forward.fill")
                }
                .hapticButtonStyle(RoutineRunnerGlassButtonStyle(tint: snapshot.visualState.foregroundColor))
            }
        }
    }

    private var currentForeground: Color {
        if run.isComplete { return RoutineRunnerVisualState.done.foregroundColor }
        if run.isPaused { return RoutineRunnerVisualState.paused.foregroundColor }
        return run.currentStage.kind == .rest
            ? RoutineRunnerVisualState.rest.foregroundColor
            : RoutineRunnerVisualState.working.foregroundColor
    }

    private var audioStatus: RoutineAudioStatus {
        #if canImport(AVFAudio)
        let session = AVAudioSession.sharedInstance()
        return RoutineAudioPolicy.status(
            userMuted: audioMuted,
            systemMuted: session.outputVolume <= 0.001,
            systemAvailable: scenePhase == .active && !session.secondaryAudioShouldBeSilencedHint
        )
        #else
        return .unavailable
        #endif
    }

    private func processTimeline(at date: Date) {
        if !run.isPaused, !run.isComplete, run.remainingSeconds(at: date) <= 0 {
            playAudio(audioCues.phaseEnded(stageID: run.currentStage.id))
        }

        _ = run.advanceIfNeeded(at: date)
        if run.isComplete {
            audioCues.suspend()
        } else {
            playAudio(
                audioCues.observe(
                    stage: run.currentStage,
                    remainingSeconds: run.remainingSeconds(at: date),
                    isPaused: run.isPaused
                )
            )
        }
        stampHeartbeat(at: date)
    }

    private func playAudio(_ cue: RoutineAudioCue?) {
        guard let cue, RoutineAudioPolicy.shouldPlay(cue, status: audioStatus) else { return }
        let soundID: SystemSoundID
        switch cue {
        case .clockTick:
            soundID = SystemSoundID(1104)
        case .countdown:
            soundID = SystemSoundID(1103)
        case .phaseEnd:
            soundID = SystemSoundID(1057)
        }
        // System sounds are intentionally best-effort. Silent mode, Focus,
        // another audio session, or device settings may suppress them.
        AudioServicesPlaySystemSound(soundID)
    }

    private func togglePause(at date: Date) {
        let nowMs = date.millisecondsSince1970
        if run.isPaused {
            run.resume(at: date)
            wallClock = wallClock.resumed(atMs: nowMs)
            audioCues.reanchor(
                stage: run.currentStage,
                remainingSeconds: run.remainingSeconds(at: date)
            )
        } else {
            audioCues.suspend()
            run.pause(at: date)
            wallClock = wallClock.paused(atMs: nowMs)
        }
        store.save(wallClock)
    }

    private func skip(at date: Date) {
        let remaining = run.remainingSeconds(at: date)
        audioCues.skipped(stageID: run.currentStage.id)
        run.skip(at: date)
        wallClock = wallClock.skipped(remaining, atMs: date.millisecondsSince1970)
        store.save(wallClock)
        audioCues.reanchor(
            stage: run.currentStage,
            remainingSeconds: run.remainingSeconds(at: date)
        )
    }

    /// Heartbeat (#633): confirm the run is actually on-screen and ticking by
    /// stamping `lastSeenMs` — throttled to ~`RoutineGate.heartbeatMs`, so a
    /// run killed at the very end is distinguishable from one abandoned
    /// minutes ago on the next launch.
    private func stampHeartbeat(at date: Date) {
        guard !run.isPaused, !run.isComplete else { return }
        let nowMs = date.millisecondsSince1970
        guard nowMs - wallClock.lastSeenMs >= RoutineGate.heartbeatMs else { return }
        wallClock = wallClock.heartbeat(atMs: nowMs)
        store.save(wallClock)
    }

    /// Close/X is an interruption unless the completion screen is already
    /// showing. A completed run uses this same path as the visible Done
    /// button, including the one-minute floor for a sub-minute routine. It
    /// uses real elapsed only, so skipped timeline credit cannot fabricate a
    /// partial session.
    private func closeRoutine() {
        let now = Date()
        let totalS = RoutineEngine.stages(for: routine).reduce(0) { $0 + $1.durationSeconds }
        guard let decision = exitGate.claim(
            isComplete: run.isComplete,
            elapsedSeconds: RoutineGate.realElapsedS(
                wallClock,
                nowMs: now.millisecondsSince1970
            ),
            totalSeconds: totalS
        ) else { return }

        audioCues.suspend()
        store.clear()
        switch decision {
        case .completed(let durationMin):
            enqueueRoutineSession(
                model: model,
                durationMin: durationMin,
                typeLabel: routine.name,
                note: "Guided routine",
                offerUndo: false
            )
        case .partial(let durationMin):
            enqueueRoutineSession(
                model: model,
                durationMin: durationMin,
                typeLabel: routine.name,
                note: "\(routine.name) (partial)",
                offerUndo: true
            )
        case .discarded:
            model.toastMessage = run.isComplete
                ? "Routine too short to log — nothing saved"
                : "Routine closed — nothing saved"
        }
        dismiss()
    }

}

private extension RoutineRunnerVisualState {
    var backgroundColor: Color {
        switch self {
        case .working: return SendmeterStyle.primary
        case .rest: return SendmeterStyle.caution
        case .paused: return SendmeterStyle.paused
        case .done: return SendmeterStyle.execution
        }
    }

    var foregroundColor: Color {
        self == .rest ? Color(hex: "#1A1A1A") : .white
    }

    var ringColors: [Color] {
        self == .rest
            ? [Color.black.opacity(0.18), .black, Color.black.opacity(0.42)]
            : [Color.white.opacity(0.28), .white, Color.white.opacity(0.58)]
    }
}

private struct RoutineRunnerGlassButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hapticTap(structuralHapticLevel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(configuration.isPressed ? 0.42 : 0.2), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension RoutineRunnerGlassButtonStyle: StructuralHapticStyle {
    var structuralHapticLevel: HapticTapLevel { .normal }
}

private func formatTime(_ seconds: Int) -> String {
    let safeSeconds = max(0, seconds)
    return String(format: "%02d:%02d", safeSeconds / 60, safeSeconds % 60)
}

private struct RoutineEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Warm-up"
    @State private var steps: [RoutineStep] = [
        RoutineStep(label: "Shoulder activation", seconds: 30, repetitions: 2, restSeconds: 15)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine") {
                    TextField("Name", text: $name)
                }
                Section("Steps") {
                    ForEach($steps) { $step in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Step name", text: $step.label)
                            TextField("Detail", text: Binding(
                                get: { step.detail ?? "" },
                                set: { step.detail = $0.isEmpty ? nil : $0 }
                            ))
                            Stepper("Work: \(step.seconds)s", value: $step.seconds, in: 1...1800, step: 5)
                            Stepper("Repetitions: \(step.repetitions)", value: $step.repetitions, in: 1...100)
                            Stepper("Rest: \(step.restSeconds)s", value: $step.restSeconds, in: 0...3600, step: 5)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                // #656: a confirmed destructive action fires
                                // the medium tick once per gesture.
                                Haptics.shared.playGesture(.medium)
                                steps.removeAll { $0.id == step.id }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    Button {
                        steps.append(RoutineStep(label: "New step", seconds: 30))
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("New Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let routine = RoutinePreset(name: name, steps: steps)
                        Task {
                            await model.saveRoutine(routine, isNew: true)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || steps.isEmpty)
                }
            }
        }
    }
}

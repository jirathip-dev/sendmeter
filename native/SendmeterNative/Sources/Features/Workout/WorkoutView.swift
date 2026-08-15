import SendmeterCore
import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @State private var engine: PhoneWorkoutEngine?
    @State private var showRoutineEditor = false
    @State private var runningRoutine: RoutineRunPresentation?
    @State private var isSaving = false
    @State private var hasResolvedPersistedRun = false

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
                            run: { runningRoutine = RoutineRunPresentation(preset: $0, restored: nil) },
                            edit: { showRoutineEditor = true }
                        )
                    } else {
                        ActiveWorkoutCard(
                            engine: $engine,
                            isSaving: isSaving,
                            finish: finishWorkout
                        )
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Workout")
            .sheet(isPresented: $showRoutineEditor) {
                RoutineEditorSheet()
            }
            .sheet(item: $runningRoutine) { presentation in
                RoutineRunnerSheet(presentation: presentation)
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
                note: "\(preset.name) (auto-logged)"
            )
        case .partial(let durationMin):
            logRoutineSession(
                durationMin: durationMin,
                typeLabel: preset.name,
                note: "\(preset.name) (partial, interrupted)"
            )
        case .discarded:
            model.toastMessage = "Routine interrupted — too little of it was confirmed to log"
        }
    }

    private func logRoutineSession(durationMin: Int, typeLabel: String, note: String) {
        let draft = SessionDraft(
            date: LocalDateSupport.string(from: Date()),
            type: "routine",
            typeLabel: typeLabel,
            durationMinutes: durationMin,
            rpe: 4,
            note: note,
            phase: model.settings.currentPhase
        )
        Task {
            await model.logSession(draft)
            model.toastMessage = "Routine logged · \(durationMin) min"
        }
    }

    private func startWorkout() {
        guard let userID = model.currentUserID else { return }
        engine = PhoneWorkoutEngine(
            accountUserID: userID,
            phase: model.settings.currentPhase,
            startedAt: Date()
        )
    }

    private func finishWorkout() {
        guard var engine else { return }
        do {
            let draft = try engine.finish()
            self.engine = nil
            isSaving = true
            Task {
                await model.saveWorkout(draft)
                isSaving = false
            }
        } catch WorkoutEngineError.emptyWorkout {
            model.errorMessage = "Record at least one attempt before finishing the workout."
        } catch {
            model.errorMessage = error.localizedDescription
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
                    Text("Phone Workout")
                        .font(.title2.bold())
                    Text("Start once, tap for each attempt, then finish. The complete workout is written atomically and appears in History immediately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Start Workout", action: start)
                    .buttonStyle(PrimaryActionButtonStyle())
            }
        }
    }
}

private struct ActiveWorkoutCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var engine: PhoneWorkoutEngine?
    let isSaving: Bool
    let finish: () -> Void

    private var isAttempting: Bool { engine?.attemptStartedAt != nil }

    var body: some View {
        SurfaceCard {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 18) {
                    HStack {
                        SectionLabel("Active workout", systemImage: "timer")
                        Spacer()
                        StatusPill(isAttempting ? "Climbing" : "Resting", color: isAttempting ? SendmeterStyle.power : SendmeterStyle.optimal)
                    }

                    if let engine {
                        Text(durationString(context.date.timeIntervalSince(engine.draft.startedAt)))
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        HStack(spacing: 28) {
                            metric("Attempts", "\(engine.draft.attempts.count)")
                            metric("RPE", engine.draft.rpe.formatted(.number.precision(.fractionLength(0...1))))
                            metric("Block", PhaseCatalog.definition(for: engine.draft.phase).name)
                        }

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
                                model.errorMessage = error.localizedDescription
                            }
                        } label: {
                            Label(
                                isAttempting ? "End Attempt" : "Start Attempt",
                                systemImage: isAttempting ? "stop.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
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
                                Text("Finish Workout")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
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
    @EnvironmentObject private var model: AppModel
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
    @EnvironmentObject private var model: AppModel
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
                        .buttonStyle(.bordered)
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
                        .buttonStyle(.plain)
                        if routine.id != model.routines.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct RoutineRunnerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
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
                VStack(spacing: 24) {
                    Spacer()
                    Text(run.currentStage.label)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    if let detail = run.currentStage.detail {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Text("\(run.remainingSeconds(at: context.date))")
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    ProgressView(
                        value: run.currentStage.durationSeconds == 0
                            ? 1.0
                            : min(1.0, Double(run.elapsedSeconds(at: context.date)) / Double(run.currentStage.durationSeconds))
                    )
                    .tint(run.currentStage.kind == .rest ? SendmeterStyle.optimal : SendmeterStyle.primary)

                    if run.isComplete {
                        Button("Log Routine & Close") {
                            logRoutineAndClose()
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    } else {
                        HStack {
                            Button(run.isPaused ? "Resume" : "Pause") {
                                togglePause(at: context.date)
                            }
                            .buttonStyle(.bordered)
                            Button("Skip") { skip(at: context.date) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Spacer()
                }
                .padding()
                .task(id: Int(context.date.timeIntervalSince1970 * 4)) {
                    _ = run.advanceIfNeeded(at: context.date)
                    stampHeartbeat(at: context.date)
                }
            }
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                let now = Date()
                if restored == nil { run.start(at: now) }
                wallClock = wallClock.heartbeat(atMs: now.millisecondsSince1970)
                store.save(wallClock)
            }
            .onDisappear {
                // The sheet is gone — the run is over, finished or abandoned.
                // Clearing here (and at log time) is what stops a closed run
                // from resurrecting on the next launch.
                store.clear()
            }
        }
    }

    private func togglePause(at date: Date) {
        let nowMs = date.millisecondsSince1970
        if run.isPaused {
            run.resume(at: date)
            wallClock = wallClock.resumed(atMs: nowMs)
        } else {
            run.pause(at: date)
            wallClock = wallClock.paused(atMs: nowMs)
        }
        store.save(wallClock)
    }

    private func skip(at date: Date) {
        let remaining = run.remainingSeconds(at: date)
        run.skip(at: date)
        wallClock = wallClock.skipped(remaining, atMs: date.millisecondsSince1970)
        store.save(wallClock)
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

    /// The Log Routine & Close decision (#633): a run under the ≥60s bar is
    /// an accidental open and is discarded visibly (nothing banked); at or
    /// past it, the session is logged with the honest partial minutes — real
    /// elapsed, clamped to the routine's staged total, never the full nominal
    /// total. RPE 4 / note / phase are unchanged from the pre-gate path.
    private func logRoutineAndClose() {
        let totalS = RoutineEngine.stages(for: routine).reduce(0) { $0 + $1.durationSeconds }
        let outcome = RoutineGate.completionOutcome(
            elapsedSeconds: RoutineGate.realElapsedS(
                wallClock,
                nowMs: Date().millisecondsSince1970
            ),
            totalSeconds: totalS
        )
        store.clear()
        switch outcome {
        case .discarded:
            model.toastMessage = "Routine too short to log — nothing saved"
            dismiss()
        case .logged(let durationMin):
            let draft = SessionDraft(
                date: LocalDateSupport.string(from: Date()),
                type: "routine",
                typeLabel: routine.name,
                durationMinutes: durationMin,
                rpe: 4,
                note: "Guided routine",
                phase: model.settings.currentPhase
            )
            Task {
                await model.logSession(draft)
                model.toastMessage = "Routine logged · \(durationMin) min"
                dismiss()
            }
        }
    }
}

private struct RoutineEditorSheet: View {
    @EnvironmentObject private var model: AppModel
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

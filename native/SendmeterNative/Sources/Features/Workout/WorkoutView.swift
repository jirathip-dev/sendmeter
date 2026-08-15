import SendmeterCore
import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @State private var engine: PhoneWorkoutEngine?
    @State private var showRoutineEditor = false
    @State private var runningRoutine: RoutinePreset?
    @State private var isSaving = false

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
                            run: { runningRoutine = $0 },
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
            .sheet(item: $runningRoutine) { routine in
                RoutineRunnerSheet(routine: routine)
            }
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
    @State private var run: RoutineRun

    init(routine: RoutinePreset) {
        self.routine = routine
        self._run = State(initialValue: RoutineRun(preset: routine))
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
                            let total = RoutineEngine.stages(for: routine).reduce(0) { $0 + $1.durationSeconds }
                            let draft = SessionDraft(
                                date: LocalDateSupport.string(from: Date()),
                                type: "routine",
                                typeLabel: routine.name,
                                durationMinutes: max(1, Int(ceil(Double(total) / 60))),
                                rpe: 4,
                                note: "Guided routine",
                                phase: model.settings.currentPhase
                            )
                            Task {
                                await model.logSession(draft)
                                dismiss()
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    } else {
                        HStack {
                            Button(run.isPaused ? "Resume" : "Pause") {
                                if run.isPaused { run.resume(at: context.date) }
                                else { run.pause(at: context.date) }
                            }
                            .buttonStyle(.bordered)
                            Button("Skip") { run.skip(at: context.date) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Spacer()
                }
                .padding()
                .task(id: Int(context.date.timeIntervalSince1970 * 4)) {
                    _ = run.advanceIfNeeded(at: context.date)
                }
            }
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { run.start() }
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

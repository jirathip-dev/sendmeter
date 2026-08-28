import SendmeterCore
import SwiftUI

/// Read-only routine preview (#834). Presented from the Workout tab as a
/// regular bottom sheet; it never starts the routine on appear. The explicit
/// Start button hands the preset back to the unchanged execution path
/// (`runningRoutine` in WorkoutView), which presents the same
/// `RoutineRunnerSheet` the immediate-start row used before.
struct RoutinePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let routine: RoutinePreset
    let play: (RoutinePreset) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if routine.steps.isEmpty {
                        Text("This routine has no steps yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(routine.steps.enumerated()), id: \.element.id) { index, step in
                            RoutineStepRow(number: index + 1, step: step)
                            if index < routine.steps.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    HStack {
                        Label("Total duration", systemImage: "timer")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Total duration, \(totalDurationText)")
                        Spacer()
                        Text(totalDurationText)
                            .font(.headline.monospacedDigit())
                    }
                    Button {
                        play(routine)
                    } label: {
                        Label("Start Routine", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .hapticButtonStyle(PrimaryActionButtonStyle())
                    .accessibilityHint("Starts the routine timer")
                }
                .padding()
                .background(.bar)
            }
        }
    }

    /// The scheduled length of the run, computed from the stored steps the
    /// same way the runner does: every work repetition plus the rests between
    /// repetitions.
    private var totalSeconds: Int {
        RoutineEngine.stages(for: routine).reduce(0) { $0 + $1.durationSeconds }
    }

    private var totalDurationText: String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes == 0 { return "\(seconds)s" }
        if seconds == 0 { return "\(minutes) min" }
        return "\(minutes) min \(seconds)s"
    }
}

private struct RoutineStepRow: View {
    let number: Int
    let step: RoutineStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, minHeight: 32)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
            VStack(alignment: .leading, spacing: 6) {
                Text(step.label)
                    .font(.headline)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Text("Work \(step.seconds)s")
                    Text("Reps \(step.repetitions)")
                    if step.restSeconds > 0 {
                        Text("Rest \(step.restSeconds)s")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

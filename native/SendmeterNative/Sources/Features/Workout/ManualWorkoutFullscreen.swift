import SendmeterCore
import SwiftUI

/// The native equivalent of `PhoneWorkoutFullscreen`: the engine remains the
/// single source of truth while this view derives the wall-clock presentation
/// from it. Dismissing this cover only minimizes the view; it never mutates or
/// saves the workout.
struct ManualWorkoutFullscreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var engine: PhoneWorkoutEngine?
    let isSaving: Bool
    let restTarget: Int
    let onRestTargetChange: (Int) -> Void
    let onMinimize: () -> Void
    let onEnd: () -> Void

    @State private var restOverPulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            if let currentEngine = engine {
                let snapshot = makeSnapshot(engine: currentEngine, now: context.date)
                screen(snapshot: snapshot)
                    .task(id: snapshot.phase) {
                        restOverPulse = snapshot.phase == .restOver
                    }
            } else {
                Color.clear
                    .onAppear(perform: onMinimize)
            }
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            // The parent arms this only for a user tap. A restored/minimized
            // workout stays silent because there is no fresh gesture to claim.
            Haptics.shared.sheetPresented()
        }
    }

    @ViewBuilder
    private func screen(snapshot: ManualWorkoutSnapshot) -> some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            snapshot.accent
                .opacity(0.12)
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        topBar(snapshot: snapshot)
                        phasePanel(snapshot: snapshot)
                        actionButton(
                            snapshot: snapshot,
                            diameter: actionDiameter(for: geometry.size)
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 540)
                    .frame(
                        minHeight: max(CGFloat.zero, geometry.size.height - 24),
                        alignment: .top
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.3),
            value: snapshot.phase
        )
    }

    private func actionDiameter(for size: CGSize) -> CGFloat {
        let widthBound = min(184, max(120, size.width - 32))
        let heightBound = size.height < 500
            ? max(120, size.height * 0.42)
            : widthBound
        return min(widthBound, heightBound)
    }

    private func topBar(snapshot: ManualWorkoutSnapshot) -> some View {
        HStack(spacing: 10) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .hapticButtonStyle(GlassWorkoutButtonStyle())
            .accessibilityLabel("Minimize manual workout")
            .accessibilityHint("Keeps the workout running in the Workout tab")

            VStack(spacing: 2) {
                Text("Manual workout")
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(formatDuration(snapshot.totalElapsed))
                    .font(.headline.weight(.bold).monospacedDigit())
                    .accessibilityLabel("Elapsed \(formatDuration(snapshot.totalElapsed))")
            }
            .frame(maxWidth: .infinity)

            Button {
                guard !isSaving else { return }
                onEnd()
            } label: {
                Text("End")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .hapticButtonStyle(GlassWorkoutButtonStyle(tint: SendmeterStyle.alert))
            .disabled(isSaving)
            .accessibilityLabel("End manual workout")
            .accessibilityHint("Saves the completed workout and opens it in History")
        }
    }

    private func phasePanel(snapshot: ManualWorkoutSnapshot) -> some View {
        VStack(spacing: 10) {
            Text(snapshot.phase.label)
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(snapshot.accent)

            Text(formatDuration(snapshot.phaseSeconds))
                .font(.system(size: 82, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .accessibilityLabel("\(snapshot.phase.label) \(formatDuration(snapshot.phaseSeconds))")

            Text(
                snapshot.phase == .climbing
                    ? "on the wall · \(attemptCountLabel(snapshot.attemptCount))"
                    : "rest target \(formatDuration(TimeInterval(restTarget))) · \(attemptCountLabel(snapshot.attemptCount))"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            if snapshot.phase != .climbing {
                restTargetPicker
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(snapshot.accent.opacity(0.32), lineWidth: 1)
        )
        .scaleEffect(
            snapshot.phase == .restOver && restOverPulse && !reduceMotion ? 1.025 : 1
        )
        .animation(
            reduceMotion
                ? nil
                : (
                    snapshot.phase == .restOver
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.15)
                ),
            value: restOverPulse
        )
        .accessibilityElement(children: .contain)
    }

    private var restTargetPicker: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
            spacing: 8
        ) {
            ForEach(ManualWorkoutRest.restTargets, id: \.self) { target in
                let selected = restTarget == target
                Button {
                    onRestTargetChange(target)
                    Haptics.shared.playGesture(.selection)
                } label: {
                    Text(formatDuration(TimeInterval(target)))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(selected ? .white : .primary)
                        .background(
                            selected ? SendmeterStyle.primary : Color.primary.opacity(0.08),
                            in: Capsule()
                        )
                }
                .hapticButtonStyle(.plain)
                .accessibilityLabel("Rest target \(formatDuration(TimeInterval(target)))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rest target")
    }

    private func actionButton(
        snapshot: ManualWorkoutSnapshot,
        diameter: CGFloat
    ) -> some View {
        Button {
            toggleAttempt()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 12)
                if snapshot.phase != .climbing {
                    Circle()
                        .trim(from: 0, to: snapshot.restProgress)
                        .stroke(
                            snapshot.accent,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .stroke(snapshot.accent.opacity(0.36), lineWidth: 1)

                VStack(spacing: 8) {
                    Image(systemName: snapshot.phase == .climbing ? "stop.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                    Text(snapshot.phase == .climbing ? "DONE" : "BOULDER")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                }
                .foregroundStyle(snapshot.accent)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .hapticButtonStyle(.plain)
        .accessibilityLabel(snapshot.phase == .climbing ? "Done boulder" : "Start boulder")
        .accessibilityHint(snapshot.phase == .climbing ? "Stops the current attempt" : "Starts a new attempt")
    }

    private func toggleAttempt() {
        guard !isSaving, var copy = engine else { return }
        do {
            if copy.attemptStartedAt == nil {
                try copy.startAttempt(at: Date())
            } else {
                _ = try copy.endAttempt(at: Date())
            }
            engine = copy
            Haptics.shared.playGesture(.medium)
        } catch {
            model.errorMessage = UserFacingError.message(for: error)
            Haptics.shared.playGesture(RefusedActionHaptics.cue(tappableAndRefused: true))
        }
    }

    private func makeSnapshot(engine: PhoneWorkoutEngine, now: Date) -> ManualWorkoutSnapshot {
        let remaining = ManualWorkoutRest.remainingSeconds(
            now: now,
            workoutStartedAt: engine.draft.startedAt,
            attempts: engine.draft.attempts,
            targetSeconds: restTarget
        )
        let phase = ManualWorkoutRest.phase(
            attemptStartedAt: engine.attemptStartedAt,
            restRemaining: remaining
        )
        let phaseSeconds: TimeInterval
        switch phase {
        case .climbing:
            phaseSeconds = max(0, now.timeIntervalSince(engine.attemptStartedAt ?? now))
        case .resting, .restOver:
            phaseSeconds = remaining
        }
        return ManualWorkoutSnapshot(
            phase: phase,
            totalElapsed: max(0, now.timeIntervalSince(engine.draft.startedAt)),
            phaseSeconds: phaseSeconds,
            restProgress: ManualWorkoutRest.progress(
                now: now,
                workoutStartedAt: engine.draft.startedAt,
                attempts: engine.draft.attempts,
                targetSeconds: restTarget
            ),
            attemptCount: engine.draft.attempts.count,
            accent: phase.accent
        )
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func attemptCountLabel(_ count: Int) -> String {
        "\(count) attempt\(count == 1 ? "" : "s")"
    }
}

private struct ManualWorkoutSnapshot {
    let phase: ManualWorkoutPhase
    let totalElapsed: TimeInterval
    let phaseSeconds: TimeInterval
    let restProgress: Double
    let attemptCount: Int
    let accent: Color
}

private extension ManualWorkoutPhase {
    var label: String {
        switch self {
        case .climbing: return "CLIMBING"
        case .resting: return "RESTING"
        case .restOver: return "REST OVER"
        }
    }

    var accent: Color {
        switch self {
        case .climbing: return SendmeterStyle.optimal
        case .resting: return SendmeterStyle.primary
        case .restOver: return SendmeterStyle.alert
        }
    }
}

private struct GlassWorkoutButtonStyle: ButtonStyle {
    let tint: Color

    init(tint: Color = .primary) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hapticTap(structuralHapticLevel)
            .foregroundStyle(tint)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension GlassWorkoutButtonStyle: StructuralHapticStyle {
    var structuralHapticLevel: HapticTapLevel { .normal }
}

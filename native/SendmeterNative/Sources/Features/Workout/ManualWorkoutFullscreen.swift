import SendmeterCore
import SwiftUI

/// The native equivalent of `PhoneWorkoutFullscreen`: the engine remains the
/// single source of truth while this view derives the wall-clock presentation
/// from it. Dismissing this cover only minimizes the view; it never mutates or
/// saves the workout.
struct ManualWorkoutFullscreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var engine: PhoneWorkoutEngine?
    /// #926: the explanation for a refused End. It must be presented HERE —
    /// the app-level error banner renders behind this cover, so a refusal
    /// routed there is invisible while the workout is up. The parent clears
    /// it when the workout progresses or is minimized, so a stale
    /// explanation never outlives the tap that produced it.
    @Binding var endRefusal: ManualWorkoutEndRefusal?
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
        // #926: each refusal explains itself once. A repeat End tap presents
        // a new token, so the explanation is spoken again instead of being
        // silently re-rendered.
        .onChange(of: endRefusal) { _, refusal in
            guard let refusal else { return }
            ErrorBannerAccessibility.post(refusal.message)
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
                        if let endRefusal {
                            endRefusalBanner(endRefusal)
                        }
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
            reduceMotion
                ? nil
                : .spring(
                    response: ForceMotionPolicy.phaseResponseSeconds,
                    dampingFraction: ForceMotionPolicy.phaseDampingFraction,
                    blendDuration: 0
                ),
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

    /// #926: a refused End answers inside this screen, in the same visual
    /// language as the app's error banner but with its own identifier — the
    /// root banner's element lies behind the cover and its explanation would
    /// never be read.
    private func endRefusalBanner(_ refusal: ManualWorkoutEndRefusal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SendmeterStyle.alert)
                // Decorative: VoiceOver reads the message itself.
                .accessibilityHidden(true)
            Text(refusal.message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Wrap to the copy's full height at every text size instead of
                // letting a compressed proposal clip it.
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(ManualWorkoutEndRefusal.messageIdentifier)
        }
        .padding(12)
        .background(SendmeterStyle.alert.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SendmeterStyle.alert.opacity(0.28), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func phasePanel(snapshot: ManualWorkoutSnapshot) -> some View {
        VStack(spacing: 10) {
            Text(snapshot.phase.label)
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(snapshot.accent)

            Text(formatDuration(snapshot.phaseSeconds))
                .modifier(SendmeterStyle.countdownMetric(baseSize: 82))
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
        .hapticButtonStyle(ForceHeroActionButtonStyle())
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
            // #926: the workout moved on, so the refusal that was on screen
            // now describes a state the user has left.
            endRefusal = nil
            // The structural style arms the default light tap. This claims
            // that same tracked gesture, so the action does not add a second
            // cue.
            Haptics.shared.playGesture(.light)
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

/// #926: a refused End as presented at the active full-screen workout. The
/// token changes on every refusal, so a repeat tap re-announces an
/// explanation that is already on screen instead of silently re-rendering.
struct ManualWorkoutEndRefusal: Equatable {
    /// The identifier the UI-test lane addresses the on-screen explanation by.
    static let messageIdentifier = "manual-workout-end-refusal"

    let message: String
    let token: UUID

    init(message: String) {
        self.message = message
        self.token = UUID()
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

private struct ForceHeroActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.shared.playGesture(StructuralHaptics.cue(level: structuralHapticLevel))
                }
            }
            .scaleEffect(
                ForceMotionPolicy.heroScale(
                    isPressed: configuration.isPressed,
                    reduceMotion: reduceMotion
                )
            )
            .animation(
                reduceMotion
                    ? nil
                    : .spring(
                        response: ForceMotionPolicy.heroActionResponseSeconds,
                        dampingFraction: ForceMotionPolicy.heroActionDampingFraction,
                        blendDuration: 0
                    ),
                value: configuration.isPressed
            )
    }
}

extension ForceHeroActionButtonStyle: StructuralHapticStyle {
    var structuralHapticLevel: HapticTapLevel { .normal }
}

private struct GlassWorkoutButtonStyle: ButtonStyle {
    let tint: Color

    init(tint: Color = .primary) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    Haptics.shared.playGesture(StructuralHaptics.cue(level: structuralHapticLevel))
                }
            }
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

import SendmeterCore
import SwiftUI

/// The regular phone Force viewport. It is deliberately a presentation over
/// the existing Tindeq/AppModel owners: Stop, disconnect, salvage, keep-awake,
/// and durable auto-save continue through the same callbacks as the compact
/// Force card. Minimize only dismisses this viewport; it never stops a pull.
struct ManualForceFullscreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let device: TindeqBluetooth
    let phase: ManualForceFullscreenPhase
    let exercise: String
    let side: TindeqSide
    let selectedProtocol: TindeqPreset?
    let targetBand: ForceTargetBand?
    let saving: Bool
    let onMinimize: () -> Void
    let onStopAndSave: () -> Void
    let onSaveCompleted: () -> Void
    let onCancelArm: () -> Void
    let onDisconnect: () -> Void

    @State private var showingDisconnectConfirmation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            GeometryReader { geometry in
                let presentation = ManualForceFullscreenPresentation.stage(
                    phase: phase,
                    exercise: exercise,
                    side: side,
                    elapsedSeconds: device.elapsedMilliseconds / 1_000
                )
                let accent = color(for: presentation.accent)
                let chartHeight = max(150, min(300, geometry.size.height * 0.30))

                ZStack {
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                    accent.opacity(0.12).ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            topBar
                            protocolDetails
                            phaseBanner(presentation, accent: accent)
                            targetCoach
                            liveChart(height: chartHeight)
                            liveMetrics
                            controls(accent: accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, max(10, geometry.safeAreaInsets.top))
                        .padding(.bottom, max(20, geometry.safeAreaInsets.bottom + 12))
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity, alignment: .top)
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
                    value: phase
                )
            }
        }
        .alert("Disconnect Progressor?", isPresented: $showingDisconnectConfirmation) {
            Button("Disconnect", role: .destructive, action: onDisconnect)
            Button("Keep measuring", role: .cancel) {}
        } message: {
            Text(
                phase == .measuring
                    ? "The active pull will follow the existing disconnect handling."
                    : "The armed stream will be stopped."
            )
        }
        .interactiveDismissDisabled(true)
    }

    private var protocolDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedProtocol.map(protocolSummary) ?? "STATIC · Free pull")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let targetBand {
                Text("Target \(targetBand.kilograms.formatted(.number.precision(.fractionLength(1)))) kg · range \(targetBand.lowKilograms.formatted(.number.precision(.fractionLength(1))))–\(targetBand.highKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SendmeterStyle.caution)
            } else {
                Label("No target configured for this protocol", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func protocolSummary(_ preset: TindeqPreset) -> String {
        if preset.protocolMode == .reverseAction {
            return "MOVEMENT · \(preset.cadenceOutSeconds.formatted())s out / \(preset.cadenceReturnSeconds.formatted())s return · \(preset.sets) × \(preset.repetitions) · \(preset.restBetweenRepetitionsSeconds)s rep rest · \(preset.restBetweenSetsSeconds)s set rest"
        }
        return "STATIC · \(preset.holdSeconds)s hold · \(preset.sets) × \(preset.repetitions) · \(preset.restBetweenRepetitionsSeconds)s rep rest · \(preset.restBetweenSetsSeconds)s set rest"
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
            }
            .hapticButtonStyle(.bordered)
            .accessibilityLabel("Minimize Force recording")
            .accessibilityHint("The recording keeps running in the Force tab until you stop or disconnect")

            Spacer(minLength: 4)

            VStack(spacing: 2) {
                Text("FORCE RECORDING")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .lineLimit(1)
                Text(selectedProtocol?.name ?? (exercise.isEmpty ? "Free pull" : exercise))
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button("Disconnect", role: .destructive) {
                if phase == .measuring || phase == .armed {
                    showingDisconnectConfirmation = true
                } else {
                    onDisconnect()
                }
            }
            .font(.caption.weight(.semibold))
            .disabled(saving)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func phaseBanner(
        _ presentation: ManualForceStagePresentation,
        accent: Color
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbol)
                    .font(.title3.weight(.bold))
                Text(presentation.label)
                    .font(.title2.weight(.black))
                    .tracking(1.8)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .foregroundStyle(accent)

            Text(presentation.detail)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if phase == .measuring {
                ProgressView(value: min(1, max(0, device.elapsedMilliseconds / 600_000)))
                    .tint(accent)
                    .accessibilityLabel("Ten minute recording safety limit")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(accent.opacity(0.72), lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.label). \(presentation.detail)")
    }

    @ViewBuilder
    private var targetCoach: some View {
        if let targetBand {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .foregroundStyle(SendmeterStyle.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TARGET COACH")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(targetBand.kilograms.formatted(.number.precision(.fractionLength(1)))) kg · "
                            + "range \(targetBand.lowKilograms.formatted(.number.precision(.fractionLength(1))))–"
                            + "\(targetBand.highKilograms.formatted(.number.precision(.fractionLength(1)))) kg"
                    )
                    .font(.subheadline.monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func liveChart(height: CGFloat) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("LIVE FORCE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(side == .unspecified ? "Side —" : "Side \(side.label)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForceTraceChart(
                    buffer: device.sampleBuffer,
                    range: device.visibleSampleRange,
                    targetRange: targetBand?.range,
                    target: targetBand?.kilograms
                )
                .frame(height: height)
                .accessibilityLabel("Live force trace")
            }
        }
    }

    private var liveMetrics: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            MetricValue(
                device.currentKilograms.formatted(.number.precision(.fractionLength(1))),
                unit: "kg",
                color: targetBand?.range.contains(device.currentKilograms) == true
                    ? SendmeterStyle.optimal
                    : .primary
            )
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Peak \(device.peakKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                Text("Average \(device.averageKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func controls(accent: Color) -> some View {
        VStack(spacing: 12) {
            Button(action: primaryAction) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(accent.opacity(0.22))
                    Circle().strokeBorder(accent, lineWidth: 3)
                    VStack(spacing: 5) {
                        Image(systemName: primarySymbol)
                            .font(.title2.weight(.bold))
                        Text(primaryLabel)
                            .font(.caption.weight(.black))
                            .tracking(1.1)
                    }
                    .foregroundStyle(accent)
                }
                .frame(width: 142, height: 142)
            }
            .hapticButtonStyle(.plain)
            .disabled(saving || !primaryActionAvailable)
            .accessibilityLabel(primaryLabel)

            if phase == .measuring || phase == .armed || phase == .readyToSave {
                Text(
                    phase == .armed
                        ? "Pull above the start threshold; release to save automatically."
                        : phase == .readyToSave
                            ? "This pull stays here until its durable save succeeds."
                            : "Stop saves this pull through the same offline queue as the Force card."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryActionAvailable: Bool {
        phase == .measuring || phase == .armed || phase == .readyToSave
    }

    private var primaryLabel: String {
        switch phase {
        case .armed: return "CANCEL"
        case .measuring: return saving ? "SAVING…" : "STOP"
        case .readyToSave: return saving ? "SAVING…" : "SAVE"
        case .saving: return "SAVING…"
        case .saved: return "DONE"
        case .interrupted: return "RETURN"
        case .idle: return "CLOSE"
        }
    }

    private var primarySymbol: String {
        switch phase {
        case .armed: return "xmark"
        case .measuring, .saving: return "stop.fill"
        case .readyToSave: return "arrow.down.doc.fill"
        case .saved: return "checkmark"
        case .interrupted: return "chevron.down"
        case .idle: return "chevron.down"
        }
    }

    private func primaryAction() {
        switch phase {
        case .measuring:
            onStopAndSave()
        case .readyToSave:
            onSaveCompleted()
        case .armed:
            onCancelArm()
        case .idle, .saving, .saved, .interrupted:
            onMinimize()
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
}

import SendmeterCore
import SwiftUI

/// #1038 G1 + G3: the Free hold full screen — the ONLY place a free pull
/// records. It opens on the first pull (never on arming), stays for the next
/// one until the user leaves, and reuses the guided full screen's visual
/// language so the two read as one product.
///
/// Phases are decided by `FreeHoldPhase`; the surface itself is deliberately
/// presentational: the hands-free machine owns the recording, the durable
/// save path is untouched.
struct FreeHoldFullscreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let device: TindeqBluetooth
    /// What this session has already recorded (drives the saved line and the
    /// top bar's count).
    let sessionCount: Int
    /// The context lines: "FDP · Left" and the mode word.
    let movementSummary: String
    /// #1038 I2 proposal: end the session and disconnect, from here too.
    let onFinishSession: () -> Void
    /// Manual stop while a pull records (the release also stops it).
    let onStopAndSave: () -> Void
    let onMinimize: () -> Void
    @State private var savedRecorder: SavedPull?
    @State private var appeared = false

    private var handsFree: HandsFreeForceController { model.handsFree }

    /// The pull that just saved, for the SAVED panel. Captured from the
    /// device summary while the screen is open, so the panel shows the pull
    /// the user just made rather than the previous one.
    private struct SavedPull: Equatable {
        let peakKilograms: Double
        let durationMilliseconds: Int
    }

    /// #1038: the phase follows the machine through `model.handsFree`, whose
    /// AppModel accessor republishes each transition (the controller is a
    /// Core type without Observation).
    private var phase: FreeHoldPhase {
        if handsFree.isMeasuring || device.status == .measuring { return .recording }
        if savedRecorder != nil { return .saved }
        return .waiting
    }

    private var accent: Color {
        switch phase {
        case .waiting: return SendmeterStyle.caution
        case .recording: return SendmeterStyle.optimal
        case .saved: return SendmeterStyle.optimal
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            GeometryReader { geometry in
                content(geometry: geometry)
            }
            // #938: the fills belong at the ROOT of the cover content,
            // outside the GeometryReader, so they paint under the status bar.
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
                value: phase
            )
        }
        .onAppear {
            appeared = true
            // A pull that completed before the screen opened (the phone in a
            // pocket, or a state the capture harness seeds) still owns the
            // SAVED panel: the values are the device's own summary.
            if savedRecorder == nil, let summary = device.completedSummary {
                savedRecorder = SavedPull(
                    peakKilograms: summary.peakKilograms,
                    durationMilliseconds: summary.durationMilliseconds
                )
            }
        }
        .onChange(of: device.completedSummary) { summary in
            // A completed pull while this screen is open becomes the SAVED
            // panel. The save path clears the summary when it is durable;
            // until then the panel holds the values it captured.
            guard let summary else { return }
            savedRecorder = SavedPull(
                peakKilograms: summary.peakKilograms,
                durationMilliseconds: summary.durationMilliseconds
            )
        }
        .onChange(of: handsFree.isMeasuring) { measuring in
            // The next pull clears the saved panel — the screen is waiting
            // again.
            if measuring { savedRecorder = nil }
        }
        .interactiveDismissDisabled(true)
    }

    private func content(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    topBar
                    identityHeader
                    phaseBanner
                    statusRow
                    liveChart
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(
                    minHeight: max(0, geometry.size.height - 74),
                    alignment: .top
                )
            }
            controls
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
            }
            .hapticButtonStyle(GuidedGlassButtonStyle(tint: .primary))
            .accessibilityLabel("Minimize free hold")
            .accessibilityHint("Free hold stays armed and the full screen returns on your next pull")

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                Text("FREE HOLD")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .lineLimit(1)
                Text("\(sessionCount) saved")
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel("\(sessionCount) pulls saved this session")
            }

            Spacer(minLength: 4)

            // #1038 I2 proposal (owner accepts or rejects): the session's own
            // way out, here as well as in the sticky bar. It runs the same
            // end-then-disconnect path.
            Button("Finish", action: onFinishSession)
                .hapticButtonStyle(GuidedGlassButtonStyle(tint: SendmeterStyle.alert))
                .disabled(phase == .recording)
                .accessibilityHint("Saves the session to History and disconnects the Progressor")
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var identityHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(movementSummary)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            StatusPill("FREE HOLD", color: SendmeterStyle.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Phase banner

    private var phaseBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: phase.symbol)
                    .font(.title3.weight(.bold))
                Text(phase.label)
                    .font(.title2.weight(.black))
                    .tracking(2.2)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
            }
            .foregroundStyle(accent)

            if phase == .saved, let saved = savedRecorder {
                Text(forceText(saved.peakKilograms))
                    .modifier(SendmeterStyle.countdownMetric(baseSize: 68))
                    .accessibilityLabel(
                        "Saved, peak \(forceText(saved.peakKilograms)) kilograms"
                    )
                Text("Peak \(forceText(saved.peakKilograms)) kg · Hold \(holdText(saved.durationMilliseconds))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(forceText(device.currentKilograms))
                    .modifier(SendmeterStyle.countdownMetric(baseSize: 68))
                    .accessibilityLabel(
                        "\(forceText(device.currentKilograms)) kilograms"
                    )
                Text(phase.detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(accent.opacity(0.72), lineWidth: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("free-hold-banner")
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill("Armed · pull to start", color: SendmeterStyle.caution)
            if phase == .recording {
                StatusPill("Recording", color: SendmeterStyle.alert)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Peak \(forceText(device.peakKilograms)) kg")
                Text("Avg \(forceText(device.averageKilograms)) kg")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Live chart

    private var liveChart: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("LIVE FORCE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                ForceTraceChart(
                    buffer: device.sampleBuffer,
                    range: device.visibleSampleRange,
                    targetRange: nil,
                    target: nil
                )
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ForceTraceAccessibility.liveSummary(peakKilograms: device.peakKilograms)
                )
            }
        }
        .accessibilityIdentifier("free-hold-chart")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if phase == .recording {
                Button("Stop & save", action: onStopAndSave)
                    .hapticButtonStyle(GuidedGlassButtonStyle(tint: SendmeterStyle.alert))
                    .accessibilityHint("Ends this pull now and saves it")
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Formatting

    private func forceText(_ kilograms: Double) -> String {
        kilograms.formatted(.number.precision(.fractionLength(1)))
    }

    private func holdText(_ milliseconds: Int) -> String {
        let seconds = max(0, Double(milliseconds)) / 1_000
        return seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}

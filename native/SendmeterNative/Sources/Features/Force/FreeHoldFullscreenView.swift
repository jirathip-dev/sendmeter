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
    /// The context line under the title: "FDP · Left".
    let movementSummary: String
    /// The best saved peak for this movement and side — the chart's dashed
    /// reference (a free pull has no target; your best is the honest one).
    let bestKilograms: Double?
    /// #1038 I2 proposal: end the session and disconnect, from here too.
    let onFinishSession: () -> Void
    /// Manual stop while a pull records (the release also stops it).
    let onStopAndSave: () -> Void
    let onMinimize: () -> Void
    @State private var savedRecorder: SavedPull?
    @State private var appeared = false
    /// Everything above the chart plus the chart card's own chrome, measured
    /// once; the chart takes the rest of the screen (no dead gap — #1038).
    @State private var measuredNonChartHeight: Double?
    @State private var measuredControlsHeight: Double?

    private var handsFree: HandsFreeForceController { model.handsFree }

    /// The pull that just saved, for the SAVED panel. Captured from the
    /// device summary while the screen is open, so the panel shows the pull
    /// the user just made rather than the previous one.
    private struct SavedPull {
        let peakKilograms: Double
        let averageKilograms: Double
        let durationMilliseconds: Int
        /// The saved pull's own trace. Auto re-arm clears the live buffer for
        /// the next pull, so the SAVED card draws this copy instead of an
        /// empty chart at 0.0 kg.
        let trace: ForceSampleBuffer
        let traceRange: Range<Int>

        init(_ summary: ForceSummary) {
            peakKilograms = summary.peakKilograms
            averageKilograms = summary.averageKilograms
            durationMilliseconds = summary.durationMilliseconds
            let buffer = ForceSampleBuffer()
            for sample in summary.samples { buffer.append(sample) }
            trace = buffer
            // The whole pull, not the live view's trailing 10 s window.
            traceRange = summary.samples.isEmpty ? 0..<0 : 0..<summary.samples.count
        }
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
        case .saved: return SendmeterStyle.primary
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
                savedRecorder = SavedPull(summary)
            }
        }
        .onChange(of: device.completedSummary) { summary in
            // A completed pull while this screen is open becomes the SAVED
            // panel. The save path clears the summary when it is durable;
            // until then the panel holds the values it captured.
            guard let summary else { return }
            savedRecorder = SavedPull(summary)
        }
        .onChange(of: handsFree.isMeasuring) { measuring in
            // The next pull clears the saved panel — the screen is waiting
            // again.
            if measuring { savedRecorder = nil }
        }
        .interactiveDismissDisabled(true)
    }

    private func content(geometry: GeometryProxy) -> some View {
        let chartHeight = FreeHoldLayout.chartHeight(
            viewport: Double(geometry.size.height),
            controls: phase == .recording ? (measuredControlsHeight ?? 68) : 0,
            nonChart: measuredNonChartHeight
        )
        return VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    topBar
                    phaseBanner
                    liveChart(height: CGFloat(chartHeight))
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                    // Measured stack minus the chart = the fixed sections.
                    // Only accept a change > 1 pt so the chart sizing cannot
                    // feed back into itself frame after frame.
                    let nonChart = height - chartHeight
                    if abs((measuredNonChartHeight ?? -100) - nonChart) > 1 {
                        measuredNonChartHeight = nonChart
                    }
                }
            }
            if phase == .recording {
                controls
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                        measuredControlsHeight = height
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Top bar

    /// Same glass bar as the guided full screen: minimize · title over the
    /// context line · the session's own exit. The movement lives HERE — the
    /// old separate identity card repeated "FREE HOLD" a second time.
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
                // The session count rides the eyebrow (Guided keeps it in
                // its status row); one line instead of a row of chips.
                Text(sessionCount > 0 ? "FREE HOLD · \(sessionCount) SAVED" : "FREE HOLD")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .lineLimit(1)
                    .monospacedDigit()
                Text(movementSummary)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            // #1038 I2 proposal (owner accepts or rejects): the session's own
            // way out, here as well as in the sticky bar. It runs the same
            // end-then-disconnect path, so it keeps the bar's verb.
            // Enabled: the danger pill label (AA on every phase tint; the raw
            // hue was 2.1:1 in light and read as disabled). Mid-pull the
            // session cannot end, so it takes the palette's disabled pair
            // instead of a dimmed danger tint.
            Button("Finish", action: onFinishSession)
                .hapticButtonStyle(
                    phase == .recording
                        ? GuidedGlassButtonStyle(tint: SendmeterStyle.textDisabled)
                        : GuidedGlassButtonStyle(tint: SendmeterStyle.alert, label: SendmeterStyle.alertPillText)
                )
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

    // MARK: Phase banner

    /// The hero is TIME, exactly like the guided screen's countdown: the
    /// hold clock while you pull, the saved hold after. Force lives in the
    /// live card below, as it does in Guided.
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

            Text(holdText(heroMilliseconds))
                .modifier(SendmeterStyle.countdownMetric(baseSize: 68))
                .accessibilityLabel(heroAccessibilityLabel)

            Text(heroDetail)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
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

    private var heroMilliseconds: Int {
        switch phase {
        case .waiting: return 0
        case .recording: return Int(device.elapsedMilliseconds)
        case .saved: return savedRecorder?.durationMilliseconds ?? 0
        }
    }

    /// The saved pull's peak is the card's headline right below, so the
    /// hero keeps to the next step instead of repeating it.
    private var heroDetail: String { phase.detail }

    private var heroAccessibilityLabel: String {
        switch phase {
        case .waiting: return "Waiting for your pull"
        case .recording: return "Holding, \(holdText(heroMilliseconds))"
        case .saved:
            guard let saved = savedRecorder else { return "Saved" }
            return "Saved, held \(holdText(saved.durationMilliseconds)), peak \(forceText(saved.peakKilograms)) kilograms"
        }
    }

    // MARK: Live chart

    private func liveChart(height: CGFloat) -> some View {
        let saved = phase == .saved ? savedRecorder : nil
        let current = saved?.peakKilograms ?? device.currentKilograms
        let peak = saved?.peakKilograms ?? device.peakKilograms
        let average = saved?.averageKilograms ?? device.averageKilograms
        let beatsBest = bestKilograms.map { peak > $0 } ?? false
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Saved: the card shows the pull that just saved —
                        // its peak and its trace — until the next pull.
                        Text(saved == nil ? "LIVE FORCE" : "THIS PULL · PEAK")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(.secondary)
                        MetricValue(forceText(current), unit: "kg", color: .primary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        if saved == nil {
                            Text("Peak \(forceText(peak)) kg")
                        }
                        Text("Avg \(forceText(average)) kg")
                        // The Best value is labelled on its dashed line now;
                        // the header only adds what the line cannot say.
                        if beatsBest {
                            Text("New best")
                                .fontWeight(.semibold)
                                .foregroundStyle(SendmeterStyle.optimalText)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                // #1028 F4's light kg scale (approved), an axis fitted to
                // the drawn pull and the Best line, and the line labelled
                // where it is drawn.
                ForceTraceChart(
                    buffer: saved?.trace ?? device.sampleBuffer,
                    range: saved?.traceRange ?? device.visibleSampleRange,
                    targetRange: nil,
                    target: bestKilograms,
                    showsKilogramScale: true,
                    fitsDomainToData: true,
                    targetLabel: bestKilograms.map { "Best \(forceText($0))" }
                )
                .frame(height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ForceTraceAccessibility.liveSummary(peakKilograms: peak)
                )
            }
        }
        .accessibilityIdentifier("free-hold-chart")
    }

    // MARK: Controls

    /// The manual stop exists only while a pull records — releasing the hang
    /// stops and saves on its own; this is the explicit way. Between pulls
    /// the slot is gone and the chart takes its height: a disabled stop, or
    /// an empty reserved band, read as a stray control or a dead gap.
    ///
    /// It is the screen's one action while recording, so it takes the bottom
    /// bar's primary treatment (onPrimary on primary, AA 5.4:1; the fill
    /// clears 3:1 against every phase tint). The glass style's 12 % fill
    /// read as a disabled control in light mode.
    private var controls: some View {
        Button(action: onStopAndSave) {
            Label("Stop & save", systemImage: "stop.fill")
                .font(.headline)
                .foregroundStyle(SendmeterStyle.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    SendmeterStyle.primary,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .hapticButtonStyle(.plain)
        .accessibilityHint("Ends this pull now and saves it")
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

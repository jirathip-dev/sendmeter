import SendLogWatchCore
import SwiftUI

/// Full-screen, one-glance guided Force surface.  RootView owns the switch to
/// this view while `GuidedForceRunner` owns all execution state, so leaving
/// setup cannot strand a timer or a BLE claim.
/// Phase/progress chrome uses the shared semantic `primary` accent (SL-538):
/// this screen IS the primary action in progress, and no phase (prepare,
/// hold, rest, switch) carries a distinct data-semantic hue. `Stop` keeps
/// `danger` since it is a destructive/abort control, not decorative.
struct GuidedForceRunnerView: View {
    @Environment(GuidedForceRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Presentation-only override for the screenshot target (SL-538 round-2
    /// review finding 1). `display` reads the fixture when
    /// `ScreenshotFixtures.guidedRun` is set and the real `runner` otherwise;
    /// it never writes back to `runner`, so the fixture cannot influence the
    /// actual run state, timers, or persistence — same guarantee
    /// `ForceGaugeView.fixtureVisual` already gives `ForceGaugeView`.
    private var display: GuidedRunDisplay {
        if let fixture = ScreenshotFixtures.guidedRun {
            return GuidedRunDisplay(fixture: fixture)
        }
        return GuidedRunDisplay(runner: runner)
    }

    // No top-level `.accessibilityIdentifier` here (SL-538 round-2 review
    // finding 1, discovered while writing the first fixture/test this view
    // ever had): on this device+OS, an identifier applied to this
    // GeometryReader's content silently overwrote every descendant's own
    // `.accessibilityIdentifier` (the phase card, Stop button) with its own
    // value, regardless of ordering relative to `.toolbar`/`.watchCanvas`.
    // Each layout/control already carries its own unique identifier
    // (`force-guided-*`); adding a container-level one is not needed and
    // reintroducing it should be re-tested against
    // `testForceGuidedRunRendersActivePhase` before landing.
    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.height < 205 || geometry.size.width < 170 {
                    microLayout
                } else if geometry.size.height < 220 {
                    compactLayout
                } else {
                    richLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(true)
        .watchCanvas()
    }

    private var richLayout: some View {
        VStack(spacing: 7) {
            header
            phaseCard
            progressCard
            stopButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// The smallest 40mm content area can be shorter than the nominal screen
    /// height once watchOS reserves safe-area insets. Keep only the phase,
    /// countdown, set/rep (or live kg/cadence) and Stop here; all four remain
    /// visible without relying on a scroll position.
    private var microLayout: some View {
        VStack(spacing: 3) {
            WatchCard(accent: WatchPalette.primary) {
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(display.phaseTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.66)
                        Spacer(minLength: 2)
                        compactSetRep
                    }

                    Text(display.countdownText)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WatchPalette.textPrimary)
                        .minimumScaleFactor(0.56)
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel("Phase countdown")
                        .accessibilityValue("\(display.countdownText) seconds")

                    HStack(spacing: 3) {
                        compactWorkStatus
                        Spacer(minLength: 2)
                        ProgressView(value: display.progress)
                            .tint(WatchPalette.primary)
                            .frame(width: 40)
                            .accessibilityLabel("Protocol progress")
                            .accessibilityValue("\(Int((display.progress * 100).rounded())) percent")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("force-guided-micro-card")

            stopButton
        }
        .padding(.horizontal, 2)
    }

    /// The 40mm layout deliberately merges the protocol/status, progress and
    /// live force/cadence line into one card. The 44pt Stop target remains a
    /// separate control, so it can never scroll below the fold.
    private var compactLayout: some View {
        VStack(spacing: 4) {
            WatchCard(accent: WatchPalette.primary) {
                VStack(spacing: 2) {
                    compactHeader

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(display.phaseTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer(minLength: 2)
                        compactSetRep
                    }

                    Text(display.countdownText)
                        .font(.system(size: 43, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WatchPalette.textPrimary)
                        .minimumScaleFactor(0.58)
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel("Phase countdown")
                        .accessibilityValue("\(display.countdownText) seconds")

                    HStack(spacing: 4) {
                        compactWorkStatus
                        Spacer(minLength: 2)
                        ProgressView(value: display.progress)
                            .tint(WatchPalette.primary)
                            .frame(width: 46)
                            .accessibilityLabel("Protocol progress")
                            .accessibilityValue("\(Int((display.progress * 100).rounded())) percent")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("force-guided-compact-card")

            stopButton
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var compactHeader: some View {
        HStack(spacing: 4) {
            WatchStateChip(
                state: display.isMeasured ? .syncing : .offline,
                title: display.isMeasured ? "Measured" : "Cadence only",
                compact: true
            )
            Spacer(minLength: 2)
            Text(display.protocolName ?? "Force protocol")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.isMeasured ? "Measured force protocol" : "Cadence-only force protocol")
        .accessibilityValue(display.protocolName ?? "Force protocol")
    }

    private var compactSetRep: some View {
        HStack(spacing: 3) {
            Text("S\(display.currentSet)/\(display.totalSets)")
            Text("R\(display.currentRep)/\(display.totalReps)")
        }
        .font(.caption2.weight(.bold).monospacedDigit())
        .foregroundStyle(WatchPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityLabel(
            "Set \(display.currentSet) of \(display.totalSets), rep \(display.currentRep) of \(display.totalReps)"
        )
    }

    private var compactWorkStatus: some View {
        Group {
            if display.isCadenceOnly {
                Label("Cadence only", systemImage: "waveform.path.ecg")
            } else if let kg = display.currentKg {
                Label(String(format: "%.1f kg", kg), systemImage: "gauge.with.dots.needle.67percent")
            } else {
                Text(display.side.isEmpty ? "Force ready" : sideLabel(display.side))
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(
            display.isCadenceOnly
                ? WatchPalette.foreground(WatchDesignTokens.warning)
                : WatchPalette.textSecondary
        )
        .lineLimit(1)
        .minimumScaleFactor(0.62)
        .accessibilityLabel(
            display.isCadenceOnly
                ? "Cadence only; force not measured"
                : display.currentKg.map { String(format: "Current force %.1f kilograms", $0) } ?? "Force ready"
        )
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                WatchStateChip(
                    state: display.isMeasured ? .syncing : .offline,
                    title: display.isMeasured ? "Measured" : "Cadence only",
                    compact: true
                )
                Spacer(minLength: 0)
                Text(display.protocolName ?? "Force protocol")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            VStack(alignment: .leading, spacing: 2) {
                WatchStateChip(
                    state: display.isMeasured ? .syncing : .offline,
                    title: display.isMeasured ? "Measured" : "Cadence only",
                    compact: true
                )
                Text(display.protocolName ?? "Force protocol")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.isMeasured ? "Measured force protocol" : "Cadence-only force protocol")
        .accessibilityValue(display.protocolName ?? "Force protocol")
    }

    private var phaseCard: some View {
        WatchCard(accent: WatchPalette.primary) {
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(display.phaseTitle)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 3)
                    Text(display.side.isEmpty ? "Side —" : sideLabel(display.side))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(display.countdownText)
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WatchPalette.textPrimary)
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityLabel("Phase countdown")
                    .accessibilityValue("\(display.countdownText) seconds")

                Text("seconds")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchPalette.textTertiary)
                    .accessibilityHidden(true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        setReadout
                        repReadout
                    }
                    VStack(spacing: 2) {
                        setReadout
                        repReadout
                    }
                }

                if display.isCadenceOnly {
                    Label("Cadence only · force not measured", systemImage: "waveform.path.ecg")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel("Cadence only; force not measured")
                } else if let kg = display.currentKg {
                    (Text(String(format: "%.1f", kg))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                    + Text(" kg").font(.caption).foregroundStyle(WatchPalette.textSecondary))
                        .accessibilityLabel("Current force")
                        .accessibilityValue(String(format: "%.1f kilograms", kg))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("force-guided-phase-card")
    }

    private var setReadout: some View {
        Label("Set \(display.currentSet) of \(display.totalSets)", systemImage: "square.stack.3d.up.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WatchPalette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .accessibilityIdentifier("force-guided-set")
    }

    private var repReadout: some View {
        Label("Rep \(display.currentRep) of \(display.totalReps)", systemImage: "repeat")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WatchPalette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .accessibilityIdentifier("force-guided-rep")
    }

    private var progressCard: some View {
        WatchCard(accent: WatchPalette.primary.opacity(isLuminanceReduced ? 0.36 : 0.72)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(display.tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("\(Int((display.progress * 100).rounded()))%")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                }
                ProgressView(value: display.progress)
                    .tint(WatchPalette.primary)
                    .animation(reduceMotion ? nil : .easeOut(duration: WatchDesignTokens.motionDuration), value: display.progress)
                    .accessibilityLabel("Protocol progress")
                    .accessibilityValue("\(Int((display.progress * 100).rounded())) percent")
            }
        }
        .accessibilityIdentifier("force-guided-progress")
    }

    private var stopButton: some View {
        Button("Stop") {
            runner.stop()
        }
        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.foreground(WatchDesignTokens.danger)))
        .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
        .disabled(!display.canStop)
        .accessibilityLabel("Stop protocol")
        .accessibilityHint("Stops now and saves any active partial set honestly")
        .accessibilityIdentifier("force-guided-stop")
    }

    private func sideLabel(_ value: String) -> String {
        switch value {
        case "left": return "Left"
        case "right": return "Right"
        case "both": return "Both"
        default: return value
        }
    }
}

/// Read-only view of either the real `GuidedForceRunner` or the screenshot
/// fixture — see `GuidedForceRunnerView.display`.
private struct GuidedRunDisplay {
    let phaseTitle: String
    let countdownText: String
    let progress: Double
    let isMeasured: Bool
    let isCadenceOnly: Bool
    let protocolName: String?
    let currentSet: Int
    let totalSets: Int
    let currentRep: Int
    let totalReps: Int
    let side: String
    let currentKg: Double?
    let tag: String
    let canStop: Bool

    init(runner: GuidedForceRunner) {
        phaseTitle = runner.phaseTitle
        countdownText = runner.countdownText
        progress = runner.progress
        isMeasured = runner.isMeasured
        isCadenceOnly = runner.isCadenceOnly
        protocolName = runner.protocolValue?.name
        currentSet = runner.currentSet
        totalSets = runner.totalSets
        currentRep = runner.currentRep
        totalReps = runner.totalReps
        side = runner.side
        currentKg = runner.currentKg
        tag = runner.tag
        canStop = runner.phase != .stopping
    }

    init(fixture: ScreenshotGuidedRunVisual) {
        phaseTitle = fixture.phaseTitle
        countdownText = fixture.countdownText
        progress = fixture.progress
        isMeasured = fixture.isMeasured
        isCadenceOnly = fixture.isCadenceOnly
        protocolName = fixture.protocolName
        currentSet = fixture.currentSet
        totalSets = fixture.totalSets
        currentRep = fixture.currentRep
        totalReps = fixture.totalReps
        side = fixture.side
        currentKg = fixture.currentKg
        tag = fixture.tag
        canStop = true
    }
}

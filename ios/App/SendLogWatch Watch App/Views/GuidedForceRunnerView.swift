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
        .accessibilityIdentifier("force-guided-runner")
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
                        Text(runner.phaseTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.66)
                        Spacer(minLength: 2)
                        compactSetRep
                    }

                    Text(runner.countdownText)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WatchPalette.textPrimary)
                        .minimumScaleFactor(0.56)
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel("Phase countdown")
                        .accessibilityValue("\(runner.countdownText) seconds")

                    HStack(spacing: 3) {
                        compactWorkStatus
                        Spacer(minLength: 2)
                        ProgressView(value: runner.progress)
                            .tint(WatchPalette.primary)
                            .frame(width: 40)
                            .accessibilityLabel("Protocol progress")
                            .accessibilityValue("\(Int((runner.progress * 100).rounded())) percent")
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
                        Text(runner.phaseTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer(minLength: 2)
                        compactSetRep
                    }

                    Text(runner.countdownText)
                        .font(.system(size: 43, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WatchPalette.textPrimary)
                        .minimumScaleFactor(0.58)
                        .lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel("Phase countdown")
                        .accessibilityValue("\(runner.countdownText) seconds")

                    HStack(spacing: 4) {
                        compactWorkStatus
                        Spacer(minLength: 2)
                        ProgressView(value: runner.progress)
                            .tint(WatchPalette.primary)
                            .frame(width: 46)
                            .accessibilityLabel("Protocol progress")
                            .accessibilityValue("\(Int((runner.progress * 100).rounded())) percent")
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
                state: runner.isMeasured ? .syncing : .offline,
                title: runner.isMeasured ? "Measured" : "Cadence only",
                compact: true
            )
            Spacer(minLength: 2)
            Text(runner.protocolValue?.name ?? "Force protocol")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(runner.isMeasured ? "Measured force protocol" : "Cadence-only force protocol")
        .accessibilityValue(runner.protocolValue?.name ?? "Force protocol")
    }

    private var compactSetRep: some View {
        HStack(spacing: 3) {
            Text("S\(runner.currentSet)/\(runner.totalSets)")
            Text("R\(runner.currentRep)/\(runner.totalReps)")
        }
        .font(.caption2.weight(.bold).monospacedDigit())
        .foregroundStyle(WatchPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityLabel(
            "Set \(runner.currentSet) of \(runner.totalSets), rep \(runner.currentRep) of \(runner.totalReps)"
        )
    }

    private var compactWorkStatus: some View {
        Group {
            if runner.isCadenceOnly {
                Label("Cadence only", systemImage: "waveform.path.ecg")
            } else if let kg = runner.currentKg {
                Label(String(format: "%.1f kg", kg), systemImage: "gauge.with.dots.needle.67percent")
            } else {
                Text(runner.side.isEmpty ? "Force ready" : sideLabel(runner.side))
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(
            runner.isCadenceOnly
                ? WatchPalette.foreground(WatchDesignTokens.warning)
                : WatchPalette.textSecondary
        )
        .lineLimit(1)
        .minimumScaleFactor(0.62)
        .accessibilityLabel(
            runner.isCadenceOnly
                ? "Cadence only; force not measured"
                : runner.currentKg.map { String(format: "Current force %.1f kilograms", $0) } ?? "Force ready"
        )
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                WatchStateChip(
                    state: runner.isMeasured ? .syncing : .offline,
                    title: runner.isMeasured ? "Measured" : "Cadence only",
                    compact: true
                )
                Spacer(minLength: 0)
                Text(runner.protocolValue?.name ?? "Force protocol")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            VStack(alignment: .leading, spacing: 2) {
                WatchStateChip(
                    state: runner.isMeasured ? .syncing : .offline,
                    title: runner.isMeasured ? "Measured" : "Cadence only",
                    compact: true
                )
                Text(runner.protocolValue?.name ?? "Force protocol")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(runner.isMeasured ? "Measured force protocol" : "Cadence-only force protocol")
        .accessibilityValue(runner.protocolValue?.name ?? "Force protocol")
    }

    private var phaseCard: some View {
        WatchCard(accent: WatchPalette.primary) {
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(runner.phaseTitle)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 3)
                    Text(runner.side.isEmpty ? "Side —" : sideLabel(runner.side))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(runner.countdownText)
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WatchPalette.textPrimary)
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityLabel("Phase countdown")
                    .accessibilityValue("\(runner.countdownText) seconds")

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

                if runner.isCadenceOnly {
                    Label("Cadence only · force not measured", systemImage: "waveform.path.ecg")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel("Cadence only; force not measured")
                } else if let kg = runner.currentKg {
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
        Label("Set \(runner.currentSet) of \(runner.totalSets)", systemImage: "square.stack.3d.up.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WatchPalette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .accessibilityIdentifier("force-guided-set")
    }

    private var repReadout: some View {
        Label("Rep \(runner.currentRep) of \(runner.totalReps)", systemImage: "repeat")
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
                    Text(runner.tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("\(Int((runner.progress * 100).rounded()))%")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                }
                ProgressView(value: runner.progress)
                    .tint(WatchPalette.primary)
                    .animation(reduceMotion ? nil : .easeOut(duration: WatchDesignTokens.motionDuration), value: runner.progress)
                    .accessibilityLabel("Protocol progress")
                    .accessibilityValue("\(Int((runner.progress * 100).rounded())) percent")
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
        .disabled(runner.phase == .stopping)
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

import SendmeterCore
import SwiftUI

/// The Dashboard's ACWR status card (#748) — a native port of the web card
/// (`src/components/Dashboard.tsx`, the ACWR card near lines 238–362) with the
/// gradient risk track that `LoadCard` and `AcwrProjectionCard` don't provide.
///
/// Per the #748 round-2 design decision this card is the **canonical Training
/// Load surface**: tapping the header title/chevron OR the card body opens the
/// same `TrainingLoadSheet` that `LoadCard` used to open. `LoadCard` is now a
/// weekly-load chart card only (numbers + status pill + open-sheet affordance
/// removed there), so the three load numbers and the open-sheet affordance are
/// never duplicated between the two cards.
///
/// Layout: title + info affordance + chevron, big `%.2f` ratio (status-colored),
/// status label, phase-fit line, a 0–2 gradient risk track with true-scale
/// 0/1.0/1.5/2 ticks and a clamped marker dot, and an Acute/Chronic footer.
///
/// Geometry, threshold mapping, phase-fit copy, VoiceOver summary, and the
/// no-data explainer all live in `SendmeterCore.AcwrStatusCard` (unit-tested);
/// this view only resolves the semantic `ChartToken` colors and renders. The
/// info button is a sibling of (never nested inside) the tappable header and
/// body surfaces, so one tap can't present both sheets (#748 round 2 finding 2).
struct AcwrStatusCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showTrainingLoad = false
    @State private var showInfo = false

    // #748 round 2 finding 3: Dynamic Type. The big ratio and the tick row
    // must scale with accessibility text sizes instead of using fixed points.
    @ScaledMetric(relativeTo: .largeTitle) private var bigNumberSize: CGFloat = 38
    @ScaledMetric(relativeTo: .caption) private var tickRowHeight: CGFloat = 16

    private var ratio: Double? { model.acwr.ratio }
    private var status: ACWRStatus { TrainingMetrics.acwrStatus(ratio) }
    private var statusColor: Color { ChartToken.acwrStatusColor(ratio, scheme) }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ACWR")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Opens training load details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openTrainingLoad() }
        .sheet(isPresented: $showTrainingLoad, onDismiss: { Haptics.shared.sheetDismissed() }) {
            TrainingLoadSheet()
                .onAppear { Haptics.shared.sheetPresented() }
        }
        .sheet(isPresented: $showInfo, onDismiss: { Haptics.shared.sheetDismissed() }) {
            AcwrStatusCardInfoSheet()
                .onAppear { Haptics.shared.sheetPresented() }
        }
    }

    // MARK: - Header

    /// Title + chevron form their own tap surface (opens the sheet); the info
    /// button is a SIBLING, outside it, so one tap can't present both sheets.
    private var header: some View {
        HStack(spacing: 10) {
            titleAndChevron
            Spacer()
            infoButton
        }
    }

    private var titleAndChevron: some View {
        HStack(spacing: 6) {
            SectionLabel("ACWR")
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .hapticTap()
        .onTapGesture(perform: openTrainingLoad)
    }

    private var infoButton: some View {
        Button {
            Haptics.shared.tap()
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .hapticButtonStyle(.plain)
        .accessibilityLabel("About ACWR")
        .accessibilityHint("Opens an explanation of how ACWR is calculated.")
    }

    // MARK: - Content

    /// The card body — also tappable to open the Training Load sheet (shared
    /// action with the header, same state, no conflict with the info button).
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ratio.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: bigNumberSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(status.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
            if let fitLine = SendmeterCore.AcwrStatusCard.phaseFitLine(
                ratio: ratio,
                phase: model.currentPhase
            ) {
                Text(fitLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            riskTrack
            tickLabels
            if ratio == nil {
                Text(SendmeterCore.AcwrStatusCard.nilExplainer(
                    hasLoadedSessions: model.hasLoadedSessions,
                    hasSessions: !model.sessions.isEmpty
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            footer
        }
        .contentShape(Rectangle())
        .hapticTap()
        .onTapGesture(perform: openTrainingLoad)
    }

    // MARK: - Risk track

    /// The gradient background band, resolved from the pure geometry in Core.
    private var gradient: LinearGradient {
        let stops = SendmeterCore.AcwrStatusCard.gradientStops.map { stop in
            Gradient.Stop(color: bandColor(stop.band), location: CGFloat(stop.fraction))
        }
        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func bandColor(_ band: AcwrRiskBand) -> Color {
        switch band {
        case .low: return ChartToken.focus.color(scheme)
        case .optimal: return ChartToken.optimal.color(scheme)
        case .caution: return ChartToken.caution.color(scheme)
        case .danger: return ChartToken.alert.color(scheme)
        }
    }

    private var riskTrack: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                gradient
                    .opacity(0.55)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                if let fraction = SendmeterCore.AcwrStatusCard.markerFraction(ratio) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                        )
                        .position(x: geo.size.width * CGFloat(fraction), y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    /// True-scale ticks under the track. Edge ticks anchor to the track's outer
    /// edge (0 leading at 0%, 2 trailing at 100%); interior ticks center on
    /// their fraction (1.0 at 50%, 1.5 at 75%) using the label's measured width
    /// via alignment guides — never magic offsets (#748 round 2 finding 1). The
    /// row height scales with Dynamic Type so labels don't clip/overlap at
    /// large accessibility sizes (#748 round 2 finding 3).
    private var tickLabels: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Invisible full-width anchor so the guides position against
                // the same span as the risk track above.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 0)
                ForEach(SendmeterCore.AcwrStatusCard.ticks, id: \.label) { tick in
                    Text(tick.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .alignmentGuide(.leading) { d in
                            tickLeadingOffset(d, fraction: tick.fraction, trackWidth: geo.size.width)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: tickRowHeight)
        .accessibilityHidden(true)
    }

    private func tickLeadingOffset(_ d: ViewDimensions, fraction: Double, trackWidth: CGFloat) -> CGFloat {
        let labelWidth = d.width
        let width = trackWidth
        // Leading-aligned at the left edge, trailing-aligned at the right edge,
        // centered on the fraction otherwise (mirrors the web's transforms).
        if fraction <= 0 {
            return 0
        } else if fraction >= 1 {
            return labelWidth - width
        }
        return labelWidth / 2 - width * CGFloat(fraction)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 24) {
            footerItem(prefix: "Acute 7d", value: model.acwr.acute)
            footerItem(prefix: "Chronic avg", value: model.acwr.chronic)
        }
        .font(.subheadline)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerItem(prefix: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(0)))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        SendmeterCore.AcwrStatusCard.accessibilitySummary(
            ratio: ratio,
            acute: model.acwr.acute,
            chronic: model.acwr.chronic,
            phase: model.currentPhase
        )
    }

    private func openTrainingLoad() {
        // #656: a tap opening a sheet arms the presentation tick.
        Haptics.shared.tap()
        showTrainingLoad = true
    }
}

/// The focused "How ACWR is calculated" explainer (#748) — a native port of
/// the web `InfoDot` acwr topic content.
private struct AcwrStatusCardInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        heading: "Session load",
                        text: "Every session gets a load in arbitrary units (AU) = duration (min) × RPE (1–10) — the session-RPE method, a simple and validated way to quantify how much training your body absorbed."
                    )
                    section(
                        heading: "Acute : Chronic Workload Ratio",
                        text: "ACWR compares what you did recently (acute ≈ last 7 days) with what you're adapted to (chronic ≈ last 28 days). Sendmeter uses exponentially-weighted moving averages, which weight recent days more heavily than simple rolling averages."
                    )
                    section(
                        heading: "Risk zones",
                        text: "0.8–1.3 is the commonly-cited 'sweet spot'; above ~1.5 injury risk rises sharply (load spiking faster than adaptation). Below 0.8 you're detraining relative to your base. The phase banner shows a phase-specific target band — a power phase legitimately runs lower than a capacity phase."
                    )
                    section(
                        heading: "Take it as a guide",
                        text: "ACWR is a screening heuristic, not a prescription. Treat sustained red zones as a prompt to look at sleep, finger niggles and volume — not as a hard rule."
                    )
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("How ACWR is calculated")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func section(heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

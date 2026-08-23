import SendmeterCore
import SwiftUI

/// The Dashboard's ACWR status card (#748) — a native port of the web card
/// (`src/components/Dashboard.tsx`, the ACWR card near lines 238–362) with the
/// gradient risk track that `LoadCard` and `AcwrProjectionCard` don't provide.
///
/// Layout: title + info affordance + chevron, big `%.2f` ratio (status-colored),
/// status label, phase-fit line, a 0–2 gradient risk track with true-scale
/// 0/1.0/1.5/2 ticks and a clamped marker dot, and an Acute/Chronic footer.
///
/// Geometry, threshold mapping, and phase-fit copy all live in
/// `SendmeterCore.AcwrStatusCard` (unit-tested); this view only resolves the
/// semantic `ChartToken` colors and renders. Tapping the card opens the same
/// `TrainingLoadSheet` `LoadCard` opens; the info affordance opens a focused
/// explainer sheet.
struct AcwrStatusCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showTrainingLoad = false
    @State private var showInfo = false

    private var ratio: Double? { model.acwr.ratio }
    private var status: ACWRStatus { TrainingMetrics.acwrStatus(ratio) }
    private var statusColor: Color { ChartToken.acwrStatusColor(ratio, scheme) }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                Text(ratio.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
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
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openTrainingLoad)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ACWR")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Opens training load details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openTrainingLoad() }
        .sheet(isPresented: $showTrainingLoad) {
            TrainingLoadSheet()
                .onAppear { Haptics.shared.sheetPresented() }
        }
        .sheet(isPresented: $showInfo) {
            AcwrStatusCardInfoSheet()
                .onAppear { Haptics.shared.sheetPresented() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel("ACWR")
            Spacer()
            Button {
                Haptics.shared.tap()
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About ACWR")
            .accessibilityHint("Opens an explanation of how ACWR is calculated.")
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
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

    private var tickLabels: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(SendmeterCore.AcwrStatusCard.ticks, id: \.label) { tick in
                    Text(tick.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .position(x: CGFloat(tick.fraction) * geo.size.width, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
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
        let number = ratio.map { String(format: "%.2f", $0) } ?? "No data"
        var parts = ["\(number). \(status.rawValue)."]
        if let fitLine = SendmeterCore.AcwrStatusCard.phaseFitLine(
            ratio: ratio,
            phase: model.currentPhase
        ) {
            parts.append(fitLine + ".")
        }
        parts.append("Acute 7d \(Int(model.acwr.acute.rounded())). Chronic avg \(Int(model.acwr.chronic.rounded())).")
        return parts.joined(separator: " ")
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

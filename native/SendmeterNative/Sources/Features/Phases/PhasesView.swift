import SendmeterCore
import SwiftUI

struct PhasesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var proposedPhase: PhaseID?
    @State private var isChanging = false

    private var blockAge: BlockAge? {
        TrainingMetrics.phaseBlockAge(
            periods: model.phasePeriods,
            currentPhase: model.settings.currentPhase,
            fallbackStartDate: model.settings.phaseStartDate,
            referenceDate: LocalDateSupport.string(from: Date())
        )
    }

    private var canonicalStart: String {
        TrainingMetrics.canonicalPhaseStart(
            periods: model.phasePeriods,
            currentPhase: model.settings.currentPhase,
            fallbackStartDate: model.settings.phaseStartDate
        )
    }

    private var guidance: BlockGuidance {
        TrainingBlockGuidance.blockGuidance(
            phase: model.currentPhase,
            age: blockAge,
            acwr: model.acwr.ratio,
            readinessHistory: model.healthMetrics
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Training blocks", systemImage: "square.stack.3d.up.fill")
                            Text("Training blocks are managed by you. Sendmeter uses your readiness and training load to show how each block is tracking and when it may be worth reviewing the next one.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    CurrentBlockCard(
                        phase: model.currentPhase,
                        age: blockAge,
                        acwr: model.acwr.ratio,
                        canonicalStart: canonicalStart,
                        onPropose: { proposedPhase = $0 }
                    )

                    GuidanceCard(
                        guidance: guidance,
                        phase: model.currentPhase,
                        onReview: { proposedPhase = $0 }
                    )

                    ForEach(PhaseCatalog.all) { phase in
                        PhaseSelectionCard(
                            phase: phase,
                            isCurrent: phase.id == model.settings.currentPhase,
                            select: { proposedPhase = phase.id }
                        )
                    }

                    PhaseTimelineCard(periods: model.phasePeriods)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Training Blocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Change Training Block?",
                isPresented: Binding(
                    get: { proposedPhase != nil },
                    set: { if !$0 { proposedPhase = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let proposedPhase {
                    Button("Change to \(PhaseCatalog.definition(for: proposedPhase).name)") {
                        change(to: proposedPhase)
                    }
                }
                Button("Cancel", role: .cancel) { proposedPhase = nil }
            } message: {
                Text("This starts a new block today. A same-day change can be undone without creating a one-day historical block.")
            }
            .overlay {
                if isChanging {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Updating block…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func change(to phase: PhaseID) {
        guard phase != model.settings.currentPhase else {
            proposedPhase = nil
            return
        }
        isChanging = true
        proposedPhase = nil
        Task {
            await model.switchPhase(to: phase)
            isChanging = false
        }
    }
}

struct CurrentBlockCard: View {
    let phase: PhaseDefinition
    let age: BlockAge?
    let acwr: Double?
    let canonicalStart: String
    let onPropose: (PhaseID) -> Void

    private var startLabel: String {
        "You selected this block on \(LocalDateSupport.monthDayLabel(for: canonicalStart))"
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel("Your current block", systemImage: "square.stack.3d.up.fill")
                        Text(phase.name)
                            .font(.largeTitle.bold())
                            .foregroundStyle(SendmeterStyle.phaseColor(phase.id))
                    }
                    Spacer()
                    if let age {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Week \(age.week)")
                                .font(.title3.bold().monospacedDigit())
                            Text("Day \(age.totalDays)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(startLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(phase.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    StatusPill("Typical \(phase.typicalWeeksLow)–\(phase.typicalWeeksHigh) weeks (guidance)", color: SendmeterStyle.phaseColor(phase.id))
                    StatusPill("Target ACWR \(phase.acwrBandText)", color: SendmeterStyle.phaseColor(phase.id))
                    if let acwr {
                        StatusPill("ACWR \(acwr.formatted(.number.precision(.fractionLength(2))))", color: acwrColor(acwr))
                    }
                }
                HStack(spacing: 12) {
                    // Menu presentation is intentionally silent; only selecting a row is a user action and ticks once.
                    Menu {
                        ForEach(PhaseCatalog.all.filter { $0.id != phase.id }) { candidate in
                            Button(candidate.name) {
                                Haptics.shared.playGesture(.light)
                                onPropose(candidate.id)
                            }
                        }
                    } label: {
                        Label("Change block", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(SendmeterStyle.phaseColor(phase.id).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(SendmeterStyle.phaseColor(phase.id))
                            .accessibilityIdentifier("change-block-menu")
                    }

                    if let next = phase.id.nextLogical {
                        Button("End block") { onPropose(next) }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(SendmeterStyle.phaseColor(phase.id), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private func acwrColor(_ value: Double) -> Color {
        switch TrainingMetrics.acwrStatus(value) {
        case .optimal: return SendmeterStyle.optimal
        case .caution, .low: return SendmeterStyle.caution
        case .danger, .underTraining: return SendmeterStyle.alert
        case .noData: return .secondary
        }
    }
}

#if DEBUG
struct MenuActivationProbeView: View {
    @State private var callbackCount = 0
    @State private var tickCount = 0

    var body: some View {
        VStack {
            CurrentBlockCard(
                phase: PhaseCatalog.definition(for: .capacity),
                age: nil,
                acwr: nil,
                canonicalStart: "2026-01-01",
                onPropose: { _ in callbackCount += 1 }
            )
            Text("Menu callbacks: \(callbackCount)")
                .accessibilityIdentifier("menu-callback-count")
            Text("Menu ticks: \(tickCount)")
                .accessibilityIdentifier("menu-tick-count")
        }
        .task {
            while !Task.isCancelled {
                tickCount = Haptics.shared.debugEmissionCount
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
#endif

private struct GuidanceCard: View {
    let guidance: BlockGuidance
    let phase: PhaseDefinition
    let onReview: (PhaseID) -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Guidance", systemImage: "chart.line.uptrend.xyaxis")
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(color)
                        Text(basis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if guidance.state == .considerNext, let next = guidance.nextPhase {
                    Button("Review \(PhaseCatalog.definition(for: next).name)") { onReview(next) }
                        .hapticButtonStyle(.borderedProminent)
                        .tint(SendmeterStyle.phaseColor(next))
                }
            }
        }
    }

    private var title: String {
        switch guidance.state {
        case .continueCurrent: return "Continue current block"
        case .reviewDuration: return "Review block duration"
        case .considerNext: return "Consider the next block"
        case .considerRecovery: return "Consider recovery"
        }
    }

    private var symbol: String {
        switch guidance.state {
        case .continueCurrent: return "checkmark.circle.fill"
        case .reviewDuration: return "clock.arrow.circlepath"
        case .considerNext: return "arrow.right.circle.fill"
        case .considerRecovery: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch guidance.state {
        case .continueCurrent: return SendmeterStyle.optimal
        case .reviewDuration: return SendmeterStyle.caution
        case .considerNext: return SendmeterStyle.phaseColor(guidance.nextPhase ?? phase.id)
        case .considerRecovery: return SendmeterStyle.alert
        }
    }

    private var basis: String {
        let band = phase.acwrBandText
        switch guidance.state {
        case .continueCurrent:
            return "Still in the fresh part of the typical \(phase.weeks) window with load \(loadText(band))."
        case .reviewDuration:
            return "You are nearing or past the typical \(phase.weeks) range. Review whether this block has run its course."
        case .considerNext:
            let nextName = PhaseCatalog.definition(for: guidance.nextPhase ?? phase.id).name
            return "Past the typical \(phase.weeks) range with load on target (\(band)). \(nextName) is the natural next block."
        case .considerRecovery:
            return "Your readiness is \(readinessText(guidance.signals.readiness)) and load is \(loadText(band)). Consider recovery before pushing on."
        }
    }

    private func loadText(_ band: String) -> String {
        switch guidance.signals.load {
        case .onTarget: return "on target (\(band))"
        case .above: return "above the \(band) target"
        case .below: return "below the \(band) target"
        case .noData: return "no recent ACWR data"
        }
    }

    private func readinessText(_ signal: BlockReadinessSignal) -> String {
        switch signal {
        case .stable: return "stable"
        case .low: return "low"
        case .falling: return "falling"
        case .noData: return "unknown"
        }
    }
}

private struct PhaseSelectionCard: View {
    let phase: PhaseDefinition
    let isCurrent: Bool
    let select: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(phase.name)
                        .font(.title2.bold())
                        .foregroundStyle(SendmeterStyle.phaseColor(phase.id))
                    Spacer()
                    if isCurrent {
                        StatusPill("Your current block", color: SendmeterStyle.phaseColor(phase.id))
                    }
                }
                if isCurrent {
                    Text("Selected by you")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(phase.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Label(phase.weeks, systemImage: "calendar")
                    Spacer()
                    Label(phase.intensity, systemImage: "gauge.with.dots.needle.67percent")
                    Spacer()
                    Label(phase.acwrBandText, systemImage: "chart.line.uptrend.xyaxis")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(phase.tools, id: \.self) { tool in
                        Label(tool, systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                }
                if !isCurrent {
                    Button("Start \(phase.name) Block", action: select)
                        .hapticButtonStyle(.borderedProminent)
                        .tint(SendmeterStyle.phaseColor(phase.id))
                }
            }
        }
    }
}

private struct PhaseTimelineCard: View {
    let periods: [PhasePeriod]

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Your block history", systemImage: "clock.arrow.circlepath")
                if periods.isEmpty {
                    Text("The first block change will start the historical timeline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(periods) { period in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(SendmeterStyle.phaseColor(period.phase))
                                .frame(width: 10, height: 10)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(PhaseCatalog.definition(for: period.phase).name)
                                    .font(.headline)
                                Text(period.endedOn.map { "\(period.startedOn) – \($0)" } ?? "\(period.startedOn) – Present")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if period.id != periods.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

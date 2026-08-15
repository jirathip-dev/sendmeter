import SendmeterCore
import SwiftUI

struct PhasesView: View {
    @EnvironmentObject private var model: AppModel
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

    private var stepBack: PhaseStepBackSuggestion {
        TrainingMetrics.phaseStepBackSuggestion(
            readinessHistory: model.healthMetrics,
            currentPhase: model.settings.currentPhase
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    CurrentBlockCard(
                        phase: model.currentPhase,
                        age: blockAge,
                        acwr: model.acwr.ratio
                    )

                    if stepBack.suggested {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 9) {
                                Label("Review training load", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline)
                                    .foregroundStyle(SendmeterStyle.caution)
                                Text("Readiness has been below 40 for \(stepBack.streakDays) consecutive days during a loading block. Consider stepping back or adding recovery; Sendmeter will not change your block automatically.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

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

private struct CurrentBlockCard: View {
    let phase: PhaseDefinition
    let age: BlockAge?
    let acwr: Double?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel("Current block", systemImage: "square.stack.3d.up.fill")
                        Text(phase.name)
                            .font(.largeTitle.bold())
                            .foregroundStyle(SendmeterStyle.phaseColor(phase.id))
                    }
                    Spacer()
                    if let age {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Week \(age.week)")
                                .font(.title3.bold().monospacedDigit())
                            Text("Day \(age.dayInWeek)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(phase.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    StatusPill(phase.weeks, color: SendmeterStyle.phaseColor(phase.id))
                    StatusPill(phase.intensity, color: SendmeterStyle.phaseColor(phase.id))
                    if let acwr {
                        StatusPill("ACWR \(acwr.formatted(.number.precision(.fractionLength(2))))", color: acwrColor(acwr))
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
                        StatusPill("Current", color: SendmeterStyle.phaseColor(phase.id))
                    }
                }
                Text(phase.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Label(phase.weeks, systemImage: "calendar")
                    Spacer()
                    Label(phase.intensity, systemImage: "gauge.with.dots.needle.67percent")
                    Spacer()
                    Label("\(phase.acwrLow.formatted(.number.precision(.fractionLength(1))))–\(phase.acwrHigh.formatted(.number.precision(.fractionLength(1))))", systemImage: "chart.line.uptrend.xyaxis")
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
                        .buttonStyle(.borderedProminent)
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
                SectionLabel("Block history", systemImage: "clock.arrow.circlepath")
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

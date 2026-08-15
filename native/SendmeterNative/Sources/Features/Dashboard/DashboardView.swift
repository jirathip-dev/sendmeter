import Charts
import SendmeterCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false
    @State private var showPhases = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    TodayDecisionCard()
                    PhaseCard(showPhases: $showPhases)
                    LoadCard()
                    RecentSessionsCard()
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLog = true } label: {
                        Label("Log Session", systemImage: "plus.circle.fill")
                    }
                }
            }
            .refreshable { await model.refreshAll(showSpinner: false) }
            .sheet(isPresented: $showLog) {
                LogSessionSheet()
            }
            .sheet(isPresented: $showPhases) {
                PhasesView()
            }
        }
    }
}

private struct TodayDecisionCard: View {
    @EnvironmentObject private var model: AppModel

    private var readinessColor: Color {
        guard let readiness = model.readiness?.readiness else { return .secondary }
        if readiness < 40 { return SendmeterStyle.alert }
        if readiness > 70 { return SendmeterStyle.optimal }
        return SendmeterStyle.caution
    }

    private var recommendation: String {
        guard let readiness = model.readiness?.readiness else {
            return "Sync Apple Health to build today's recommendation."
        }
        if readiness < 40 { return "Recover — keep intensity low and reduce volume." }
        if readiness > 70 { return "Ready to train — use the planned block intensity." }
        return "Maintain — train, but keep one rep in reserve."
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Today's decision", systemImage: "sparkles")
                    Spacer()
                    if let zone = model.readiness?.zone {
                        StatusPill(zone.capitalized, color: readinessColor)
                    }
                }

                HStack(alignment: .center, spacing: 20) {
                    if let score = model.readiness?.readiness {
                        ZStack {
                            Circle()
                                .stroke(readinessColor.opacity(0.18), lineWidth: 10)
                            Circle()
                                .trim(from: 0, to: CGFloat(score) / 100)
                                .stroke(
                                    readinessColor,
                                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                            Text("\(score)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(width: 92, height: 92)
                    } else {
                        Image(systemName: "heart.text.square")
                            .font(.system(size: 54))
                            .foregroundStyle(.secondary)
                            .frame(width: 92, height: 92)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(recommendation)
                            .font(.title3.weight(.semibold))
                        Text("\(model.currentPhase.name) Training Block")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let ratio = model.acwr.ratio {
                            Text("Load ratio \(ratio, format: .number.precision(.fractionLength(2))) · \(TrainingMetrics.acwrStatus(ratio).rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct PhaseCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPhases: Bool

    private var age: BlockAge? {
        TrainingMetrics.phaseBlockAge(
            periods: model.phasePeriods,
            currentPhase: model.settings.currentPhase,
            fallbackStartDate: model.settings.phaseStartDate,
            referenceDate: LocalDateSupport.string(from: Date())
        )
    }

    var body: some View {
        Button { showPhases = true } label: {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Training Block", systemImage: "calendar.badge.clock")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(SendmeterStyle.phaseColor(model.settings.currentPhase))
                            .frame(width: 8, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.currentPhase.name)
                                .font(.title2.bold())
                            Text(age.map { "Week \($0.week) · Day \($0.totalDays)" } ?? model.currentPhase.weeks)
                                .foregroundStyle(.secondary)
                            Text(model.currentPhase.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LoadCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Training load", systemImage: "chart.bar.fill")
                    Spacer()
                    StatusPill(
                        TrainingMetrics.acwrStatus(model.acwr.ratio).rawValue,
                        color: statusColor
                    )
                }
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("Acute")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.acwr.acute, format: .number.precision(.fractionLength(0)))
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading) {
                        Text("Chronic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.acwr.chronic, format: .number.precision(.fractionLength(0)))
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading) {
                        Text("ACWR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.acwr.ratio.map { String(format: "%.2f", $0) } ?? "—")
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                }

                Chart(model.weeklyLoads) { item in
                    BarMark(
                        x: .value("Week", item.label),
                        y: .value("Load", item.total)
                    )
                    .foregroundStyle(SendmeterStyle.primary.gradient)
                    .cornerRadius(5)
                }
                .frame(height: 150)
                .chartYAxis { AxisMarks(position: .leading) }
            }
        }
    }

    private var statusColor: Color {
        switch TrainingMetrics.acwrStatus(model.acwr.ratio) {
        case .optimal: return SendmeterStyle.optimal
        case .low, .underTraining: return SendmeterStyle.primary
        case .caution: return SendmeterStyle.caution
        case .danger: return SendmeterStyle.alert
        case .noData: return .secondary
        }
    }
}

private struct RecentSessionsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Recent sessions", systemImage: "clock")
                    Spacer()
                    Button("View all") { model.selectedTab = .history }
                        .font(.caption.weight(.semibold))
                }
                if model.recentSessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "figure.climbing",
                        description: Text("Log your first training session or start a workout.")
                    )
                } else {
                    ForEach(model.recentSessions) { session in
                        SessionSummaryRow(session: session)
                        if session.id != model.recentSessions.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct SessionSummaryRow: View {
    let session: SendmeterCore.Session

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SendmeterStyle.phaseColor(session.phase).opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: session.workoutSource == .watch ? "applewatch" : "figure.climbing")
                        .foregroundStyle(SendmeterStyle.phaseColor(session.phase))
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.typeLabel)
                        .font(.subheadline.weight(.semibold))
                    if session.pending {
                        StatusPill("Syncing", color: SendmeterStyle.caution)
                    }
                }
                Text("\(session.date) · \(session.durationMinutes) min · RPE \(session.rpe, format: .number.precision(.fractionLength(0...1)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.load, format: .number.precision(.fractionLength(0)))
                .font(.headline.monospacedDigit())
        }
        .contentShape(Rectangle())
    }
}

private struct LogSessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var typeID = "fingerboard"
    @State private var duration = 45
    @State private var rpe = 6.0
    @State private var note = ""

    private var selectedType: SessionTypeDefinition {
        SessionTypeCatalog.definition(for: typeID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Type", selection: $typeID) {
                        ForEach(SessionTypeCatalog.all) { type in
                            Text(type.label).tag(type.id)
                        }
                    }
                    Stepper("Duration: \(duration) min", value: $duration, in: 1...600, step: 5)
                }

                Section("Effort") {
                    HStack {
                        Text("RPE")
                        Slider(value: $rpe, in: 1...10, step: 0.5)
                        Text(rpe, format: .number.precision(.fractionLength(0...1)))
                            .monospacedDigit()
                            .frame(width: 32)
                    }
                    Text("Training load: \(Double(duration) * rpe, format: .number.precision(.fractionLength(0)))")
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle("Log Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let draft = SessionDraft(
                            date: LocalDateSupport.string(from: date),
                            type: typeID,
                            typeLabel: selectedType.label,
                            durationMinutes: duration,
                            rpe: rpe,
                            note: note,
                            phase: model.settings.currentPhase
                        )
                        Task {
                            await model.logSession(draft)
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: typeID) { newValue in
                let definition = SessionTypeCatalog.definition(for: newValue)
                duration = definition.defaultDurationMinutes
                rpe = definition.defaultRPE
            }
        }
    }
}

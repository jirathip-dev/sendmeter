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
                    ReadinessTrendCard()
                    HStack(alignment: .top, spacing: 16) {
                        PhaseCard(showPhases: $showPhases)
                        SendConditionsCard()
                    }
                    LoadCard()
                    AcwrProjectionCard()
                    RecentSessionsCard()
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // #656: a tap opening a sheet arms the presentation
                        // tick.
                        Haptics.shared.tap()
                        showLog = true
                    } label: {
                        Label("Log Session", systemImage: "plus.circle.fill")
                    }
                }
            }
            .refreshable {
                // #661 (finding 5): pull-to-refresh is the ONLY user-initiated
                // HealthKit resync — run the full server refetch AND a manual
                // (authoritative, #109 bypass) readiness recompute.
                await model.refreshAll(showSpinner: false)
                await model.silentHealthRefresh(trigger: .manual)
            }
            .task {
                // #661: on Dashboard appear, silently refresh readiness/health
                // (gated on HealthKit authorization; the read is automatic).
                // A failed or empty refresh keeps the last reading — never
                // blank, never fabricated.
                await model.silentHealthRefresh(trigger: .appear)
            }
            .sheet(isPresented: $showLog) {
                LogSessionSheet()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showPhases) {
                PhasesView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
        }
    }
}

private struct TodayDecisionCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private func readinessColor(_ scheme: ColorScheme) -> Color {
        guard let readiness = model.readiness?.readiness else { return .secondary }
        if readiness < 40 { return ChartToken.alert.color(scheme) }
        if readiness > 70 { return ChartToken.optimal.color(scheme) }
        return ChartToken.caution.color(scheme)
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
                    if model.health.isSyncing {
                        // #661: the auto-sync runs silently, but the pill says
                        // it's in-flight — no prolonged stale flash.
                        StatusPill("Syncing", color: SendmeterStyle.caution)
                    } else if let zone = model.readiness?.zone {
                        StatusPill(zone.capitalized, color: readinessColor(scheme))
                    }
                }

                HStack(alignment: .center, spacing: 20) {
                    if let score = model.readiness?.readiness {
                        let color = readinessColor(scheme)
                        ZStack {
                            Circle()
                                .stroke(color.opacity(0.18), lineWidth: 10)
                            Circle()
                                .trim(from: 0, to: CGFloat(score) / 100)
                                .stroke(
                                    color,
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
        Button {
            // #656: a tap opening a sheet arms the presentation tick.
            Haptics.shared.tap()
            showPhases = true
        } label: {
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
    @Environment(\.colorScheme) private var scheme
    @State private var showTrainingLoad = false

    var body: some View {
        Button { showTrainingLoad = true } label: {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionLabel("Training load", systemImage: "chart.bar.fill")
                        Spacer()
                        StatusPill(
                            TrainingMetrics.acwrStatus(model.acwr.ratio).rawValue,
                            color: statusColor(scheme)
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
                        .foregroundStyle(ChartToken.load.areaGradient(scheme))
                        .cornerRadius(5)
                    }
                    .frame(height: 150)
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                            AxisValueLabel().foregroundStyle(ChartToken.axis.color(scheme))
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showTrainingLoad) {
            TrainingLoadSheet()
        }
    }

    private func statusColor(_ scheme: ColorScheme) -> Color {
        ChartToken.acwrStatusColor(model.acwr.ratio, scheme)
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
                    if #available(iOS 17, *) {
                        ContentUnavailableView(
                            "No sessions yet",
                            systemImage: "figure.climbing",
                            description: Text("Log your first training session or start a workout.")
                        )
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "figure.climbing")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No sessions yet").font(.headline)
                            Text("Log your first training session or start a workout.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
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
                        StatusPill(
                            session.rejected ? "Rejected" : "Syncing",
                            color: session.rejected ? SendmeterStyle.alert : SendmeterStyle.caution
                        )
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

/// "Send conditions" (SL-69, #631): temperature + humidity → a climbing
/// friction score, fetched from Open-Meteo for the device's location. The
/// first check is user-initiated (so the location prompt is a tap away, web
/// parity); once a reading exists it silently refreshes on appear/foreground
/// and a failed refresh keeps the last reading — never a fabricated score.
private struct SendConditionsCard: View {
    @EnvironmentObject private var model: AppModel

    /// Percentile-first framing (SL-91): a hot-climate day that's good FOR
    /// HERE reads green even when the absolute score is low.
    private func label(for conditions: SendConditions) -> SendConditionsLabel {
        if let percentile = conditions.percentile {
            return SendConditionsScore.percentileLabel(percentile)
        }
        return conditions.label
    }

    private func color(for conditions: SendConditions) -> Color {
        if let percentile = conditions.percentile {
            if percentile >= 75 { return SendmeterStyle.optimal }
            if percentile >= 40 { return SendmeterStyle.caution }
            return SendmeterStyle.alert
        }
        if conditions.score >= 55 { return SendmeterStyle.optimal }
        if conditions.score >= 35 { return SendmeterStyle.caution }
        return SendmeterStyle.alert
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Send Conditions", systemImage: "cloud.sun")
                    Spacer()
                    if model.weather.isFetching {
                        ProgressView()
                    }
                }

                if let conditions = model.weather.conditions {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("\(conditions.score)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(color(for: conditions))
                            VStack(alignment: .leading, spacing: 2) {
                                StatusPill(label(for: conditions).rawValue, color: color(for: conditions))
                                Text("\(Int(conditions.tempC.rounded()))°C · \(Int(conditions.humidity.rounded()))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let percentile = conditions.percentile {
                            Text("\(SendConditionsScore.percentileDetail(percentile)) of the last \(conditions.daysTotal ?? 0) days at this hour")
                                .font(.caption)
                                .foregroundStyle(color(for: conditions))
                        }
                        Text("Updated \(conditions.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if model.weather.failed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unavailable")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Enable location and check your connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { _ = await model.weather.refresh() }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                } else {
                    Button {
                        Task { _ = await model.weather.refresh() }
                    } label: {
                        Text("Check")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("Temperature + humidity at your location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            // Silent refresh when a reading already exists; a cold first run
            // waits for the Check tap so the location prompt is user-initiated.
            if model.weather.conditions != nil {
                _ = await model.weather.refresh()
            }
        }
    }
}

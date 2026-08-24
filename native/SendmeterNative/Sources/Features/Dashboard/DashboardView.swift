import Charts
import SendmeterCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false
    @State private var showPhases = false
    @State private var showRecovery = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    TodayDecisionCard(showRecovery: $showRecovery)
                    ReadinessTrendCard()
                    // #704: reserve the largest Send Conditions state before
                    // equalizing both cards to the same measured row height.
                    DashboardContextRow(spacing: 16) {
                        PhaseCard(showPhases: $showPhases)
                            .frame(maxHeight: .infinity, alignment: .top)
                        SendConditionsCard()
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LoadCard()
                    // #748 round 2: the ACWR status card is the canonical
                    // Training Load surface (ratio + status + phase-fit + risk
                    // track + Acute/Chronic, tap opens TrainingLoadSheet).
                    // LoadCard is now the weekly-load chart card only — it no
                    // longer shows the three load numbers or opens the sheet.
                    AcwrStatusCard()
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
            .sheet(isPresented: $showLog, onDismiss: { Haptics.shared.sheetDismissed() }) {
                LogSessionSheet()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showPhases, onDismiss: { Haptics.shared.sheetDismissed() }) {
                PhasesView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showRecovery, onDismiss: { Haptics.shared.sheetDismissed() }) {
                RecoveryInputsSheet()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
        }
    }
}

/// A two-column row that measures its children at their actual column width,
/// then places both at the tallest measured height with a shared bottom edge.
/// The Send Conditions card supplies hidden state reservations, so this height
/// is stable across its empty, failed, and populated states while still
/// following Dynamic Type.
private struct DashboardContextRow: Layout {
    private let spacing: CGFloat

    init(spacing: CGFloat = 16) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = resolvedWidth(proposal: proposal, subviews: subviews)
        let columnWidth = columnWidth(totalWidth: width, count: subviews.count)
        let heights = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }

        return CGSize(
            width: width,
            height: DashboardCardLayout.equalizedRowHeight(heights)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let columnWidth = columnWidth(totalWidth: bounds.width, count: subviews.count)
        let rowHeight = bounds.height

        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (columnWidth + spacing)
            subview.place(
                at: CGPoint(x: x, y: bounds.maxY),
                anchor: .bottomLeading,
                proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
            )
        }
    }

    private func resolvedWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width { return width }

        let idealWidth = subviews.reduce(CGFloat.zero) { total, subview in
            total + subview.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width
        }
        return idealWidth + spacing * CGFloat(max(0, subviews.count - 1))
    }

    private func columnWidth(totalWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let totalSpacing = spacing * CGFloat(max(0, count - 1))
        return max(0, (totalWidth - totalSpacing) / CGFloat(count))
    }
}

private struct TodayDecisionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Binding var showRecovery: Bool

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
        Button {
            // #656: a tap opening a sheet arms the presentation tick.
            Haptics.shared.tap()
            showRecovery = true
        } label: {
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
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
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
        .hapticButtonStyle(.plain)
        .accessibilityHint("Shows the raw HealthKit metrics behind today's readiness score.")
    }
}

private struct PhaseCard: View {
    @Environment(AppModel.self) private var model
    @Binding var showPhases: Bool

    private var age: BlockAge? {
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
            age: age,
            acwr: model.acwr.ratio,
            readinessHistory: model.healthMetrics
        )
    }

    private var guidanceLine: String {
        switch guidance.state {
        case .continueCurrent:
            return "On track — keep building"
        case .reviewDuration:
            return "Near the end of a typical block — review timing"
        case .considerNext:
            let next = guidance.nextPhase.map { PhaseCatalog.definition(for: $0).name } ?? model.currentPhase.name
            return "Consider \(next) next"
        case .considerRecovery:
            return "Readiness low or falling — consider recovery"
        }
    }

    var body: some View {
        Button {
            // #656: a tap opening a sheet arms the presentation tick.
            Haptics.shared.tap()
            showPhases = true
        } label: {
            SurfaceCard(fillsHeight: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Your current block", systemImage: "calendar.badge.clock")
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
                            Text("You selected this block on \(LocalDateSupport.monthDayLabel(for: canonicalStart))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(guidanceLine)
                                .font(.caption)
                                .foregroundStyle(SendmeterStyle.phaseColor(model.settings.currentPhase))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .hapticButtonStyle(.plain)
    }
}

/// Weekly-load bar chart card (#748 round 2). The ACWR status card
/// (`AcwrStatusCard`) is the canonical Training Load surface — the three load
/// numbers (Acute/Chronic/ACWR), the status pill, and the open-sheet
/// affordance live there. This card keeps only the weekly bars + chart title,
/// so the numbers and the open-sheet affordance are never duplicated.
private struct LoadCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Training load", systemImage: "chart.bar.fill")
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
}

private struct RecentSessionsCard: View {
    @Environment(AppModel.self) private var model

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
    @Environment(AppModel.self) private var model
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
    @Environment(AppModel.self) private var model
    @State private var showSendConditions = false

    private var state: SendConditionsCardContent.State {
        if let conditions = model.weather.conditions {
            return .populated(conditions)
        }
        return model.weather.failed ? .failed : .empty
    }

    private func refresh() {
        Task { _ = await model.weather.refresh(trigger: .manual) }
    }

    private func openSheet() {
        Haptics.shared.tap()
        showSendConditions = true
    }

    var body: some View {
        SurfaceCard(fillsHeight: true) {
            ZStack(alignment: .topLeading) {
                SendConditionsCardContent(
                    state: state,
                    isFetching: model.weather.isFetching,
                    refresh: refresh,
                    open: openSheet
                )

                // Reserve every real state at the current Dynamic Type before
                // the row measures this card. Always include the ProgressView
                // footprint: using the live fetching value here would let the
                // row grow when loading starts and shrink when it finishes.
                // Hidden views keep their layout size but add no pixels or
                // accessibility elements.
                SendConditionsCardContent(
                    state: .empty,
                    isFetching: true,
                    refresh: {},
                    open: openSheet
                )
                .hidden()
                .accessibilityHidden(true)
                SendConditionsCardContent(
                    state: .failed,
                    isFetching: true,
                    refresh: {},
                    open: openSheet
                )
                .hidden()
                .accessibilityHidden(true)
                SendConditionsCardContent(
                    state: .populated(SendConditionsCardContent.layoutReservation),
                    isFetching: true,
                    refresh: {},
                    open: openSheet
                )
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showSendConditions, onDismiss: { Haptics.shared.sheetDismissed() }) {
            SendConditionsDetailSheet()
                .onAppear { Haptics.shared.sheetPresented() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send Conditions")
        .accessibilityHint("Opens Send Conditions details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openSheet() }
        .task {
            // Silent refresh when a reading already exists; a cold first run
            // waits for the Check tap so the location prompt is user-initiated.
            if model.weather.conditions != nil {
                _ = await model.weather.refresh(trigger: .appear)
            }
        }
    }
}

private struct SendConditionsCardContent: View {
    /// A representative maximum populated footprint. These values describe
    /// the actual data domain (three-digit score/temperature, 100% humidity,
    /// the longest percentile label, and the inclusive ~30-day archive) and
    /// are used only to measure the real populated rendering path.
    static let layoutReservation = SendConditions(
        tempC: -99,
        humidity: 100,
        score: 100,
        label: .prime,
        percentile: 49,
        daysBelow: 15,
        daysTotal: 31,
        hourOfDay: 0,
        hist: nil,
        fetchedAt: Date(timeIntervalSince1970: 86_340)
    )

    enum State {
        case empty
        case failed
        case populated(SendConditions)
    }

    let state: State
    let isFetching: Bool
    let refresh: () -> Void
    let open: () -> Void

    /// Percentile-first framing (SL-91): a hot-climate day that's good FOR
    /// HERE reads green even when the absolute score is low.
    private func label(for conditions: SendConditions) -> SendConditionsLabel {
        SendConditionsScore.displayLabel(for: conditions)
    }

    private func color(for conditions: SendConditions) -> Color {
        SendConditionsScore.colorBand(for: conditions).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    SectionLabel("Send Conditions", systemImage: "cloud.sun")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .hapticTap()
                .onTapGesture(perform: open)
                Spacer()
                if isFetching {
                    ProgressView()
                }
            }

            stateContent
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .populated(let conditions):
            populatedContent(conditions)
                .contentShape(Rectangle())
                .hapticTap()
                .onTapGesture(perform: open)
        case .failed:
            failedContent
        case .empty:
            emptyContent
        }
    }

    private func populatedContent(_ conditions: SendConditions) -> some View {
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
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unavailable")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Enable location and check your connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Try Again", action: refresh)
                .font(.subheadline.weight(.semibold))
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: refresh) {
                Text("Check")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Temperature + humidity at your location.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

import SendmeterCore
import SwiftUI

/// #630: the expanded detail for a session in the combined History timeline —
/// the native counterpart of the web's `SessionRow` detail sheet. Tindeq
/// sessions show their recordings (grouped by tag) with per-rep box plots +
/// the zone-mix badge; workout sessions show the summary card plus an HR
/// chart drawn from the `climb_workouts.raw` trace (#645), fetched
/// lazily on expand — the list fetch (`fetchWorkouts`) deliberately never
/// selects `raw`, exactly like the recording-samples pattern.
struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let session: SendmeterCore.Session

    @State private var boxStatsByID: [UUID: BoxStats] = [:]
    @State private var loadingSamples = false
    /// #755: shared scrub position for the stacked HR and effort charts. The
    /// parent owns it so the two charts stay perfectly aligned, and the
    /// haptic guard stays here too so crossing into a different sample or
    /// attempt ticks once for the whole visible chart group.
    @State private var selectedWorkoutTime: Double?
    @State private var tickedWorkoutSelection: String?
    /// #645: the lazily-fetched detail for this session's workout — the HR
    /// trace, its fetch state and the attempt windows. A 4-state model
    /// (notLoaded/loading/loaded/failed) so a null/empty `raw` on a watch
    /// workout reads as "still syncing" (AC4), never as an empty chart, and
    /// a failed fetch degrades in-card with a retry instead of raising the
    /// app-wide error banner (#645 review F2/F6).
    private enum WorkoutTraceState: Equatable {
        case notLoaded
        case loading
        case loaded(trace: [WorkoutHrSample], attempts: [WorkoutAttempt])
        case failed
    }

    @State private var traceState: WorkoutTraceState = .notLoaded

    private var isTindeq: Bool { session.type == "tindeq" && session.groupID != nil }
    private var isWorkout: Bool { session.workoutSource != nil }

    private var groupRecordings: [TindeqRecording] {
        guard let groupID = session.groupID else { return [] }
        return model.recordings.filter { $0.groupID == groupID }
    }

    private var zoneMix: [ZoneQuality: Double] {
        ZoneMix.zoneSets(groupRecordings)
    }

    private var dominantZone: ZoneQuality? {
        ZoneMix.dominantZone(zoneMix)
    }

    private var workout: WorkoutListItem? {
        model.workouts.first { $0.sessionID == session.id }
    }

    private var tagGroups: [(tag: String, recs: [TindeqRecording])] {
        var result: [(tag: String, recs: [TindeqRecording])] = []
        for recording in groupRecordings {
            if let index = result.firstIndex(where: { $0.tag == recording.tag }) {
                result[index].recs.append(recording)
            } else {
                result.append((recording.tag, [recording]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                headerCard
                if isTindeq {
                    recordingsSection
                } else if isWorkout {
                    workoutSummaryCard
                    workoutChartsSection
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(session.typeLabel)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedWorkoutTime) { _ in
            handleWorkoutScrubHaptic()
        }
        .onDisappear {
            selectedWorkoutTime = nil
            tickedWorkoutSelection = nil
        }
        .task {
            await loadSamples()
            await loadWorkoutDetail()
        }
    }

    // MARK: Header

    private var headerCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let dominantZone {
                        ZoneBadge(zone: dominantZone, mix: zoneMix)
                    }
                    if session.pending {
                        StatusPill(
                            session.rejected ? "Rejected" : "Pending",
                            color: session.rejected ? SendmeterStyle.alert : SendmeterStyle.caution
                        )
                    }
                    if isWorkout {
                        StatusPill(
                            session.workoutSource == .watch ? "Watch" : "Phone",
                            color: SendmeterStyle.primary
                        )
                    }
                }
                Text(session.note.isEmpty ? PhaseCatalog.definition(for: session.phase).name : session.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(session.date)", systemImage: "calendar")
                    Label("\(session.durationMinutes) min", systemImage: "clock")
                    Label("RPE \(session.rpe.formatted(.number.precision(.fractionLength(0...1))))", systemImage: "gauge")
                    Label("\(Int(session.load)) AU", systemImage: "bolt")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Tindeq recordings

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loadingSamples {
                ProgressView("Loading force curves…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if groupRecordings.isEmpty {
                Text("No recordings in this session")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ForEach(tagGroups.indices, id: \.self) { index in
                    tagGroupCard(tagGroups[index])
                }
            }
        }
    }

    private func tagGroupCard(_ group: (tag: String, recs: [TindeqRecording])) -> some View {
        let chronological = group.recs.sorted { $0.recordedAt < $1.recordedAt }
        let measured = group.recs.compactMap { recording -> TindeqRecording? in
            recording.source == .dynamometer && recording.peakKilograms != nil ? recording : nil
        }
        let best = measured.map(\.peakKilograms).compactMap { $0 }.max()
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(group.tag.isEmpty ? "Untagged" : group.tag)
                        .font(.headline)
                    Spacer()
                    Text("\(group.recs.count) entr\(group.recs.count == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let best {
                        Text("best \(best.formatted(.number.precision(.fractionLength(1)))) kg")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(SendmeterStyle.primary)
                    }
                }
                if !chronological.isEmpty {
                    RepBoxPlotCanvas(
                        reps: chronological.map {
                            RepBoxPlotEntry(recording: $0, stats: boxStatsByID[$0.id])
                        },
                        bestIndex: bestIndex(in: chronological)
                    )
                }
                ForEach(chronological) { recording in
                    NavigationLink {
                        ForceRecordingDetailView(recording: recording)
                    } label: {
                        sessionRecordingRow(recording)
                    }
                    .hapticButtonStyle(.plain)
                }
            }
        }
    }

    private func sessionRecordingRow(_ recording: TindeqRecording) -> some View {
        HStack(spacing: 10) {
            Image(systemName: recording.protocolMode == .reverseAction ? "arrow.left.and.right.circle.fill" : "waveform.path.ecg")
                .foregroundStyle(SendmeterStyle.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle(for: recording))
                    .font(.subheadline)
                if let metrics = recording.setMetrics {
                    Text("Mean \(metrics.meanKilograms?.formatted(.number.precision(.fractionLength(1))) ?? "–") kg · In-target \(metrics.inTargetPercent?.formatted(.number.precision(.fractionLength(1))) ?? "–")% · Cadence \(metrics.cadenceAdherencePercent.formatted(.number.precision(.fractionLength(1))))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text((recording.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1))) + " kg")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .contentShape(Rectangle())
    }

    private func subtitle(for recording: TindeqRecording) -> String {
        var parts: [String] = []
        if let setNumber = recording.setNumber {
            if recording.protocolMode == .reverseAction {
                let completed = recording.completedRepetitions ?? 0
                parts.append("Set \(setNumber) · \(completed) reps")
            } else {
                parts.append("Set \(setNumber) · Rep \(recording.repetitionNumber ?? 1)")
            }
        }
        if recording.side != .unspecified { parts.append(recording.side.label) }
        if let zone = recording.zone { parts.append(zone.displayLabel) }
        if parts.isEmpty { parts.append(recording.recordedAt.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private func bestIndex(in chronological: [TindeqRecording]) -> Int {
        guard let first = chronological.first else { return 0 }
        var best = first
        var bestIndex = 0
        for (index, recording) in chronological.enumerated() {
            let peak = recording.peakKilograms ?? -Double.infinity
            if peak > (best.peakKilograms ?? -Double.infinity) {
                best = recording
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: Workout summary

    private var workoutSummaryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Workout", systemImage: "figure.climbing")
                if let workout {
                    // The web's WorkoutDetailPanel — six rows, "—" for nulls.
                    LabeledContent("Average HR", value: workout.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "—")
                    LabeledContent("Max HR", value: workout.maxHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "—")
                    LabeledContent("Active", value: workout.activeKilocalories.map { "\(Int($0.rounded())) kcal" } ?? "—")
                    LabeledContent(
                        "Elev gain",
                        value: workout.elevationGainMeters.map { "+\($0.formatted(.number.precision(.fractionLength(1))))m" } ?? "—"
                    )
                    LabeledContent("Attempts", value: "\(workout.attemptsConfirmed) confirmed · \(workout.attemptsDetected) detected")
                    LabeledContent(
                        "RPE",
                        value: "\(workout.rpeConfirmed.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—") conf · \(workout.rpePredicted.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—") pred"
                    )
                    LabeledContent(
                        "Source",
                        value: workout.source == .watch ? "Auto-tracked by the watch" : "Logged on the phone"
                    )
                } else {
                    Text("No workout data for this session")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: HR trace + effort (#645)

    /// The HR chart card, below the summary, plus the effort chart stacked on
    /// the SAME x-domain (AC3). The raw trace and attempts are fetched lazily
    /// here (like `fetchRecordingSamples`), never on the list.
    ///
    /// The trace's fetch state is a 4-state model (F2):
    /// - loading → spinner;
    /// - loaded, trace renderable → the charts;
    /// - loaded, trace nil/empty → "still syncing" for a watch workout
    ///   (the watch uploads it in the background), nothing for a phone one;
    /// - failed → a quiet in-card "couldn't load" state with a retry, never
    ///   the app-wide error banner.
    @ViewBuilder
    private var workoutChartsSection: some View {
        if let workout {
            switch traceState {
            case .notLoaded:
                EmptyView()
            case .loading:
                SurfaceCard {
                    ProgressView("Loading heart-rate trace…")
                        .frame(maxWidth: .infinity, minHeight: 100)
                }
            case let .loaded(trace, attempts):
                let chartTMax = WorkoutChartAxis.timeMaxS(
                    startedAt: workout.startedAt,
                    endedAt: workout.endedAt,
                    attempts: attempts,
                    samples: trace
                )
                if WorkoutRawTrace.isChartRenderable(trace) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            WorkoutHrChartView(
                                samples: trace,
                                attempts: attempts,
                                startedAt: workout.startedAt,
                                endedAt: workout.endedAt,
                                source: workout.source,
                                tMax: chartTMax,
                                selectedTime: $selectedWorkoutTime
                            )
                            if !attempts.isEmpty {
                                WorkoutEffortChartView(
                                    attempts: attempts,
                                    startedAt: workout.startedAt,
                                    tMax: chartTMax,
                                    selectedTime: $selectedWorkoutTime
                                )
                            }
                        }
                    }
                } else {
                    if workout.source == .watch {
                        // AC4: a watch workout whose trace has not uploaded
                        // yet gets reassurance, not a blank box.
                        SurfaceCard {
                            WorkoutHrChartView(
                                samples: [],
                                attempts: attempts,
                                startedAt: workout.startedAt,
                                endedAt: workout.endedAt,
                                source: workout.source,
                                tMax: chartTMax,
                                selectedTime: $selectedWorkoutTime
                            )
                        }
                    }
                    if !attempts.isEmpty {
                        // Web parity: the effort chart stands alone when the
                        // trace is absent (a phone workout has attempts but
                        // never a trace).
                        SurfaceCard {
                            WorkoutEffortChartView(
                                attempts: attempts,
                                startedAt: workout.startedAt,
                                tMax: chartTMax,
                                selectedTime: $selectedWorkoutTime
                            )
                        }
                    }
                }
            case .failed:
                SurfaceCard {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Couldn't load the heart-rate trace.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await loadWorkoutDetail() } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    // MARK: Samples

    /// #755: one `.selection` tick per distinct HR sample or attempt the
    /// stacked charts expose. Both chart views write this same `selectedTime`
    /// binding, so a single parent-side guard prevents two ticks when the
    /// sibling observes the same scrub frame.
    private func handleWorkoutScrubHaptic() {
        guard case let .loaded(trace, attempts) = traceState, let workout else {
            tickedWorkoutSelection = nil
            return
        }
        let key = workoutSelectionKey(
            selectedWorkoutTime,
            trace: trace,
            attempts: attempts,
            startedAt: workout.startedAt
        )
        if let key {
            if SelectionHaptics.valueChanged(tickedWorkoutSelection, key) {
                tickedWorkoutSelection = key
                Haptics.shared.playGesture(.selection)
            }
        } else {
            tickedWorkoutSelection = nil
        }
    }

    private func workoutSelectionKey(
        _ time: Double?,
        trace: [WorkoutHrSample],
        attempts: [WorkoutAttempt],
        startedAt: Date
    ) -> String? {
        guard let time else { return nil }
        let runs = WorkoutRawTrace.downsampleRuns(
            trace,
            maxPoints: WorkoutRawTrace.maxChartPoints
        )
        let sample = WorkoutRawTrace.selectedSample(at: time, inRuns: runs)
        let attempt = attempts.first { attempt in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            return time >= start && time <= start + Double(attempt.durationSeconds)
        }
        if let sample {
            return "hr:\(sample.t)|attempt:\(attempt?.id.uuidString ?? "none")"
        }
        return attempt.map { "attempt:\($0.id.uuidString)" }
    }

    private func loadWorkoutDetail() async {
        guard isWorkout, let workout, traceState != .loading else { return }
        traceState = .loading
        defer { if traceState == .loading { traceState = .notLoaded } }
        do {
            let trace = try await model.repository.fetchWorkoutRaw(id: workout.id)
            let attempts = try await model.repository.fetchWorkoutAttempts(id: workout.id)
            traceState = .loaded(trace: trace ?? [], attempts: attempts)
        } catch is CancellationError {
            // Popped the detail mid-fetch — nothing to show, and the app-wide
            // banner must not say "cancelled" over History (#645 review F6).
        } catch let error as URLError where error.code == .cancelled {
            // Same — `session.data(for:)` surfaces cancellation as URLError.
        } catch {
            traceState = .failed
        }
    }

    private func loadSamples() async {
        guard isTindeq, !loadingSamples, boxStatsByID.isEmpty else { return }
        loadingSamples = true
        defer { loadingSamples = false }
        let ids = groupRecordings.map(\.id)
        let repository = model.repository
        await withTaskGroup(of: (UUID, BoxStats?).self) { group in
            for id in ids {
                group.addTask {
                    let samples = try? await repository.fetchRecordingSamples(id: id)
                    return (id, samples.flatMap { BoxPlot.boxStats($0.map(\.kilograms)) })
                }
            }
            for await (id, stats) in group {
                boxStatsByID[id] = stats
            }
        }
    }
}

/// One rep of a per-rep box-plot series; `stats` is nil while that rep's
/// samples are still loading (or genuinely absent) — the canvas draws a faint
/// baseline tick for it instead of a gap.
struct RepBoxPlotEntry: Sendable {
    let recording: TindeqRecording
    let stats: BoxStats?
}

/// Per-rep vertical box plot for one tag group (#630) — the force
/// distribution of every rep, side by side in chronological order, at a
/// glance. Classic Tukey boxes: Q1–Q3 + median tick, whiskers clamped to the
/// furthest in-fence point, outliers beyond. Side-colored (left = force,
/// right = forceSecondary); the session-best rep's median tick is called out
/// in the caution color. Port of the web's `RepBoxPlotChart` (minus
/// hover/scrub) with ChartTheme tokens (#649) so light/dark both match the
/// web palette.
struct RepBoxPlotCanvas: View {
    let reps: [RepBoxPlotEntry]
    /// Index (into `reps`) of the session-best rep by peak kg; first rep wins
    /// a tie.
    let bestIndex: Int
    @Environment(\.colorScheme) private var scheme
    @State private var selectedRepIndex: Int?
    @State private var tickedRepIndex: Int?
    @State private var tooltipSize: CGSize = .zero

    private static let maxOutlierDots = 12

    /// Left = force (indigo), right = forceSecondary (electric blue) — the
    /// web's `sideColor` (`RepBoxPlotChart.tsx`).
    private func sideColors(for side: TindeqSide) -> (stroke: ChartToken, fill: ChartToken) {
        side == .left ? (.force, .focus) : (.forceSecondary, .health)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let leftInset: CGFloat = 30
                let rightInset: CGFloat = 8
                let topInset: CGFloat = 8
                let bottomInset: CGFloat = 8
                let plotWidth = max(1, width - leftInset - rightInset)
                let plotHeight = max(1, height - topInset - bottomInset)
                let gridColor = ChartToken.grid.color(scheme)
                let axisColor = ChartToken.axis.color(scheme)

                var allValues: [Double] = []
                for rep in reps {
                    if let stats = rep.stats {
                        allValues.append(stats.whiskerLow)
                        allValues.append(stats.whiskerHigh)
                        allValues.append(contentsOf: stats.outliers)
                    }
                }
                let yMin: Double = allValues.isEmpty ? 0 : (allValues.min() ?? 0)
                let yMax: Double = allValues.isEmpty ? 1 : (allValues.max() ?? 1)
                let yPad = max((yMax - yMin) * 0.08, 0.5)
                let domainLow = yMin - yPad
                let domainHigh = yMax + yPad

                func y(_ value: Double) -> CGFloat {
                    topInset + plotHeight - CGFloat((value - domainLow) / (domainHigh - domainLow)) * plotHeight
                }

                for index in 1..<4 {
                    var grid = Path()
                    let gridY = topInset + plotHeight * CGFloat(index) / 4
                    grid.move(to: CGPoint(x: leftInset, y: gridY))
                    grid.addLine(to: CGPoint(x: width - rightInset, y: gridY))
                    context.stroke(grid, with: .color(gridColor), lineWidth: 1)
                }

                guard !reps.isEmpty else { return }
                let bandWidth = plotWidth / CGFloat(reps.count)
                let boxWidth = min(34, max(10, bandWidth * 0.6))
                let capWidth = boxWidth * 0.4

                for (index, rep) in reps.enumerated() {
                    let centerX = leftInset + bandWidth * (CGFloat(index) + 0.5)
                    let isSelected = selectedRepIndex == index
                    if isSelected {
                        let highlightRect = CGRect(
                            x: centerX - boxWidth / 2 - 2,
                            y: topInset + 2,
                            width: boxWidth + 4,
                            height: max(1, plotHeight - 4)
                        )
                        context.fill(
                            Path(roundedRect: highlightRect, cornerRadius: 4),
                            with: .color(axisColor.opacity(0.07))
                        )
                        context.stroke(
                            Path(roundedRect: highlightRect, cornerRadius: 4),
                            with: .color(axisColor.opacity(0.4)),
                            lineWidth: 1
                        )
                    }
                    guard let stats = rep.stats else {
                        // Fetched (or loading) with no samples — faint baseline.
                        var tick = Path()
                        tick.move(to: CGPoint(x: centerX - boxWidth / 2, y: y(domainLow)))
                        tick.addLine(to: CGPoint(x: centerX + boxWidth / 2, y: y(domainLow)))
                        context.stroke(
                            tick,
                            with: .color(axisColor.opacity(0.5)),
                            style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])
                        )
                        continue
                    }
                    let (strokeToken, fillToken) = sideColors(for: rep.recording.side)
                    let strokeColor = strokeToken.color(scheme)

                    var whisker = Path()
                    whisker.move(to: CGPoint(x: centerX, y: y(stats.whiskerLow)))
                    whisker.addLine(to: CGPoint(x: centerX, y: y(stats.whiskerHigh)))
                    context.stroke(whisker, with: .color(axisColor.opacity(0.7)), lineWidth: 1)

                    for value in [stats.whiskerLow, stats.whiskerHigh] {
                        var cap = Path()
                        cap.move(to: CGPoint(x: centerX - capWidth / 2, y: y(value)))
                        cap.addLine(to: CGPoint(x: centerX + capWidth / 2, y: y(value)))
                        context.stroke(cap, with: .color(axisColor.opacity(0.7)), lineWidth: 1)
                    }

                    let boxRect = CGRect(
                        x: centerX - boxWidth / 2,
                        y: y(stats.q3),
                        width: boxWidth,
                        height: max(0.5, y(stats.q1) - y(stats.q3))
                    )
                    let boxPath = Path(roundedRect: boxRect, cornerRadius: 2.5)
                    // Glassy vertical fill — the web's focus-area / health-area
                    // gradients (`ChartDefs.tsx`).
                    context.fill(
                        boxPath,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: fillToken.color(scheme).opacity(fillToken.areaOpacity(scheme)), location: 0),
                                .init(color: fillToken.color(scheme).opacity(fillToken.areaBottomOpacity), location: 1)
                            ]),
                            startPoint: CGPoint(x: boxRect.midX, y: boxRect.minY),
                            endPoint: CGPoint(x: boxRect.midX, y: boxRect.maxY)
                        )
                    )
                    context.stroke(boxPath, with: .color(strokeColor), lineWidth: isSelected ? 2 : 1)

                    var median = Path()
                    median.move(to: CGPoint(x: centerX - boxWidth / 2, y: y(stats.median)))
                    median.addLine(to: CGPoint(x: centerX + boxWidth / 2, y: y(stats.median)))
                    context.stroke(
                        median,
                        // Session-best rep called out in the caution token (the
                        // web uses `--warning` for the same tick).
                        with: .color(index == bestIndex ? ChartToken.caution.color(scheme) : strokeColor),
                        style: StrokeStyle(lineWidth: isSelected ? 2.5 : 2, lineCap: .round)
                    )

                    for value in stats.outliers.prefix(Self.maxOutlierDots) {
                        let rect = CGRect(x: centerX - 1.5, y: y(value) - 1.5, width: 3, height: 3)
                        context.stroke(
                            Path(ellipseIn: rect),
                            with: .color(axisColor.opacity(0.55)),
                            lineWidth: 1
                        )
                    }
                }
            }

            GeometryReader { geo in
                if #available(iOS 17, *) {
                    Color.clear
                        .contentShape(Rectangle())
                        .hapticTapMuted()
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    let index = repIndex(at: value.location, size: geo.size)
                                    select(index == selectedRepIndex ? nil : index)
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    select(repIndex(at: value.location, size: geo.size))
                                }
                        )
                        .accessibilityHidden(true)
                }

                if let selectedRepIndex,
                   reps.indices.contains(selectedRepIndex) {
                    tooltip(
                        rep: reps[selectedRepIndex],
                        x: repCenterX(index: selectedRepIndex, size: geo.size),
                        containerSize: geo.size
                    )
                }
            }
        }
        .frame(height: 110)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Force distribution by repetition")
        .accessibilityValue(accessibilityValue)
        .accessibilityRepBoxChartDescriptor(reps)
        .onDisappear {
            selectedRepIndex = nil
            tickedRepIndex = nil
        }
    }

    private var accessibilityValue: String {
        guard let selectedRepIndex, reps.indices.contains(selectedRepIndex) else {
            return "\(reps.count) repetitions"
        }
        let rep = reps[selectedRepIndex]
        let peak = rep.recording.peakKilograms.map {
            ", \($0.formatted(.number.precision(.fractionLength(1)))) kilograms peak"
        } ?? ""
        return "Selected \(repLabel(rep.recording))\(peak)"
    }

    private func select(_ index: Int?) {
        if SelectionHaptics.valueChanged(tickedRepIndex, index) {
            tickedRepIndex = index
            Haptics.shared.playGesture(.selection)
        }
        selectedRepIndex = index
    }

    private func repIndex(at point: CGPoint, size: CGSize) -> Int? {
        let leftInset: CGFloat = 30
        let rightInset: CGFloat = 8
        let plotWidth = max(1, size.width - leftInset - rightInset)
        guard !reps.isEmpty,
              point.x >= leftInset,
              point.x <= size.width - rightInset
        else { return nil }
        let bandWidth = plotWidth / CGFloat(reps.count)
        let index = Int((point.x - leftInset) / bandWidth)
        return reps.indices.contains(index) ? index : nil
    }

    private func repCenterX(index: Int, size: CGSize) -> CGFloat {
        let leftInset: CGFloat = 30
        let rightInset: CGFloat = 8
        let plotWidth = max(1, size.width - leftInset - rightInset)
        let bandWidth = plotWidth / CGFloat(max(1, reps.count))
        return leftInset + bandWidth * (CGFloat(index) + 0.5)
    }

    private func repLabel(_ recording: TindeqRecording) -> String {
        var parts: [String] = []
        if let setNumber = recording.setNumber {
            if recording.protocolMode == .reverseAction {
                let completed = recording.completedRepetitions ?? 0
                parts.append("Set \(setNumber) · \(completed) reps")
            } else {
                parts.append("Set \(setNumber) · Rep \(recording.repetitionNumber ?? 1)")
            }
        }
        if recording.side != .unspecified { parts.append(recording.side.label) }
        if let zone = recording.zone { parts.append(zone.displayLabel) }
        if parts.isEmpty {
            parts.append(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func tooltip(
        rep: RepBoxPlotEntry,
        x: CGFloat,
        containerSize: CGSize
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(repLabel(rep.recording))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let peak = rep.recording.peakKilograms {
                Text("\(peak.formatted(.number.precision(.fractionLength(1)))) kg peak")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            } else {
                Text("No recorded peak")
                    .font(.subheadline.weight(.semibold))
            }
            if let stats = rep.stats {
                Text("Median \(stats.median.formatted(.number.precision(.fractionLength(1)))) kg")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(ChartToken.tooltip.color(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChartToken.tooltipBorder.color(scheme), lineWidth: 1)
        )
        .shadow(radius: 4, y: 2)
        .fixedSize()

        let plotFrame = CGRect(origin: .zero, size: containerSize)
        return content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { tooltipSize = geo.size }
                        .onChange(of: geo.size) { newSize in tooltipSize = newSize }
                }
            )
            .position(
                x: clampedTooltipX(x: x, plotFrame: plotFrame, tooltipWidth: tooltipSize.width),
                y: clampedTooltipY(plotFrame: plotFrame, tooltipHeight: tooltipSize.height)
            )
            .zIndex(1)
    }

    private func clampedTooltipX(x: CGFloat, plotFrame: CGRect, tooltipWidth: CGFloat) -> CGFloat {
        let width = tooltipWidth > 0 ? tooltipWidth : 90
        let minCenter = plotFrame.minX + width / 2 + 8
        let maxCenter = plotFrame.maxX - width / 2 - 8
        if minCenter > maxCenter { return plotFrame.midX }
        return min(max(x, minCenter), maxCenter)
    }

    private func clampedTooltipY(plotFrame: CGRect, tooltipHeight: CGFloat) -> CGFloat {
        let height = tooltipHeight > 0 ? tooltipHeight : 60
        let minCenter = plotFrame.minY + height / 2 + 4
        let maxCenter = plotFrame.maxY - height / 2 - 4
        if minCenter > maxCenter { return plotFrame.midY }
        return minCenter
    }
}

private struct RepBoxAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let reps: [RepBoxPlotEntry]

    func makeChartDescriptor() -> AXChartDescriptor { makeDescriptor() }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let rebuilt = makeDescriptor()
        descriptor.title = rebuilt.title
        descriptor.summary = rebuilt.summary
        descriptor.xAxis = rebuilt.xAxis
        descriptor.yAxis = rebuilt.yAxis
        descriptor.series = rebuilt.series
    }

    private func makeDescriptor() -> AXChartDescriptor {
        let labels = reps.indices.map { "Rep \($0 + 1)" }
        let points = reps.enumerated().map { index, rep -> AXDataPoint in
            let recording = rep.recording
            let peak = recording.peakKilograms ?? 0
            let y = rep.stats?.median ?? peak
            let peakLabel = recording.peakKilograms.map {
                ", \($0.formatted(.number.precision(.fractionLength(1)))) kilograms peak"
            } ?? ""
            let side = recording.side == .unspecified ? "" : ", \(recording.side.label)"
            let zone = recording.zone.map { ", \($0.displayLabel)" } ?? ""
            return AXDataPoint(
                x: labels[index],
                y: y,
                label: "\(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))\(side)\(zone)\(peakLabel)"
            )
        }
        let yMax = max(1, reps.compactMap { $0.recording.peakKilograms }.max() ?? 1)
        return AXChartDescriptor(
            title: "Force distribution by repetition",
            summary: "Per-rep force distribution for this Tindeq session, with peak force and side for each rep.",
            xAxis: AXCategoricalDataAxisDescriptor(title: "Rep", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Kilograms", range: 0...yMax, gridlinePositions: []) {
                "\($0.formatted(.number.precision(.fractionLength(1)))) kg"
            },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(
                name: "Force distribution",
                isContinuous: false,
                dataPoints: points
            )]
        )
    }
}

private extension View {
    func accessibilityRepBoxChartDescriptor(_ reps: [RepBoxPlotEntry]) -> some View {
        accessibilityChartDescriptor(RepBoxAccessibilityDescriptor(reps: reps))
    }
}

/// The training-quality badge on a Tindeq session row (#630, web #214): the
/// dominant zone of the session's own recordings, colored by quality.
struct ZoneBadge: View {
    let zone: ZoneQuality
    let mix: [ZoneQuality: Double]?

    var body: some View {
        Text(zone.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(SendmeterStyle.zoneColor(zone))
            .background(SendmeterStyle.zoneColor(zone).opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(SendmeterStyle.zoneColor(zone).opacity(0.35), lineWidth: 1))
            .accessibilityLabel("\(zone.label) zone")
            .accessibilityHint(mix.map(zoneMixAccessibility) ?? "")
    }

    private func zoneMixAccessibility(_ mix: [ZoneQuality: Double]) -> String {
        ZoneMix.zoneOrder
            .map { "\($0.label) \(String(format: "%.1f", mix[$0] ?? 0)) sets" }
            .joined(separator: ", ")
    }
}

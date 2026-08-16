import SendmeterCore
import SwiftUI

/// #630: the expanded detail for a session in the combined History timeline —
/// the native counterpart of the web's `SessionRow` detail sheet. Tindeq
/// sessions show their recordings (grouped by tag) with per-rep box plots +
/// the zone-mix badge; workout sessions show a summary card. Workout sessions
/// deliberately stop at the summary: the native model fetches `climb_workouts`
/// without the 1 Hz `raw` trace, so there is no HR chart to draw — the
/// summary is everything the model already holds.
struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let session: SendmeterCore.Session

    @State private var boxStatsByID: [UUID: BoxStats] = [:]
    @State private var loadingSamples = false

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
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(session.typeLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSamples() }
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
                        StatusPill("Pending", color: SendmeterStyle.caution)
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
                    .buttonStyle(.plain)
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
        if let zone = recording.zone { parts.append(zone.rawValue.capitalized) }
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
                    LabeledContent("Average HR", value: workout.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "—")
                    LabeledContent("Attempts", value: "\(workout.attemptsConfirmed) confirmed · \(workout.attemptsDetected) detected")
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

    // MARK: Samples

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

    private static let maxOutlierDots = 12

    /// Left = force (indigo), right = forceSecondary (electric blue) — the
    /// web's `sideColor` (`RepBoxPlotChart.tsx`).
    private func sideColors(for side: TindeqSide) -> (stroke: ChartToken, fill: ChartToken) {
        side == .left ? (.force, .focus) : (.forceSecondary, .health)
    }

    var body: some View {
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
                context.stroke(boxPath, with: .color(strokeColor), lineWidth: 1)

                var median = Path()
                median.move(to: CGPoint(x: centerX - boxWidth / 2, y: y(stats.median)))
                median.addLine(to: CGPoint(x: centerX + boxWidth / 2, y: y(stats.median)))
                context.stroke(
                    median,
                    // Session-best rep called out in the caution token (the
                    // web uses `--warning` for the same tick).
                    with: .color(index == bestIndex ? ChartToken.caution.color(scheme) : strokeColor),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
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
        .frame(height: 110)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Force distribution by repetition")
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

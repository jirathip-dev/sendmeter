import Charts
import SendmeterCore
import SwiftUI

/// The expanded workout row's HR chart (#645) — the native counterpart of the
/// web's `WorkoutHrChart`: one line/area over the workout-level trace,
/// plotted on seconds-since-workout-start (x, m:ss labels) against bpm (y),
/// with each climb attempt shaded as a segment (manual attempts in the
/// caution token, detected in the focus token). Sensor gaps (nil `hr`) split
/// the line into runs — drawing across one would invent data, so each run
/// renders as its own series.
///
/// Renders nothing when the workout kept no trace (older builds, phone
/// workouts); a watch workout without a trace gets the "still syncing"
/// reassurance instead (the watch uploads it in the background).
///
/// `tMax` is the shared x domain computed by the parent from the trace AND
/// the attempts (web `WorkoutDetailPanel`), so the effort chart below plots
/// the same instants.
struct WorkoutHrChartView: View {
    let samples: [WorkoutHrSample]
    let attempts: [WorkoutAttempt]
    let startedAt: Date
    let endedAt: Date
    let source: WorkoutSource
    /// The shared x domain in seconds — the parent computes it once so every
    /// chart in the stack plots the same instants (web `workoutTimeMaxS`).
    let tMax: Double

    @Binding private var selectedTime: Double?
    @State private var tooltipSize: CGSize = .zero

    /// Derived series computed once in the initializer (#645 review F12) —
    /// the run split, the downsample (F11) and the y-domain are all stable
    /// for the life of the view, so body evaluation reuses them instead of
    /// re-walking the trace six times.
    private struct Derived {
        let runs: [[WorkoutHrSample]]
        let hrs: [Double]
        let hrMin: Double
        let hrMax: Double
        let yPad: Double
        let yDomain: ClosedRange<Double>
        let yTicks: [Double]
        let windows: [WorkoutChartAxis.AttemptWindow]
        /// HR recovery (web `hrRecoveryBpm`): mean bpm the heart drops in the
        /// 60s after each climb — nil when no attempt yields a positive drop
        /// (AC5, #645 review F5).
        let recoveryBpm: Double?

        init(samples: [WorkoutHrSample], attempts: [WorkoutAttempt], startedAt: Date) {
            runs = WorkoutRawTrace.downsampleRuns(
                samples,
                maxPoints: WorkoutRawTrace.maxChartPoints
            )
            hrs = samples.compactMap(\.hr)
            hrMin = hrs.min() ?? 0
            hrMax = hrs.max() ?? 1
            // Pad the y-domain so the line doesn't kiss the frame edges (web:
            // 10%, minimum 3 bpm).
            yPad = max(3, (hrMax - hrMin) * 0.1)
            yDomain = (hrMin - yPad)...(hrMax + yPad)
            yTicks = [hrMin, (hrMin + hrMax) / 2, hrMax]
            windows = WorkoutChartAxis.attemptWindows(
                startedAt: startedAt,
                attempts: attempts
            )
            recoveryBpm = WorkoutStats.hrRecoveryBpm(
                trace: samples,
                startedAt: startedAt,
                attempts: attempts
            )
        }
    }

    @Environment(\.colorScheme) private var scheme

    private let derived: Derived

    init(
        samples: [WorkoutHrSample],
        attempts: [WorkoutAttempt],
        startedAt: Date,
        endedAt: Date,
        source: WorkoutSource,
        tMax: Double,
        selectedTime: Binding<Double?>
    ) {
        self.samples = samples
        self.attempts = attempts
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.tMax = tMax
        _selectedTime = selectedTime
        self.derived = Derived(samples: samples, attempts: attempts, startedAt: startedAt)
    }

    var body: some View {
        if WorkoutRawTrace.isChartRenderable(samples) {
            chart
        } else if source == .watch {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityHidden(true)
                Text("Heart-rate trace still syncing from your watch…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func windowColor(_ window: WorkoutChartAxis.AttemptWindow) -> Color {
        (window.manual ? ChartToken.caution : ChartToken.optimal).color(scheme).opacity(0.12)
    }

    /// Attempt-window shading — sits behind the HR marks (web `<rect>`).
    @ChartContentBuilder
    private var windowMarks: some ChartContent {
        ForEach(derived.windows.indices, id: \.self) { index in
            let window = derived.windows[index]
            RectangleMark(
                xStart: .value("Climb start", window.start),
                xEnd: .value("Climb end", window.end)
            )
            .foregroundStyle(windowColor(window))
        }
    }

    /// One series per contiguous run — WITHOUT `series:` every run's points
    /// collapse into one implicit series and Swift Charts connects across
    /// the gap (drawing a straight line over a period where no HR was
    /// measured).
    @ChartContentBuilder
    private var runMarks: some ChartContent {
        ForEach(Array(derived.runs.enumerated()), id: \.offset) { runIndex, run in
            ForEach(run, id: \.t) { sample in
                let heartRate = sample.hr ?? 0
                AreaMark(
                    x: .value("Time", sample.t),
                    y: .value("Heart rate", heartRate),
                    series: .value("Run", runIndex)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(ChartToken.health.areaGradient(scheme))
                LineMark(
                    x: .value("Time", sample.t),
                    y: .value("Heart rate", heartRate),
                    series: .value("Run", runIndex)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(ChartToken.health.color(scheme))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if #available(iOS 17, *) {
            baseChart
                .chartXSelection(value: $selectedTime)
                .hapticTapMuted()
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if selectedTime != nil, let selectedSample {
                            let plotFrame = geo[proxy.plotAreaFrame]
                            let x = (proxy.position(forX: selectedSample.t) ?? 0) + plotFrame.minX
                            tooltip(for: selectedSample, x: x, plotFrame: plotFrame)
                        }
                    }
                }
                .accessibilityLabel("Workout heart rate timeline")
                .accessibilityValue(selectedSample.map(accessibilityText) ?? accessibilitySummary)
                .accessibilityWorkoutHrChartDescriptor(
                    runs: derived.runs,
                    attempts: attempts,
                    startedAt: startedAt
                )
        } else {
            baseChart
                .hapticTapMuted()
                .accessibilityLabel("Workout heart rate timeline")
                .accessibilityValue(accessibilitySummary)
                .accessibilityWorkoutHrChartDescriptor(
                    runs: derived.runs,
                    attempts: attempts,
                    startedAt: startedAt
                )
        }
    }

    private var baseChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Heart rate", systemImage: "heart.fill")
            if let recoveryBpm = derived.recoveryBpm {
                // Web parity: "HR recovery −N bpm in the 60s after a climb,
                // on average" — the web styles the number in danger/alert.
                // `Text.foregroundStyle` is iOS 17+; this target is 16.2, so
                // the composed text uses `foregroundColor` instead.
                (Text("HR recovery ").foregroundColor(.secondary)
                    + Text("−\(Int(recoveryBpm.rounded())) bpm")
                        .foregroundColor(ChartToken.alert.color(scheme))
                    + Text(" in the 60s after a climb, on average")
                        .foregroundColor(.secondary))
                    .font(.caption)
            }
            Chart {
                windowMarks
                runMarks
                if let sample = selectedSample {
                    RuleMark(x: .value("Selected time", sample.t))
                        .foregroundStyle(ChartToken.axis.color(scheme))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: 0...tMax)
            .chartYScale(domain: derived.yDomain)
            .chartXAxis {
                // First/last labels anchored to their edge like the web's
                // start/end textAnchor, so "0:00"/end aren't clipped at the
                // plot edges (#645 review F15).
                let xTicks = WorkoutChartAxis.xTicks(tMax: tMax)
                AxisMarks(values: xTicks) { value in
                    AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                    AxisValueLabel(
                        anchor: value.as(Double.self) == xTicks.first
                            ? .bottomLeading
                            : (value.as(Double.self) == xTicks.last ? .bottomTrailing : .center)
                    ) {
                        if let t = value.as(Double.self) {
                            Text(WorkoutChartAxis.fmtMinSec(t))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(ChartToken.axis.color(scheme))
                }
            }
            .chartYAxis {
                AxisMarks(values: derived.yTicks) { value in
                    AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v == derived.yTicks.last ? "\(Int(v.rounded())) bpm" : "\(Int(v.rounded()))")
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(ChartToken.axis.color(scheme))
                }
            }
            .frame(height: 160)
        }
    }

    private var selectedSample: WorkoutHrSample? {
        guard let selectedTime else { return nil }
        return WorkoutRawTrace.selectedSample(at: selectedTime, inRuns: derived.runs)
    }

    private var selectedAttempt: WorkoutAttempt? {
        guard let selectedTime else { return nil }
        return attempts.first { attempt in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            return selectedTime >= start && selectedTime <= start + Double(attempt.durationSeconds)
        }
    }

    private var accessibilitySummary: String {
        "\(derived.hrs.count) samples, \(Int(derived.hrMin.rounded())) to \(Int(derived.hrMax.rounded())) bpm"
    }

    private func accessibilityText(for sample: WorkoutHrSample) -> String {
        let hr = sample.hr.map { "\(Int($0.rounded())) beats per minute" } ?? "no reading"
        if let attempt = selectedAttempt {
            return "\(WorkoutChartAxis.fmtMinSec(sample.t)), \(hr), \(attempt.source == "manual" ? "manual climb" : "detected climb")"
        }
        return "\(WorkoutChartAxis.fmtMinSec(sample.t)), \(hr)"
    }

    private func tooltip(for sample: WorkoutHrSample, x: CGFloat, plotFrame: CGRect) -> some View {
        let hr = sample.hr.map {
            "\(Int($0.rounded())) bpm"
        } ?? "No reading"
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(WorkoutChartAxis.fmtMinSec(sample.t))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(hr)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if let attempt = selectedAttempt {
                Text(attempt.source == "manual" ? "Manual climb" : "Detected climb")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(attempt.source == "manual" ? ChartToken.caution.color(scheme) : ChartToken.optimal.color(scheme))
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

private struct WorkoutHrAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let runs: [[WorkoutHrSample]]
    let attempts: [WorkoutAttempt]
    let startedAt: Date

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
        let allSamples = runs.flatMap { $0 }
        let labels = allSamples.enumerated().map { index, _ in "Sample \(index + 1)" }
        let points = allSamples.enumerated().map { index, sample -> AXDataPoint in
            let attempt = attempt(at: sample.t)
            let attemptLabel = attempt.map { $0.source == "manual" ? ", manual climb" : ", detected climb" } ?? ""
            let hr = sample.hr.map { "\(Int($0.rounded())) beats per minute" } ?? "no reading"
            return AXDataPoint(
                x: labels[index],
                y: sample.hr ?? 0,
                label: "\(WorkoutChartAxis.fmtMinSec(sample.t)), \(hr)\(attemptLabel)"
            )
        }
        let yMax = max(1, allSamples.compactMap(\.hr).max() ?? 1)
        return AXChartDescriptor(
            title: "Workout heart rate timeline",
            summary: "Heart-rate samples across the workout, with climb attempts shown as shaded windows.",
            xAxis: AXCategoricalDataAxisDescriptor(title: "Time", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Beats per minute", range: 0...yMax, gridlinePositions: []) {
                "\(Int($0)) bpm"
            },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(
                name: "Heart rate",
                isContinuous: true,
                dataPoints: points
            )]
        )
    }

    private func attempt(at t: Double) -> WorkoutAttempt? {
        attempts.first { attempt in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            return t >= start && t <= start + Double(attempt.durationSeconds)
        }
    }
}

private extension View {
    func accessibilityWorkoutHrChartDescriptor(
        runs: [[WorkoutHrSample]],
        attempts: [WorkoutAttempt],
        startedAt: Date
    ) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(
                WorkoutHrAccessibilityDescriptor(
                    runs: runs,
                    attempts: attempts,
                    startedAt: startedAt
                )
            )
    }
}

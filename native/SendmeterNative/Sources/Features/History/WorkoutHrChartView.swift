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
        tMax: Double
    ) {
        self.samples = samples
        self.attempts = attempts
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.tMax = tMax
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

    private var chart: some View {
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workout heart rate timeline")
            .accessibilityValue(
                "\(derived.hrs.count) samples, \(Int(derived.hrMin.rounded())) to \(Int(derived.hrMax.rounded())) bpm"
            )
        }
    }
}

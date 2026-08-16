import Charts
import SendmeterCore
import SwiftUI

/// The expanded workout row's HR chart (#645) — the native counterpart of the
/// web's `WorkoutHrChart`: one line/area over the workout-level 1 Hz trace,
/// plotted on seconds-since-workout-start (x, m:ss labels) against bpm (y).
/// Sensor gaps (nil `hr`) split the line into runs — drawing across one
/// would invent data.
///
/// Renders nothing when the workout kept no trace (older builds, phone
/// workouts); a watch workout without a trace gets the "still syncing"
/// reassurance instead (the watch uploads it in the background).
struct WorkoutHrChartView: View {
    let samples: [WorkoutHrSample]
    let startedAt: Date
    let endedAt: Date
    let source: WorkoutSource

    /// One contiguous non-nil-HR run — the unit the chart draws.
    private struct HrRun {
        let samples: [WorkoutHrSample]
    }

    private var runs: [HrRun] {
        var result: [HrRun] = []
        var current: [WorkoutHrSample] = []
        for sample in samples {
            if sample.hr == nil {
                if !current.isEmpty {
                    result.append(HrRun(samples: current))
                    current = []
                }
            } else {
                current.append(sample)
            }
        }
        if !current.isEmpty { result.append(HrRun(samples: current)) }
        return result
    }

    private var tMax: Double {
        WorkoutChartAxis.timeMaxS(
            startedAt: startedAt,
            endedAt: endedAt,
            attempts: [],
            samples: samples
        )
    }

    private var hrs: [Double] { samples.compactMap(\.hr) }
    private var hrMin: Double { hrs.min() ?? 0 }
    private var hrMax: Double { hrs.max() ?? 1 }
    /// Pad the y-domain so the line doesn't kiss the frame edges (web: 10%,
    /// minimum 3 bpm).
    private var yPad: Double { max(3, (hrMax - hrMin) * 0.1) }
    private var yDomain: ClosedRange<Double> { (hrMin - yPad)...(hrMax + yPad) }
    private var yTicks: [Double] { [hrMin, (hrMin + hrMax) / 2, hrMax] }
    private var xTicks: [Double] { WorkoutChartAxis.xTicks(tMax: tMax) }

    var body: some View {
        if WorkoutRawTrace.isChartRenderable(samples) {
            chart
        } else if source == .watch {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Heart-rate trace still syncing from your watch…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Heart rate", systemImage: "heart.fill")
            Chart {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    ForEach(run.samples, id: \.t) { sample in
                        AreaMark(
                            x: .value("Time", sample.t),
                            y: .value("Heart rate", sample.hr!)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [SendmeterStyle.optimal.opacity(0.22), SendmeterStyle.optimal.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Time", sample.t),
                            y: .value("Heart rate", sample.hr!)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(SendmeterStyle.optimal)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
            }
            .chartXScale(domain: 0...tMax)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: xTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let t = value.as(Double.self) {
                            Text(WorkoutChartAxis.fmtMinSec(t))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: yTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v == yTicks.last ? "\(Int(v.rounded())) bpm" : "\(Int(v.rounded()))")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 160)
            .accessibilityLabel("Workout heart rate timeline")
            .accessibilityValue("\(hrs.count) samples, \(Int(hrMin.rounded())) to \(Int(hrMax.rounded())) bpm")
        }
    }
}

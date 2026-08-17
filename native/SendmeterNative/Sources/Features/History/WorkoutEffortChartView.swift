import Charts
import SendmeterCore
import SwiftUI

/// Per-attempt effort, plotted on the *workout timeline* rather than one
/// even-width bar per attempt (#645, web `WorkoutEffortChart`) — so an x
/// pixel here is the same instant as in the HR chart stacked above it, and
/// each bar sits under the climb segment it belongs to. Manual attempts use
/// the caution token, detected ones the optimal token — the same shading the
/// HR chart uses for its windows. Effort scores are a 0–10 scale.
struct WorkoutEffortChartView: View {
    let attempts: [WorkoutAttempt]
    let startedAt: Date
    /// The shared x domain (seconds) — the same value the HR chart above
    /// plots into, computed once by the parent.
    let tMax: Double

    /// One attempt's effort on the 0–10 scale, clamped like the web.
    private func effortValue(_ attempt: WorkoutAttempt) -> Double {
        min(10, attempt.effortScore ?? 0)
    }

    /// Manual attempts use the caution token, detected the optimal token —
    /// the same shading the HR chart uses for its windows.
    private func barColor(_ attempt: WorkoutAttempt) -> Color {
        (attempt.source == "manual" ? ChartToken.caution : ChartToken.optimal)
            .color(scheme)
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Attempts · effort", systemImage: "bolt.fill")
            Chart {
                ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
                    let start = attempt.startedAt.timeIntervalSince(startedAt)
                    RectangleMark(
                        xStart: .value("Climb start", start),
                        xEnd: .value("Climb end", start + Double(attempt.durationSeconds)),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Effort", effortValue(attempt))
                    )
                    .foregroundStyle(barColor(attempt))
                    .cornerRadius(1.5)
                }
            }
            .chartXScale(domain: 0...tMax)
            .chartYScale(domain: 0...10)
            .chartXAxis {
                // First/last labels anchored to their edge (web parity, F15).
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
                AxisMarks(values: [0, 10]) { value in
                    AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v == 10 ? "10 eff" : "\(Int(v))")
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(ChartToken.axis.color(scheme))
                }
            }
            .frame(height: 110)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workout attempt effort timeline")
            .accessibilityValue(
                "\(attempts.count) attempts, \(attempts.filter { $0.source == "manual" }.count) manual"
            )
        }
    }
}

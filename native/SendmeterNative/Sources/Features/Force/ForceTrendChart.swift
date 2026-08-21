import Charts
import SendmeterCore
import SwiftUI

/// Peak-force trend for the Static capacity detail sheet (#655).
///
/// The parent supplies the already-scoped Static rows. Keeping the chart
/// component unaware of tag/side selection prevents a detail sheet from
/// silently broadening the evidence it displays.
struct ForceTrendChart: View {
    let recordings: [TindeqRecording]

    @Environment(\.colorScheme) private var scheme

    private var peaks: [TindeqRecording] {
        recordings.filter { $0.peakKilograms != nil }
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Peak force trend", systemImage: "chart.line.uptrend.xyaxis")

                if peaks.count >= 2 {
                    chart
                } else {
                    Text("Complete a couple of measured Static holds to unlock the trend.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chart: some View {
        let maximum = max(1, (peaks.compactMap(\.peakKilograms).max() ?? 1) * 1.1)
        return Chart {
            ForEach(peaks) { recording in
                if let peak = recording.peakKilograms {
                    AreaMark(
                        x: .value("Date", recording.recordedAt),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Peak", peak)
                    )
                    .foregroundStyle(ChartToken.force.areaGradient(scheme))

                    LineMark(
                        x: .value("Date", recording.recordedAt),
                        y: .value("Peak", peak)
                    )
                    .foregroundStyle(ChartToken.force.color(scheme))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Date", recording.recordedAt),
                        y: .value("Peak", peak)
                    )
                    .foregroundStyle(ChartToken.forceSecondary.color(scheme))
                    .symbolSize(28)
                }
            }
        }
        .chartYScale(domain: 0...maximum)
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                AxisValueLabel().foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(4, peaks.count))) {
                AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                AxisValueLabel(format: xAxisFormat)
                    .foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Static peak force trend")
        .accessibilityValue(
            "\(peaks.count) measured holds, best \(peaks.compactMap(\.peakKilograms).max()!.formatted(.number.precision(.fractionLength(1)))) kilograms"
        )
    }

    private var xAxisFormat: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        style.calendar = Calendar(identifier: .gregorian)
        style.locale = Locale(identifier: "en_US_POSIX")
        style.timeZone = .current
        return style
    }
}

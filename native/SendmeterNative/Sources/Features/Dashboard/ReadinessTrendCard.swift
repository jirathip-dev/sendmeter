import Charts
import SendmeterCore
import SwiftUI

/// 14-day readiness trend chart (#664) — port of the web's `ReadinessCard.tsx`
/// trend section to the native Dashboard. Same series the web derives (the
/// per-day `health_metrics` readiness over the last 14 calendar days), same
/// zone-threshold gridlines at 40/70, and ChartTheme health tokens
/// (`#2E96F0`/`#4FB0FF`) with the health vertical area gradient.
///
/// Scrub parity per #656: dragging the chart selects the nearest day via
/// `chartXSelection` (iOS 17+); on iOS 16 the chart reads the series through
/// VoiceOver via per-day labels instead. The chart reads `model.healthMetrics`
/// directly, so it refreshes whenever a health sync lands.
struct ReadinessTrendCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDate: Date?

    private var series: [ReadinessDay] {
        TrainingMetrics.readinessSeries(metrics: model.healthMetrics)
    }

    /// The nearest day to the scrubbed position, falling back to no selection.
    private var selected: ReadinessDay? {
        guard let selectedDate else { return nil }
        return series.min { lhs, rhs in
            abs(lhs.dateValue.timeIntervalSince(selectedDate))
                < abs(rhs.dateValue.timeIntervalSince(selectedDate))
        }
    }

    /// Zone-threshold color for a day's bar — same mapping as the web's
    /// `ZONE_COLORS` (push → optimal/blue, maintain → caution/yellow,
    /// recover → alert/orange). A missing zone falls back to the reference.
    private func zoneColor(_ zone: String?) -> ChartToken {
        switch zone?.lowercased() {
        case "push": return .optimal
        case "maintain": return .caution
        case "recover": return .alert
        default: return .reference
        }
    }

    /// VoiceOver label for one day — matches the web's per-day aria-label.
    private func accessibilityText(for day: ReadinessDay) -> String {
        if let readiness = day.readiness {
            let zone = day.zone.map { " \($0)" } ?? ""
            return "\(day.date): \(readiness)\(zone)"
        }
        return "\(day.date): no data"
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Readiness trend", systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                    if let selected {
                        Text(selected.date)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if series.allSatisfy({ $0.readiness == nil }) {
                    Text("Sync Apple Health for a 14-day readiness trend.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    chart
                }
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if #available(iOS 17, *) {
            baseChart
                .frame(height: 170)
                .chartXSelection(value: $selectedDate)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if let selectedDate, let selected {
                            let x = proxy.position(forX: selected.dateValue) ?? 0
                            let isRightEdge = x > geo.size.width - 90
                            VStack(alignment: isRightEdge ? .trailing : .leading, spacing: 2) {
                                if let readiness = selected.readiness {
                                    Text("\(readiness)")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                    if let zone = selected.zone {
                                        Text(zone.capitalized)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(zoneColor(zone).color(scheme))
                                    }
                                } else {
                                    Text("No data")
                                        .font(.subheadline.weight(.semibold))
                                }
                                HStack(spacing: 8) {
                                    if let hrv = selected.hrvSDNNMilliseconds {
                                        Text("HRV \(Int(hrv.rounded()))ms")
                                    }
                                    if let rhr = selected.restingHeartRate {
                                        Text("RHR \(Int(rhr.rounded()))")
                                    }
                                    if let sleep = selected.sleepHours {
                                        Text("Sleep \(sleep.formatted(.number.precision(.fractionLength(1))))h")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(ChartToken.tooltip.color(scheme), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ChartToken.tooltipBorder.color(scheme), lineWidth: 1)
                            )
                            .shadow(radius: 4, y: 2)
                            .position(
                                x: isRightEdge ? geo.size.width - 8 : min(max(x, 44), geo.size.width - 44),
                                y: 20
                            )
                        }
                    }
                }
                .accessibilityLabel("Fourteen-day readiness trend")
                .accessibilityValue(selected.map(accessibilityText) ?? "")
                .accessibilityChartDescriptor(series)
        } else {
            baseChart
                .frame(height: 170)
                .accessibilityLabel("Fourteen-day readiness trend")
                .accessibilityValue(selected.map(accessibilityText) ?? "")
                .accessibilityChartDescriptor(series)
        }
    }

    private var baseChart: some View {
        Chart(series) { day in
            // Zone-threshold gridlines at 40 / 70 — the push/maintain/recover
            // boundaries the web draws as dashed lines.
            RuleMark(y: .value("Recover threshold", 40))
                .foregroundStyle(ChartToken.grid.color(scheme))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("Push threshold", 70))
                .foregroundStyle(ChartToken.grid.color(scheme))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            AreaMark(
                x: .value("Day", day.dateValue),
                yStart: .value("Baseline", 0),
                yEnd: .value("Readiness", day.readiness ?? 0)
            )
            .foregroundStyle(ChartToken.health.areaGradient(scheme))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Day", day.dateValue),
                y: .value("Readiness", day.readiness ?? 0)
            )
            .foregroundStyle(ChartToken.health.color(scheme))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Day", day.dateValue),
                y: .value("Readiness", day.readiness ?? 0)
            )
            .foregroundStyle(day.readiness == nil ? Color.clear : zoneColor(day.zone).color(scheme))
            .symbolSize(selected == nil || selected?.date == day.date ? 16 : 8)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                AxisValueLabel().foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    .foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
    }
}

/// VoiceOver descriptor for the trend chart: the whole series as elements plus
/// the zone-threshold boundaries, so a VoiceOver user gets the same
/// per-day breakdown the scrub tooltip shows a sighted user.
struct ReadinessSeriesAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let days: [ReadinessDay]

    func makeChartDescriptor() -> AXChartDescriptor {
        let dateAxis = AXCategoricalDataAxisDescriptor(
            title: "Date",
            categoryOrder: days.map(\.date)
        )
        let valueAxis = AXNumericDataAxisDescriptor(
            title: "Readiness",
            range: 0...100,
            gridlinePositions: [40.0, 70.0]
        ) { value in
            "\(Int(value))"
        }
        let series = AXDataSeriesDescriptor(
            name: "Readiness",
            isContinuous: true,
            dataPoints: days.map { day in
                AXDataPoint(
                    x: day.date,
                    y: day.readiness.map(Double.init) ?? 0,
                    label: day.readiness.map { "\($0)" } ?? "no data"
                )
            }
        )
        return AXChartDescriptor(
            title: "Fourteen-day readiness trend",
            summary: "Readiness score for each of the last fourteen days, with recover and push thresholds at 40 and 70.",
            xAxis: dateAxis,
            yAxis: valueAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

extension View {
    /// Adds an accessibility chart descriptor for the readiness trend chart.
    func accessibilityChartDescriptor(_ days: [ReadinessDay]) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(ReadinessSeriesAccessibilityDescriptor(days: days))
    }
}

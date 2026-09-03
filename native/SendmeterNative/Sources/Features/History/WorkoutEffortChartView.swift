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

    @Binding private var selectedTime: Double?
    @State private var tooltipSize: CGSize = .zero

    init(
        attempts: [WorkoutAttempt],
        startedAt: Date,
        tMax: Double,
        selectedTime: Binding<Double?>
    ) {
        self.attempts = attempts
        self.startedAt = startedAt
        self.tMax = tMax
        _selectedTime = selectedTime
    }

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
        chart
    }

    @ViewBuilder
    private var chart: some View {
        if #available(iOS 17, *) {
            baseChart
                .chartXSelection(value: $selectedTime)
                .hapticTapMuted()
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if selectedTime != nil, let attempt = selectedAttempt {
                            let plotFrame = geo[proxy.plotAreaFrame]
                            let x = (proxy.position(forX: selectedTime ?? 0) ?? 0) + plotFrame.minX
                            tooltip(for: attempt, x: x, plotFrame: plotFrame)
                        }
                    }
                }
                .accessibilityLabel("Workout attempt effort timeline")
                .accessibilityValue(
                    selectedAttempt.map(accessibilityText) ?? accessibilitySummary
                )
                .accessibilityWorkoutEffortChartDescriptor(attempts, startedAt: startedAt)
        } else {
            baseChart
                .hapticTapMuted()
                .accessibilityLabel("Workout attempt effort timeline")
                .accessibilityValue(accessibilitySummary)
                .accessibilityWorkoutEffortChartDescriptor(attempts, startedAt: startedAt)
        }
    }

    private var baseChart: some View {
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
                    .opacity(selectedAttempt?.id == attempt.id ? 1 : 0.72)
                    .cornerRadius(1.5)
                }
                if let selectedTime, selectedAttempt != nil {
                    RuleMark(x: .value("Selected time", selectedTime))
                        .foregroundStyle(ChartToken.axis.color(scheme))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
                // #880: same leading-edge pin as the HR chart above — an
                // automatic placement would reserve a trailing gutter and
                // detach the "10 eff" label from the bars.
                AxisMarks(position: .leading, values: [0, 10]) { value in
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
        }
    }

    private var selectedAttempt: WorkoutAttempt? {
        guard let selectedTime else { return nil }
        return attempts.first { attempt in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            return selectedTime >= start && selectedTime <= start + Double(attempt.durationSeconds)
        }
    }

    private var accessibilitySummary: String {
        "\(attempts.count) attempts, \(attempts.filter { $0.source == "manual" }.count) manual"
    }

    private func accessibilityText(for attempt: WorkoutAttempt) -> String {
        let start = attempt.startedAt.timeIntervalSince(startedAt)
        return "\(WorkoutChartAxis.fmtMinSec(start)), \(effortValue(attempt).formatted(.number.precision(.fractionLength(0...1)))) effort, \(attempt.source == "manual" ? "manual climb" : "detected climb")"
    }

    private func tooltip(for attempt: WorkoutAttempt, x: CGFloat, plotFrame: CGRect) -> some View {
        let start = attempt.startedAt.timeIntervalSince(startedAt)
        let content = VStack(alignment: .leading, spacing: 2) {
            Text("\(WorkoutChartAxis.fmtMinSec(start))–\(WorkoutChartAxis.fmtMinSec(start + Double(attempt.durationSeconds)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(effortValue(attempt).formatted(.number.precision(.fractionLength(0...1)))) effort")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(attempt.source == "manual" ? "Manual climb" : "Detected climb")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(attempt.source == "manual" ? ChartToken.caution.color(scheme) : ChartToken.optimal.color(scheme))
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

private struct WorkoutEffortAccessibilityDescriptor: AXChartDescriptorRepresentable {
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
        let labels = attempts.indices.map { "Attempt \($0 + 1)" }
        let points = attempts.enumerated().map { index, attempt -> AXDataPoint in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            let effort = min(10, attempt.effortScore ?? 0)
            return AXDataPoint(
                x: labels[index],
                y: effort,
                label: "\(WorkoutChartAxis.fmtMinSec(start)), \(effort.formatted(.number.precision(.fractionLength(0...1)))) effort, \(attempt.source == "manual" ? "manual climb" : "detected climb")"
            )
        }
        return AXChartDescriptor(
            title: "Workout attempt effort timeline",
            summary: "Rated effort for each climb attempt on the shared workout timeline.",
            xAxis: AXCategoricalDataAxisDescriptor(title: "Attempt", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Effort", range: 0...10, gridlinePositions: []) {
                "\($0.formatted(.number.precision(.fractionLength(0...1))))"
            },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(
                name: "Attempt effort",
                isContinuous: false,
                dataPoints: points
            )]
        )
    }
}

private extension View {
    func accessibilityWorkoutEffortChartDescriptor(
        _ attempts: [WorkoutAttempt],
        startedAt: Date
    ) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(
                WorkoutEffortAccessibilityDescriptor(
                    attempts: attempts,
                    startedAt: startedAt
                )
            )
    }
}

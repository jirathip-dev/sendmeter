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
    @State private var selectedDate: Date?
    @State private var tooltipSize: CGSize = .zero
    @State private var tickedRecording: TindeqRecording?

    private var peaks: [TindeqRecording] {
        recordings.filter { $0.peakKilograms != nil }
    }

    private var selected: TindeqRecording? {
        guard let selectedDate else { return nil }
        return peaks.min { lhs, rhs in
            abs(lhs.recordedAt.timeIntervalSince(selectedDate))
                < abs(rhs.recordedAt.timeIntervalSince(selectedDate))
        }
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
        return Group {
            if #available(iOS 17, *) {
                baseChart(maximum: maximum)
                    .frame(height: 190)
                    .chartXSelection(value: $selectedDate)
                    .hapticTapMuted()
                    .onChange(of: selectedDate) { _ in
                        if let selected {
                            if SelectionHaptics.valueChanged(tickedRecording, selected) {
                                tickedRecording = selected
                                Haptics.shared.playGesture(.selection)
                            }
                        } else {
                            tickedRecording = nil
                        }
                    }
                    .onDisappear { tickedRecording = nil }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            if selectedDate != nil, let selected {
                                let plotFrame = geo[proxy.plotAreaFrame]
                                let x = (proxy.position(forX: selected.recordedAt) ?? 0) + plotFrame.minX
                                tooltip(for: selected, x: x, plotFrame: plotFrame)
                            }
                        }
                    }
                    .accessibilityLabel("Static peak force trend")
                    .accessibilityValue(selected.map(accessibilityText) ?? accessibilitySummary)
                    .accessibilityForceTrendChartDescriptor(peaks)
            } else {
                baseChart(maximum: maximum)
                    .frame(height: 190)
                    .hapticTapMuted()
                    .accessibilityLabel("Static peak force trend")
                    .accessibilityValue(accessibilitySummary)
                    .accessibilityForceTrendChartDescriptor(peaks)
            }
        }
    }

    private func baseChart(maximum: Double) -> some View {
        Chart {
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
                    .symbolSize(selected?.id == recording.id ? 44 : 28)
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
    }

    private var accessibilitySummary: String {
        "\(peaks.count) measured holds, best \(peaks.compactMap(\.peakKilograms).max()!.formatted(.number.precision(.fractionLength(1)))) kilograms"
    }

    private func accessibilityText(for recording: TindeqRecording) -> String {
        guard let peak = recording.peakKilograms else { return "No peak" }
        return "\(recording.recordedAt.formatted(date: .abbreviated, time: .shortened)): \(peak.formatted(.number.precision(.fractionLength(1)))) kilograms"
    }

    private func tooltip(for recording: TindeqRecording, x: CGFloat, plotFrame: CGRect) -> some View {
        let peak = recording.peakKilograms.map {
            "\($0.formatted(.number.precision(.fractionLength(1)))) kg"
        } ?? "No peak"
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(peak)
                .font(.subheadline.weight(.semibold).monospacedDigit())
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

    private var xAxisFormat: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        style.calendar = Calendar(identifier: .gregorian)
        style.locale = Locale(identifier: "en_US_POSIX")
        style.timeZone = .current
        return style
    }
}

private struct ForceTrendAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let peaks: [TindeqRecording]

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
        let labels = peaks.indices.map { "Held \($0 + 1)" }
        let yMax = max(1, peaks.compactMap(\.peakKilograms).max() ?? 1)
        let points = peaks.enumerated().compactMap { index, recording -> AXDataPoint? in
            guard let peak = recording.peakKilograms else { return nil }
            return AXDataPoint(
                x: labels[index],
                y: peak,
                label: "\(recording.recordedAt.formatted(date: .abbreviated, time: .shortened)), \(peak.formatted(.number.precision(.fractionLength(1)))) kilograms"
            )
        }
        return AXChartDescriptor(
            title: "Static peak force trend",
            summary: "Peak force for each measured static hold in this evidence set.",
            xAxis: AXCategoricalDataAxisDescriptor(title: "Held", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Kilograms", range: 0...yMax, gridlinePositions: []) {
                "\($0.formatted(.number.precision(.fractionLength(1)))) kg"
            },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(
                name: "Peak force",
                isContinuous: true,
                dataPoints: points
            )]
        )
    }
}

private extension View {
    func accessibilityForceTrendChartDescriptor(_ peaks: [TindeqRecording]) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(ForceTrendAccessibilityDescriptor(peaks: peaks))
    }
}

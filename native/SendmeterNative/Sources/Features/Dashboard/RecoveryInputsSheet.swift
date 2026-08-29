import Charts
import SendmeterCore
import SwiftUI

/// #753: native port of the web Recovery Inputs sheet.
///
/// This is the raw-health breakdown behind the readiness score. It uses the
/// same `model.healthMetrics` as the readiness trend card, but presents each
/// metric as its own small bars-plus-single-7d-EWMA card. All rows share the
/// same 14-day X window so a scrub/tap in one row highlights the same column
/// in every row.
struct RecoveryInputsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppUnits.storageKey) private var unitsPreference = UnitsPreference.metric.rawValue

    @State private var snapshot = RecoveryInputsSeries(days: [], rows: [])
    /// The shared selected day. `selectedDay` is kept instead of a raw Date
    /// so all rows can compare against the same immutable day identity while
    /// the chart rule mark still gets a stable `dateValue`.
    @State private var selectedDay: RecoverySeriesDay?
    /// The row that owns the tooltip. The shared column still highlights in
    /// every row, but only the row being touched shows its own tooltip.
    @State private var activeMetric: RecoveryMetric?
    /// Haptic dedupe: one `.selection` tick per day crossed, never per drag
    /// frame, matching the readiness trend card.
    @State private var tickedDay: RecoverySeriesDay?

    private var preference: UnitsPreference {
        AppUnits.normalize(unitsPreference)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if snapshot.hasData {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("The raw HealthKit metrics your daily readiness score is computed from.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                legend
                            }
                        }
                        metricRows
                        sharedAxis
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Recovery Inputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { rebuild() }
        .onChange(of: model.healthMetrics) { _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            rebuild()
        }
        .onDisappear {
            selectedDay = nil
            activeMetric = nil
            tickedDay = nil
        }
    }

    private func rebuild() {
        snapshot = RecoveryInputsSeries.build(metrics: model.healthMetrics)
        if let selectedDay,
           !snapshot.days.contains(where: { $0.id == selectedDay.id }) {
            self.selectedDay = nil
            activeMetric = nil
            tickedDay = nil
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ChartToken.health.color(scheme).opacity(0.65))
                    .frame(width: 9, height: 9)
                Text("Day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Rectangle()
                    .fill(ChartToken.focus.color(scheme))
                    .frame(width: 14, height: 2)
                Text("7d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Rectangle()
                    .fill(ChartToken.reference.color(scheme))
                    .frame(width: 14, height: 2)
                    .overlay { Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(ChartToken.reference.color(scheme)) }
                Text("28d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bars show each day. The blue line is the seven-day average trend. The dashed line is the 28-day average trend.")
    }

    // MARK: - Rows

    private var metricRows: some View {
        LazyVStack(spacing: 14) {
            ForEach(snapshot.rows) { row in
                RecoveryMetricRowView(
                    series: row,
                    axisDays: snapshot.days,
                    selectedDay: selectedDay,
                    activeMetric: activeMetric,
                    preference: preference,
                    onSelect: { day in
                        select(day, metric: row.metric)
                    }
                )
            }
        }
    }

    private var sharedAxis: some View {
        HStack {
            Text(axisLabel(snapshot.days.first))
            Spacer()
            Text(axisLabel(snapshot.days.dropFirst(snapshot.days.count / 2).first))
            Spacer()
            Text(axisLabel(snapshot.days.last))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }

    private func axisLabel(_ day: RecoverySeriesDay?) -> String {
        guard let day else { return "" }
        return LocalDateSupport.monthDayLabel(for: day.date)
    }

    private func select(_ day: RecoverySeriesDay, metric: RecoveryMetric) {
        if SelectionHaptics.valueChanged(tickedDay, day) {
            tickedDay = day
            Haptics.shared.playGesture(.selection)
        }
        selectedDay = day
        activeMetric = metric
    }

    // MARK: - Empty

    private var emptyState: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("The raw HealthKit metrics your daily readiness score is computed from.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("HRV, resting heart rate, sleep, and weight will show here once your watch starts syncing overnight data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One metric row: label + latest value, then a small bar/EWMA chart. The
/// row is deliberately self-contained so the seven metrics stay visually and
/// structurally identical.
private struct RecoveryMetricRowView: View {
    let series: RecoveryMetricSeries
    let axisDays: [RecoverySeriesDay]
    let selectedDay: RecoverySeriesDay?
    let activeMetric: RecoveryMetric?
    let preference: UnitsPreference
    let onSelect: (RecoverySeriesDay) -> Void

    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 70
    @State private var tooltipSize: CGSize = .zero

    private var selectedMetricDay: RecoveryMetricDay? {
        guard let selectedDay else { return nil }
        return series.days.first { $0.id == selectedDay.id }
    }

    private var latestText: String {
        guard let latest = series.latestDay, let value = latest.value else {
            return "No data"
        }
        return series.metric.formatted(value, for: preference)
    }

    private var latestUnit: String {
        series.metric.displayUnit(for: preference)
    }

    private var xDomain: ClosedRange<Date>? {
        guard let first = axisDays.first?.dateValue,
              let last = axisDays.last?.dateValue else { return nil }
        return first...last
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                header
                chart
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityValue(accessibilityRowValue)
        .accessibilityHint("Shows \(series.metric.title.lowercased()) over the last fourteen days.")
        .accessibilityChartDescriptor(
            RecoverySeriesAccessibilityDescriptor(
                metric: series.metric,
                days: series.days,
                preference: preference
            )
        )
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.metric.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                valueText
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(series.metric.title)
                    .font(.subheadline.weight(.semibold))
                valueText
            }
        }
    }

    private var valueText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(latestText)
                .font(.headline.monospacedDigit())
            Text(latestUnit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Accessibility

    private var accessibilityRowLabel: String {
        series.metric.title
    }

    private var accessibilityRowValue: String {
        guard let latest = series.latestDay, let value = latest.value else {
            return "No data"
        }
        let formatted = series.metric.formattedWithUnit(value, for: preference)
        if let selectedDay, selectedMetricDay?.value == nil {
            return "\(selectedDay.date): no data; latest \(formatted) on \(latest.date)"
        }
        return "\(latest.date): \(formatted)"
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            if let selectedDay {
                RuleMark(x: .value("Selected day", selectedDay.dateValue))
                    .foregroundStyle(ChartToken.axis.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            ForEach(series.days) { day in
                if let value = day.value {
                    let baseline = day.trend28 ?? series.yDomain?.lowerBound ?? value
                    BarMark(
                        x: .value("Day", day.dateValue),
                        yStart: .value("Baseline", series.yDomain?.lowerBound ?? baseline),
                        yEnd: .value(series.metric.title, value)
                    )
                    .foregroundStyle(barColor(value: value, baseline: baseline))
                    .opacity(selectedDay == nil || selectedDay?.id == day.id ? 0.75 : 0.38)
                    .cornerRadius(2)
                }

                if let trend = day.trend, let runIndex = day.runIndex {
                    LineMark(
                        x: .value("Day", day.dateValue),
                        y: .value("7d EWMA", trend),
                        series: .value("Run", runIndex)
                    )
                    .foregroundStyle(ChartToken.focus.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
                if let trend28 = day.trend28, let runIndex = day.runIndex {
                    LineMark(
                        x: .value("Day", day.dateValue),
                        y: .value("28d EWMA", trend28),
                        series: .value("Long run", runIndex)
                    )
                    .foregroundStyle(ChartToken.reference.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: series.yDomain ?? 0...1)
        .chartXScale(domain: xDomain ?? Date()...Date())
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                AxisValueLabel().foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) {
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel().foregroundStyle(.clear)
            }
        }
        .frame(height: chartHeight)
        .chartPlotStyle { plotArea in
            plotArea.clipped()
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                Color.clear
                    .contentShape(Rectangle())
                    .hapticTapMuted()
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                if let day = nearestDay(at: value.location.x, proxy: proxy, plotFrame: plotFrame) {
                                    onSelect(day)
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                if let day = nearestDay(at: value.location.x, proxy: proxy, plotFrame: plotFrame) {
                                    onSelect(day)
                                }
                            }
                    )

                if let selectedDay, activeMetric == series.metric {
                    let x = (proxy.position(forX: selectedDay.dateValue) ?? 0) + plotFrame.minX
                    tooltip(for: selectedDay, x: x, plotFrame: plotFrame)
                }
            }
        }
        .hapticTapMuted()
    }

    private func barColor(value: Double, baseline: Double) -> Color {
        let position = RecoveryBarGradient.position(value: value, baseline: baseline)
        let lower = UIColor(ChartToken.caution.color(scheme))
        let middle = UIColor(ChartToken.health.color(scheme))
        let upper = UIColor(ChartToken.load.color(scheme))
        if position <= 0.5 {
            return blend(lower, middle, amount: position * 2)
        }
        return blend(middle, upper, amount: (position - 0.5) * 2)
    }

    private func blend(_ first: UIColor, _ second: UIColor, amount: Double) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, opacity: a1 + (a2 - a1) * t)
    }

    private func nearestDay(at x: CGFloat, proxy: ChartProxy, plotFrame: CGRect) -> RecoverySeriesDay? {
        let plotX = x - plotFrame.minX
        return axisDays.min { lhs, rhs in
            let lhsX = proxy.position(forX: lhs.dateValue) ?? 0
            let rhsX = proxy.position(forX: rhs.dateValue) ?? 0
            return abs(lhsX - plotX) < abs(rhsX - plotX)
        }
    }

    // MARK: - Tooltip

    private func tooltip(for day: RecoverySeriesDay, x: CGFloat, plotFrame: CGRect) -> some View {
        let value = selectedMetricDay?.value
        let text = value.map {
            series.metric.formattedWithUnit($0, for: preference)
        } ?? "No data"
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(LocalDateSupport.monthDayLabel(for: day.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
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
                        .onChange(of: geo.size) { newSize in
                            tooltipSize = newSize
                        }
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

/// VoiceOver audio graph for one recovery metric row. It mirrors the
/// readiness trend descriptor but omits gap days so a missing night never
/// sounds like a value at the bottom of the row's scale.
private struct RecoverySeriesAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let metric: RecoveryMetric
    let days: [RecoveryMetricDay]
    let preference: UnitsPreference

    func makeChartDescriptor() -> AXChartDescriptor {
        makeDescriptor()
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let rebuilt = makeDescriptor()
        descriptor.title = rebuilt.title
        descriptor.summary = rebuilt.summary
        descriptor.xAxis = rebuilt.xAxis
        descriptor.yAxis = rebuilt.yAxis
        descriptor.series = rebuilt.series
    }

    private func makeDescriptor() -> AXChartDescriptor {
        let dateAxis = AXCategoricalDataAxisDescriptor(
            title: "Date",
            categoryOrder: days.map(\.date)
        )
        let domain = RecoveryMetricSeries(metric: metric, days: days).yDomain ?? 0...1
        let valueAxis = AXNumericDataAxisDescriptor(
            title: metric.title,
            range: domain,
            gridlinePositions: []
        ) { value in
            metric.formatted(value, for: preference)
        }
        let points = days.compactMap { day -> AXDataPoint? in
            guard let value = day.value else { return nil }
            return AXDataPoint(
                x: day.date,
                y: value,
                label: metric.formattedWithUnit(value, for: preference)
            )
        }
        let series = AXDataSeriesDescriptor(
            name: metric.title,
            isContinuous: false,
            dataPoints: points
        )
        return AXChartDescriptor(
            title: "\(metric.title) recovery input",
            summary: "\(metric.title) for each of the last fourteen days.",
            xAxis: dateAxis,
            yAxis: valueAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

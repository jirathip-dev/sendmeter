import Charts
import SendmeterCore
import SwiftUI

/// #756: native port of the web Send Conditions detail sheet.
///
/// The sheet is percentile-first when the same-hour history is available,
/// exactly like the web: a big local-rank headline, the countable callout, a
/// same-hour 30-day bar chart with a median reference line, the absolute
/// friction gauge, and the temperature/humidity sub-score breakdown. It uses
/// the same `SendConditionsScore` formulas as the summary card, so the two
/// surfaces cannot disagree about a reading.
struct SendConditionsDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 150

    @State private var selectedDate: Date?
    @State private var tickedDay: SendConditionsHistoryDay?
    @State private var tooltipSize: CGSize = .zero

    private var conditions: SendConditions? {
        model.weather.conditions
    }

    private var history: SendConditionsHistory? {
        conditions.flatMap(SendConditionsHistoryBuilder.build)
    }

    private var selectedDay: SendConditionsHistoryDay? {
        guard let selectedDate, let history else { return nil }
        return history.allDays.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(selectedDate))
                < abs(rhs.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Friction is best when it's cool and dry — better grip, less sweat.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let conditions {
                        populatedContent(conditions)
                    } else {
                        unavailableContent
                    }

                    refreshButton
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Send conditions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onDisappear {
            selectedDate = nil
            tickedDay = nil
        }
    }

    // MARK: - Refresh and availability

    private var refreshButton: some View {
        Button {
            refresh()
        } label: {
            HStack(spacing: 8) {
                if model.weather.isFetching {
                    ProgressView()
                        .tint(.white)
                }
                Text(model.weather.isFetching ? "Checking…" : buttonTitle)
            }
        }
        .hapticButtonStyle(PrimaryActionButtonStyle())
        .disabled(model.weather.isFetching)
    }

    private var buttonTitle: String {
        conditions == nil ? "Check conditions" : "Refresh"
    }

    private func refresh() {
        Task { _ = await model.weather.refresh(trigger: .manual) }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        Text(model.weather.failed
            ? "Couldn't read the weather — check that location access is allowed, then try again."
            : "Check the current temperature and humidity at your location to see how good conditions are for sending."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Populated sections

    private func populatedContent(_ conditions: SendConditions) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            headline(conditions)

            if let percentile = conditions.percentile {
                percentileCallout(percentile: percentile, conditions: conditions)
            }

            if conditions.percentile != nil, let history {
                historySection(conditions: conditions, history: history)
            }

            absoluteFriction(conditions)
            scoringSection(conditions)

            Text(SendConditionsDetails.explainer(conditions: conditions))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Updated \(conditions.fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Headline

    private func headline(_ conditions: SendConditions) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(SendConditionsScore.displayLabel(for: conditions).rawValue)
                .font(.system(size: headlineSize, weight: .heavy, design: .rounded))
                .foregroundStyle(color(for: conditions))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(headlineDetail(for: conditions))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(Int(conditions.tempC.rounded()))°C · \(Int(conditions.humidity.rounded()))% humidity")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SendConditionsScore.displayLabel(for: conditions).rawValue) conditions for here")
        .accessibilityValue(headlineDetail(for: conditions))
    }

    private func headlineDetail(for conditions: SendConditions) -> String {
        guard let percentile = conditions.percentile else {
            return "\(conditions.score)/100"
        }
        let suffix = SendConditionsDetails.headlineSuffix(
            percentile: percentile,
            daysTotal: conditions.daysTotal
        )
        return suffix.map { "conditions for here · \($0)" } ?? "conditions for here"
    }

    // MARK: - Percentile callout

    @ViewBuilder
    private func percentileCallout(percentile: Int, conditions: SendConditions) -> some View {
        if let dayBelow = conditions.daysBelow, let daysTotal = conditions.daysTotal {
            let callout = Text("Better than ")
                + Text("\(dayBelow) of the last \(daysTotal) days")
                    .bold()
                + Text(" at this time of day. \(SendConditionsDetails.percentilePhrase(percentile))")
            callout
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    SendConditionsDetails.percentileCallout(
                        daysBelow: conditions.daysBelow,
                        daysTotal: conditions.daysTotal,
                        percentile: percentile
                    ) ?? ""
                )
        }
    }

    // MARK: - History chart

    private func historySection(conditions: SendConditions, history: SendConditionsHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Same time of day · last 30 days")

            chart(conditions: conditions, history: history)

            HStack {
                Text("\(history.days.first?.daysAgo ?? 0) days ago")
                Spacer()
                Text("today")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)

            rangeLine(conditions: conditions)
        }
    }

    @ViewBuilder
    private func rangeLine(conditions: SendConditions) -> some View {
        if let hist = conditions.hist {
            let label = Text("Range here: ")
                + Text("\(Int(hist.tempMin.rounded()))–\(Int(hist.tempMax.rounded()))°C").bold()
                + Text(", ")
                + Text("\(Int(hist.humMin.rounded()))–\(Int(hist.humMax.rounded()))%").bold()
                + Text(" humidity.")
            label
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func chart(conditions: SendConditions, history: SendConditionsHistory) -> some View {
        let yMax = Double(max(1, history.scoreValues.max() ?? 0, conditions.score))
        if #available(iOS 17, *) {
            return baseChart(conditions: conditions, history: history, yMax: yMax)
                .frame(height: chartHeight)
                .chartXSelection(value: $selectedDate)
                .hapticTapMuted()
                .onChange(of: selectedDate) { _ in
                    if let selectedDay {
                        if SelectionHaptics.valueChanged(tickedDay, selectedDay) {
                            tickedDay = selectedDay
                            Haptics.shared.playGesture(.selection)
                        }
                    } else {
                        tickedDay = nil
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let plotFrame = geo[proxy.plotAreaFrame]
                        referenceLineLabels(history: history, conditions: conditions, proxy: proxy, plotFrame: plotFrame)
                        if selectedDate != nil, let selectedDay {
                            let x = (proxy.position(forX: selectedDay.date) ?? 0) + plotFrame.minX
                            tooltip(for: selectedDay, x: x, plotFrame: plotFrame)
                        }
                    }
                }
                .accessibilityLabel("Same-time-of-day send conditions comparison")
                .accessibilityValue(selectedDay.map(accessibilityText) ?? "")
                .accessibilitySendConditionsChartDescriptor(history)
        } else {
            return baseChart(conditions: conditions, history: history, yMax: yMax)
                .frame(height: chartHeight)
                .hapticTapMuted()
                .accessibilityLabel("Same-time-of-day send conditions comparison")
                .accessibilityValue(selectedDay.map(accessibilityText) ?? "")
                .accessibilitySendConditionsChartDescriptor(history)
        }
    }

    private func baseChart(
        conditions: SendConditions,
        history: SendConditionsHistory,
        yMax: Double
    ) -> some View {
        Chart {
            ForEach(history.allDays) { day in
                if let score = day.score {
                    BarMark(
                        x: .value("Day", day.date),
                        y: .value("Score", score)
                    )
                    .foregroundStyle(
                        (day.isToday ? color(for: conditions) : ChartToken.reference.color(scheme))
                            .opacity(selectedDay == nil || selectedDay?.id == day.id ? 0.85 : 0.42)
                    )
                    .cornerRadius(2)
                }
            }

            if let median = history.median {
                RuleMark(y: .value("Median", median))
                    .foregroundStyle(ChartToken.reference.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            RuleMark(y: .value("Today", conditions.score))
                .foregroundStyle(color(for: conditions))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartYScale(domain: 0...yMax)
        .chartXScale(domain: history.dateDomain ?? Date()...Date())
        .chartYAxis {
            AxisMarks {
                AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                AxisValueLabel().foregroundStyle(.clear)
            }
        }
        .chartXAxis {
            AxisMarks {
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel().foregroundStyle(.clear)
            }
        }
    }

    @ViewBuilder
    private func referenceLineLabels(
        history: SendConditionsHistory,
        conditions: SendConditions,
        proxy: ChartProxy,
        plotFrame: CGRect
    ) -> some View {
        // Web `todayAbove`: each label sits on the side away from the other
        // line, so they cannot collide when today is exactly the median.
        let todayAbove = history.median.map { Double(conditions.score) >= $0 } ?? true
        ZStack(alignment: .topTrailing) {
            if let median = history.median {
                Text("median")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ChartToken.axis.color(scheme))
                    .frame(width: 64, alignment: .trailing)
                    .position(
                        x: referenceLabelX(plotFrame: plotFrame),
                        y: referenceLineY(
                            proxy: proxy,
                            value: median,
                            plotFrame: plotFrame,
                            side: todayAbove ? -1 : 1
                        )
                    )
            }
            Text("today")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: conditions))
                .frame(width: 64, alignment: .trailing)
                .position(
                    x: referenceLabelX(plotFrame: plotFrame),
                    y: referenceLineY(
                        proxy: proxy,
                        value: Double(conditions.score),
                        plotFrame: plotFrame,
                        side: todayAbove ? 1 : -1
                    )
                )
        }
    }

    private func referenceLabelX(plotFrame: CGRect) -> CGFloat {
        plotFrame.maxX - 34
    }

    private func referenceLineY(
        proxy: ChartProxy,
        value: Double,
        plotFrame: CGRect,
        side: Int
    ) -> CGFloat {
        let lineY = (proxy.position(forY: value) ?? 0) + plotFrame.minY
        let rawY = side > 0 ? lineY + 14 : lineY - 14
        return min(max(rawY, plotFrame.minY + 7), plotFrame.maxY - 7)
    }

    // MARK: - Tooltip

    private func tooltip(for day: SendConditionsHistoryDay, x: CGFloat, plotFrame: CGRect) -> some View {
        let content = TrainingLoadTooltip {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle(for: day))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let score = day.score {
                    Text("Score \(score)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                } else {
                    Text("No data")
                        .font(.subheadline.weight(.semibold))
                }
                if let tempC = day.tempC, let humidity = day.humidity {
                    Text("\(Int(tempC.rounded()))°C · \(Int(humidity.rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

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

    private func dayTitle(for day: SendConditionsHistoryDay) -> String {
        day.isToday ? "Today" : "\(day.daysAgo) days ago"
    }

    private func accessibilityText(for day: SendConditionsHistoryDay) -> String {
        let title = dayTitle(for: day)
        guard let score = day.score else { return "\(title): no data" }
        var text = "\(title): send conditions score \(score)"
        if let tempC = day.tempC, let humidity = day.humidity {
            text += ", \(Int(tempC.rounded())) degrees, \(Int(humidity.rounded())) percent humidity"
        }
        return text
    }

    // MARK: - Absolute friction

    private func absoluteFriction(_ conditions: SendConditions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Absolute friction")

            if conditions.percentile != nil {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(SendConditionsScore.scoreLabel(score: conditions.score).rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scoreColor(conditions.score))
                    Text("· \(conditions.score)/100")
                        .font(.subheadline)
                    Text("— \(Int(conditions.tempC.rounded()))°C · \(Int(conditions.humidity.rounded()))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [
                                SendmeterStyle.alert,
                                SendmeterStyle.caution,
                                SendmeterStyle.optimal
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .opacity(0.85)
                    Circle()
                        .fill(scoreColor(conditions.score))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                        .position(
                            x: min(max(CGFloat(conditions.score) / 100, 0), 1) * geo.size.width,
                            y: geo.size.height / 2
                        )
                }
            }
            .frame(height: 10)

            HStack {
                Text("Poor")
                Spacer()
                Text("Fair")
                Spacer()
                Text("Good")
                Spacer()
                Text("Prime")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Absolute friction")
        .accessibilityValue(
            "\(SendConditionsScore.scoreLabel(score: conditions.score).rawValue), \(conditions.score) out of 100"
        )
    }

    // MARK: - Sub-scores

    private func scoringSection(_ conditions: SendConditions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("How it's scored")

            SendConditionsSubScore(
                label: "Temperature",
                detail: "\(Int(conditions.tempC.rounded()))°C · 60%",
                score: Int(SendConditionsScore.tempFrictionScore(tempC: conditions.tempC).rounded()),
                color: scoreColor(Int(SendConditionsScore.tempFrictionScore(tempC: conditions.tempC).rounded()))
            )
            SendConditionsSubScore(
                label: "Humidity",
                detail: "\(Int(conditions.humidity.rounded()))% · 40%",
                score: Int(SendConditionsScore.humidityFrictionScore(humidity: conditions.humidity).rounded()),
                color: scoreColor(Int(SendConditionsScore.humidityFrictionScore(humidity: conditions.humidity).rounded()))
            )
        }
    }

    // MARK: - Color mapping

    private func color(for conditions: SendConditions) -> Color {
        SendConditionsScore.colorBand(for: conditions).color
    }

    private func scoreColor(_ score: Int) -> Color {
        SendConditionsScore.scoreColorBand(score).color
    }
}

private struct SendConditionsSubScore: View {
    let label: String
    let detail: String
    let score: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· \(score)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .secondarySystemFill))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(max(score, 0), 100)) / 100)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(detail), \(score) out of 100")
    }
}

/// VoiceOver audio graph for the same-hour comparison chart. The axis keeps
/// every day slot so null days remain visibly absent rather than reading as a
/// zero score.
private struct SendConditionsChartAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let history: SendConditionsHistory

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
        let dayAxis = AXCategoricalDataAxisDescriptor(
            title: "Day",
            categoryOrder: history.allDays.map { LocalDateSupport.string(from: $0.date) }
        )
        let scoreAxis = AXNumericDataAxisDescriptor(
            title: "Send conditions score",
            range: 0...100,
            gridlinePositions: []
        ) { value in
            "\(Int(value))"
        }
        let points = history.allDays.compactMap { day -> AXDataPoint? in
            guard let score = day.score else { return nil }
            var label = day.isToday ? "Today" : "\(day.daysAgo) days ago"
            label += ": \(score)"
            if let tempC = day.tempC, let humidity = day.humidity {
                label += ", \(Int(tempC.rounded())) degrees, \(Int(humidity.rounded())) percent humidity"
            }
            return AXDataPoint(
                x: LocalDateSupport.string(from: day.date),
                y: Double(score),
                label: label
            )
        }
        let series = AXDataSeriesDescriptor(
            name: "Send conditions score",
            isContinuous: false,
            dataPoints: points
        )
        return AXChartDescriptor(
            title: "Same-time-of-day send conditions comparison",
            summary: "Send conditions score at the same time of day over the last thirty days, with today's reading highlighted.",
            xAxis: dayAxis,
            yAxis: scoreAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

private extension View {
    func accessibilitySendConditionsChartDescriptor(
        _ history: SendConditionsHistory
    ) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(
                SendConditionsChartAccessibilityDescriptor(history: history)
            )
    }
}

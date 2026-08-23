import Charts
import SendmeterCore
import SwiftUI

/// ACWR next-7-days projection card (#652) — port of the web's
/// `AcwrProjectionCard.tsx` + `src/lib/acwrProjection.ts` to the native
/// Dashboard. Shows where the ACWR ratio drifts over the next week if you
/// train NOTHING, against the current phase's band, plus what a single
/// session would have to be to keep it in band.
///
/// The math is pure and lives in `SendmeterCore.AcwrProjection` (unit-tested
/// against the web's fixtures); this view only renders. The dashed projection
/// line uses the `reference` token, the phase band is a `RectangleMark` with
/// the reference band gradient, the first day under the floor gets a dashed
/// `axis` `RuleMark`, and day 0 — the only real number on the chart — is a
/// solid dot colored by the universal ACWR status with a radial halo.
struct AcwrProjectionCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    /// Bumped on a calendar-day rollover so the projection (whose dates and
    /// relative labels read `Date()`) recomputes for the new today (#652 F11).
    @State private var dayMarker = Date()
    @State private var selectedScrubX: Double?
    @State private var tooltipSize: CGSize = .zero
    @State private var tickedDayOffset: Int?

    /// The projection, recomputed on each model change. Deliberately no
    /// snapshot machinery like the readiness trend — the projection itself is
    /// only 8 forward steps (~0.02 ms), and the view recomputes it from the
    /// model's sessions exactly once per body pass, in one place (`projection`
    /// below) that every subview reads.
    private var projection: AcwrProjection.Result? {
        _ = dayMarker
        let phase = model.currentPhase
        let band = AcwrProjection.Band(low: phase.acwrLow, high: phase.acwrHigh)
        return AcwrProjection.project(
            state: TrainingMetrics.ewmaLoadState(sessions: model.sessions),
            band: band
        )
    }

    private func selectedProjectionDay(_ projection: AcwrProjection.Result) -> AcwrProjection.ProjectedDay? {
        guard let selectedScrubX else { return nil }
        return projection.days.min { lhs, rhs in
            abs(Double(lhs.dayOffset) - selectedScrubX)
                < abs(Double(rhs.dayOffset) - selectedScrubX)
        }
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("ACWR next 7 days", systemImage: "chart.line.uptrend.xyaxis")
                Text("If you train nothing")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let projection {
                    chart(projection)
                    Text(headline(projection))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let keepInBand = projection.keepInBand, let band = projection.band {
                        Text(keepInBandText(keepInBand, todayFit: projection.days[0].fit, bandLow: band.low))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    emptyState
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            // A full day in the foreground must not keep yesterday's dates and
            // relative labels — bump the marker so the projection recomputes
            // from the new today (#652 F11). The projection reads `Date()`
            // internally, so any body invalidation recomputes it.
            dayMarker = Date()
        }
    }

    /// #652 F2: distinguish the nil causes instead of telling a user with
    /// years of history "log a few sessions" on every cold launch.
    ///
    /// `projection` is nil in three materially different situations:
    /// - sessions not fetched yet → "still loading" (distinct — sessions have
    ///   no disk cache, so every cold launch renders a pass with `[]`);
    /// - genuinely no sessions → the "log a few sessions" explainer;
    /// - sessions exist but all load fell out of the 90-day window (or the
    ///   chronic term is zero) → the ratio has nothing to project from.
    @ViewBuilder
    private var emptyState: some View {
        if !model.hasLoadedSessions {
            Text("Your training history is still loading.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if model.sessions.isEmpty {
            Text("Log a few sessions and this card will show where your ACWR drifts over the coming week if you don't train.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text("Your most recent sessions fall outside the 90-day window this card projects from, so there's no ACWR ratio to extend yet — log a session and this card will show where it drifts over the coming week.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    private func chart(_ projection: AcwrProjection.Result) -> some View {
        return Group {
            if #available(iOS 17, *) {
                baseChart(projection)
                    .frame(height: 150)
                    .chartXSelection(value: $selectedScrubX)
                    .hapticTapMuted()
                    .onChange(of: selectedScrubX) { _ in
                        if let day = selectedProjectionDay(projection) {
                            if SelectionHaptics.valueChanged(tickedDayOffset, day.dayOffset) {
                                tickedDayOffset = day.dayOffset
                                Haptics.shared.playGesture(.selection)
                            }
                        } else {
                            tickedDayOffset = nil
                        }
                    }
                    .onDisappear { tickedDayOffset = nil }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            if selectedScrubX != nil, let day = selectedProjectionDay(projection) {
                                let plotFrame = geo[proxy.plotAreaFrame]
                                let x = (proxy.position(forX: Double(day.dayOffset)) ?? 0) + plotFrame.minX
                                tooltip(for: day, projection: projection, x: x, plotFrame: plotFrame)
                            }
                        }
                    }
                    .accessibilityLabel("Projected ACWR over the next seven days")
                    .accessibilityValue(
                        selectedProjectionDay(projection).map {
                            accessibilityText(for: $0, projection: projection)
                        } ?? accessibilitySummary(projection)
                    )
                    .accessibilityProjectionChartDescriptor(projection)
            } else {
                baseChart(projection)
                    .frame(height: 150)
                    .hapticTapMuted()
                    .accessibilityLabel("Projected ACWR over the next seven days")
                    .accessibilityValue(accessibilitySummary(projection))
                    .accessibilityProjectionChartDescriptor(projection)
            }
        }
    }

    private func baseChart(_ projection: AcwrProjection.Result) -> some View {
        let today = projection.days[0]
        let selectedDay = selectedProjectionDay(projection)
        return Chart {
            // The phase's target band — deliberately the phase band, not the
            // universal 0.8–1.3 risk zone the ACWR track draws.
            if let band = projection.band {
                RectangleMark(
                    xStart: .value("Start", 0),
                    xEnd: .value("End", Double(AcwrProjection.projectionDays)),
                    yStart: .value("Band low", band.low),
                    yEnd: .value("Band high", band.high)
                )
                .foregroundStyle(ChartToken.reference.bandGradient(scheme))
                RuleMark(y: .value("Band high", band.high))
                    .foregroundStyle(ChartToken.optimal.color(scheme).opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RuleMark(y: .value("Band low", band.low))
                    .foregroundStyle(ChartToken.optimal.color(scheme).opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            // Dashed on purpose: none of this is measured data. All x values
            // are Double so the whole chart shares one numeric x scale.
            ForEach(projection.days, id: \.dayOffset) { day in
                LineMark(
                    x: .value("Day", Double(day.dayOffset)),
                    y: .value("ACWR", day.acwr)
                )
            }
            .foregroundStyle(ChartToken.reference.color(scheme))
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 4]))

            if let selectedDay {
                RuleMark(x: .value("Selected day", Double(selectedDay.dayOffset)))
                    .foregroundStyle(ChartToken.axis.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // The first day the curve drops under the floor.
            if let crossing = projection.fallsBelow {
                RuleMark(x: .value("Crossing", Double(crossing.dayOffset)))
                    .foregroundStyle(ChartToken.axis.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Today is the only real number on the chart — a solid point
            // colored by its risk status, with a radial halo behind it. The
            // halo's symbolSize is an area (≈ r²·π), so it is sized to make
            // its radius match the gradient's endRadius — the fade completes
            // at the shape edge, exactly like the web's r=7 halo.
            PointMark(
                x: .value("Day", Double(today.dayOffset)),
                y: .value("ACWR", today.acwr)
            )
            .foregroundStyle(ChartToken.selectedHalo(scheme, endRadius: 7))
            .symbolSize(154)
            PointMark(
                x: .value("Day", Double(today.dayOffset)),
                y: .value("ACWR", today.acwr)
            )
            .foregroundStyle(ChartToken.acwrStatusColor(today.acwr, scheme))
            .symbolSize(8)
        }
        .chartYScale(domain: yDomain(projection))
        .chartXScale(domain: 0...Double(AcwrProjection.projectionDays))
        .chartXAxis {
            AxisMarks(values: axisValues(projection)) { value in
                AxisValueLabel {
                    axisLabel(value.as(Double.self), projection: projection)
                }
                .foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: bandAxisValues(projection)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v.formatted(.number.precision(.fractionLength(1))))
                    }
                }
                .foregroundStyle(ChartToken.axis.color(scheme).opacity(0.7))
            }
        }
    }

    private func tooltip(
        for day: AcwrProjection.ProjectedDay,
        projection: AcwrProjection.Result,
        x: CGFloat,
        plotFrame: CGRect
    ) -> some View {
        let heading = day.dayOffset == 0 ? "Now" : "Day \(day.dayOffset)"
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(day.acwr.formatted(.number.precision(.fractionLength(2))))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if let fit = day.fit {
                Text(fit.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(fit == .below ? ChartToken.alert.color(scheme) : .secondary)
            }
            if let band = projection.band {
                Text("Band \(formatOneDecimal(band.low))–\(formatOneDecimal(band.high))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if projection.fallsBelow?.dayOffset == day.dayOffset {
                Text("Crosses below the band here")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ChartToken.caution.color(scheme))
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

    private func accessibilityText(
        for day: AcwrProjection.ProjectedDay,
        projection: AcwrProjection.Result
    ) -> String {
        let heading = day.dayOffset == 0 ? "Now" : "Day \(day.dayOffset)"
        var parts = ["\(heading) \(String(format: "%.2f", day.acwr))"]
        if let fit = day.fit {
            parts.append(fit.rawValue)
        }
        if projection.fallsBelow?.dayOffset == day.dayOffset {
            parts.append("crosses below the band")
        }
        return parts.joined(separator: ", ")
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

    /// Y domain from the plotted values + band edges, with ~12% headroom
    /// either side (min 0.05) so the band edges and the today dot never sit
    /// flush against the frame — the web's `Math.max((hi-lo)*0.12, 0.05)`.
    private func yDomain(_ projection: AcwrProjection.Result) -> ClosedRange<Double> {
        var values = projection.days.map(\.acwr)
        if let band = projection.band {
            values.append(band.low)
            values.append(band.high)
        }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.12, 0.05)
        return (lo - pad)...(hi + pad)
    }

    /// X-axis positions: 0 ("Now"), the crossing day, and the horizon (+7d).
    private func axisValues(_ projection: AcwrProjection.Result) -> [Double] {
        var values = [0.0, Double(AcwrProjection.projectionDays)]
        if let crossing = projection.fallsBelow {
            let d = Double(crossing.dayOffset)
            if !values.contains(d) { values.append(d) }
        }
        return values.sorted()
    }

    /// #652 F9 / #705: keep the current value out of the `Now` position marker
    /// so an early crossing weekday has room beside it. The current ACWR is
    /// still visible in Today's decision and the Training load card above.
    /// A day-7 crossing keeps BOTH its weekday and the horizon label on
    /// separate lines.
    private func axisLabel(_ value: Double?, projection: AcwrProjection.Result) -> Text {
        guard let value else { return Text("") }
        let crossing = projection.fallsBelow
        let lines = AcwrProjection.projectionXAxisLabelLines(
            dayOffset: Int(value.rounded()),
            crossingDayOffset: crossing?.dayOffset,
            crossingWeekday: crossing.map { weekdayLabel(for: $0.date) }
        )
        return Text(lines.joined(separator: "\n"))
    }

    private func bandAxisValues(_ projection: AcwrProjection.Result) -> [Double] {
        guard let band = projection.band else { return [] }
        return [band.low, band.high]
    }

    /// #652 F10: the device locale for the weekday — matching
    /// `relativeDayLabel` in the headline directly beneath the chart (the web
    /// uses the device locale for both). Only the calendar is pinned.
    private func weekdayLabel(for date: String) -> String {
        guard let day = LocalDateSupport.date(from: date) else { return "" }
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.calendar = Calendar(identifier: .gregorian)
        return day.formatted(style)
    }

    // MARK: - Copy

    /// The plain-language version of the projection: what leaves the band,
    /// when. Mirrors the web's `headline()`. `model.currentPhase` always has a
    /// band (non-optional `acwrLow/acwrHigh`), so the projection is never
    /// created with `band == nil` from this card — but the no-band branches
    /// are kept for the pure function's contract (#652 F12).
    private func headline(_ projection: AcwrProjection.Result) -> String {
        let todayFit = projection.days[0].fit
        guard let band = projection.band, let todayFit else {
            return "No phase band to project against."
        }
        let bandText = "\(model.currentPhase.name) band (\(formatOneDecimal(band.low))–\(formatOneDecimal(band.high)))"
        switch todayFit {
        case .above:
            let back = projection.entersBand.map {
                "back inside \(LocalDateSupport.relativeDayLabel(for: $0.date))"
            } ?? "still above it in a week"
            let out = projection.fallsBelow.map {
                ", then under it \(LocalDateSupport.relativeDayLabel(for: $0.date))"
            } ?? ""
            return "Above your \(bandText) — resting brings you \(back)\(out)."
        case .below:
            return "Already below your \(bandText), and resting keeps it falling."
        case .onTarget:
            return projection.fallsBelow.map {
                "Drops below your \(bandText) \(LocalDateSupport.relativeDayLabel(for: $0.date))."
            } ?? "Stays inside your \(bandText) all week, even with no training."
        }
    }

    private func keepInBandText(
        _ keepInBand: AcwrProjection.LoadSuggestion,
        todayFit: PhaseFit?,
        bandLow: Double
    ) -> String {
        let verb = todayFit == .below ? "bring you back to" : "hold"
        return "About \(keepInBand.durationMin) min @ RPE \(Int(keepInBand.rpe)) "
            + LocalDateSupport.relativeDayLabel(for: keepInBand.date)
            + " would \(verb) the \(formatOneDecimal(bandLow)) floor — "
            + "\(Int(keepInBand.load.rounded())) AU, or any duration × RPE that multiplies out the same."
    }

    private func formatOneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func accessibilitySummary(_ projection: AcwrProjection.Result) -> String {
        var parts = [
            "Today \(projection.days[0].acwr.formatted(.number.precision(.fractionLength(2))))"
        ]
        for day in projection.days.dropFirst() {
            let fit = day.fit.map { " \($0.rawValue)" } ?? ""
            parts.append("day \(day.dayOffset), \(day.acwr.formatted(.number.precision(.fractionLength(2))))\(fit)")
        }
        return parts.joined(separator: ". ")
    }
}

/// VoiceOver descriptor for the projection chart: the whole curve as elements,
/// the phase band, and the crossing day — so a VoiceOver user gets the same
/// per-day breakdown the headline gives a sighted user.
private struct ProjectionAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let projection: AcwrProjection.Result

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
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Day",
            categoryOrder: projection.days.map { "Day \($0.dayOffset)" }
        )
        var gridlines: [Double] = []
        if let band = projection.band {
            gridlines = [band.low, band.high]
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "ACWR",
            range: 0...2,
            gridlinePositions: gridlines
        ) { value in
            String(format: "%.2f", value)
        }
        let points = projection.days.map { day -> AXDataPoint in
            let fit = day.fit.map { " \($0.rawValue)" } ?? ""
            return AXDataPoint(
                x: "Day \(day.dayOffset)",
                y: day.acwr,
                label: "\(String(format: "%.2f", day.acwr))\(fit)"
            )
        }
        let series = AXDataSeriesDescriptor(
            name: "Projected ACWR",
            isContinuous: true,
            dataPoints: points
        )
        let crossingSummary = projection.fallsBelow.map {
            " The curve drops below the band on day \($0.dayOffset)."
        } ?? ""
        return AXChartDescriptor(
            title: "Projected ACWR over the next seven days",
            summary: "Assumes no training. Today's ratio then the zero-load decay over the next seven days, against the current phase band.\(crossingSummary)",
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

private extension View {
    func accessibilityProjectionChartDescriptor(_ projection: AcwrProjection.Result) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(ProjectionAccessibilityDescriptor(projection: projection))
    }
}

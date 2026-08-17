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

    /// The projection, recomputed on each model change. Cheap (8 forward
    /// steps), so no snapshot machinery is needed like the readiness trend.
    private var projection: AcwrProjection.Result? {
        let phase = model.currentPhase
        let band = AcwrProjection.Band(low: phase.acwrLow, high: phase.acwrHigh)
        return AcwrProjection.project(
            state: TrainingMetrics.ewmaLoadState(sessions: model.sessions),
            band: band
        )
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
                        .frame(height: 150)
                    Text(headline(projection))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let keepInBand = projection.keepInBand {
                        Text(keepInBandText(keepInBand, todayFit: projection.days[0].fit, bandLow: projection.band!.low))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Log a few sessions and this card will show where your ACWR drifts over the coming week if you don't train.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Chart

    private func chart(_ projection: AcwrProjection.Result) -> some View {
        let today = projection.days[0]
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

            // Dashed on purpose: none of this is measured data.
            ForEach(projection.days, id: \.dayOffset) { day in
                LineMark(
                    x: .value("Day", day.dayOffset),
                    y: .value("ACWR", day.acwr)
                )
            }
            .foregroundStyle(ChartToken.reference.color(scheme))
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 4]))

            // The first day the curve drops under the floor.
            if let crossing = projection.fallsBelow {
                RuleMark(x: .value("Crossing", crossing.dayOffset))
                    .foregroundStyle(ChartToken.axis.color(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Today is the only real number on the chart — a solid point
            // colored by its risk status, with a radial halo behind it.
            PointMark(
                x: .value("Day", today.dayOffset),
                y: .value("ACWR", today.acwr)
            )
            .foregroundStyle(ChartToken.selectedHalo(scheme, endRadius: 14))
            .symbolSize(28)
            PointMark(
                x: .value("Day", today.dayOffset),
                y: .value("ACWR", today.acwr)
            )
            .foregroundStyle(statusColor(scheme))
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
        .accessibilityLabel("Projected ACWR over the next seven days")
        .accessibilityValue(accessibilitySummary(projection))
        .accessibilityProjectionChartDescriptor(projection)
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

    private func axisLabel(_ value: Double?, projection: AcwrProjection.Result) -> Text {
        guard let value else { return Text("") }
        if value == 0 {
            return Text("Now \(projection.days[0].acwr.formatted(.number.precision(.fractionLength(2))))")
        }
        if value == Double(AcwrProjection.projectionDays) {
            return Text("+\(AcwrProjection.projectionDays)d")
        }
        if let crossing = projection.fallsBelow, value == Double(crossing.dayOffset) {
            return Text(weekdayLabel(for: crossing.date))
        }
        return Text("")
    }

    private func bandAxisValues(_ projection: AcwrProjection.Result) -> [Double] {
        guard let band = projection.band else { return [] }
        return [band.low, band.high]
    }

    private func weekdayLabel(for date: String) -> String {
        guard let day = LocalDateSupport.date(from: date) else { return "" }
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.calendar = Calendar(identifier: .gregorian)
        style.locale = Locale(identifier: "en_US_POSIX")
        return day.formatted(style)
    }

    /// The universal ACWR status color — same mapping the Load card uses.
    private func statusColor(_ scheme: ColorScheme) -> Color {
        switch TrainingMetrics.acwrStatus(projection?.days[0].acwr) {
        case .optimal: return ChartToken.optimal.color(scheme)
        case .low, .underTraining: return ChartToken.focus.color(scheme)
        case .caution: return ChartToken.caution.color(scheme)
        case .danger: return ChartToken.alert.color(scheme)
        case .noData: return .secondary
        }
    }

    // MARK: - Copy

    /// The plain-language version of the projection: what leaves the band,
    /// when. Mirrors the web's `headline()`.
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

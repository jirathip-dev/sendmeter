import Charts
import SendmeterCore
import SwiftUI

/// 14-day readiness trend chart (#664) — port of the web's `ReadinessCard.tsx`
/// trend section to the native Dashboard. Same series the web derives (the
/// per-day `health_metrics` readiness over the last 14 calendar days), same
/// zone-threshold gridlines at 40/70, and ChartTheme health tokens
/// (`#2E96F0`/`#4FB0FF`) with the health vertical area gradient.
///
/// Missing days plot honest gaps, never a zero line: the Core series groups
/// contiguous scored days into runs, and the marks pass `series:` through so
/// Swift Charts never interpolates across a run break (review F1).
///
/// Scrub: on iOS 17+ dragging selects the nearest day (`chartXSelection`) with
/// a tooltip showing that day's score, zone and HRV/resting-HR/sleep context;
/// the same per-day data is exposed to VoiceOver via an `AXChartDescriptor` on
/// both branches (iOS 16 has no scrub gesture, so the descriptor is the whole
/// accessible surface there). The scrub currently emits no haptic tick — that
/// belongs to #656 (haptics parity), which is still open; a `sensoryFeedback`
/// may be added there, not here.
///
/// Refresh: the chart reads `model.healthMetrics` directly, so a health sync
/// landing re-renders it. The 14-day window is recomputed on a day-change
/// notification so an app left open across midnight doesn't keep plotting
/// yesterday's window.
struct ReadinessTrendCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDate: Date?

    /// The 14-day series, computed once per data change (or day rollover),
    /// not per body pass. `chartXSelection` fires on every touch-move sample
    /// and each one invalidates the body; rebuilding the series (which used to
    /// allocate a `DateFormatter` per day) per pass made the scrub run at
    /// ~5 fps (review F2).
    @State private var snapshot = ReadinessSnapshot.empty

    private var hasAnyScore: Bool {
        snapshot.days.contains { $0.readiness != nil }
    }

    /// Nearest scored/observed day to the scrubbed position, or nil.
    private var selected: ReadinessDay? {
        guard let selectedDate else { return nil }
        return snapshot.days.min { lhs, rhs in
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

                // Empty state (review F6): "nothing synced" (no health rows at
                // all) is different from "syncing but no baseline yet" (rows
                // present, every readiness nil until ~7 days of HRV / resting-HR
                // history) — giving baseline-less users the web's explanation
                // instead of telling them to sync something already syncing.
                if model.healthMetrics.isEmpty {
                    Text("Sync Apple Health to see a 14-day readiness trend.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !hasAnyScore {
                    Text("Your metrics are syncing, but the score needs about a week of overnight HRV / resting-heart-rate history in Apple Health before the trend appears.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    chart
                }
            }
        }
        .onChange(of: model.healthMetrics) { _ in rebuildSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            rebuildSnapshot()
        }
        .onAppear { rebuildSnapshot() }
    }

    private func rebuildSnapshot() {
        let days = TrainingMetrics.readinessSeries(metrics: model.healthMetrics)
        snapshot = ReadinessSnapshot(
            days: days,
            yAxisGregorian: ReadinessSnapshot.gregorianAxisStyle
        )
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
                            let plotFrame = geo[proxy.plotAreaFrame]
                            // proxy.position is relative to the plot area;
                            // add the plot frame's origin to place the
                            // tooltip in the chart's (overlay) coordinates
                            // (review F3).
                            let x = (proxy.position(forX: selected.dateValue) ?? 0) + plotFrame.origin.x
                            tooltip(for: selected, x: x, plotFrame: plotFrame)
                        }
                    }
                }
                .accessibilityLabel("Fourteen-day readiness trend")
                .accessibilityValue(selected.map(accessibilityText) ?? "")
                .accessibilityReadinessChartDescriptor(snapshot.days)
        } else {
            baseChart
                .frame(height: 170)
                .accessibilityLabel("Fourteen-day readiness trend")
                .accessibilityValue(selected.map(accessibilityText) ?? "")
                .accessibilityReadinessChartDescriptor(snapshot.days)
        }
    }

    private var baseChart: some View {
        Chart {
            // Zone-threshold gridlines at 40 / 70 — the push/maintain/recover
            // boundaries the web draws as dashed lines. Emitted once, outside
            // the per-day element builder (review F5).
            RuleMark(y: .value("Recover threshold", 40))
                .foregroundStyle(ChartToken.grid.color(scheme))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("Push threshold", 70))
                .foregroundStyle(ChartToken.grid.color(scheme))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(snapshot.days) { day in
                if let readiness = day.readiness {
                    let seriesValue: Int = day.runIndex ?? 0
                    AreaMark(
                        x: .value("Day", day.dateValue),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Readiness", readiness),
                        series: .value("Run", seriesValue)
                    )
                    .foregroundStyle(ChartToken.health.areaGradient(scheme))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Day", day.dateValue),
                        y: .value("Readiness", readiness),
                        series: .value("Run", seriesValue)
                    )
                    .foregroundStyle(ChartToken.health.color(scheme))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Day", day.dateValue),
                        y: .value("Readiness", readiness)
                    )
                    .foregroundStyle(zoneColor(day.zone).color(scheme))
                    .symbolSize(selected?.date == day.date ? 16 : 8)
                }
            }
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
                AxisValueLabel(format: snapshot.yAxisGregorian)
                    .foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
    }

    /// The scrub tooltip. Positioned in the chart's coordinate space and
    /// clamped so it never overflows the plot frame: it anchors at the
    /// scrubbed day's x but pins itself inside the frame's bounds, so a
    /// populated "82 / Push / HRV 62ms RHR 48 Sleep 7.5h" tooltip (~220 pt)
    /// stays on card at every scrub position and Dynamic Type size, and a
    /// right-edge day (the common "today" case) clamps to just inside the
    /// trailing edge instead of half-dropping off-card (review F3).
    private func tooltip(for day: ReadinessDay, x: CGFloat, plotFrame: CGRect) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            if let readiness = day.readiness {
                Text("\(readiness)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                if let zone = day.zone {
                    Text(zone.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(zoneColor(zone).color(scheme))
                }
            } else {
                Text("No data")
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 8) {
                if let hrv = day.hrvSDNNMilliseconds {
                    Text("HRV \(Int(hrv.rounded()))ms")
                }
                if let rhr = day.restingHeartRate {
                    Text("RHR \(Int(rhr.rounded()))")
                }
                if let sleep = day.sleepHours {
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
        .fixedSize()

        return content
            .position(x: clampedTooltipX(x: x, plotFrame: plotFrame), y: 20)
    }

    /// Clamp the tooltip's center inside the plot frame. `plotFrame.origin.x`
    /// is the y-axis label strip; the tooltip is anchored at the scrubbed
    /// day's x but the center is clamped so the whole fixed-size tooltip stays
    /// within the plot's bounds with ~8 pt margins. `.position` centers the
    /// view at the returned x, so a right-edge day (the common "today" case)
    /// must land at `rightBound - halfWidth - 8`, not `rightBound - 8`, or
    /// half the tooltip renders off-card (review F3).
    private func clampedTooltipX(x: CGFloat, plotFrame: CGRect) -> CGFloat {
        let leftBound = plotFrame.origin.x
        let rightBound = plotFrame.maxX
        // The tooltip is ~180-220 pt at default sizes; a 110 pt half-width
        // guard keeps it on card even when the label row is present.
        let halfWidth: CGFloat = 110
        let minCenter = leftBound + halfWidth + 8
        let maxCenter = rightBound - halfWidth - 8
        return min(max(x, minCenter), maxCenter)
    }
}

/// Immutable snapshot of the trend chart's inputs, computed once per data
/// change so a body pass (and every scrub-frame body invalidation) is O(1)
/// lookups instead of ~34 series rebuilds (review F2).
struct ReadinessSnapshot {
    let days: [ReadinessDay]
    let yAxisGregorian: Date.FormatStyle

    static let empty = ReadinessSnapshot(days: [], yAxisGregorian: Self.gregorianAxisStyle)

    /// Gregorian-pinned `M/d` axis labels — everything else in this diff
    /// routes through `LocalDateSupport`, and a Thai-region device defaults
    /// `Date.FormatStyle` to the Buddhist calendar (review F10). Month/day are
    /// identical between the calendars today; pinning now keeps a future
    /// `.year()` from silently regressing.
    static var gregorianAxisStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        style.calendar = Calendar(identifier: .gregorian)
        style.locale = Locale(identifier: "en_US_POSIX")
        style.timeZone = .current
        return style
    }
}

/// VoiceOver descriptor for the trend chart: the whole series as elements plus
/// the zone-threshold boundaries, so a VoiceOver user gets the same per-day
/// breakdown the scrub tooltip shows a sighted user. Implements both
/// `make`/`update` so a health sync that lands after the descriptor was first
/// built (e.g. an all-nil series at open) rewrites the audio graph in place
/// (review F4).
struct ReadinessSeriesAccessibilityDescriptor: AXChartDescriptorRepresentable {
    var days: [ReadinessDay]

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
    /// Named distinctly from SwiftUI's generic
    /// `accessibilityChartDescriptor(_ representable:)` so the two overloads
    /// can't shadow each other in a surprise way (review F9).
    func accessibilityReadinessChartDescriptor(_ days: [ReadinessDay]) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(ReadinessSeriesAccessibilityDescriptor(days: days))
    }
}

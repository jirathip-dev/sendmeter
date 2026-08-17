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
    /// Measured tooltip size, updated as the tooltip renders, so the clamp
    /// pins the tooltip using its actual width/height rather than a guess
    /// (review L1).
    @State private var tooltipSize: CGSize = .zero

    /// The 14-day series, computed once per data change (or day rollover),
    /// not per body pass. `chartXSelection` fires on every touch-move sample
    /// and each one invalidates the body; rebuilding the series (which used to
    /// allocate a `DateFormatter` per day) per pass made the scrub run at
    /// ~5 fps (review F2).
    @State private var snapshot = ReadinessSnapshot.empty

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

    /// Whether ANY stored health row carries a readiness score — the whole
    /// `model.healthMetrics` array (up to 60 rows), not just the 14-day
    /// window. A user with months of history but a recent wear gap has plenty
    /// of scored rows, so they get the chart (honestly empty in the window)
    /// instead of a "no baseline yet" sentence (review N1). Also reads the
    /// model live rather than the not-yet-rebuilt `snapshot`, so the first
    /// body pass can't flash the wrong copy before `.onAppear` rebuilds
    /// (review L3).
    private var hasAnyScoredRowEver: Bool {
        model.healthMetrics.contains { $0.readiness != nil }
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

                // Empty state (review N1): gate on "no scored row at all in
                // the model" — NOT on whether any score falls in the 14-day
                // window. Nothing synced gets the sync prompt; rows present but
                // every readiness nil gets the web's baseline explanation; and
                // a user with scored history but a fully-gapped window still
                // gets the chart, which renders its honest all-gap window.
                // (The web always draws the 14 bars once `metrics.length > 0`.)
                if model.healthMetrics.isEmpty {
                    Text("Sync Apple Health to see a 14-day readiness trend.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !hasAnyScoredRowEver {
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
            xAxisGregorian: ReadinessSnapshot.gregorianDateAxisStyle
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
                        if selectedDate != nil, let selected {
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
                // `groupedIntoRuns` guarantees a non-nil runIndex for a
                // scored day; binding it here instead of falling back to
                // series 0, so a directly-constructed `ReadinessDay` (init
                // defaults runIndex to nil) can never silently bridge every
                // day into one series (review I3).
                if let readiness = day.readiness, let runIndex = day.runIndex {
                    AreaMark(
                        x: .value("Day", day.dateValue),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Readiness", readiness),
                        series: .value("Run", runIndex)
                    )
                    .foregroundStyle(ChartToken.health.areaGradient(scheme))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Day", day.dateValue),
                        y: .value("Readiness", readiness),
                        series: .value("Run", runIndex)
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
        // Pin the x-domain to the full 14-day window so a scored-subrange
        // collapse (trailing/leading wear gap) or a fully-gapped window still
        // renders 14 dated slots — the web's fixed-flex-slot layout equivalent
        // (review N2). Only the marks carry x values, so without this the
        // automatic domain shrinks to the scored days and the gap becomes
        // invisible instead of honest.
        .chartXScale(domain: snapshot.dateDomain ?? Date()...Date())
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(ChartToken.grid.color(scheme))
                AxisValueLabel().foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisValueLabel(format: snapshot.xAxisGregorian)
                    .foregroundStyle(ChartToken.axis.color(scheme))
            }
        }
    }

    /// The scrub tooltip. Positioned in the chart's coordinate space and
    /// clamped so it never overflows the plot frame: it anchors at the
    /// scrubbed day's x but is pinned inside the frame's bounds, so a
    /// populated "82 / Push / HRV 62ms RHR 48 Sleep 7.5h" tooltip stays on
    /// card at every scrub position and Dynamic Type size, and a right-edge
    /// day (the common "today" case) clamps to just inside the trailing edge
    /// instead of half-dropping off-card (review F3). The clamp uses the
    /// tooltip's MEASURED size — a guessed half-width over-clamps at default
    /// sizes and still overhangs at accessibility sizes (review L1).
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

    /// Clamp the tooltip's center inside the plot frame. `plotFrame.origin.x`
    /// is the y-axis label strip; the tooltip is anchored at the scrubbed
    /// day's x but the center is clamped so the whole measured tooltip stays
    /// within the plot's bounds with ~8 pt margins. `.position` centers the
    /// view at the returned x, so a right-edge day (the common "today" case)
    /// must land at `rightBound - width/2 - 8`, not `rightBound - 8`, or half
    /// the tooltip renders off-card (review F3/L1). Degenerate narrow plots
    /// (minCenter > maxCenter) fall back to the plot's horizontal center.
    private func clampedTooltipX(x: CGFloat, plotFrame: CGRect, tooltipWidth: CGFloat) -> CGFloat {
        let width = tooltipWidth > 0 ? tooltipWidth : 90
        let minCenter = plotFrame.minX + width / 2 + 8
        let maxCenter = plotFrame.maxX - width / 2 - 8
        if minCenter > maxCenter { return plotFrame.midX }
        return min(max(x, minCenter), maxCenter)
    }

    /// Clamp the tooltip's vertical center so a tall tooltip doesn't clip past
    /// the plot's top/bottom edge. Top-anchored (`minCenter`) rather than
    /// `plotFrame.midY` so the tooltip floats above the data it annotates
    /// instead of covering the readiness line in the 30-70 band (review N3);
    /// `minCenter` is only relaxed when the tooltip is too tall for the plot.
    private func clampedTooltipY(plotFrame: CGRect, tooltipHeight: CGFloat) -> CGFloat {
        let height = tooltipHeight > 0 ? tooltipHeight : 60
        let minCenter = plotFrame.minY + height / 2 + 4
        let maxCenter = plotFrame.maxY - height / 2 - 4
        if minCenter > maxCenter { return plotFrame.midY }
        return minCenter
    }
}

/// Immutable snapshot of the trend chart's inputs, computed once per data
/// change so a body pass (and every scrub-frame body invalidation) is O(1)
/// lookups instead of ~34 series rebuilds (review F2).
struct ReadinessSnapshot {
    let days: [ReadinessDay]
    let xAxisGregorian: Date.FormatStyle

    static let empty = ReadinessSnapshot(days: [], xAxisGregorian: Self.gregorianDateAxisStyle)

    /// The chart's full 14-day x-domain, oldest → newest. `days` always has
    /// exactly 14 entries whenever metrics exist, so this is the true window —
    /// pinning it keeps Swift Charts from collapsing the domain to the scored
    /// subrange (N2): with a trailing wear gap the plot would otherwise fill
    /// the full card width ending days ago with no visual cue, and a fully
    /// gapped window would draw nothing at all. Nil only when the window is
    /// empty (no metrics), which the view gates before rendering the chart.
    var dateDomain: ClosedRange<Date>? {
        guard let first = days.first?.dateValue, let last = days.last?.dateValue else { return nil }
        return first...last
    }

    /// Gregorian-pinned `M/d` x-axis labels (review F10/I4: the style is used
    /// on the chart's *x* axis; the `xAxisGregorian` name says so). Everything
    /// else in this diff routes through `LocalDateSupport`, and a Thai-region
    /// device defaults `Date.FormatStyle` to the Buddhist calendar. Month/day
    /// are identical between the calendars today; pinning now keeps a future
    /// `.year()` from silently regressing.
    static var gregorianDateAxisStyle: Date.FormatStyle {
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
        // Gap days are OMITTED from the data points (the categorical x-axis
        // keeps the remaining days in their positions). The label was already
        // honest ("no data"), but the audio-graph pitch is derived from `y`,
        // so a missing week used to play as a dive to the bottom of the range
        // — F1's visual defect, delivered to VoiceOver users (review L4).
        let points = days.compactMap { day -> AXDataPoint? in
            guard let readiness = day.readiness else { return nil }
            return AXDataPoint(
                x: day.date,
                y: Double(readiness),
                label: "\(readiness)\(day.zone.map { " \($0)" } ?? "")"
            )
        }
        let series = AXDataSeriesDescriptor(
            name: "Readiness",
            isContinuous: true,
            dataPoints: points
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

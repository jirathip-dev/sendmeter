import SendmeterCore
import SwiftUI

/// The training-load sheet: weekly bars (same `WeeklyLoad` array the card
/// behind it shows), the 53×7 daily heatmap, and the 28-day activity mix.
/// Port of the web `TrainingLoadSheet.tsx` (#650). Pure math lives in
/// `Sources/Core/TrainingLoad.swift`; this file is thin layout only.
///
/// Snapshotting (F2/F10): `mix`, `daily` and the week-delta are computed once
/// per data/date change into `@State`, never per body pass — the original
/// recomputed `activityMix` up to 4× per pass. One `referenceDate` drives both
/// the 28-day mix and the heatmap so the two windows advance together across
/// midnight (`.NSCalendarDayChanged`).
struct TrainingLoadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var mix: ActivityMix = ActivityMix(total: 0, activities: [])
    @State private var daily: [String: DailyLoad] = [:]
    @State private var currentDelta: WeekDelta?
    @State private var referenceDate = Date()
    /// #895 evidence harness: when non-nil, the sheet renders from these
    /// deterministic sessions instead of `model.sessions` so simulator
    /// captures can exercise the Daily Load heatmap without a signed-in
    /// Supabase session (same pattern as RecoveryInputsSheet.fixtureMetrics).
    private let fixtureSessions: [Session]?

    init(fixtureSessions: [Session]? = nil) {
        self.fixtureSessions = fixtureSessions
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    weeklyLoadSection
                    dailyLoadSection
                    activityMixSection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Training Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { rebuild() }
        .onChange(of: model.sessions) { _ in rebuild() }
        #if DEBUG
        // #895 evidence harness: the launch-argument fixture can swap its
        // session set (empty -> populated) the way a real sync populates
        // `model.sessions` after the sheet is already on screen. Two-parameter
        // form: the action must run against the post-update view value.
        .onChange(of: fixtureSessions) { _, _ in rebuild() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            referenceDate = Date()
            rebuild()
        }
    }

    private func rebuild() {
        let sessions = fixtureSessions ?? model.sessions
        mix = TrainingLoad.activityMix(
            sessions: sessions,
            endDate: LocalDateSupport.string(from: referenceDate)
        )
        daily = TrainingLoad.dailyLoads(sessions: sessions)
        let weeks = weeklyLoadsForDisplay
        guard weeks.count >= 2 else { currentDelta = nil; return }
        currentDelta = TrainingLoad.weekDelta(
            current: weeks[weeks.count - 1].total,
            previous: weeks[weeks.count - 2].total
        )
    }

    /// Weekly totals for the card: `model.weeklyLoads` in production, the
    /// fixture sessions' own totals when the #895 evidence harness is active.
    private var weeklyLoadsForDisplay: [WeeklyLoad] {
        if let fixtureSessions {
            return TrainingMetrics.weeklyLoads(sessions: fixtureSessions)
        }
        return model.weeklyLoads
    }

    // MARK: - Weekly load

    private var weeklyLoadSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                // #929: at accessibility text sizes the title and the delta
                // chip no longer share a row — the chip squeezed the title into
                // a hard-wrapped "WEE / KLY / LOA / D" column on the smallest
                // phone. The chip moves to its own line instead (the same
                // one-column adaptation the Force tiles use, #928).
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        weeklyLoadTitle
                        deltaChip
                    }
                } else {
                    HStack {
                        weeklyLoadTitle
                        Spacer()
                        deltaChip
                    }
                }
                WeeklyBarsView(weeks: weeklyLoadsForDisplay)
            }
        }
    }

    private var weeklyLoadTitle: some View {
        SectionLabel("Weekly load", systemImage: "chart.bar.fill")
    }

    @ViewBuilder
    private var deltaChip: some View {
        if let delta = currentDelta {
            Text(deltaLabel(delta))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(deltaColor(delta))
        }
    }

    private func deltaLabel(_ delta: WeekDelta) -> String {
        let pct = Int(abs(delta.pct).rounded())
        return "\(delta.arrow) \(pct)% vs prior wk"
    }

    /// #649 rule: chart views never read `SendmeterStyle.*` (static, no
    /// appearance switch). The up/down stops are ChartToken semantics; they
    /// are NOT a hex-for-hex match of the web's `--success`/`--danger`
    /// (those are `#1674BE`/`#B95122`) — the chart palette is the right call
    /// under #649 even though the exact hues differ (N5).
    private func deltaColor(_ delta: WeekDelta) -> Color {
        if delta.isFlat { return .secondary }
        return delta.isUp
            ? ChartToken.optimal.color(scheme)
            : ChartToken.alert.color(scheme)
    }

    // MARK: - Daily load

    private var dailyLoadSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Daily load", systemImage: "square.grid.3x3.fill")
                ContributionHeatmapView(daily: daily, today: referenceDate)
            }
        }
    }

    // MARK: - Activity mix

    private var activityMixSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Activity mix", systemImage: "chart.pie.fill")
                Text("Last 28 days · \(TrainingLoad.formatAU(mix.total)) AU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if mix.activities.isEmpty {
                    Text("No training load in the last 28 days. Log a session to see how your activities contribute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    ActivityMixBar(activities: mix.activities)
                    ForEach(mix.activities, id: \.type) { activity in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(ChartActivityHue.color(forActivityID: activity.type, scheme: scheme))
                                .frame(width: 9, height: 9)
                            Text(activity.label)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(TrainingLoad.formatAU(activity.load)) AU · \(TrainingLoad.formatSharePercent(activity.percentage))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

/// Weekly bars with per-week totals + labels — the same `WeeklyLoad` array the
/// LoadCard uses, not a recomputed one (#650 acceptance 1).
///
/// #929: the two label rows (the AU total above each bar, the week caption
/// below it) were pinned at 9 pt and shrank with `minimumScaleFactor` when the
/// smallest phone could not fit them. Both now go through the shared Dynamic
/// Type-aware axis rule from #928:
///
/// 1. Both rows draw with `ChartAxisLabelRule.font` (`caption2`), and the
///    resolved size (`@ScaledMetric(relativeTo: .caption2)` seeded with
///    `ChartAxisLabelRule.basePointSize`, exactly like `NativeForceCurvePlot`)
///    feeds the layout arithmetic.
/// 2. `ChartAxisLabelRule.columnLabelPlan` decides which bars carry a label:
///    a label that cannot fit inside its own column is omitted (the columns
///    span the card, so it would overhang the neighbouring bar or leave the
///    card) and the survivors go through the shared tick-density rule, so a
///    grown label thins the row instead of colliding with its neighbour.
/// 3. When the value row is incomplete the exact per-week values stay readable
///    in `valuesReadout` under the chart. Tap/scrub selection, haptics, the
///    selected-value tooltip and the per-bar VoiceOver labels (which carry
///    "… AU" and the week-over-week delta) are unchanged.
///
/// Internal (not `private`) so the app-target legibility lane can render this
/// view directly: `TrainingLoadSheet` itself needs an `AppModel`.
struct WeeklyBarsView: View {
    let weeks: [WeeklyLoad]
    /// #929 evidence seam: a non-nil index opens the chart with that bar
    /// selected, so the app-target legibility lane can render the
    /// selected-value tooltip without touch injection (`Tests/SendmeterNativeUITests`
    /// is outside this slice's fence). The sheet always passes nil.
    let initialSelection: Int?

    @State private var selectedIndex: Int?
    /// Haptic dedupe guard: a drag can deliver many frames for the same bar,
    /// so this must track the last tick independently of the rendered state.
    @State private var tickedIndex: Int?
    /// The chart's own width, published by a background `GeometryReader` (the
    /// same pattern `ContributionHeatmapView` uses) so the label plan and the
    /// values readout resolve outside the chart's fixed-height frame.
    @State private var containerWidth: CGFloat = 0

    /// The one resolved label size (#929): `caption2` at the default text
    /// size, scaling through every Dynamic Type size.
    @ScaledMetric(relativeTo: .caption2)
    private var axisLabelPointSize: CGFloat = ChartAxisLabelRule.basePointSize

    /// The reserve for the selected-value tooltip slot at the default text
    /// size. Follows the resolved text size (#929): the pre-#929 slot was a
    /// fixed 60 pt and the three-line tooltip covered the chart below it at
    /// accessibility sizes.
    @ScaledMetric(relativeTo: .caption2)
    private var tooltipReserveHeight: CGFloat = WeeklyBarsView.tooltipReserveBaseHeight

    /// The tooltip slot's reserve at the default text size (the shipped 60 pt).
    static let tooltipReserveBaseHeight: CGFloat = 60

    private let barSpacing = CGFloat(TrainingLoadInteraction.weeklyBarSpacing)

    /// The tallest bar the plot draws, the gap between a bar and its labels,
    /// and the height the chart held before #929 — the chart's height contract
    /// (#929). The app-target legibility lane rebuilds a column from these and
    /// checks that `chartHeight(bandHeight:)` makes room for it.
    static let maximumBarHeight: CGFloat = 64
    static let columnSpacing: CGFloat = 4
    static let minimumChartHeight: CGFloat = 108

    /// The resolved height of one label band. Seeded with the `caption2` Text
    /// box at the default text size — measured, because `Text`'s box is taller
    /// than the font's line height and the chart's frame must hold two of them
    /// at every Dynamic Type size (the shared rule's `estimatedLabelHeight` is
    /// a collision estimate, not a rendered box).
    @ScaledMetric(relativeTo: .caption2)
    private var axisLabelBandHeight: CGFloat = WeeklyBarsView.labelBandBaseHeight

    /// The default-size `caption2` Text box, measured on the smallest phone by
    /// the app-target legibility lane (two of these plus the bar and its gaps
    /// are exactly the chart's shipped 108 pt).
    static let labelBandBaseHeight: CGFloat = 16

    private var maxW: Double { max(weeks.map(\.total).max() ?? 0, 1) }

    init(weeks: [WeeklyLoad], initialSelection: Int? = nil) {
        self.weeks = weeks
        self.initialSelection = initialSelection
        _selectedIndex = State(initialValue: initialSelection)
        _tickedIndex = State(initialValue: initialSelection)
    }

    /// The per-bar AU totals and week captions, in bar order — the candidate
    /// labels the shared rule plans for.
    private var valueLabels: [String] { weeks.map { TrainingLoad.formatAU($0.total) } }
    private var weekLabels: [String] { weeks.map(\.label) }

    /// #929: the chart's own height follows the resolved label size. The two
    /// label bands used to be pinned inside 108 pt, so a grown band spilled
    /// out of the frame instead of the chart making room for it.
    static func chartHeight(bandHeight: CGFloat) -> CGFloat {
        max(
            minimumChartHeight,
            maximumBarHeight + 2 * columnSpacing + 2 * bandHeight + labelBandSlack
        )
    }

    private var chartHeight: CGFloat { Self.chartHeight(bandHeight: axisLabelBandHeight) }

    /// Half a point of slack per band: the scaled metric and the rendered Text
    /// box can disagree by a fraction of a point, and the frame must never be
    /// the smaller of the two.
    private static let labelBandSlack: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tooltipSlot

            GeometryReader { proxy in
                // The shared rule's decisions resolve from the REAL laid-out
                // width inside the reader, so the labels are correct on the
                // first pass and in offscreen renders alike, and the readout
                // below reads the same width through `ChartWidthKey`.
                let valuePlan = ChartAxisLabelRule.columnLabelPlan(
                    labels: valueLabels,
                    width: proxy.size.width,
                    spacing: barSpacing,
                    pointSize: axisLabelPointSize
                )
                let weekPlan = ChartAxisLabelRule.columnLabelPlan(
                    labels: weekLabels,
                    width: proxy.size.width,
                    spacing: barSpacing,
                    pointSize: axisLabelPointSize
                )

                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                            column(
                                week: week,
                                index: index,
                                showsValueLabel: valuePlan.labelledIndices.contains(index),
                                showsWeekLabel: weekPlan.labelledIndices.contains(index),
                                // A row that drew any label keeps its band in
                                // every column, so all bars sit on one baseline
                                // (#929).
                                reservesValueBand: !valuePlan.labelledIndices.isEmpty,
                                reservesWeekBand: !weekPlan.labelledIndices.isEmpty
                            )
                        }
                    }

                    // One chart-level hit surface keeps the bars usable on a
                    // phone even when the bar itself is only a few points
                    // wide. The surface is hidden from VoiceOver; each bar
                    // above remains the accessible element.
                    Color.clear
                        .contentShape(Rectangle())
                        .hapticTapMuted()
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    guard let index = index(at: value.location.x, width: proxy.size.width) else { return }
                                    toggleSelection(index)
                                }
                        )
                        .simultaneousGesture(
                            // A deliberate drag scrubs between bars without
                            // hijacking a vertical ScrollView gesture.
                            DragGesture(minimumDistance: 12)
                                .onChanged { value in
                                    if let index = index(at: value.location.x, width: proxy.size.width) {
                                        select(index)
                                    }
                                }
                        )
                        .accessibilityHidden(true)
                }
                .preference(key: ChartWidthKey.self, value: proxy.size.width)
            }
            .frame(height: chartHeight)

            if showsValuesReadout {
                valuesReadout
            }
        }
        .onPreferenceChange(ChartWidthKey.self) { width in
            // The chart's own laid-out width, published during layout rather
            // than on appearance so offscreen renders agree with the app.
            containerWidth = width
        }
        .onChange(of: weeks) { _ in
            // Data replacement is passive; never buzz merely because the
            // sheet rebuilt while a sync was in flight.
            selectedIndex = nil
            tickedIndex = nil
        }
        .onDisappear {
            selectedIndex = nil
            tickedIndex = nil
        }
    }

    /// The reserved selected-value tooltip slot.
    ///
    /// The reserve follows the resolved text size (the pre-#929 slot was a
    /// fixed 60 pt, which the three-line tooltip outgrew at accessibility
    /// sizes and covered the chart below the slot). The slot measures its own
    /// width so the tooltip's text wraps inside the card — the same
    /// `GeometryReader` width the chart is laid out in, resolved during layout
    /// rather than on appearance.
    private var tooltipSlot: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let selectedIndex, let week = week(at: selectedIndex) {
                    tooltipCard(week: week, index: selectedIndex, maxWidth: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, alignment: .topLeading)
        }
        // A definite height: the slot is the reserved band, and a greedy
        // geometry reader must not absorb the surrounding proposal.
        .frame(height: tooltipReserveHeight, alignment: .topLeading)
    }

    private func tooltipCard(week: WeeklyLoad, index: Int, maxWidth: CGFloat) -> some View {
        TrainingLoadTooltip {
            VStack(alignment: .leading, spacing: 2) {
                Text(week.label)
                    .font(.subheadline.weight(.semibold))
                Text("\(TrainingLoad.formatAU(week.total)) AU")
                    .font(.caption2.monospacedDigit())
                if let delta = delta(for: index) {
                    Text(deltaLabel(delta))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(deltaColor(delta))
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// #929 AC4: when the shared rule omits a per-bar value (the columns are
    /// too narrow for the resolved label size), the exact values stay readable
    /// here — on one line per week, units explicit — instead of being shrunk
    /// into the bars or clipped. Each bar still carries its own VoiceOver
    /// value, so this copy is hidden from VoiceOver.
    ///
    /// Whether a value label was omitted needs the width the chart is laid out
    /// in; that comes from the background reader's published `containerWidth`,
    /// which only exists once the view is on screen — until then the readout
    /// stays hidden rather than flickering in and out.
    private var showsValuesReadout: Bool {
        guard containerWidth > 0, !weeks.isEmpty else { return false }
        let plan = ChartAxisLabelRule.columnLabelPlan(
            labels: valueLabels,
            width: containerWidth,
            spacing: barSpacing,
            pointSize: axisLabelPointSize
        )
        return plan.labelledIndices.count < weeks.count
    }

    private var valuesReadout: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                Text("\(week.label) \(TrainingLoad.formatAU(week.total)) AU")
                    .font(ChartAxisLabelRule.font)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// One bar with its two label bands. A band is reserved in every column of
    /// a row that drew any label, so all bars share one baseline (#929); the
    /// labels themselves are drawn only where the shared rule planned them.
    /// The bar, its color and its accessibility contract are unchanged.
    @ViewBuilder
    private func column(
        week: WeeklyLoad,
        index: Int,
        showsValueLabel: Bool,
        showsWeekLabel: Bool,
        reservesValueBand: Bool,
        reservesWeekBand: Bool
    ) -> some View {
        VStack(spacing: Self.columnSpacing) {
            if reservesValueBand {
                Text(TrainingLoad.formatAU(week.total))
                    .font(ChartAxisLabelRule.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(showsValueLabel ? 1 : 0)
            }
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: index == weeks.count - 1
                            ? [ChartToken.optimal.color(scheme).opacity(0.58), ChartToken.optimal.color(scheme)]
                            : [ChartToken.load.color(scheme).opacity(0.58), ChartToken.load.color(scheme)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: max((week.total / maxW) * Self.maximumBarHeight, 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(selectedIndex == index ? Color.primary : .clear, lineWidth: 1.5)
                )
            if reservesWeekBand {
                Text(week.label)
                    .font(ChartAxisLabelRule.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(showsWeekLabel ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: week, index: index))
        .accessibilityValue(selectedIndex == index ? "Selected" : "")
        .accessibilityHint(selectedIndex == index ? "Double-tap to hide details." : "Double-tap to show details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
        .accessibilityAction {
            toggleSelection(index)
        }
    }

    @Environment(\.colorScheme) private var scheme

    private func week(at index: Int) -> WeeklyLoad? {
        guard weeks.indices.contains(index) else { return nil }
        return weeks[index]
    }

    private func delta(for index: Int) -> WeekDelta? {
        guard index > 0, index < weeks.count else { return nil }
        return TrainingLoad.weekDelta(
            current: weeks[index].total,
            previous: weeks[index - 1].total
        )
    }

    private func deltaLabel(_ delta: WeekDelta) -> String {
        "\(delta.arrow) \(Int(abs(delta.pct).rounded()))% vs prior wk"
    }

    private func deltaColor(_ delta: WeekDelta) -> Color {
        if delta.isFlat { return .secondary }
        return delta.isUp
            ? ChartToken.optimal.color(scheme)
            : ChartToken.alert.color(scheme)
    }

    private func accessibilityLabel(for week: WeeklyLoad, index: Int) -> String {
        var label = "\(week.label): \(TrainingLoad.formatAU(week.total)) AU"
        if let delta = delta(for: index) {
            label += ", \(deltaLabel(delta))"
        }
        return label
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        TrainingLoadInteraction.weeklyBarIndex(
            x: Double(x),
            width: Double(width),
            count: weeks.count,
            spacing: Double(barSpacing)
        )
    }

    private func select(_ index: Int) {
        guard weeks.indices.contains(index) else { return }
        setSelection(index)
    }

    private func toggleSelection(_ index: Int) {
        guard weeks.indices.contains(index) else { return }
        setSelection(
            TrainingLoadInteraction.toggledSelection(current: tickedIndex, candidate: index)
        )
    }

    private func setSelection(_ index: Int?) {
        if SelectionHaptics.valueChanged(tickedIndex, index) {
            tickedIndex = index
            Haptics.shared.playGesture(.selection)
        }
        selectedIndex = index
    }
}

/// The width the weekly chart is laid out in, published as a preference so the
/// exact-values readout can resolve during layout (#929) rather than on the
/// appearance lifecycle.
private struct ChartWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

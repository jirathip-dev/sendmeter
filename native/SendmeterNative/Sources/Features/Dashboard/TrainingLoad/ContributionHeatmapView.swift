import SendmeterCore
import SwiftUI

/// GitHub-contribution-style daily training-load heatmap (web
/// `ContributionHeatmap.tsx` port, #650). One square per day; columns are
/// Sun–Sat weeks oldest→newest ending on the current week's Saturday. Each
/// day is hued by its dominant activity type (SL-60) and shaded by total AU
/// across the 5 intensity levels; future days render greyed-out and are not
/// selectable. Cells are fixed-size squares derived from the measured card
/// width, so 53 columns always fit with no horizontal scrolling — even on an
/// SE.
///
/// Layout (F1): the grid must NOT be a self-sizing `GeometryReader` — a
/// ScrollView proposes nil height and `GeometryReader` answers with 10pt,
/// collapsing the heatmap and overdrawing whatever follows. Instead the width
/// is read once via a background `GeometryReader` into `containerWidth` and
/// every cell is an explicit `.frame(width:height:)` of `cellSize` derived
/// from it, so the natural VStack/HStack layout produces the real height.
///
/// Performance (F2): the 53×7 grid is a pure snapshot in `@State`, rebuilt
/// only when `daily` or `today` changes — never per cell and never per body
/// pass (the original rebuilt it ~374× per render because `fillColor` read
/// the computed `grid` property, ~172ms/pass on a Mac).
///
/// Interaction (F3/F7): one scrub surface over the whole grid resolves the
/// nearest cell from the finger position (a fingertip covers ~8 columns of
/// 3.4pt cells, so 371 discrete buttons would be untappable) — mirroring the
/// web's single `chart-scrub` surface. A stationary tap on the already
/// selected day dismisses the tooltip.
///
/// VoiceOver (F4): the grid is one `.contain` element with a group label;
/// each day carries its AU + activity + date label; future days are hidden
/// rather than announced as dimmed.
struct ContributionHeatmapView: View {
    let daily: [String: DailyLoad]
    var weeks: Int = 53
    var unit: String = "AU"
    var today: Date

    @Environment(\.colorScheme) private var scheme
    @State private var grid: HeatmapGrid?
    /// #895: the inputs the cached `grid` was built from. The grid is a pure
    /// snapshot of `daily` + `today` (F2), so the empty/heatmap/legend
    /// decision must never run against a build that predates the CURRENT
    /// `daily` — the reopened-symptom wedge where a session-filled window
    /// rendered the honest empty state because the snapshot was built while
    /// `daily` was still empty and never refreshed (the deprecated
    /// one-parameter `onChange(of:)` action can run against the pre-update
    /// view value, stranding the cache). `resolvedGrid` therefore rebuilds
    /// whenever the cached build's inputs differ from the current ones.
    @State private var gridBuiltFromDaily: [String: DailyLoad] = [:]
    @State private var gridBuiltFromTodayKey: String = ""
    @State private var containerWidth: CGFloat = 0
    @State private var selectedDate: String?
    /// Haptic dedupe guard: a scrub can deliver many frames for one cell, so
    /// it tracks the last tick independently of the rendered selection.
    @State private var tickedDate: String?

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdayRows = [1, 3, 5] // Mon / Wed / Fri (0-indexed)
    private static let weekdayNames = ["Mon", "Wed", "Fri"]

    private let gap: CGFloat = 2
    private let weekdayColumnWidth: CGFloat = 22
    private let hSpacing: CGFloat = 6
    private let monthLabelHeight: CGFloat = 14

    init(
        daily: [String: DailyLoad],
        weeks: Int = 53,
        unit: String = "AU",
        today: Date = Date()
    ) {
        self.daily = daily
        self.weeks = weeks
        self.unit = unit
        self.today = today
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if containerWidth > 0 {
                let grid = resolvedGrid
                if TrainingLoad.heatmapHasVisibleLoad(in: grid) {
                    heatmap(grid: grid)
                    legend(for: grid)
                } else {
                    emptyState
                }
            } else {
                // Placeholder for the one-frame window before the background
                // GeometryReader reports the real width — avoids a 1pt flash.
                Color.clear
                    .frame(height: 52)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { newValue in containerWidth = newValue }
            }
        )
        .onAppear { resetSelection() }
        .onChange(of: daily) { _, _ in resetSelection() }
        .onChange(of: today) { _, _ in resetSelection() }
    }

    /// The grid for the CURRENT `daily`/`today` inputs. Reuses the cached
    /// build when its inputs are unchanged (F2: the 53×7 grid is a snapshot,
    /// never rebuilt per body pass); rebuilds the moment the inputs differ so
    /// the empty/heatmap/legend decision can never run against a grid that
    /// predates the current daily map (#895).
    private var resolvedGrid: HeatmapGrid {
        let todayKey = LocalDateSupport.string(from: today)
        if let grid,
           gridBuiltFromDaily == daily,
           gridBuiltFromTodayKey == todayKey {
            return grid
        }
        let fresh = TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: weeks)
        grid = fresh
        gridBuiltFromDaily = daily
        gridBuiltFromTodayKey = todayKey
        return fresh
    }

    private func resetSelection() {
        // Data/day replacement is passive (sync/day rollover), so it must not
        // emit a haptic. A stale selection also cannot survive into a new
        // window.
        selectedDate = nil
        tickedDate = nil
    }

    // MARK: - Geometry

    private func cellSize(for grid: HeatmapGrid) -> CGFloat {
        // F6: clamp so a zero/narrow first-layout pass never yields a
        // negative frame dimension.
        max(
            1,
            (containerWidth - weekdayColumnWidth - hSpacing - CGFloat(grid.columns.count - 1) * gap)
                / CGFloat(grid.columns.count)
        )
    }

    private func heatmap(grid: HeatmapGrid) -> some View {
        let size = cellSize(for: grid)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                monthLabelsRow(cellSize: size, grid: grid)
                HStack(spacing: hSpacing) {
                    weekdayColumn(cellSize: size)
                    cellsGrid(cellSize: size, grid: grid)
                }
            }
            .frame(width: containerWidth, alignment: .leading)
            .overlay(alignment: .topLeading) {
                scrubSurface(cellSize: size, grid: grid)
                    .offset(x: weekdayColumnWidth + hSpacing, y: monthLabelHeight)
            }
            if let cell = selectedCell(in: grid) {
                tooltip(for: cell, cellSize: size, grid: grid)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: containerWidth, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Training load contribution heatmap for \(grid.columns.count) weeks")
    }

    // MARK: - Grid rows

    private func weekdayColumn(cellSize: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Group {
                    if let index = Self.weekdayRows.firstIndex(of: row) {
                        Text(Self.weekdayNames[index])
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: weekdayColumnWidth, height: cellSize)
            }
        }
        .accessibilityHidden(true)
    }

    private func cellsGrid(cellSize: CGFloat, grid: HeatmapGrid) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<grid.columns.count, id: \.self) { column in
                        cellView(cell: grid.columns[column][row], size: cellSize, max: grid.max)
                    }
                }
            }
        }
    }

    private func cellView(cell: HeatmapCell, size: CGFloat, max: Double) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fillColor(for: cell, max: max))
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(isSelected(cell) ? Color.primary : .clear, lineWidth: 1.5)
            )
            .frame(width: size, height: size)
            .opacity(cell.future ? 0.35 : 1)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel(for: cell))
            .accessibilityValue(isSelected(cell) ? "Selected" : "")
            .accessibilityAddTraits(cell.future ? [] : .isButton)
            .accessibilityAction {
                guard !cell.future else { return }
                select(
                    TrainingLoadInteraction.toggledSelection(
                        current: tickedDate,
                        candidate: cell.date
                    )
                )
            }
            .accessibilityHidden(cell.future)
    }

    private func monthLabelsRow(cellSize: CGFloat, grid: HeatmapGrid) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(monthLabelPositions(grid: grid), id: \.col) { position in
                Text(Self.monthNames[position.month - 1])
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .position(
                        x: weekdayColumnWidth + hSpacing + CGFloat(position.col) * (cellSize + gap) + cellSize / 2,
                        y: monthLabelHeight / 2
                    )
            }
        }
        .frame(width: containerWidth, height: monthLabelHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    // MARK: - Scrub surface (F3 / F7)

    private func scrubSurface(cellSize: CGFloat, grid: HeatmapGrid) -> some View {
        Color.clear
            .frame(
                width: CGFloat(grid.columns.count) * cellSize + CGFloat(grid.columns.count - 1) * gap,
                height: 7 * cellSize + 6 * gap
            )
            .contentShape(Rectangle())
            .hapticTapMuted()
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if let cell = cell(at: value.location, cellSize: cellSize, grid: grid) {
                            // Tap-again on the selected day dismisses the
                            // tooltip (F7); a first tap selects.
                            select(
                                TrainingLoadInteraction.toggledSelection(
                                    current: tickedDate,
                                    candidate: cell.date
                                )
                            )
                        }
                    }
            )
            .simultaneousGesture(
                // A `minimumDistance: 12` drag lets a vertical scroll starting
                // on the (tiny) grid still scroll the sheet; only a deliberate
                // drag scrubs day-by-day. `minimumDistance: 0` would hijack
                // the ScrollView entirely.
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if let cell = cell(at: value.location, cellSize: cellSize, grid: grid) {
                            select(cell.date)
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    private func cell(at point: CGPoint, cellSize: CGFloat, grid: HeatmapGrid) -> HeatmapCell? {
        let column = Int(point.x / (cellSize + gap))
        let row = Int(point.y / (cellSize + gap))
        guard column >= 0, column < grid.columns.count, row >= 0, row < 7 else { return nil }
        let cell = grid.columns[column][row]
        return cell.future ? nil : cell
    }

    // MARK: - Tooltip

    private func tooltip(for cell: HeatmapCell, cellSize: CGFloat, grid: HeatmapGrid) -> some View {
        let row = rowIndex(of: cell, in: grid) ?? 0
        let columnX = weekdayColumnWidth + hSpacing
            + CGFloat(columnIndex(of: cell, in: grid)) * (cellSize + gap) + cellSize / 2
        let clampedX = min(max(columnX, 64), max(containerWidth - 64, 64))
        let y = row < 4
            ? monthLabelHeight + CGFloat(row + 1) * (cellSize + gap) + 8
            : monthLabelHeight + CGFloat(row) * (cellSize + gap) - 8
        return Text(tooltipText(for: cell))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ChartToken.tooltip.color(scheme), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ChartToken.tooltipBorder.color(scheme), lineWidth: 1))
            .position(x: clampedX, y: y)
            .fixedSize()
            .zIndex(1)
    }

    // MARK: - Colors / labels

    /// Honest state when the rendered 53-week window has no load at all: a
    /// silent wall of grey cells would read exactly like the all-grey bug
    /// (#754), so the sheet explains itself instead — either no records yet,
    /// or records that fall outside the shown window.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            if daily.isEmpty {
                Text("No training records yet. Log a session to start your daily load heatmap.")
            } else {
                Text("No training load in the past 53 weeks.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func fillColor(for cell: HeatmapCell, max: Double) -> Color {
        let fill = TrainingLoad.heatmapCellFill(
            value: cell.value,
            type: cell.type,
            future: cell.future,
            max: max
        )
        if fill.grey { return Color(uiColor: .secondarySystemFill) }
        let hue = ChartActivityHue.color(forActivityID: fill.type, scheme: scheme)
        return hue.opacity(fill.alpha)
    }

    private func tooltipText(for cell: HeatmapCell) -> String {
        if cell.value <= 0 { return "\(cell.date) · rest" }
        let activity = cell.type.isEmpty ? "" : " · \(TrainingLoad.activityLabel(cell.type))"
        return "\(cell.date) · \(TrainingLoad.formatAU(cell.value)) \(unit)\(activity)"
    }

    private func accessibilityLabel(for cell: HeatmapCell) -> String {
        if cell.future { return "\(cell.date): unavailable (future)" }
        if cell.value <= 0 { return "\(cell.date): rest" }
        let activity = cell.type.isEmpty ? "" : ", \(TrainingLoad.activityLabel(cell.type))"
        return "\(cell.date): \(TrainingLoad.formatAU(cell.value)) \(unit)\(activity)"
    }

    // MARK: - Selection / metadata

    /// All three Training Load charts use the same selection cue: one crisp
    /// `.selection` tick for each value change, including the deliberate
    /// tap-again dismissal. Re-reading the same cell during a drag is silent.
    private func select(_ date: String?) {
        if SelectionHaptics.valueChanged(tickedDate, date) {
            tickedDate = date
            Haptics.shared.playGesture(.selection)
        }
        selectedDate = date
    }

    private func isSelected(_ cell: HeatmapCell) -> Bool {
        !cell.future && selectedDate == cell.date
    }

    private func selectedCell(in grid: HeatmapGrid) -> HeatmapCell? {
        guard let selectedDate else { return nil }
        for column in grid.columns {
            for cell in column where cell.date == selectedDate && !cell.future {
                return cell
            }
        }
        return nil
    }

    private func columnIndex(of cell: HeatmapCell, in grid: HeatmapGrid) -> Int {
        for (index, column) in grid.columns.enumerated() {
            if column.contains(where: { $0.date == cell.date }) { return index }
        }
        return 0
    }

    private func rowIndex(of cell: HeatmapCell, in grid: HeatmapGrid) -> Int? {
        for column in grid.columns {
            if let row = column.firstIndex(where: { $0.date == cell.date }) { return row }
        }
        return nil
    }

    /// Mark a column when the month of its first (Sunday) cell changes; skip
    /// a label that would collide with the previous one (web logic).
    private func monthLabelPositions(grid: HeatmapGrid) -> [(col: Int, month: Int)] {
        var out: [(col: Int, month: Int)] = []
        var lastMonth = -1
        var lastCol = -10
        for (index, column) in grid.columns.enumerated() {
            guard let first = column.first else { continue }
            let month = first.month
            if month != lastMonth {
                if index - lastCol >= 3 {
                    out.append((col: index, month: month))
                    lastCol = index
                }
                lastMonth = month
            }
        }
        return out
    }

    // MARK: - Legend

    /// Activity types the grid actually renders, in palette order — derived
    /// from the RENDERED cells (via `TrainingLoad.heatmapLegendTypes`), not
    /// the full `daily` map: an activity whose sessions all fall outside the
    /// rendered 53-week window must not appear next to a grid that cannot
    /// show it, which is how the screen read as "grey cells under a colored
    /// legend" (#754 r2). Rendered only when the grid has visible load.
    private func legend(for grid: HeatmapGrid) -> some View {
        let types = TrainingLoad.heatmapLegendTypes(in: grid)
        if types.isEmpty {
            return AnyView(EmptyView())
        }
        return AnyView(
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 12)], alignment: .leading, spacing: 6) {
                ForEach(types, id: \.self) { type in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(ChartActivityHue.color(forActivityID: type, scheme: scheme))
                            .frame(width: 9, height: 9)
                        Text(TrainingLoad.activityLabel(type))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        )
    }
}

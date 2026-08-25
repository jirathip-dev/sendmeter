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
            if let grid, containerWidth > 0 {
                heatmap(grid: grid)
                legend
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
        .onAppear { rebuild() }
        .onChange(of: daily) { _ in rebuild() }
        .onChange(of: today) { _ in rebuild() }
    }

    private func rebuild() {
        grid = TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: weeks)
        // Rebuilding is passive (sync/day rollover), so it must not emit a
        // haptic. A stale selection also cannot survive into a new window.
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

    private func fillColor(for cell: HeatmapCell, max: Double) -> Color {
        if cell.future { return Color(uiColor: .secondarySystemFill) }
        if cell.value <= 0 { return Color(uiColor: .secondarySystemFill) }
        let level = TrainingLoad.heatmapLevel(value: cell.value, max: max)
        let hue = ChartActivityHue.color(forActivityID: cell.type, scheme: scheme)
        return hue.opacity(TrainingLoad.heatmapAlpha(level: level))
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

    /// Activity types that actually appear (for the legend), in the palette
    /// order — unknown ids sort last. Mirrors the web's `presentTypes`
    /// (ContributionHeatmap.tsx), which scans the full `values` map — not the
    /// rendered grid — so an activity whose sessions all fall outside the
    /// 53-week window still shows up in the legend.
    private var legendTypes: [String] {
        var seen: Set<String> = []
        for entry in daily.values where entry.total > 0 && !entry.type.isEmpty {
            seen.insert(entry.type)
        }
        return seen.sorted { lhs, rhs in
            let lhsIndex = ChartActivityHue.allCases.firstIndex { $0.rawValue == lhs } ?? .max
            let rhsIndex = ChartActivityHue.allCases.firstIndex { $0.rawValue == rhs } ?? .max
            return lhsIndex < rhsIndex
        }
    }

    private var legend: some View {
        let types = legendTypes
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

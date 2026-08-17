import SendmeterCore
import SwiftUI

/// GitHub-contribution-style daily training-load heatmap (web
/// `ContributionHeatmap.tsx` port, #650). One square per day; columns are
/// Sun–Sat weeks oldest→newest ending on the current week's Saturday. Each
/// day is hued by its dominant activity type (SL-60) and shaded by total AU
/// across the 5 intensity levels; future days render greyed-out and are not
/// selectable. Cells are fixed-size squares derived from the available width,
/// so 53 columns always fit with no horizontal scrolling — even on an SE.
struct ContributionHeatmapView: View {
    let daily: [String: TrainingLoad.DailyLoad]
    var weeks: Int = 53
    var unit: String = "AU"
    var today: Date = Date()

    @Environment(\.colorScheme) private var scheme
    @State private var selectedDate: String?

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdayRows = [1, 3, 5] // Mon / Wed / Fri (0-indexed)
    private static let weekdayNames = ["Mon", "Wed", "Fri"]

    private let gap: CGFloat = 2
    private let weekdayColumnWidth: CGFloat = 22
    private let hSpacing: CGFloat = 6
    private let monthLabelHeight: CGFloat = 14

    private var grid: HeatmapGrid {
        TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: weeks)
    }

    var body: some View {
        let grid = self.grid
        VStack(alignment: .leading, spacing: 8) {
            heatmap(grid: grid)
            legend(grid: grid)
        }
    }

    // MARK: - Grid

    private func heatmap(grid: HeatmapGrid) -> some View {
        GeometryReader { proxy in
            let cellSize = (proxy.size.width - weekdayColumnWidth - hSpacing - CGFloat(grid.columns.count - 1) * gap)
                / CGFloat(grid.columns.count)
            ZStack(alignment: .topLeading) {
                HStack(spacing: hSpacing) {
                    weekdayColumn(cellSize: cellSize)
                    cellsGrid(cellSize: cellSize, grid: grid)
                }
                .frame(width: proxy.size.width, height: monthLabelHeight + 7 * cellSize + 6 * gap, alignment: .topLeading)
                monthLabels(cellSize: cellSize, grid: grid)
                if let cell = selectedCell(in: grid) {
                    tooltip(for: cell, cellSize: cellSize, gridWidth: proxy.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

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
    }

    private func cellsGrid(cellSize: CGFloat, grid: HeatmapGrid) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<grid.columns.count, id: \.self) { column in
                        cellView(cell: grid.columns[column][row], size: cellSize)
                    }
                }
            }
        }
    }

    private func cellView(cell: HeatmapCell, size: CGFloat) -> some View {
        Button {
            selectedDate = cell.date
        } label: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(fillColor(for: cell))
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(isSelected(cell) ? Color.primary : .clear, lineWidth: 1.5)
                )
                .frame(width: size, height: size)
                .opacity(cell.future ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(cell.future)
        .accessibilityLabel(accessibilityLabel(for: cell))
        .accessibilityAddTraits(cell.future ? [] : .isButton)
    }

    private func monthLabels(cellSize: CGFloat, grid: HeatmapGrid) -> some View {
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

    private func tooltip(for cell: HeatmapCell, cellSize: CGFloat, gridWidth: CGFloat) -> some View {
        let row = rowIndex(of: cell) ?? 0
        let x = weekdayColumnWidth + hSpacing + columnIndex(of: cell) * (cellSize + gap) + cellSize / 2
        let clampedX = min(max(x, 64), max(gridWidth - 64, 64))
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

    private func fillColor(for cell: HeatmapCell) -> Color {
        if cell.future { return Color(uiColor: .secondarySystemFill) }
        if cell.value <= 0 { return Color(uiColor: .secondarySystemFill) }
        let level = TrainingLoad.heatmapLevel(value: cell.value, max: grid.max)
        let hue = ChartActivityHue.color(forActivityID: cell.type, scheme: scheme)
        return hue.opacity(TrainingLoad.heatmapAlpha(level: level))
    }

    private func tooltipText(for cell: HeatmapCell) -> String {
        if cell.value <= 0 { return "\(cell.date) · rest" }
        let activity = cell.type.isEmpty ? "" : " · \(TrainingLoad.activityLabel(cell.type))"
        return "\(cell.date) · \(Int(cell.value)) \(unit)\(activity)"
    }

    private func accessibilityLabel(for cell: HeatmapCell) -> String {
        if cell.future { return "\(cell.date): unavailable (future)" }
        if cell.value <= 0 { return "\(cell.date): rest" }
        let activity = cell.type.isEmpty ? "" : ", \(TrainingLoad.activityLabel(cell.type))"
        return "\(cell.date): \(Int(cell.value)) \(unit)\(activity)"
    }

    // MARK: - Selection / metadata

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

    private func columnIndex(of cell: HeatmapCell) -> Int {
        for (index, column) in grid.columns.enumerated() {
            if column.contains(where: { $0.date == cell.date }) { return index }
        }
        return 0
    }

    private func rowIndex(of cell: HeatmapCell) -> Int? {
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

    /// Activity types that actually appear (for the legend), in the palette
    /// order — unknown ids sort last (web `presentTypes`).
    private func legendTypes(grid: HeatmapGrid) -> [String] {
        var seen: [String] = []
        for column in grid.columns {
            for cell in column where cell.value > 0 && !cell.type.isEmpty {
                if !seen.contains(cell.type) { seen.append(cell.type) }
            }
        }
        return seen.sorted { lhs, rhs in
            let lhsIndex = ChartActivityHue.allCases.firstIndex { $0.rawValue == lhs } ?? .max
            let rhsIndex = ChartActivityHue.allCases.firstIndex { $0.rawValue == rhs } ?? .max
            return lhsIndex < rhsIndex
        }
    }

    private func legend(grid: HeatmapGrid) -> some View {
        let types = legendTypes(grid: grid)
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

import Foundation

/// Pure training-load math ported from the web's `src/lib/trainingLoad.ts`
/// and the per-day / heatmap aggregation in `TrainingLoadSheet.tsx` (#650).
/// The views are thin: every number the load sheet shows — the activity mix,
/// per-day totals + dominant type, heatmap geometry and intensity levels —
/// comes from these functions, so the product contract is unit-testable.
public enum TrainingLoad {
    // MARK: - Activity mix

    /// AU grouped by activity over the 28 calendar days ending on `endDate`.
    /// Mirror of the web `activityMix()`: label resolution is SESSION_TYPES →
    /// previously resolved group label → legacy `typeLabel` → titlecased
    /// `type`; zero-load groups are dropped; sorting is load desc, then label
    /// asc (web `localeCompare`).
    public static func activityMix(
        sessions: [Session],
        endDate: String,
        timeZone: TimeZone = .current
    ) -> ActivityMix {
        guard let end = LocalDateSupport.date(from: endDate, timeZone: timeZone) else {
            return ActivityMix(total: 0, activities: [])
        }
        let calendar = LocalDateSupport.calendar(timeZone: timeZone)
        let start = calendar.date(byAdding: .day, value: -27, to: end) ?? end
        let startDate = LocalDateSupport.string(from: start, timeZone: timeZone)

        struct Group {
            var load: Double = 0
            var label: String?
        }
        var grouped: [String: Group] = [:]
        for session in sessions {
            guard let date = LocalDateSupport.canonicalDayKey(
                session.date,
                timeZone: timeZone
            ),
            date >= startDate && date <= endDate
            else { continue }
            let knownLabel = SessionTypeCatalog.all.first { $0.id == session.type }?.label
            let legacy = session.typeLabel.trimmingCharacters(in: .whitespaces)
            let label = knownLabel
                ?? grouped[session.type]?.label
                ?? (legacy.isEmpty ? nil : legacy)
                ?? fallbackLabel(session.type)
            var group = grouped[session.type] ?? Group()
            group.load += session.load
            group.label = label
            grouped[session.type] = group
        }

        let total = grouped.values.reduce(0) { $0 + $1.load }
        let activities = grouped
            .map { type, item in
                ActivityLoad(
                    type: type,
                    label: item.label ?? fallbackLabel(type),
                    load: item.load,
                    percentage: total > 0 ? item.load / total * 100 : 0
                )
            }
            .filter { $0.load > 0 }
            .sorted { lhs, rhs in
                if lhs.load != rhs.load { return lhs.load > rhs.load }
                // `localizedCompare` mirrors JS `localeCompare`; the
                // numeric-aware `localizedStandardCompare` (Finder order)
                // would sort "Board 10" before "Board 2" (N2).
                return lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
        return ActivityMix(total: total, activities: activities)
    }

    /// Displays an AU figure the way the web's `Number.toLocaleString()` does:
    /// grouped thousands separators and fractional AU preserved when present
    /// (a 292.5 AU session must read "292.5", not the truncated "292" — F5).
    /// The locale is a parameter so tests pin `en_US` deterministically;
    /// production callers use the user's current locale, like the web.
    public static func formatAU(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).grouping(.automatic).locale(locale))
    }

    /// Human label for an activity id, mirroring the web `activityLabel()`:
    /// the session-type catalog label when known, else the titlecased id
    /// ("Unknown activity" when empty). Used by the heatmap tooltip, legend
    /// and per-cell accessibility labels.
    public static func activityLabel(_ type: String) -> String {
        let known = SessionTypeCatalog.all.first { $0.id == type }?.label
        return known ?? fallbackLabel(type)
    }

    /// Titlecases an activity id the way the web's `fallbackLabel` does:
    /// `[_-]+` → space, then the first letter of every word is uppercased.
    /// Empty results read as "Unknown activity".
    static func fallbackLabel(_ type: String) -> String {
        let spaced = type.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        let words = spaced.split(separator: " ").map { word in
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + word.dropFirst()
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? "Unknown activity" : result
    }

    /// Rounds a share for display; a real but sub-1% sliver reads as "<1%"
    /// rather than "0%" (web `formatSharePercent`).
    public static func formatSharePercent(_ percentage: Double) -> String {
        if percentage > 0 && percentage < 1 { return "<1%" }
        return "\(Int(percentage.rounded()))%"
    }

    // MARK: - Daily aggregation

    /// Per-date load + dominant activity over ALL sessions (the sheet builds
    /// this map once; the heatmap looks up by date key). Keys are normalized
    /// to the same `LocalDateSupport.string(from:timeZone:)` calendar day the
    /// grid generates, so a noncanonical/wrong-zone `session.date` cannot make
    /// a trained day fall through to a grey rest cell (#754 cause 1). A day
    /// with several activity types is hued by the type with the HIGHEST load —
    /// dominant, not first; ties resolve to the first-encountered type.
    public static func dailyLoads(
        sessions: [Session],
        timeZone: TimeZone = .current
    ) -> [String: DailyLoad] {
        var accumulated: [String: (total: Double, byType: [(type: String, load: Double)])] = [:]
        for session in sessions {
            guard let date = LocalDateSupport.canonicalDayKey(
                session.date,
                timeZone: timeZone
            ) else { continue }
            var entry = accumulated[date] ?? (total: 0, byType: [])
            entry.total += session.load
            if let index = entry.byType.firstIndex(where: { $0.type == session.type }) {
                entry.byType[index].load += session.load
            } else {
                entry.byType.append((type: session.type, load: session.load))
            }
            accumulated[date] = entry
        }

        var result: [String: DailyLoad] = [:]
        result.reserveCapacity(accumulated.count)
        for (date, entry) in accumulated {
            // `-.infinity` so a day whose sessions all carry `load == 0` still
            // resolves to the first-encountered type, matching the web's
            // stable sort (the wrong `leastNormalMagnitude` sentinel would
            // yield an empty dominant type — N1).
            var dominant = ""
            var dominantLoad = -Double.infinity
            for candidate in entry.byType where candidate.load > dominantLoad {
                dominantLoad = candidate.load
                dominant = candidate.type
            }
            result[date] = DailyLoad(total: entry.total, type: dominant)
        }
        return result
    }

    // MARK: - Heatmap geometry

    /// The Sun–Sat week window behind a contribution heatmap: `end` is the
    /// Saturday of the week containing `today`, `start` is `weeks` columns
    /// back (`end - (weeks*7 - 1)`), both at local midnight. Mirror of the
    /// web `ContributionHeatmap` (SL-60 geometry).
    public static func heatmapRange(
        today: Date,
        weeks: Int = 53,
        timeZone: TimeZone = .current
    ) -> (start: Date, end: Date) {
        let calendar = LocalDateSupport.calendar(timeZone: timeZone)
        let day = calendar.startOfDay(for: today)
        // Gregorian weekday: 1 = Sunday … 7 = Saturday; JS getDay() is 0 = Sun.
        let weekday = calendar.component(.weekday, from: day)
        let end = calendar.date(byAdding: .day, value: 7 - weekday, to: day) ?? day
        let start = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: end) ?? end
        return (start, end)
    }

    /// Builds the `weeks`×7 cell grid, oldest→newest columns, Sun–Sat rows.
    /// `max` is the intensity scale cap: the largest non-future per-day total,
    /// capped at 2× the median positive load so one outlier cannot wash real
    /// training days down to the faintest level (#754). It is at least 1 so a
    /// low-load window never divides by zero. Future cells are rendered but
    /// not selectable.
    public static func heatmapGrid(
        daily: [String: DailyLoad],
        today: Date,
        weeks: Int = 53,
        timeZone: TimeZone = .current
    ) -> HeatmapGrid {
        let (start, end) = heatmapRange(today: today, weeks: weeks, timeZone: timeZone)
        let calendar = LocalDateSupport.calendar(timeZone: timeZone)
        let day = calendar.startOfDay(for: today)

        var columns: [[HeatmapCell]] = []
        columns.reserveCapacity(weeks)
        var positiveLoads: [Double] = []
        var cursor = start
        for _ in 0..<weeks {
            var column: [HeatmapCell] = []
            column.reserveCapacity(7)
            for _ in 0..<7 {
                let key = LocalDateSupport.string(from: cursor, timeZone: timeZone)
                let entry = daily[key]
                let value = entry?.total ?? 0
                let isFuture = cursor > day
                // Future cells render as unavailable (gray) in the sheet, so
                // they must not participate in the load scale. A session can
                // be dated up to +7 days ahead (DB `sessions_date_sane`), and
                // if that row carried the largest load it would otherwise
                // inflate `max` and compress every real past data day to level
                // 1, reading as "all cells gray despite data" (#706).
                if value > 0 && !isFuture { positiveLoads.append(value) }
                column.append(
                    HeatmapCell(
                        date: key,
                        month: calendar.component(.month, from: cursor),
                        value: value,
                        type: entry?.type ?? "",
                        future: isFuture
                    )
                )
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            columns.append(column)
        }
        // The `weeks*7` walk must land exactly on `end`; asserting the last
        // cell matches keeps a future edit to `heatmapRange` from silently
        // desynchronising the two (F8 — `end` would otherwise be dead).
        let lastCellDate = columns.last?.last?.date ?? ""
        assert(
            lastCellDate == LocalDateSupport.string(from: end, timeZone: timeZone),
            "heatmap walk must end on heatmapRange's Saturday"
        )
        let maximum = heatmapScaleMax(positiveLoads)
        return HeatmapGrid(columns: columns, max: max(1, maximum))
    }

    /// Robust upper bound for the heatmap scale (#754). A single unusually
    /// large day must not set the raw maximum: otherwise a typical 500 AU day
    /// against a 5,000 AU outlier lands at level 1 (0.34 alpha), which reads
    /// as grey at the native cells' ~3.4pt size. Anchoring to 2× the median
    /// keeps ordinary training shaded while values above the cap still clamp
    /// to full opacity. The actual maximum is preserved when it is already
    /// within the typical range.
    private static func heatmapScaleMax(_ values: [Double]) -> Double {
        let positive = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard let actualMaximum = positive.last else { return 1 }
        guard positive.count > 1 else { return actualMaximum }
        let median = positive[(positive.count - 1) / 2]
        return min(actualMaximum, median * 2)
    }

    // MARK: - Weekly delta

    /// Week-over-week change for the load sheet's delta chip and per-bar
    /// tooltip (web `weekDelta`): nil when the prior week is 0, so the chip
    /// is hidden rather than claiming an infinite change.
    public static func weekDelta(current: Double, previous: Double) -> WeekDelta? {
        guard previous > 0 else { return nil }
        let pct = (current - previous) / previous * 100
        return WeekDelta(
            pct: pct,
            arrow: pct > 0 ? "▲" : (pct < 0 ? "▼" : ""),
            isUp: pct > 0,
            isDown: pct < 0,
            isFlat: abs(pct) < 1
        )
    }

    // MARK: - Intensity levels

    /// The 5 GitHub-style intensity alpha stops, indexed by level 0…4.
    public static let heatmapLevelAlpha: [Double] = [0, 0.34, 0.55, 0.78, 1.0]

    /// Alpha for a level, mirrored from `LEVEL_ALPHA`.
    public static func heatmapAlpha(level: Int) -> Double {
        heatmapLevelAlpha[min(max(level, 0), 4)]
    }

    /// `v <= 0 ? 0 : min(4, ceil(v/max * 4))` — the web's `level()`.
    public static func heatmapLevel(value: Double, max: Double) -> Int {
        if value <= 0 { return 0 }
        return min(4, Int(ceil(value / max * 4)))
    }

    // MARK: - Cell fill resolution (#754 r2)

    /// The full fill decision for one rendered heatmap cell, mirroring
    /// `ContributionHeatmapView.fillColor(for:max:)` so the view's color
    /// contract is unit-testable: rest/no-load and future cells resolve grey;
    /// a genuine-load cell resolves to its dominant activity type at the
    /// level alpha. `paletteType` is false when the dominant type has no
    /// `ChartActivityHue` entry — the view then paints the reference token,
    /// the same token the legend swatch uses for that type.
    public static func heatmapCellFill(
        value: Double,
        type: String,
        future: Bool,
        max: Double
    ) -> HeatmapCellFill {
        if future || value <= 0 {
            return HeatmapCellFill(grey: true, type: "", level: 0, alpha: 0, paletteType: false)
        }
        let level = heatmapLevel(value: value, max: max)
        return HeatmapCellFill(
            grey: false,
            type: type,
            level: level,
            alpha: heatmapAlpha(level: level),
            paletteType: ChartActivityHue(rawValue: type) != nil
        )
    }

    /// Activity types the RENDERED grid actually paints, in palette order
    /// (unknown ids sort last) — the legend input. Derived from the grid's
    /// non-future positive cells, NOT the full `daily` map: an activity whose
    /// sessions all fall outside the rendered 53-week window must not be
    /// advertised next to a grid that cannot show it — the grey-grid-under-a-
    /// colored-legend wedge the #754 reports kept mistaking for a render bug.
    /// Mirrors the web `presentTypes` ordering.
    public static func heatmapLegendTypes(in grid: HeatmapGrid) -> [String] {
        var seen: Set<String> = []
        for column in grid.columns {
            for cell in column where !cell.future && cell.value > 0 && !cell.type.isEmpty {
                seen.insert(cell.type)
            }
        }
        return seen.sorted { lhs, rhs in
            let lhsIndex = ChartActivityHue.allCases.firstIndex { $0.rawValue == lhs } ?? .max
            let rhsIndex = ChartActivityHue.allCases.firstIndex { $0.rawValue == rhs } ?? .max
            return lhsIndex < rhsIndex
        }
    }

    /// Whether the grid paints any colored cell at all — a positive,
    /// non-future day. When false the rendered window is a silent wall of
    /// grey and the sheet must show its honest empty state instead (#754 r2,
    /// acceptance 6), rather than reproducing the all-grey appearance.
    public static func heatmapHasVisibleLoad(in grid: HeatmapGrid) -> Bool {
        for column in grid.columns {
            for cell in column where !cell.future && cell.value > 0 {
                return true
            }
        }
        return false
    }
}

public struct ActivityLoad: Equatable, Sendable {
    public let type: String
    public let label: String
    public let load: Double
    public let percentage: Double

    public init(type: String, label: String, load: Double, percentage: Double) {
        self.type = type
        self.label = label
        self.load = load
        self.percentage = percentage
    }
}

public struct ActivityMix: Equatable, Sendable {
    public let total: Double
    public let activities: [ActivityLoad]

    public init(total: Double, activities: [ActivityLoad]) {
        self.total = total
        self.activities = activities
    }
}

public struct WeekDelta: Equatable, Sendable {
    public let pct: Double
    public let arrow: String
    public let isUp: Bool
    public let isDown: Bool
    public let isFlat: Bool

    public init(pct: Double, arrow: String, isUp: Bool, isDown: Bool, isFlat: Bool) {
        self.pct = pct
        self.arrow = arrow
        self.isUp = isUp
        self.isDown = isDown
        self.isFlat = isFlat
    }
}

public struct DailyLoad: Equatable, Sendable {
    public let total: Double
    public let type: String

    public init(total: Double, type: String) {
        self.total = total
        self.type = type
    }
}

public struct HeatmapCell: Equatable, Sendable {
    public let date: String
    public let month: Int
    public let value: Double
    public let type: String
    public let future: Bool

    public init(date: String, month: Int, value: Double, type: String, future: Bool) {
        self.date = date
        self.month = month
        self.value = value
        self.type = type
        self.future = future
    }
}

public struct HeatmapGrid: Equatable, Sendable {
    public let columns: [[HeatmapCell]]
    public let max: Double

    public init(columns: [[HeatmapCell]], max: Double) {
        self.columns = columns
        self.max = max
    }
}

/// The resolved fill for one rendered heatmap cell (see
/// `TrainingLoad.heatmapCellFill`). Grey cells carry no type/level; colored
/// cells carry the dominant type and the level alpha the view paints.
public struct HeatmapCellFill: Equatable, Sendable {
    public let grey: Bool
    public let type: String
    public let level: Int
    public let alpha: Double
    /// True when `type` has a `ChartActivityHue` entry; a false value paints
    /// the reference token (same swatch the legend shows for that type).
    public let paletteType: Bool

    public init(grey: Bool, type: String, level: Int, alpha: Double, paletteType: Bool) {
        self.grey = grey
        self.type = type
        self.level = level
        self.alpha = alpha
        self.paletteType = paletteType
    }
}

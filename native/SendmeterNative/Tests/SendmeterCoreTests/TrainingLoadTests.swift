import XCTest
@testable import SendmeterCore

/// Tests for the training-load sheet math port (#650) — mirrors the web's
/// `src/lib/trainingLoad.test.ts` fixtures plus the native heatmap-geometry
/// contract (53×7 Sun–Sat grid ending on the current week's Saturday, future
/// cells flagged, dominant-type hue resolution). Every date is Gregorian and
/// pinned to the Bangkok time zone, the same convention as `MetricsTests`.
final class TrainingLoadTests: XCTestCase {
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!

    private func session(
        _ date: String,
        _ type: String,
        _ load: Double,
        typeLabel: String = ""
    ) -> Session {
        Session(
            id: UUID(),
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: 60,
            rpe: 6,
            load: load,
            phase: .capacity
        )
    }

    // MARK: - activityMix

    func testActivityMixIncludesBothEndsOfThe28DayWindow() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-07-06", "board", 100),
                session("2026-07-05", "gym", 999),
                session("2026-08-02", "gym", 200),
                session("2026-08-03", "gym", 999)
            ],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(mix.total, 300)
        XCTAssertEqual(mix.activities.map(\.type), ["gym", "board"])
    }

    func testActivityMixGroupsSortsAndComputesPercentages() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-01", "board", 100),
                session("2026-08-02", "board", 200),
                session("2026-08-02", "gym", 100)
            ],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(mix.total, 400)
        XCTAssertEqual(mix.activities, [
            ActivityLoad(type: "board", label: "Board Climbing", load: 300, percentage: 75),
            ActivityLoad(type: "gym", label: "Gym Session", load: 100, percentage: 25)
        ])
    }

    func testActivityMixReturnsEmptyMixForZeroLoad() {
        let mix = TrainingLoad.activityMix(
            sessions: [session("2026-08-02", "board", 0)],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(mix.total, 0)
        XCTAssertTrue(mix.activities.isEmpty)
    }

    func testActivityMixKeepsUnknownAndLegacyTypesWithUsefulLabels() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-02", "moon_board", 80, typeLabel: "Moon Board Legacy"),
                session("2026-08-02", "mystery-type", 20)
            ],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(
            mix.activities.map(\.label),
            ["Moon Board Legacy", "Mystery Type"]
        )
    }

    func testActivityMixLabelResolutionPrefersCatalogOverLegacy() {
        // Known catalog label beats the (stale/blank) stored typeLabel.
        let known = TrainingLoad.activityMix(
            sessions: [session("2026-08-02", "board", 100, typeLabel: "Stale Board")],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(known.activities.first?.label, "Board Climbing")
    }

    /// F11: the "previously resolved group label" link in the resolution chain
    /// (second position, the only order-dependent one) — two sessions of the
    /// same unknown type, the first carrying a legacy label, the second a
    /// blank one. The blank one must reuse the group's already-resolved label.
    func testActivityMixReusesPreviouslyResolvedGroupLabel() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-02", "moon_board", 80, typeLabel: "Moon Board Legacy"),
                session("2026-08-02", "moon_board", 20, typeLabel: "")
            ],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(mix.activities.count, 1)
        XCTAssertEqual(mix.activities.first?.type, "moon_board")
        XCTAssertEqual(mix.activities.first?.label, "Moon Board Legacy")
    }

    /// N2: equal-load tie-break uses `localizedCompare` (JS `localeCompare`),
    /// not the numeric-aware `localizedStandardCompare`. JS default collation
    /// is not numeric-aware, so "Board 10" sorts BEFORE "Board 2" — verified
    /// against the real strings below ("moon_board_10" < "moon_board_2" by
    /// code point at the '1' vs '2' position).
    func testActivityMixTieBreakMatchesLocaleCompareNotNumeric() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-02", "moon_board_10", 100),
                session("2026-08-02", "moon_board_2", 100)
            ],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        XCTAssertEqual(mix.activities.map(\.type), ["moon_board_10", "moon_board_2"])
    }

    func testActivityMixSortsLoadDescThenLabelAsc() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-01", "gym", 50),
                session("2026-08-02", "board", 50),
                session("2026-08-02", "outdoor", 120)
            ],
            endDate: "2026-08-02",
            timeZone: bangkok
        )
        // Equal loads tie-break on label ascending (web localeCompare): board
        // < gym.
        XCTAssertEqual(mix.activities.map(\.type), ["outdoor", "board", "gym"])
    }

    // MARK: - dailyLoads

    func testDailyLoadsTotalsPerDateAndPicksDominantType() {
        let daily = TrainingLoad.dailyLoads(sessions: [
            session("2026-08-02", "board", 200),
            session("2026-08-02", "gym", 100),
            session("2026-08-02", "board", 50),
            session("2026-08-03", "gym", 300)
        ])
        let aug2 = try! XCTUnwrap(daily["2026-08-02"])
        XCTAssertEqual(aug2.total, 350)
        XCTAssertEqual(aug2.type, "board")
        let aug3 = try! XCTUnwrap(daily["2026-08-03"])
        XCTAssertEqual(aug3.total, 300)
        XCTAssertEqual(aug3.type, "gym")
    }

    func testDailyLoadsTieResolvesToFirstEncounteredType() {
        let daily = TrainingLoad.dailyLoads(sessions: [
            session("2026-08-02", "board", 100),
            session("2026-08-02", "gym", 100)
        ])
        // JS Array.prototype.sort is stable, so a tie keeps insertion order.
        XCTAssertEqual(daily["2026-08-02"]?.type, "board")
    }

    /// N1: a day whose sessions all carry `load == 0` must still resolve a
    /// dominant type (the first-encountered), not an empty string — the
    /// `-.infinity` sentinel handles it where `leastNormalMagnitude` would not.
    func testDailyLoadsZeroLoadDayStillPicksFirstType() {
        let daily = TrainingLoad.dailyLoads(sessions: [
            session("2026-08-02", "board", 0),
            session("2026-08-02", "gym", 0)
        ])
        XCTAssertEqual(daily["2026-08-02"]?.total, 0)
        XCTAssertEqual(daily["2026-08-02"]?.type, "board")
    }

    // MARK: - Heatmap geometry

    func testHeatmapRangeEndsOnSaturdayOfCurrentWeek() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let (start, end) = TrainingLoad.heatmapRange(today: today, weeks: 53, timeZone: bangkok)
        let endString = LocalDateSupport.string(from: end, timeZone: bangkok)
        XCTAssertEqual(endString, "2026-08-22", "2026-08-18 is a Tuesday; week ends Sat 08-22")
        // start = end - (53*7 - 1) = end - 370 days.
        let startString = LocalDateSupport.string(from: start, timeZone: bangkok)
        XCTAssertEqual(startString, "2025-08-17")
    }

    func testHeatmapGridIsExactlyWeeksTimesSevenCells() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let grid = TrainingLoad.heatmapGrid(daily: [:], today: today, weeks: 53, timeZone: bangkok)
        XCTAssertEqual(grid.columns.count, 53)
        for column in grid.columns {
            XCTAssertEqual(column.count, 7)
        }
    }

    func testHeatmapGridRightmostColumnEndsOnCurrentWeekSaturday() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let grid = TrainingLoad.heatmapGrid(daily: [:], today: today, weeks: 53, timeZone: bangkok)
        let last = grid.columns.last?.last
        XCTAssertEqual(last?.date, "2026-08-22", "rightmost cell is this week's Saturday")
        XCTAssertEqual(grid.columns.first?.first?.date, "2025-08-17")
    }

    func testHeatmapGridFlagsFutureCells() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let grid = TrainingLoad.heatmapGrid(daily: [:], today: today, weeks: 53, timeZone: bangkok)
        let flattened = grid.columns.flatMap { $0 }
        XCTAssertTrue(flattened.contains { $0.future }, "future days exist past today")
        let todayCell = flattened.first { $0.date == "2026-08-18" }
        XCTAssertEqual(todayCell?.future, false)
        let saturdayCell = flattened.first { $0.date == "2026-08-22" }
        XCTAssertEqual(saturdayCell?.future, true)
    }

    func testHeatmapGridMaxFloorsToOne() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let empty = TrainingLoad.heatmapGrid(daily: [:], today: today, weeks: 53, timeZone: bangkok)
        XCTAssertEqual(empty.max, 1)
    }

    func testHeatmapGridReadsDailyTotalsAndDominantType() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let daily = ["2026-08-18": DailyLoad(total: 480, type: "board")]
        let grid = TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: 53, timeZone: bangkok)
        XCTAssertEqual(grid.max, 480)
        let cell = grid.columns.flatMap { $0 }.first { $0.date == "2026-08-18" }
        XCTAssertEqual(cell?.value, 480)
        XCTAssertEqual(cell?.type, "board")
    }

    // MARK: - Intensity levels

    func testHeatmapLevelMatchesWebFormula() {
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 0, max: 100), 0)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: -5, max: 100), 0)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 1, max: 100), 1)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 25, max: 100), 1)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 25.1, max: 100), 2)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 50, max: 100), 2)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 75, max: 100), 3)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 100, max: 100), 4)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: 500, max: 100), 4)
    }

    func testHeatmapAlphaStops() {
        XCTAssertEqual(
            TrainingLoad.heatmapLevelAlpha,
            [0, 0.34, 0.55, 0.78, 1.0]
        )
        XCTAssertEqual(TrainingLoad.heatmapAlpha(level: 0), 0)
        XCTAssertEqual(TrainingLoad.heatmapAlpha(level: 2), 0.55)
        XCTAssertEqual(TrainingLoad.heatmapAlpha(level: 4), 1.0)
        XCTAssertEqual(TrainingLoad.heatmapAlpha(level: 9), 1.0, "clamps at the top stop")
        XCTAssertEqual(TrainingLoad.heatmapAlpha(level: -3), 0, "clamps at the bottom stop")
    }

    // MARK: - Weekly delta

    func testWeekDeltaNilWhenPriorWeekIsZero() {
        XCTAssertNil(TrainingLoad.weekDelta(current: 400, previous: 0))
    }

    func testWeekDeltaUpDownAndFlat() {
        let up = try! XCTUnwrap(TrainingLoad.weekDelta(current: 400, previous: 100))
        XCTAssertEqual(up.pct, 300)
        XCTAssertEqual(up.arrow, "▲")
        XCTAssertTrue(up.isUp)

        let down = try! XCTUnwrap(TrainingLoad.weekDelta(current: 80, previous: 100))
        XCTAssertEqual(down.pct, -20)
        XCTAssertEqual(down.arrow, "▼")
        XCTAssertTrue(down.isDown)

        let flat = try! XCTUnwrap(TrainingLoad.weekDelta(current: 100.4, previous: 100))
        XCTAssertTrue(flat.isFlat, "|pct| < 1 reads as flat, muted")

        let zero = try! XCTUnwrap(TrainingLoad.weekDelta(current: 100, previous: 100))
        XCTAssertEqual(zero.arrow, "")
        XCTAssertTrue(zero.isFlat)
    }

    // MARK: - Formatting

    func testFormatSharePercentShowsSubOnePercentAsOnePercent() {
        XCTAssertEqual(TrainingLoad.formatSharePercent(0.4), "<1%")
        XCTAssertEqual(TrainingLoad.formatSharePercent(0), "0%")
        XCTAssertEqual(TrainingLoad.formatSharePercent(25.4), "25%")
        XCTAssertEqual(TrainingLoad.formatSharePercent(25.6), "26%")
        XCTAssertEqual(TrainingLoad.formatSharePercent(100), "100%")
    }

    func testActivityLabelResolvesCatalogAndFallback() {
        XCTAssertEqual(TrainingLoad.activityLabel("board"), "Board Climbing")
        XCTAssertEqual(TrainingLoad.activityLabel("moon_board"), "Moon Board")
        XCTAssertEqual(TrainingLoad.activityLabel("mystery-type"), "Mystery Type")
        XCTAssertEqual(TrainingLoad.activityLabel(""), "Unknown activity")
    }

    /// F5: AU figures keep their decimals (the web shows "292.5" for a 292.5
    /// session, never the truncated "292") and are thousands-grouped, matching
    /// `Number.toLocaleString()`. Pinned to en_US.
    func testFormatAURoundsAndGroups() {
        let enUS = Locale(identifier: "en_US")
        XCTAssertEqual(TrainingLoad.formatAU(292.5, locale: enUS), "292.5")
        XCTAssertEqual(TrainingLoad.formatAU(292.49, locale: enUS), "292.49")
        XCTAssertEqual(TrainingLoad.formatAU(4200, locale: enUS), "4,200")
        XCTAssertEqual(TrainingLoad.formatAU(0, locale: enUS), "0")
        XCTAssertEqual(TrainingLoad.formatAU(1234.75, locale: enUS), "1,234.75")
    }

    func testActivityMixPercentagesSumToOneHundred() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-01", "board", 480),
                session("2026-08-02", "gym", 120),
                session("2026-08-03", "routine", 36)
            ],
            endDate: "2026-08-03",
            timeZone: bangkok
        )
        let sum = mix.activities.reduce(0) { $0 + $1.percentage }
        XCTAssertEqual(sum, 100, accuracy: 1.0, "acceptance 5: sums to 100% ±1 rounding")
    }
}

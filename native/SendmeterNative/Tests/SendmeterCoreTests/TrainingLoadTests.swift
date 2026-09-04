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

    func testActivityMixNormalizesNoncanonicalSessionDate() {
        let mix = TrainingLoad.activityMix(
            sessions: [
                session("2026-08-02T00:00:00Z", "board", 100),
                session("2026-08-03T00:00:00Z", "gym", 200)
            ],
            endDate: "2026-08-03",
            timeZone: bangkok
        )
        XCTAssertEqual(mix.total, 300)
        XCTAssertEqual(mix.activities.map(\.type), ["gym", "board"])
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

    /// #754 cause 1: `heatmapGrid` builds its keys with
    /// `LocalDateSupport.string(from: cursor)`, but `dailyLoads` has always
    /// keyed the map by the raw `session.date`. A session that arrives as an
    /// ISO timestamp (or any noncanonical payload) therefore misses every
    /// lookup: the cell reads `value == 0`, `type == ""`, the tooltip says
    /// "rest", and the legend still shows the color because it scans the
    /// `daily` values directly. This is the grey+rest symptom from the issue.
    func testHeatmapGridFindsTrainedDayWhenSessionDateArrivesAsTimestamp() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-21", timeZone: bangkok))
        let sessions = [
            session("2026-06-11T00:00:00Z", "board", 420)
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions, timeZone: bangkok)
        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        let cellsByDate = Dictionary(
            uniqueKeysWithValues: grid.columns.flatMap { $0 }.map { ($0.date, $0) }
        )

        XCTAssertEqual(daily["2026-06-11"]?.total, 420)
        let trained = try! XCTUnwrap(cellsByDate["2026-06-11"])
        XCTAssertEqual(trained.value, 420, "the trained day must not render as rest")
        XCTAssertEqual(trained.type, "board")
        XCTAssertGreaterThan(trained.value, 0)
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: trained.value, max: grid.max), 4)
    }

    /// #754 cause 1, the concrete historical payload: before e22cf78 the
    /// watch's `Date.localDateString` used `Calendar.current`, so a Thai-region
    /// device stored sessions as `2569-...` while the grid generated
    /// `2026-...` keys. The old daily map kept that raw `session.date`, so the
    /// trained day missed the lookup, rendered grey, and the tooltip said rest.
    func testHeatmapGridFindsTrainedDayWhenSessionDateIsLegacyBuddhistDate() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-21", timeZone: bangkok))
        let sessions = [
            session("2569-06-11", "board", 420)
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions, timeZone: bangkok)
        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        let cellsByDate = Dictionary(
            uniqueKeysWithValues: grid.columns.flatMap { $0 }.map { ($0.date, $0) }
        )

        XCTAssertNil(daily["2569-06-11"])
        XCTAssertEqual(daily["2026-06-11"]?.total, 420)
        let trained = try! XCTUnwrap(cellsByDate["2026-06-11"])
        XCTAssertEqual(trained.value, 420, "the trained day must not render as rest")
        XCTAssertEqual(trained.type, "board")
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: trained.value, max: grid.max), 4)
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

    /// #706: a session can be dated up to +7 days ahead (DB `sessions_date_sane`),
    /// landing in a future grid cell. Future cells render gray (unavailable) and
    /// must not participate in the load scale, otherwise a large future load
    /// inflates `grid.max` and compresses every real past data day to level 1 —
    /// "all cells gray despite data". 2026-08-21 is a Friday, so 08-22 (Saturday,
    /// the current-week end) is the first future day inside the 53-week grid.
    func testHeatmapGridExcludesFutureCellsFromScale() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-21", timeZone: bangkok))
        let daily = [
            "2026-08-20": DailyLoad(total: 680, type: "gym"),
            "2026-08-21": DailyLoad(total: 910, type: "auto"),
            "2026-08-22": DailyLoad(total: 5_000, type: "board") // future (+1 day)
        ]
        let grid = TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: 53, timeZone: bangkok)
        let cellsByDate = Dictionary(uniqueKeysWithValues: grid.columns.flatMap { $0 }.map { ($0.date, $0) })

        let future = try! XCTUnwrap(cellsByDate["2026-08-22"])
        XCTAssertTrue(future.future, "the +1 day row is a future (gray) cell")

        let pastMax = try! XCTUnwrap(cellsByDate["2026-08-21"])
        XCTAssertEqual(grid.max, 910, "grid.max must be the largest NON-future load, not the future 5000")
        XCTAssertEqual(
            TrainingLoad.heatmapLevel(value: pastMax.value, max: grid.max),
            4,
            "the real maximum day must not be compressed by the future cell"
        )
        XCTAssertEqual(
            TrainingLoad.heatmapAlpha(level: TrainingLoad.heatmapLevel(value: pastMax.value, max: grid.max)),
            1.0,
            "the real maximum day renders at full opacity"
        )
    }

    /// #706 production path: a future-dated session flows into `dailyLoads` and
    /// must not depress the scale of the real data days in the rendered grid.
    func testProductionFutureSessionDoesNotDimRealData() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-21", timeZone: bangkok))
        let sessions = [
            session("2026-08-20", "gym", 680),
            session("2026-08-21", "auto", 910),
            session("2026-08-22", "board", 5_000) // future (DB allows up to +7 days)
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions)
        let grid = TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: 53, timeZone: bangkok)
        let cellsByDate = Dictionary(uniqueKeysWithValues: grid.columns.flatMap { $0 }.map { ($0.date, $0) })

        XCTAssertEqual(daily["2026-08-22"]?.total, 5_000, "the future-dated session reaches dailyLoads")
        XCTAssertEqual(grid.max, 910, "grid.max excludes the future cell")

        let realMax = try! XCTUnwrap(cellsByDate["2026-08-21"])
        XCTAssertEqual(realMax.type, "auto")
        XCTAssertEqual(TrainingLoad.heatmapLevel(value: realMax.value, max: grid.max), 4)
        XCTAssertEqual(TrainingLoad.heatmapAlpha(level: 4), 1.0)
    }

    /// #754: a single large PAST day can still dominate the raw max and
    /// compress every real training day to level 1 (0.34 alpha), which reads
    /// as grey at the tiny native cell size even though the activity hue is
    /// correct. The scale must stay anchored to the typical load: a real
    /// day just below the outlier must be visibly shaded, while the outlier
    /// itself still clamps to full opacity.
    func testHeatmapGridScaleSurvivesLargePastOutlier() {
        let today = try! XCTUnwrap(LocalDateSupport.date(from: "2026-08-21", timeZone: bangkok))
        var daily: [String: DailyLoad] = [:]

        // 20 ordinary training days spanning 25...500 AU.
        for offset in 0..<20 {
            let date = LocalDateSupport.daysAgo(20 - offset, from: today, timeZone: bangkok)
            daily[date] = DailyLoad(total: Double((offset + 1) * 25), type: "gym")
        }

        let outlierDate = LocalDateSupport.daysAgo(0, from: today, timeZone: bangkok)
        daily[outlierDate] = DailyLoad(total: 5_000, type: "board")

        let grid = TrainingLoad.heatmapGrid(daily: daily, today: today, weeks: 53, timeZone: bangkok)
        let cellsByDate = Dictionary(uniqueKeysWithValues: grid.columns.flatMap { $0 }.map { ($0.date, $0) })
        let ordinaryPeak = try! XCTUnwrap(
            cellsByDate[LocalDateSupport.daysAgo(1, from: today, timeZone: bangkok)]
        )
        let outlier = try! XCTUnwrap(cellsByDate[outlierDate])

        XCTAssertLessThan(grid.max, outlier.value, "the outlier must not set the scale")
        XCTAssertGreaterThanOrEqual(
            TrainingLoad.heatmapLevel(value: ordinaryPeak.value, max: grid.max),
            2,
            "ordinary training load must not be compressed to the faintest level"
        )
        XCTAssertEqual(
            TrainingLoad.heatmapLevel(value: outlier.value, max: grid.max),
            4,
            "the outlier day still renders at full opacity"
        )
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

    // MARK: - Cell fill resolution (#754 r2)

    /// The fill decision the view makes per cell, resolved in Core so the
    /// color contract is unit-testable: rest and future cells must resolve
    /// grey; a trained day must resolve to a colored fill.
    func testHeatmapCellFillResolvesRestAndFutureToGrey() {
        let rest = TrainingLoad.heatmapCellFill(value: 0, type: "board", future: false, max: 480)
        XCTAssertTrue(rest.grey)
        XCTAssertEqual(rest.alpha, 0)

        let noLoad = TrainingLoad.heatmapCellFill(value: -5, type: "", future: false, max: 480)
        XCTAssertTrue(noLoad.grey)

        let future = TrainingLoad.heatmapCellFill(value: 480, type: "board", future: true, max: 480)
        XCTAssertTrue(future.grey, "a future-dated row stays grey and unselectable")
    }

    func testHeatmapCellFillResolvesTrainedDayToColoredFill() {
        let fill = TrainingLoad.heatmapCellFill(
            value: 480,
            type: "board",
            future: false,
            max: 480
        )
        XCTAssertFalse(fill.grey, "genuine load must never resolve to the rest grey")
        XCTAssertEqual(fill.type, "board")
        XCTAssertEqual(fill.level, 4)
        XCTAssertEqual(fill.alpha, 1.0)
        XCTAssertTrue(fill.paletteType, "board has a ChartActivityHue entry")
        XCTAssertEqual(
            ChartActivityHue(rawValue: fill.type)?.lightHex,
            "#2E96F0",
            "the resolved hue is the board palette color the legend paints"
        )
    }

    /// The grey+rest symptom, through the real persisted-record shapes: a
    /// trained day whose session date arrives as a timestamp, plus a legacy
    /// Buddhist-era row, must resolve to a COLORED cell fill inside the grid —
    /// not the rest grey (#754). Fails against the pre-#769 raw-key behavior
    /// (lookup miss -> value 0 -> grey fill).
    func testHeatmapCellFillForHistoricalRecordsResolvesColored() throws {
        let today = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-21", timeZone: bangkok))
        let sessions = [
            session("2026-06-11T00:00:00Z", "board", 420),
            session("2569-07-12", "gym", 260),
            session("2026-08-21", "auto", 100)
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions, timeZone: bangkok)
        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        let cellsByDate = Dictionary(
            uniqueKeysWithValues: grid.columns.flatMap { $0 }.map { ($0.date, $0) }
        )
        for (date, type, value) in [("2026-06-11", "board", 420.0), ("2026-07-12", "gym", 260.0)] {
            let cell = try XCTUnwrap(cellsByDate[date], "trained day must be inside the grid")
            let fill = TrainingLoad.heatmapCellFill(
                value: cell.value,
                type: cell.type,
                future: cell.future,
                max: grid.max
            )
            XCTAssertEqual(cell.value, value, "lookup must find the session")
            XCTAssertEqual(cell.type, type)
            XCTAssertFalse(fill.grey, "\(date) must not render as rest/grey")
            XCTAssertTrue(fill.paletteType)
            XCTAssertGreaterThan(fill.alpha, 0)
        }
    }

    /// The reopened-symptom wedge (#754 r2): the legend previously scanned the
    /// FULL daily map, so an activity whose sessions all fall OUTSIDE the
    /// rendered 53-week window still got colored swatches next to a grid that
    /// could not show it — the "grey grid under a colored legend" screen.
    /// Legend types must come from the rendered cells only.
    func testHeatmapLegendTypesMatchRenderedGridNotFullHistory() throws {
        let today = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        // 2020-01-02 is far outside the 53-week window ending 2026-08-22 but a
        // real session date (DB floor 2020-01-01) — the old full-map legend
        // advertised it while the grid stayed grey.
        let sessions = [
            session("2026-08-18T00:00:00Z", "board", 420),
            session("2020-01-02", "tindeq", 500)
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions, timeZone: bangkok)
        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )

        XCTAssertTrue(TrainingLoad.heatmapHasVisibleLoad(in: grid))
        XCTAssertEqual(
            TrainingLoad.heatmapLegendTypes(in: grid),
            ["board"],
            "legend lists only what the rendered grid paints — the tindeq row is outside the window"
        )
        XCTAssertTrue(
            daily["2020-01-02"] != nil,
            "the out-of-window session still exists in daily (that is the wedge)"
        )
        let tindeqCell = grid.columns.flatMap { $0 }.first { $0.date == "2020-01-02" }
        XCTAssertNil(tindeqCell, "2020-01-02 is not a rendered cell at all")
    }

    func testHeatmapLegendTypesPaletteOrderWithUnknownLast() throws {
        let today = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))
        let daily = [
            "2026-08-18": DailyLoad(total: 100, type: "tindeq"),
            "2026-08-17": DailyLoad(total: 100, type: "board"),
            "2026-08-16": DailyLoad(total: 100, type: "moon_board")
        ]
        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        XCTAssertEqual(
            TrainingLoad.heatmapLegendTypes(in: grid),
            ["board", "tindeq", "moon_board"],
            "palette order, unknown ids last — same ordering the legend always used"
        )
    }

    func testHeatmapHasVisibleLoadIsFalseOnlyForLoadFreeWindows() throws {
        let today = try XCTUnwrap(LocalDateSupport.date(from: "2026-08-18", timeZone: bangkok))

        let empty = TrainingLoad.heatmapGrid(daily: [:], today: today, weeks: 53, timeZone: bangkok)
        XCTAssertFalse(TrainingLoad.heatmapHasVisibleLoad(in: empty), "no records -> no colored cells")

        // A day whose sessions carry no load is a rest day: still no colored
        // cells, but it stays inside the map (the view renders rest grey).
        let restOnly = TrainingLoad.heatmapGrid(
            daily: ["2026-08-18": DailyLoad(total: 0, type: "board")],
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        XCTAssertFalse(TrainingLoad.heatmapHasVisibleLoad(in: restOnly))
        XCTAssertEqual(TrainingLoad.heatmapLegendTypes(in: restOnly), [])

        // A future-dated session (+1 day, allowed by DB `sessions_date_sane`)
        // is not visible load — future cells stay grey and unselectable.
        let futureOnly = TrainingLoad.heatmapGrid(
            daily: ["2026-08-19": DailyLoad(total: 5_000, type: "board")],
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        XCTAssertFalse(TrainingLoad.heatmapHasVisibleLoad(in: futureOnly))

        // Out-of-window history (older than the grid's start) is also not
        // rendered load — the sheet's honest empty state takes over.
        let oldOnly = TrainingLoad.heatmapGrid(
            daily: ["2020-01-02": DailyLoad(total: 500, type: "tindeq")],
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        XCTAssertFalse(TrainingLoad.heatmapHasVisibleLoad(in: oldOnly))
        XCTAssertEqual(TrainingLoad.heatmapLegendTypes(in: oldOnly), [])

        // One real past training day flips it to true.
        let trained = TrainingLoad.heatmapGrid(
            daily: ["2026-08-17": DailyLoad(total: 480, type: "board")],
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        XCTAssertTrue(TrainingLoad.heatmapHasVisibleLoad(in: trained))
        XCTAssertEqual(TrainingLoad.heatmapLegendTypes(in: trained), ["board"])
    }

    // MARK: - #895: Buddhist-era/Thai-locale window paths

    /// The reopened-symptom contract (#895): under a Buddhist-era device
    /// calendar (this suite runs on a Buddhist Calendar.current host; the
    /// assertions themselves are era-independent), the WINDOW ANCHOR's day
    /// key, the grid enumeration, the daily map keys, heatmapHasVisibleLoad,
    /// and the legend must ALL agree in the current era. A record stored with
    /// a Buddhist-era key (2569 = 2026 + 543) must land on a colored cell in
    /// the rendered 53-week window, and every rendered cell key must be a CE
    /// `20xx` day — never a `25xx` key the CE daily map cannot hit.
    func testBuddhistEraWindowAnchorDailyKeysAndGridAgreeOnCurrentEra() throws {
        let today = try XCTUnwrap(LocalDateSupport.date(from: "2026-09-01", timeZone: bangkok))
        // Sessions in the trailing month, stored as legacy Buddhist-era rows
        // and a timestamp payload — the historical-record shapes #887 pinned
        // for cell FILL; this test pins the WINDOW side of the same data.
        let sessions = [
            session("2569-08-20", "gym", 300),
            session("2569-08-30", "board", 420),
            session("2026-08-25T00:00:00Z", "auto", 100)
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions, timeZone: bangkok)

        XCTAssertNil(daily["2569-08-20"], "Buddhist-era keys must never reach the daily map")
        XCTAssertEqual(daily["2026-08-20"]?.total, 300)
        XCTAssertEqual(daily["2026-08-30"]?.total, 420)
        XCTAssertEqual(daily["2026-08-25"]?.total, 100)

        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        let cells = grid.columns.flatMap { $0 }
        XCTAssertFalse(
            cells.contains { $0.date.hasPrefix("25") || $0.date.hasPrefix("24") },
            "every rendered cell must be current-era (20xx); a 25xx/24xx grid key can never match the CE daily map"
        )
        let cellsByDate = Dictionary(uniqueKeysWithValues: cells.map { ($0.date, $0) })
        for (date, value) in [("2026-08-20", 300.0), ("2026-08-30", 420.0), ("2026-08-25", 100.0)] {
            let cell = try XCTUnwrap(cellsByDate[date], "trained day must be inside the window")
            XCTAssertEqual(cell.value, value)
            XCTAssertFalse(cell.future)
        }
        XCTAssertTrue(
            TrainingLoad.heatmapHasVisibleLoad(in: grid),
            "in-window historical records must flip the honest-empty branch off"
        )
        XCTAssertEqual(
            Set(TrainingLoad.heatmapLegendTypes(in: grid)),
            Set(["gym", "board", "auto"]),
            "legend derives from the rendered (era-normalized) cells"
        )
    }

    /// The view-window anchor itself must be a current-era day under a
    /// Buddhist-era representation of today: the anchor string "2569-09-04"
    /// (Buddhist year for 2026-09-04) normalizes through the canonical path
    /// to the same CE day the grid generates.
    func testBuddhistEraAnchorDayKeyNormalizesToGridsCurrentEraDay() throws {
        let anchorKey = try XCTUnwrap(
            LocalDateSupport.canonicalDayKey("2569-09-04", timeZone: bangkok)
        )
        XCTAssertEqual(anchorKey, "2026-09-04", "a Buddhist-era anchor key must land on the CE day")
        let gridFromCEAnchor = TrainingLoad.heatmapGrid(
            daily: [:],
            today: try XCTUnwrap(LocalDateSupport.date(from: "2026-09-04", timeZone: bangkok)),
            weeks: 53,
            timeZone: bangkok
        )
        // The window's rightmost column ends on the CE Saturday of the anchor
        // week; assert the whole grid walks current-era keys (2025/2026),
        // i.e. the window did not enumerate 543 years ahead of the daily map.
        let dates = gridFromCEAnchor.columns.flatMap { $0 }.map(\.date)
        XCTAssertTrue(dates.allSatisfy { $0.hasPrefix("2025") || $0.hasPrefix("2026") })
        XCTAssertEqual(gridFromCEAnchor.columns.last?.last?.date, "2026-09-05")
    }

    /// Legend advertising under era-normalized records: an activity whose
    /// sessions fall OUTSIDE the rendered window (even a Buddhist-era row
    /// that normalizes to an old CE year) must not be listed next to a grid
    /// that cannot show it (#895 keeps the #887 legend-window contract for
    /// the era path).
    func testBuddhistEraOutOfWindowRecordNotAdvertisedByLegend() throws {
        let today = try XCTUnwrap(LocalDateSupport.date(from: "2026-09-01", timeZone: bangkok))
        let sessions = [
            session("2569-08-28", "board", 420),   // -> 2026-08-28, in window
            session("2568-01-02", "tindeq", 500)   // -> 2025-01-02, out of window
        ]
        let daily = TrainingLoad.dailyLoads(sessions: sessions, timeZone: bangkok)
        let grid = TrainingLoad.heatmapGrid(
            daily: daily,
            today: today,
            weeks: 53,
            timeZone: bangkok
        )
        XCTAssertTrue(TrainingLoad.heatmapHasVisibleLoad(in: grid))
        XCTAssertEqual(
            TrainingLoad.heatmapLegendTypes(in: grid),
            ["board"],
            "the legend must list only what the rendered window paints"
        )
    }
}

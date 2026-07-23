import XCTest
@testable import SendLogHealthCore

/// Covers `Calendar.nightWindow`, the fixed overnight window HRV/sleep/resp
/// are read against in `HealthKitReader.readToday`. Pure date math only —
/// whether `HealthKitReader` actually wires this correctly against live
/// HealthKit data (and whether `HKQuery.predicateForSamples`'s default,
/// non-strict matching behaves as expected for samples straddling the
/// boundary) is device-only to verify; these tests don't and can't cover
/// that HealthKit-integration layer. #109's actual intraday-stability fix
/// lives in `ReadinessWritePolicyTests`, not here — resting HR deliberately
/// does *not* use this window (see the comment on its call sites).
final class DateSupportTests: XCTestCase {
    private let cal = Calendar.gregorianLocal

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testNightWindowSpans18hPrevDayToNoon() {
        let w = cal.nightWindow(endingOn: date(2026, 7, 23, 9, 0))
        XCTAssertEqual(w.start, date(2026, 7, 22, 18, 0))
        XCTAssertEqual(w.end, date(2026, 7, 23, 12, 0))
    }

    /// The window is a function of the calendar `day` passed in, not of what
    /// time it happens to be queried at — a morning call and an afternoon
    /// call for the same day must agree.
    func testNightWindowStableAcrossIntradayResync() {
        let morningWindow = cal.nightWindow(endingOn: date(2026, 7, 23, 7, 30))
        let afternoonWindow = cal.nightWindow(endingOn: date(2026, 7, 23, 15, 45))

        XCTAssertEqual(morningWindow.start, afternoonWindow.start)
        XCTAssertEqual(morningWindow.end, afternoonWindow.end)
    }

    func testNightWindowExcludesAfternoonSamples() {
        let w = cal.nightWindow(endingOn: date(2026, 7, 23, 8, 0))
        XCTAssertFalse(w.contains(date(2026, 7, 23, 14, 0)))
    }

    /// `DateInterval.contains` is inclusive of both endpoints — noon itself
    /// is still "in" the window, one second past it is not.
    func testNightWindowEndpointIsInclusive() {
        let w = cal.nightWindow(endingOn: date(2026, 7, 23, 8, 0))
        XCTAssertTrue(w.contains(w.end))
        XCTAssertFalse(w.contains(w.end.addingTimeInterval(1)))
    }

    func testNightWindowIncludesLateEveningAndEarlyMorningSamples() {
        let w = cal.nightWindow(endingOn: date(2026, 7, 23, 8, 0))
        XCTAssertTrue(w.contains(date(2026, 7, 22, 22, 0))) // 10pm the night before
        XCTAssertTrue(w.contains(date(2026, 7, 23, 6, 0)))  // 6am same morning
    }

    /// Regression guard for the DST review nit: computing the start as
    /// "noon minus 18 hours" (raw absolute-time arithmetic) shifts the
    /// wall-clock start by an hour when `endingOn` itself is the
    /// spring-forward day (the old formula landed on 17:00, not 18:00 —
    /// verified against the pre-fix math). Setting 18:00 on the previous
    /// calendar day directly, as the current implementation does, is
    /// unaffected by the transition.
    func testNightWindowStartIsWallClock18hOnSpringForwardDay() {
        var tzCal = Calendar(identifier: .gregorian)
        // US Eastern, 2026: DST begins 2026-03-08 (spring forward, 2am -> 3am).
        tzCal.timeZone = TimeZone(identifier: "America/New_York")!
        let springForwardDay = tzCal.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 9
        ))!
        let w = tzCal.nightWindow(endingOn: springForwardDay)
        let expectedStart = tzCal.date(from: DateComponents(
            year: 2026, month: 3, day: 7, hour: 18
        ))!
        XCTAssertEqual(w.start, expectedStart)
    }

    /// Same regression, fall-back direction: the old "noon minus 18 hours"
    /// formula landed on 19:00 the previous day (verified against the
    /// pre-fix math) instead of the correct wall-clock 18:00.
    func testNightWindowStartIsWallClock18hOnFallBackDay() {
        var tzCal = Calendar(identifier: .gregorian)
        // US Eastern, 2026: DST ends 2026-11-01 (fall back, 2am -> 1am).
        tzCal.timeZone = TimeZone(identifier: "America/New_York")!
        let fallBackDay = tzCal.date(from: DateComponents(
            year: 2026, month: 11, day: 1, hour: 9
        ))!
        let w = tzCal.nightWindow(endingOn: fallBackDay)
        let expectedStart = tzCal.date(from: DateComponents(
            year: 2026, month: 10, day: 31, hour: 18
        ))!
        XCTAssertEqual(w.start, expectedStart)
    }
}

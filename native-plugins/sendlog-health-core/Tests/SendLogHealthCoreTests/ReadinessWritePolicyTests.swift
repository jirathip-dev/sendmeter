import XCTest
@testable import SendLogHealthCore

/// #109: an automatic (HealthKit background/foreground-driven) re-sync
/// must not keep overwriting today's already-computed readiness through the
/// day.
final class ReadinessWritePolicyTests: XCTestCase {
    private let cal = Calendar.gregorianLocal

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testMorningAutomaticRecomputeAllowed() {
        let now = date(2026, 7, 23, 9, 0)
        // Existing readiness from an earlier automatic sync, still before noon.
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: 62,
            existingRowDate: now.localDateString,
            now: now,
            trigger: .automatic,
            calendar: cal
        )
        XCTAssertTrue(allow)
    }

    func testAfternoonAutomaticBlockedWhenReadinessExists() {
        let now = date(2026, 7, 23, 15, 0)
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: 100,
            existingRowDate: now.localDateString,
            now: now,
            trigger: .automatic,
            calendar: cal
        )
        XCTAssertFalse(allow)
    }

    func testAfternoonManualAlwaysAllowed() {
        let now = date(2026, 7, 23, 21, 0)
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: 100,
            existingRowDate: now.localDateString,
            now: now,
            trigger: .manual,
            calendar: cal
        )
        XCTAssertTrue(allow)
    }

    /// First compute of the day happening late (phone locked all morning,
    /// or the user only unlocks it — and thus gets a background wake —
    /// after noon) must still write; a day can't be left scoreless.
    func testAfternoonAutomaticAllowedWhenNoReadinessYet() {
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: nil,
            existingRowDate: nil, // no row for today
            now: date(2026, 7, 23, 16, 0),
            trigger: .automatic,
            calendar: cal
        )
        XCTAssertTrue(allow)
    }

    /// A row is scoped to a single `date`, so "yesterday's" row is simply not
    /// what gets passed in for a new day — the caller looks up today's row,
    /// finds none, and the lock never engages.
    func testNextDayAutomaticAllowed() {
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: nil, // no row yet for the new date
            existingRowDate: nil,
            now: date(2026, 7, 24, 6, 0),
            trigger: .automatic,
            calendar: cal
        )
        XCTAssertTrue(allow)
    }

    /// Self-defense: even if `existingReadiness` is non-nil, a row whose own
    /// `date` string doesn't match today's must not be trusted as "today
    /// already scored" — guards against a caller bug in the lookup query
    /// (stale cache, wrong filter) locking the wrong day.
    func testRowDateMismatchIsNotTrustedAsLocked() {
        let now = date(2026, 7, 23, 15, 0)
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: 100,
            existingRowDate: "2026-07-22", // yesterday, not today
            now: now,
            trigger: .automatic,
            calendar: cal
        )
        XCTAssertTrue(allow)
    }

    func testExactlyNoonIsNoLongerBeforeNoon() {
        let now = date(2026, 7, 23, 12, 0)
        let allow = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: 50,
            existingRowDate: now.localDateString,
            now: now,
            trigger: .automatic,
            calendar: cal
        )
        XCTAssertFalse(allow)
    }
}

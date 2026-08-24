import Foundation
import XCTest
@testable import SendLogWatch_Watch_App

/// #486: `Repo.insertTindeqRecording` used to be a bare `try await …insert(…)`
/// with no offline queue at all — unlike workouts (`OfflineQueue`) and gauge
/// sessions (`PendingSessionQueue`), a Tindeq force recording had no on-disk
/// fallback, so a gym-basement network drop right at Stop lost the rep
/// outright. `PendingRecordingQueue` (mirroring those two exactly) fixes
/// that, but it can only replay a queued upload safely if the SAME row
/// (including its `id`) survives being written to disk and read back — a
/// retry that re-minted a fresh id, or dropped it, would either duplicate
/// the recording server-side or defeat the idempotent upsert entirely. This
/// is the host-testable half of that guarantee (the actor's file I/O and
/// network call aren't reachable from a unit test without a live Supabase
/// session — same limitation `OfflineQueue`/`PendingSessionQueue` already
/// have, which is why neither has an actor-level test either); it pins the
/// two things that are pure and would silently regress otherwise.
final class PendingTindeqRecordingTests: XCTestCase {
    private func fixtureRecording() -> StoppedRecording {
        StoppedRecording(
            durationMs: 12_000,
            peakKg: 34.5,
            avgKg: 28.1,
            samples: [(t: 0, kg: 0), (t: 1000, kg: 34.5)]
        )
    }

    /// The bug this fix exists to prevent: `Repo.makeTindeqRecordingRow` must
    /// carry through the EXACT id the caller mints, not generate its own —
    /// otherwise every retry of a queued upload would insert a duplicate row
    /// instead of upserting over the original.
    func testMakeRowCarriesTheExactIdItWasGiven() {
        let id = UUID()
        let row = Repo.makeTindeqRecordingRow(
            fixtureRecording(), id: id, note: "", tag: "FDP", side: "left", groupId: nil
        )
        XCTAssertEqual(row.id, id)
    }

    /// Two different callers (e.g. `saveStop()` and `salvageInterruptedRecording`)
    /// mint independent ids — nothing in row-building coalesces them, which
    /// would silently merge two distinct reps into one upsert.
    func testDifferentIdsProduceDifferentRows() {
        let a = Repo.makeTindeqRecordingRow(
            fixtureRecording(), id: UUID(), note: "", tag: "FDP", side: "left", groupId: nil
        )
        let b = Repo.makeTindeqRecordingRow(
            fixtureRecording(), id: UUID(), note: "", tag: "FDP", side: "left", groupId: nil
        )
        XCTAssertNotEqual(a.id, b.id)
    }

    /// The property `PendingRecordingQueue.drain()` depends on: a row
    /// persisted to disk (as part of a `PendingTindeqRecording`) and read
    /// back still carries the same id, so a retry after an app relaunch
    /// upserts over the original insert instead of duplicating it.
    func testRowIdSurvivesDiskRoundTrip() throws {
        let id = UUID()
        let groupId = UUID()
        let row = Repo.makeTindeqRecordingRow(
            fixtureRecording(), id: id, note: "Recovered after connection loss",
            tag: "FDP", side: "left", groupId: groupId
        )
        let pending = PendingTindeqRecording(row: row, enqueuedUserId: UUID())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pending)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PendingTindeqRecording.self, from: data)

        XCTAssertEqual(decoded.row.id, id)
        XCTAssertEqual(decoded.row.groupId, groupId)
        XCTAssertEqual(decoded.row.note, "Recovered after connection loss")
        XCTAssertEqual(decoded.enqueuedUserId, pending.enqueuedUserId)
    }

    /// `enqueuedUserId` stays a legal `nil` for a genuinely legacy/unstamped
    /// item so the decoder can retain it for an explicit recovery path, but
    /// #747's `shouldDrain` policy quarantines it rather than guessing an
    /// owner. #529 slice 2 removed the memberwise init's default so every
    /// PRODUCTION call site must pass it explicitly (mirrors
    /// `WorkoutSaveBundle.enqueuedUserId`); this pins that `nil` is still a
    /// legal stored VALUE, not a convenience default a caller could forget.
    func testEnqueuedUserIdNilIsStillALegalLegacyValue() {
        let row = Repo.makeTindeqRecordingRow(
            fixtureRecording(), id: UUID(), note: "", tag: "FDP", side: "left", groupId: nil
        )
        let pending = PendingTindeqRecording(row: row, enqueuedUserId: nil)
        XCTAssertNil(pending.enqueuedUserId)
    }

    /// The wire shape PostgREST expects: snake_case keys, `id` present and
    /// NOT silently omitted (a bare `insert` with no id relied on the
    /// column's `gen_random_uuid()` default — #486 deliberately stops doing
    /// that so retries can upsert).
    func testRowEncodesTheIdAndSnakeCaseKeys() throws {
        let id = UUID()
        let row = Repo.makeTindeqRecordingRow(
            fixtureRecording(), id: id, note: "", tag: "FDP", side: "left", groupId: nil
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(row)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, id.uuidString)
        XCTAssertNotNil(json["duration_ms"])
        XCTAssertNotNil(json["peak_kg"])
        XCTAssertNotNil(json["avg_kg"])
        XCTAssertNotNil(json["sample_count"])
    }
}

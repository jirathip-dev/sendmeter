import Foundation
import XCTest
@testable import SendLogWatch_Watch_App

/// Issue #477 review finding F1. Swift's synthesized `Encodable` uses
/// `encodeIfPresent` for every `Optional` property, which OMITS the key
/// entirely when the value is nil — not the same as encoding JSON `null`.
/// `LiveWorkoutSync.upsert` sends `LiveWorkoutUpsert` straight to
/// PostgREST's `upsert(row, onConflict: "user_id")`, which only overwrites
/// columns present in the request body. An omitted `hr` key therefore left
/// `live_workouts.hr` at its last non-nil value forever — the exact "stale
/// reading survives as if live" bug #477 exists to close, just moved onto
/// the wire instead of fixed. `LiveWorkoutUpsert.encode(to:)` is now
/// hand-written so `hr` specifically encodes an explicit `null`.
///
/// Pure Foundation — no HealthKit, no network, runs in this host like any
/// other unit test.
final class LiveWorkoutUpsertEncodingTests: XCTestCase {
    private func encode(_ row: LiveWorkoutUpsert) throws -> [String: Any] {
        let data = try JSONEncoder().encode(row)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sampleRow(hr: Double?) -> LiveWorkoutUpsert {
        LiveWorkoutUpsert(
            userId: UUID(), workoutId: UUID(), status: "live",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hr: hr, attemptCount: 3, activeKcal: nil, elevationGainM: nil,
            climbing: false, climbingSince: nil, restStartedAt: nil,
            restTargetS: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    /// The load-bearing case: a nil `hr` must be a PRESENT key with a JSON
    /// `null` value — not absent from the body at all.
    func testNilHRIsEncodedAsAnExplicitJSONNullNotOmitted() throws {
        let object = try encode(sampleRow(hr: nil))
        XCTAssertTrue(object.keys.contains("hr"), "the hr key must be present in the upsert body, not omitted")
        XCTAssertTrue(object["hr"] is NSNull, "a nil hr must serialize as JSON null so PostgREST actually overwrites the column")
    }

    /// A present HR value must still round-trip as its numeric value.
    func testFreshHRIsEncodedAsItsNumericValue() throws {
        let object = try encode(sampleRow(hr: 142))
        XCTAssertEqual(object["hr"] as? Double, 142)
    }

    /// The other optionals deliberately keep the omit-when-nil default
    /// (`markEnded()` relies on this to avoid stomping those columns with
    /// null) — pin that this fix did not flip every field to explicit null.
    func testOtherOptionalFieldsStayOmittedWhenNil() throws {
        let object = try encode(sampleRow(hr: nil))
        XCTAssertFalse(object.keys.contains("active_kcal"), "active_kcal must stay omitted when nil (markEnded() relies on this)")
        XCTAssertFalse(object.keys.contains("elevation_gain_m"), "elevation_gain_m must stay omitted when nil")
        XCTAssertFalse(object.keys.contains("climbing_since"), "climbing_since must stay omitted when nil")
        XCTAssertFalse(object.keys.contains("rest_started_at"), "rest_started_at must stay omitted when nil")
        XCTAssertFalse(object.keys.contains("rest_target_s"), "rest_target_s must stay omitted when nil")
    }

    /// Every non-optional field must still be present — a hand-written
    /// `encode(to:)` is exactly the kind of change that can silently drop a
    /// field on a typo.
    func testAllNonOptionalFieldsArePresent() throws {
        let object = try encode(sampleRow(hr: nil))
        for key in ["user_id", "workout_id", "status", "started_at", "attempt_count", "climbing", "updated_at"] {
            XCTAssertTrue(object.keys.contains(key), "expected \(key) to be present in the encoded body")
        }
    }
}

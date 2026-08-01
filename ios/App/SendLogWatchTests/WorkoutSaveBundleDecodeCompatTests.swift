import Foundation
import XCTest
@testable import SendLogWatch_Watch_App

final class WorkoutSaveBundleDecodeCompatTests: XCTestCase {
    /// Frozen JSON from the previous on-disk bundle shape, before the optional
    /// account stamp was added. Keep this hand-written: encoding today's model
    /// in the test would make it impossible to catch a future incompatible
    /// Codable change before drain silently strands old-build workouts.
    private let previousWorkoutSaveBundle = #"""
    {
      "session": {
        "id": "11111111-1111-1111-1111-111111111111",
        "date": "2026-07-24",
        "type": "bouldering",
        "type_label": "Bouldering",
        "duration_min": 42,
        "rpe": 7.2,
        "rpe_confirmed": true,
        "note": "3 boulders",
        "phase": "capacity",
        "workout_source": "watch"
      },
      "workout": {
        "id": "22222222-2222-2222-2222-222222222222",
        "started_at": "2026-07-24T02:00:00Z",
        "ended_at": "2026-07-24T02:42:00Z",
        "avg_hr": 132.5,
        "max_hr": 171,
        "active_kcal": 318.4,
        "elevation_gain_m": 9.2,
        "attempts_detected": 3,
        "attempts_confirmed": 3,
        "rpe_predicted": 7.2,
        "rpe_confirmed": 7.2,
        "mean_effort": 68.4,
        "attempts_per_10min": 0.71,
        "session_id": "11111111-1111-1111-1111-111111111111",
        "raw": [[0, 12.1, 0.08, 118], [1, 12.2, null, 121]]
      },
      "attempts": [
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "workout_id": "22222222-2222-2222-2222-222222222222",
          "started_at": "2026-07-24T02:05:00Z",
          "duration_s": 24.5,
          "elevation_gain_m": 3.1,
          "avg_hr": 148,
          "peak_hr": 166,
          "motion_intensity": 0.83,
          "effort_score": 72.4,
          "source": "auto"
        }
      ]
    }
    """#

    func testWorkoutSaveBundleDecodesFrozenPreviousShape() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            WorkoutSaveBundle.self,
            from: Data(previousWorkoutSaveBundle.utf8)
        )

        XCTAssertEqual(decoded.session.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(decoded.session.durationMin, 42)
        XCTAssertEqual(decoded.session.rpeConfirmed, true)
        XCTAssertEqual(decoded.workout.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(decoded.workout.raw?.count, 2)
        XCTAssertEqual(decoded.attempts.count, 1)
        XCTAssertEqual(decoded.attempts[0].source, "auto")
        XCTAssertNil(decoded.enqueuedUserId)
    }
}

import Foundation
import XCTest
import SendLogWatchCore

final class PendingQueueDecodeCompatTests: XCTestCase {
    /// Frozen JSON written by the model before `rpeConfirmed` and
    /// `enqueuedUserId` were added. This must stay a literal rather than being
    /// re-encoded from today's type, or a future incompatible Codable change
    /// would update both sides of the test and hide the data loss.
    private let previousPendingTindeqSession = #"""
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "date": "2026-07-24",
      "durationMin": 17,
      "rpe": 6.5,
      "note": "11 recordings",
      "groupId": "22222222-2222-2222-2222-222222222222"
    }
    """#

    func testPendingTindeqSessionDecodesFrozenPreviousShape() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            PendingTindeqSession.self,
            from: Data(previousPendingTindeqSession.utf8)
        )

        XCTAssertEqual(decoded.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(decoded.date, "2026-07-24")
        XCTAssertEqual(decoded.durationMin, 17)
        XCTAssertEqual(decoded.rpe, 6.5)
        XCTAssertEqual(decoded.note, "11 recordings")
        XCTAssertEqual(decoded.groupId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertNil(decoded.rpeConfirmed)
        XCTAssertNil(decoded.enqueuedUserId)
    }
}

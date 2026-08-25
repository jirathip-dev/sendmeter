import XCTest
@testable import SendmeterCore

final class PendingSessionWritePolicyTests: XCTestCase {
    func testSessionAndWorkoutInsertsShareDeleteBarrierAndRestoreSuppression() {
        let sessionID = UUID()
        let otherID = UUID()
        let remote: Set<UUID> = []
        let inserts: [PendingSessionInsert] = [
            .loggedSession(sessionID: sessionID),
            .manualWorkout(sessionID: sessionID)
        ]

        for insert in inserts {
            XCTAssertTrue(
                PendingSessionDeletePolicy.matches(
                    insert: insert,
                    deleteSessionID: sessionID
                )
            )
            XCTAssertFalse(
                PendingSessionDeletePolicy.matches(
                    insert: insert,
                    deleteSessionID: otherID
                )
            )
            XCTAssertTrue(
                PendingSessionDeletePolicy.shouldDrainDeleteAfterInsert(insert)
            )
            XCTAssertFalse(
                PendingSessionDeletePolicy.shouldRestore(
                    insert: insert,
                    remoteSessionIDs: remote,
                    deleteIsClaimed: true
                )
            )
            XCTAssertTrue(
                PendingSessionDeletePolicy.shouldRestore(
                    insert: insert,
                    remoteSessionIDs: remote,
                    deleteIsClaimed: false
                )
            )
            XCTAssertFalse(
                PendingSessionDeletePolicy.shouldRestore(
                    insert: insert,
                    remoteSessionIDs: [sessionID],
                    deleteIsClaimed: false
                )
            )
        }
    }

    func testPendingDeleteCopyDistinguishesManualWorkoutFromSession() {
        XCTAssertEqual(
            PendingSessionDeletePolicy.successMessage(for: .manualWorkout),
            "Workout deleted."
        )
        XCTAssertEqual(
            PendingSessionDeletePolicy.successMessage(for: .session),
            "Session deleted."
        )
    }
}

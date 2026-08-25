import XCTest
@testable import SendmeterCore

final class WatchMetadataTests: XCTestCase {
    func testWireKeysMatchTheWatchStampedKeys() {
        XCTAssertEqual(WatchMetadata.accountUserIdKey, "account_user_id")
        XCTAssertEqual(WatchMetadata.versionKey, "watch_app_version")
        XCTAssertEqual(WatchMetadata.buildKey, "watch_app_build")
        XCTAssertEqual(WatchMetadata.pendingSyncKey, "watch_pending_sync")
        XCTAssertEqual(WatchMetadata.unscopedSyncKey, "watch_unscoped_sync")
        XCTAssertEqual(WatchMetadata.quarantinedSyncKey, "watch_quarantined_sync")
        XCTAssertEqual(WatchMetadata.quarantinedStuckSyncKey, "watch_quarantined_stuck_sync")
    }

    func testParsesWatchShapedMessage() {
        let message: [String: Any] = [
            "kind": "queueStatus",
            WatchMetadata.accountUserIdKey: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            WatchMetadata.versionKey: "1.4.0",
            WatchMetadata.buildKey: "57",
            WatchMetadata.pendingSyncKey: 3,
            WatchMetadata.unscopedSyncKey: 1,
            WatchMetadata.quarantinedSyncKey: 2,
            WatchMetadata.quarantinedStuckSyncKey: 1
        ]

        let metadata = WatchMetadata.parse(message)

        XCTAssertEqual(
            metadata.accountUserID,
            UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        )
        XCTAssertEqual(metadata.version, "1.4.0")
        XCTAssertEqual(metadata.build, "57")
        XCTAssertEqual(metadata.pendingSync, 3)
        XCTAssertEqual(metadata.unscopedSync, 1)
        XCTAssertEqual(metadata.quarantinedSync, 2)
        XCTAssertEqual(metadata.quarantinedStuckSync, 1)
    }

    func testMissingFieldsParseAsNilNotZero() {
        let message: [String: Any] = ["kind": "liveWorkout"]

        let metadata = WatchMetadata.parse(message)

        XCTAssertNil(metadata.version)
        XCTAssertNil(metadata.accountUserID)
        XCTAssertNil(metadata.build)
        XCTAssertNil(metadata.pendingSync)
        XCTAssertNil(metadata.quarantinedSync)
        XCTAssertNil(metadata.quarantinedStuckSync)
    }

    func testCountsWidenFromDoubleAndRejectNegative() {
        let doubleCounts: [String: Any] = [
            WatchMetadata.pendingSyncKey: 2.0,
            WatchMetadata.quarantinedSyncKey: 1.0,
            WatchMetadata.quarantinedStuckSyncKey: 0.0
        ]
        let widened = WatchMetadata.parse(doubleCounts)
        XCTAssertEqual(widened.pendingSync, 2)
        XCTAssertEqual(widened.quarantinedSync, 1)
        XCTAssertEqual(widened.quarantinedStuckSync, 0)

        let negative: [String: Any] = [
            WatchMetadata.pendingSyncKey: -1,
            WatchMetadata.quarantinedSyncKey: -1.0,
            WatchMetadata.quarantinedStuckSyncKey: -2
        ]
        let rejected = WatchMetadata.parse(negative)
        XCTAssertNil(rejected.pendingSync)
        XCTAssertNil(rejected.quarantinedSync)
        XCTAssertNil(rejected.quarantinedStuckSync)
    }
}

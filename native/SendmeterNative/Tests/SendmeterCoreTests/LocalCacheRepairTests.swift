import Foundation
import GRDB
import XCTest
@testable import SendmeterCore

/// #1004 half 2: an undecodable STORED payload must not dead-end the app.
///
/// The launch path hydrates through the coherent read, and that read used to
/// `try?`-skip a row it could not decode — silently. The row stayed in
/// `cache_rows` forever while its data vanished from every surface, and no
/// refresh could heal it (an incremental delta only returns rows whose
/// `updated_at` moved). These tests pin the replacement:
///
/// * the read REPORTS the row instead of dropping it silently,
/// * a row whose authoritative copy is on the server is set aside with its raw
///   payload preserved, and its entity's cursor is reset so the next refresh
///   rebuilds it,
/// * a PENDING row — the only copy of a real un-uploaded recording — is never
///   touched.
final class LocalCacheRepairTests: XCTestCase {
    private let account = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let legacyRecordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let readableRecordingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeStore() throws -> LocalCacheStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-cache-repair-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try LocalCacheStore(databaseURL: url)
    }

    /// A payload in the PREVIOUS build's shape, as a build that predates
    /// `protocolMode`/`capacityEvidence`/`completionStatus` wrote it: the same
    /// recording, with the peak stored under the old key and no protocol mode.
    /// It is valid JSON, so nothing about it looks broken — it simply cannot be
    /// decoded into the type this build asks for.
    private func legacyRecordingPayload(id: UUID) -> String {
        """
        {
          "id": "\(id.uuidString)",
          "recordedAt": "2024-05-01T10:00:00Z",
          "durationMilliseconds": 5000,
          "maxKilograms": 21.5,
          "sampleCount": 120,
          "note": "old build",
          "tag": "campus",
          "side": "left",
          "zone": "strength"
        }
        """
    }

    private func makeReadableRecording(id: UUID) -> TindeqRecording {
        TindeqRecording(
            id: id,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 5000,
            peakKilograms: 12.3,
            averageKilograms: 10.1,
            sampleCount: 120,
            note: "sharp holds",
            tag: "campus",
            side: .left,
            groupID: nil,
            zone: .strength
        )
    }

    /// Inserts a raw row the way a previous build's cache would have left it.
    private func insertRawRow(
        in store: LocalCacheStore,
        entityType: LocalCacheEntityType,
        entityID: String,
        payload: String,
        pending: Bool,
        writeOrigin: String = "server"
    ) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload,
                         deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?)
                    """,
                arguments: [
                    account.uuidString,
                    entityType.rawValue,
                    entityID,
                    payload,
                    "2026-09-01T00:00:00.000000Z",
                    writeOrigin,
                    pending ? 1 : 0,
                    pending ? 1 : 0,
                ]
            )
        }
    }

    // MARK: - The read reports, never silently drops

    func testCoherentReadReportsAnUndecodableRowInsteadOfDroppingItSilently() throws {
        let store = try makeStore()
        try insertRawRow(
            in: store,
            entityType: .recordings,
            entityID: legacyRecordingID.uuidString,
            payload: legacyRecordingPayload(id: legacyRecordingID),
            pending: false
        )
        let readable = makeReadableRecording(id: readableRecordingID)
        try store.upsertServer(
            readable,
            accountUserID: account,
            entityType: .recordings,
            entityID: readable.id.uuidString,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let read = try store.coherentSnapshotRead(accountUserID: account)

        XCTAssertEqual(
            read.invalidRows,
            [
                LocalCacheInvalidRow(
                    entityType: .recordings,
                    entityID: legacyRecordingID.uuidString,
                    isPending: false
                )
            ],
            "the launch path must be TOLD about the unreadable row"
        )
        XCTAssertEqual(read.snapshot.recordings.map(\.id), [readableRecordingID])
    }

    // MARK: - Quarantine + heal

    func testQuarantinePreservesTheRawPayloadAndResetsTheCursorToHeal() throws {
        let store = try makeStore()
        try insertRawRow(
            in: store,
            entityType: .recordings,
            entityID: legacyRecordingID.uuidString,
            payload: legacyRecordingPayload(id: legacyRecordingID),
            pending: false
        )
        let readable = makeReadableRecording(id: readableRecordingID)
        try store.upsertServer(
            readable,
            accountUserID: account,
            entityType: .recordings,
            entityID: readable.id.uuidString,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try store.setCursor("2026-09-01T00:00:00.000000Z", accountUserID: account, entityType: .recordings)
        let read = try store.coherentSnapshotRead(accountUserID: account)

        let report = try store.quarantineInvalidRows(read.invalidRows, accountUserID: account)

        XCTAssertEqual(report.quarantinedCount, 1)
        XCTAssertEqual(report.preservedPendingCount, 0)
        XCTAssertEqual(report.healedEntityTypes, [.recordings])
        XCTAssertEqual(
            report.quarantined.first?.payload,
            legacyRecordingPayload(id: legacyRecordingID),
            "the unreadable payload is preserved VERBATIM for a later build"
        )
        XCTAssertEqual(report.quarantined.first?.reason, LocalCacheStore.undecodablePayloadReason)

        // The row is gone from the serve set, its payload is not.
        let quarantined = try store.quarantinedRows(accountUserID: account)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined.first?.entityID, legacyRecordingID.uuidString)
        XCTAssertEqual(quarantined.first?.payload, legacyRecordingPayload(id: legacyRecordingID))
        let after = try store.coherentSnapshotRead(accountUserID: account)
        XCTAssertTrue(after.invalidRows.isEmpty)
        XCTAssertEqual(after.snapshot.recordings.map(\.id), [readableRecordingID])

        // Cursor (and boundary) reset: the next refresh is a full reconcile,
        // which is how the removed row comes back from the server.
        XCTAssertNil(try store.cursor(accountUserID: account, entityType: .recordings))
        XCTAssertFalse(try store.hasCompletedSync(accountUserID: account, entityType: .recordings))
    }

    // MARK: - Un-synced data is never touched

    func testAPendingUndecodableRowIsPreservedInPlace() throws {
        let store = try makeStore()
        try insertRawRow(
            in: store,
            entityType: .recordings,
            entityID: legacyRecordingID.uuidString,
            payload: legacyRecordingPayload(id: legacyRecordingID),
            pending: true,
            writeOrigin: "local"
        )
        try store.setCursor("2026-09-01T00:00:00.000000Z", accountUserID: account, entityType: .recordings)
        let read = try store.coherentSnapshotRead(accountUserID: account)

        XCTAssertEqual(read.invalidRows.map(\.isPending), [true])

        let report = try store.quarantineInvalidRows(read.invalidRows, accountUserID: account)

        XCTAssertEqual(report.quarantinedCount, 0, "an un-synced payload is never quarantined")
        XCTAssertEqual(report.preservedPendingCount, 1)
        XCTAssertTrue(report.healedEntityTypes.isEmpty, "no cursor reset: nothing is being refetched")
        XCTAssertTrue(try store.quarantinedRows(accountUserID: account).isEmpty)

        // The row — and the only copy of that recording — is still there.
        let rows = try store.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT entity_id, payload, pending FROM cache_rows
                    WHERE account_user_id = ? AND entity_type = ?
                    """,
                arguments: [account.uuidString, LocalCacheEntityType.recordings.rawValue]
            ).map { ($0["entity_id"] as String, $0["payload"] as String, $0["pending"] as Int) }
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.0, legacyRecordingID.uuidString)
        XCTAssertEqual(rows.first?.1, legacyRecordingPayload(id: legacyRecordingID))
        XCTAssertEqual(rows.first?.2, 1)
        XCTAssertNotNil(try store.cursor(accountUserID: account, entityType: .recordings))

        // The notice states both halves: what was set aside, and that unsynced
        // data was not.
        XCTAssertTrue(report.message.contains("unsynced"))
    }

    func testACleanRowInAnotherEntityTypeIsUntouchedByASiblingRepair() throws {
        let store = try makeStore()
        try insertRawRow(
            in: store,
            entityType: .recordings,
            entityID: legacyRecordingID.uuidString,
            payload: legacyRecordingPayload(id: legacyRecordingID),
            pending: false
        )
        let readable = makeReadableRecording(id: readableRecordingID)
        try store.upsertServer(
            readable,
            accountUserID: account,
            entityType: .recordings,
            entityID: readable.id.uuidString,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try store.setCursor("2026-09-01T00:00:00.000000Z", accountUserID: account, entityType: .sessions)
        let read = try store.coherentSnapshotRead(accountUserID: account)

        _ = try store.quarantineInvalidRows(read.invalidRows, accountUserID: account)

        XCTAssertEqual(
            try store.cursor(accountUserID: account, entityType: .sessions),
            "2026-09-01T00:00:00.000000Z",
            "only the entity whose row was set aside is refetched"
        )
        let after = try store.coherentSnapshotRead(accountUserID: account)
        XCTAssertEqual(after.snapshot.recordings.map(\.id), [readableRecordingID])
    }

    /// Two accounts share one file: a repair for one must not reach the other.
    func testRepairIsAccountScoped() throws {
        let other = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let store = try makeStore()
        try insertRawRow(
            in: store,
            entityType: .recordings,
            entityID: legacyRecordingID.uuidString,
            payload: legacyRecordingPayload(id: legacyRecordingID),
            pending: false
        )
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_rows
                        (account_user_id, entity_type, entity_id, payload,
                         deleted_at, updated_at, write_origin, pending, local_revision)
                    VALUES (?, 'recordings', ?, ?, NULL, ?, 'server', 0, 0)
                    """,
                arguments: [
                    other.uuidString,
                    self.legacyRecordingID.uuidString,
                    self.legacyRecordingPayload(id: self.legacyRecordingID),
                    "2026-09-01T00:00:00.000000Z",
                ]
            )
        }

        let read = try store.coherentSnapshotRead(accountUserID: account)
        _ = try store.quarantineInvalidRows(read.invalidRows, accountUserID: account)

        let otherRead = try store.coherentSnapshotRead(accountUserID: other)
        XCTAssertEqual(otherRead.invalidRows.count, 1, "another account's row is untouched")
        XCTAssertTrue(try store.quarantinedRows(accountUserID: other).isEmpty)
    }
}

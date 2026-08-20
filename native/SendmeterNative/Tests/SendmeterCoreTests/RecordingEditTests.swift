import XCTest
@testable import SendmeterCore

final class RecordingEditTests: XCTestCase {
    private let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000676")!
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000677")!
    private let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000678")!

    private func recording() -> TindeqRecording {
        TindeqRecording(
            id: recordingID,
            recordedAt: Date(timeIntervalSince1970: 1_000),
            durationMilliseconds: 12_000,
            peakKilograms: 42.5,
            averageKilograms: 31.25,
            sampleCount: 960,
            note: "before",
            tag: "Old grip",
            side: .left,
            groupID: sessionID,
            protocolRunID: otherID,
            setNumber: 2,
            zone: .strength,
            targetKilograms: 35
        )
    }

    private func session() -> Session {
        Session(
            id: sessionID,
            date: "2026-08-20",
            type: "tindeq",
            typeLabel: "Tindeq",
            durationMinutes: 18,
            rpe: 6.5,
            rpeConfirmed: false,
            load: 117,
            note: "predicted",
            phase: .strength,
            groupID: sessionID
        )
    }

    func testReducerChangesOnlyEditableRecordingMetadata() {
        let edit = RecordingEdit(
            recordingID: recordingID,
            tag: "  FDP  ",
            side: .right,
            note: "  tweaky  ",
            sessionID: sessionID,
            sessionRPE: 8.5
        )

        let updated = RecordingEditReducer.apply(edit, to: recording())

        XCTAssertEqual(updated.tag, "FDP")
        XCTAssertEqual(updated.side, .right)
        XCTAssertEqual(updated.note, "tweaky")
        XCTAssertEqual(updated.id, recordingID)
        XCTAssertEqual(updated.recordedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(updated.durationMilliseconds, 12_000)
        XCTAssertEqual(updated.peakKilograms, 42.5)
        XCTAssertEqual(updated.averageKilograms, 31.25)
        XCTAssertEqual(updated.sampleCount, 960)
        XCTAssertEqual(updated.groupID, sessionID)
        XCTAssertEqual(updated.protocolRunID, otherID)
        XCTAssertEqual(updated.targetKilograms, 35)
    }

    func testReducerUpdatesOnlyTheMatchingLinkedSessionAndConfirmsRPE() {
        let edit = RecordingEdit(
            recordingID: recordingID,
            tag: "FDP",
            side: .right,
            note: "",
            sessionID: sessionID,
            sessionRPE: 8.5
        )

        let updated = RecordingEditReducer.apply(edit, to: session())
        XCTAssertEqual(updated.rpe, 8.5)
        XCTAssertTrue(updated.rpeConfirmed)
        XCTAssertEqual(updated.load, 153)
        XCTAssertEqual(updated.note, "predicted")
        XCTAssertEqual(updated.durationMinutes, 18)

        let unrelated = RecordingEditReducer.apply(edit, to: Session(
            id: otherID,
            date: "2026-08-20",
            type: "gym",
            typeLabel: "Gym Session",
            durationMinutes: 60,
            rpe: 4,
            note: "untouched",
            phase: .capacity
        ))
        XCTAssertEqual(unrelated.rpe, 4)
        XCTAssertEqual(unrelated.note, "untouched")
    }

    /// The repository's two PATCH methods encode these public payload types;
    /// pin their wire shape here without requiring a live Supabase session.
    func testRepositoryPatchPayloadsContainOnlyNarrowPatchFields() throws {
        let edit = RecordingEdit(
            recordingID: recordingID,
            tag: "FDP",
            side: .right,
            note: "after",
            sessionID: sessionID,
            sessionRPE: 8.5
        )
        let encoder = JSONEncoder()

        let metadata = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: encoder.encode(edit.recordingPayload)
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(metadata.keys), Set(["tag", "side", "note"]))
        XCTAssertEqual(metadata["tag"] as? String, "FDP")
        XCTAssertEqual(metadata["side"] as? String, "right")
        XCTAssertEqual(metadata["note"] as? String, "after")
        XCTAssertNil(metadata["samples"])

        let sessionPayload = try XCTUnwrap(edit.sessionPayload)
        let effort = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: encoder.encode(sessionPayload)
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(effort.keys), Set(["rpe", "rpe_confirmed"]))
        XCTAssertEqual(effort["rpe"] as? Double, 8.5)
        XCTAssertEqual(effort["rpe_confirmed"] as? Bool, true)
        XCTAssertNil(effort["samples"])
    }

    func testDurableQueueEditPayloadRoundTripsLinkedSessionFields() throws {
        let edit = RecordingEdit(
            recordingID: recordingID,
            tag: "FDP",
            side: .right,
            note: "after",
            sessionID: sessionID,
            sessionRPE: 8.5
        )

        let data = try JSONEncoder().encode(edit)
        let restored = try JSONDecoder().decode(RecordingEdit.self, from: data)

        XCTAssertEqual(restored, edit)
        XCTAssertEqual(restored.sessionID, sessionID)
        XCTAssertEqual(restored.sessionRPE, 8.5)
    }

    func testEditNormalizesBoundsAndLooseRecordingsHaveNoSessionPatch() {
        let edit = RecordingEdit(
            recordingID: recordingID,
            tag: String(repeating: "x", count: 140),
            side: .unspecified,
            note: String(repeating: "n", count: 2_100),
            sessionRPE: 99
        )

        XCTAssertEqual(edit.tag.count, 120)
        XCTAssertEqual(edit.note.count, 2_000)
        XCTAssertEqual(edit.sessionRPE, 10)

        let loose = RecordingEdit(
            recordingID: recordingID,
            tag: "loose",
            side: .unspecified,
            note: "",
            sessionRPE: 7
        )
        XCTAssertNil(loose.sessionPayload)
    }

    func testSessionRPEUsesOneKeyAcrossLinkedRecordingsAndCoordinatorSurvivesRelaunch() {
        let otherRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000679")!
        let firstEdit = RecordingEdit(
            recordingID: recordingID,
            tag: "left",
            side: .left,
            note: "",
            sessionID: sessionID,
            sessionRPE: 6.5
        )
        let secondEdit = RecordingEdit(
            recordingID: otherRecordingID,
            tag: "right",
            side: .right,
            note: "",
            sessionID: sessionID,
            sessionRPE: 7.5
        )
        let sessionKey = RecordingEditQueueIdentity.sessionRPE(sessionID)
        XCTAssertEqual(
            sessionKey,
            RecordingEditQueueIdentity.sessionRPE(firstEdit.sessionID!)
        )
        XCTAssertEqual(
            sessionKey,
            RecordingEditQueueIdentity.sessionRPE(secondEdit.sessionID!)
        )
        XCTAssertNotEqual(
            RecordingEditQueueIdentity.recording(recordingID),
            RecordingEditQueueIdentity.recording(otherRecordingID)
        )

        var coordinator = RecordingEditCoordinator(now: Date(timeIntervalSince1970: 1_000))
        let first = coordinator.nextSessionRPERevision(
            now: Date(timeIntervalSince1970: 1_000)
        )
        let second = coordinator.nextSessionRPERevision(
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertGreaterThan(second, first)

        var relaunched = RecordingEditCoordinator(now: Date(timeIntervalSince1970: 900))
        relaunched.observe(
            sessionRPERevision: second,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertGreaterThan(
            relaunched.nextSessionRPERevision(now: Date(timeIntervalSince1970: 1_000)),
            second
        )
    }

    func testOptimisticLoadMatchesDatabaseRoundForOddHalfPoint() {
        XCTAssertEqual(
            RecordingEditCoordinator.optimisticLoad(durationMinutes: 9, rpe: 6.5),
            59
        )

        let oddSession = Session(
            id: sessionID,
            date: "2026-08-20",
            type: "tindeq",
            typeLabel: "Tindeq",
            durationMinutes: 9,
            rpe: 6.5,
            note: "",
            phase: .strength
        )
        XCTAssertEqual(oddSession.load, 59)
    }

    func testDeleteTombstoneRejectsStaleResponseEvenWhenClaimRevisionMatches() {
        let responseRevision = UUID()
        var coordinator = RecordingEditCoordinator()
        XCTAssertTrue(coordinator.tombstone(recordingID: recordingID))
        XCTAssertTrue(coordinator.isDeleted(recordingID))
        XCTAssertFalse(coordinator.tombstone(recordingID: recordingID))
        XCTAssertFalse(
            RecordingEditRacePolicy.acceptsRecordingResponse(
                recordingID: recordingID,
                responseRevision: responseRevision,
                currentRevision: responseRevision,
                deleted: true
            )
        )
        XCTAssertFalse(
            RecordingEditRacePolicy.acceptsSessionRPEResponse(
                responseRevision: responseRevision,
                currentRevision: responseRevision,
                deleted: true
            )
        )
        XCTAssertFalse(
            RecordingEditRacePolicy.acceptsRecordingResponse(
                recordingID: recordingID,
                responseRevision: responseRevision,
                currentRevision: UUID(),
                deleted: false
            )
        )
    }

    func testLegacySessionRPEMigrationUsesRevisionNotBackoffEnumerationAcrossRelaunch() {
        let firstRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000681")!
        let secondRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000682")!
        let thirdRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000683")!
        let first = RecordingEdit(
            recordingID: firstRecordingID,
            tag: "first",
            side: .left,
            note: "",
            sessionID: sessionID,
            sessionRPE: 6,
            sessionRPERevision: 101
        )
        let second = RecordingEdit(
            recordingID: secondRecordingID,
            tag: "second",
            side: .right,
            note: "",
            sessionID: sessionID,
            sessionRPE: 7,
            sessionRPERevision: 103
        )
        let third = RecordingEdit(
            recordingID: thirdRecordingID,
            tag: "third",
            side: .left,
            note: "",
            sessionID: sessionID,
            sessionRPE: 8,
            sessionRPERevision: 102
        )
        let candidates = [
            // This is the order returned when the newest edit is in a long
            // backoff window: queue enumeration must not make it lose.
            RecordingEditQueueCandidate(
                edit: second,
                queueItemID: secondRecordingID,
                createdAt: Date(timeIntervalSince1970: 1_002),
                nextAttemptAt: Date(timeIntervalSince1970: 5_000)
            ),
            RecordingEditQueueCandidate(
                edit: first,
                queueItemID: firstRecordingID,
                createdAt: Date(timeIntervalSince1970: 1_003),
                nextAttemptAt: Date(timeIntervalSince1970: 1_000)
            ),
            RecordingEditQueueCandidate(
                edit: third,
                queueItemID: thirdRecordingID,
                createdAt: Date(timeIntervalSince1970: 1_004),
                nextAttemptAt: Date(timeIntervalSince1970: 1_001)
            )
        ]

        let authoritative = RecordingEditMigration.authoritativeSessionRPE(
            sessionID: sessionID,
            candidates: candidates.sorted { $0.nextAttemptAt < $1.nextAttemptAt }
        )
        XCTAssertEqual(authoritative?.edit, second)

        // A relaunch can enumerate the same durable entries in a different
        // nextAttemptAt order. The decision remains the same, and all legacy
        // combined payloads become metadata-only once the shared item wins.
        let relaunched = RecordingEditMigration.authoritativeSessionRPE(
            sessionID: sessionID,
            candidates: Array(candidates.reversed())
        )
        XCTAssertEqual(relaunched?.edit, second)
        for edit in [first, second, third] {
            let metadata = RecordingEditMigration.metadataOnly(edit)
            XCTAssertNil(metadata.sessionID)
            XCTAssertNil(metadata.sessionRPE)
            XCTAssertNil(metadata.sessionRPERevision)
            XCTAssertEqual(metadata.tag, edit.tag)
        }

        // Once the newer shared item has uploaded and disappeared, an old
        // combined item is incapable of carrying an RPE back into the queue.
        XCTAssertNil(RecordingEditMigration.metadataOnly(second).sessionPayload)

        let legacyOld = RecordingEdit(
            recordingID: firstRecordingID,
            tag: "legacy-old",
            side: .left,
            note: "",
            sessionID: sessionID,
            sessionRPE: 5
        )
        let legacyNew = RecordingEdit(
            recordingID: secondRecordingID,
            tag: "legacy-new",
            side: .right,
            note: "",
            sessionID: sessionID,
            sessionRPE: 9
        )
        let createdOrdering = RecordingEditMigration.authoritativeSessionRPE(
            sessionID: sessionID,
            candidates: [
                RecordingEditQueueCandidate(
                    edit: legacyNew,
                    queueItemID: secondRecordingID,
                    createdAt: Date(timeIntervalSince1970: 2_000),
                    nextAttemptAt: Date(timeIntervalSince1970: 9_000)
                ),
                RecordingEditQueueCandidate(
                    edit: legacyOld,
                    queueItemID: firstRecordingID,
                    createdAt: Date(timeIntervalSince1970: 1_000),
                    nextAttemptAt: Date(timeIntervalSince1970: 1_001)
                )
            ]
        )
        XCTAssertEqual(createdOrdering?.edit, legacyNew)
    }

    func testSessionRPEDeleteBarrierDrainsConcurrentClaimsBeforeReplacement() {
        let firstRecordingID = recordingID
        let secondRecordingID = otherID
        var coordinator = RecordingEditCoordinator()

        let firstClaim = coordinator.beginSessionRPEWrite(
            recordingID: firstRecordingID,
            sessionID: sessionID
        )
        let secondClaim = coordinator.beginSessionRPEWrite(
            recordingID: secondRecordingID,
            sessionID: sessionID
        )
        XCTAssertNotNil(firstClaim)
        XCTAssertNotNil(secondClaim)
        XCTAssertTrue(coordinator.hasActiveSessionRPEWrites(sessionID: sessionID))

        let barrier = coordinator.beginSessionRPEBarrier(sessionID: sessionID)
        XCTAssertTrue(coordinator.isSessionRPEBarrierActive(sessionID: sessionID))
        XCTAssertNil(
            coordinator.beginSessionRPEWrite(
                recordingID: UUID(uuidString: "00000000-0000-0000-0000-000000000684")!,
                sessionID: sessionID
            )
        )
        XCTAssertFalse(coordinator.acceptsSessionRPEWrite(firstClaim!))

        XCTAssertTrue(coordinator.endSessionRPEWrite(firstClaim!))
        XCTAssertTrue(coordinator.hasActiveSessionRPEWrites(sessionID: sessionID))
        XCTAssertTrue(coordinator.endSessionRPEWrite(secondClaim!))
        XCTAssertFalse(coordinator.hasActiveSessionRPEWrites(sessionID: sessionID))
        XCTAssertTrue(coordinator.endSessionRPEBarrier(barrier))

        let replacement = coordinator.beginSessionRPEWrite(
            recordingID: secondRecordingID,
            sessionID: sessionID
        )
        XCTAssertNotNil(replacement)
        XCTAssertTrue(coordinator.endSessionRPEWrite(replacement!))
    }

    func testRestoreClearsRecordingTombstoneBeforeRefreshCanReplayEdits() {
        var coordinator = RecordingEditCoordinator()
        XCTAssertTrue(coordinator.tombstone(recordingID: recordingID))
        XCTAssertNil(
            coordinator.beginSessionRPEWrite(
                recordingID: recordingID,
                sessionID: sessionID
            )
        )

        // This is the ordering used by AppModel: the successful restore
        // clears the in-memory tombstone before refresh rebuilds overlays.
        coordinator.clearTombstone(recordingID: recordingID)
        let replay = coordinator.beginSessionRPEWrite(
            recordingID: recordingID,
            sessionID: sessionID
        )
        XCTAssertNotNil(replay)
        XCTAssertTrue(coordinator.acceptsSessionRPEWrite(replay!))
        XCTAssertTrue(coordinator.endSessionRPEWrite(replay!))
    }

    func testDeleteAndRestoreTokensRejectStaleABACompletions() {
        let accountA = UUID(uuidString: "00000000-0000-0000-0000-0000000006A1")!
        let accountB = UUID(uuidString: "00000000-0000-0000-0000-0000000006B1")!
        let oldA = AccountScopedFetch(accountUserID: accountA, accountEpoch: 10)
        let newA = AccountScopedFetch(accountUserID: accountA, accountEpoch: 12)
        var coordinator = RecordingEditCoordinator()

        let oldDelete = try! XCTUnwrap(
            coordinator.beginDelete(recordingID: recordingID, capturedBy: oldA)
        )
        // resetAccountState() clears the old account's in-memory tombstones;
        // a fresh A after B can therefore create a newer tombstone.
        coordinator.clearTombstones()
        XCTAssertFalse(oldA.canApply(to: accountB, accountEpoch: 11))
        let newDelete = try! XCTUnwrap(
            coordinator.beginDelete(recordingID: recordingID, capturedBy: newA)
        )

        XCTAssertFalse(
            coordinator.clearDelete(
                oldDelete,
                currentUserID: accountA,
                accountEpoch: newA.accountEpoch
            )
        )
        XCTAssertTrue(coordinator.isDeleted(recordingID))
        XCTAssertTrue(
            coordinator.clearDelete(
                newDelete,
                currentUserID: accountA,
                accountEpoch: newA.accountEpoch
            )
        )

        // A restore that started with no tombstone must not clear a delete
        // created while its request was suspended, even in the same epoch.
        let restoreScope = AccountScopedFetch(accountUserID: accountA, accountEpoch: 20)
        let restoreToken = try! XCTUnwrap(
            coordinator.beginRestore(recordingID: recordingID, capturedBy: restoreScope)
        )
        XCTAssertNil(
            coordinator.beginDelete(recordingID: recordingID, capturedBy: restoreScope)
        )
        XCTAssertTrue(
            coordinator.clearRestore(
                restoreToken,
                currentUserID: accountA,
                accountEpoch: restoreScope.accountEpoch
            )
        )
        XCTAssertTrue(
            coordinator.clearDelete(
                recordingID: recordingID,
                expectedToken: nil,
                currentUserID: accountA,
                accountEpoch: restoreScope.accountEpoch,
                capturedBy: restoreScope
            )
        )
        _ = coordinator.beginDelete(recordingID: recordingID, capturedBy: restoreScope)
        XCTAssertFalse(
            coordinator.clearDelete(
                recordingID: recordingID,
                expectedToken: nil,
                currentUserID: accountA,
                accountEpoch: restoreScope.accountEpoch,
                capturedBy: restoreScope
            )
        )
        XCTAssertTrue(coordinator.isDeleted(recordingID))
    }

    func testConditionalMigrationAndSemanticOrderingCannotOverwriteNewerRPE() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let terminalKey = recordingID
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let stableID = RecordingEditQueueIdentity.sessionRPE(sessionID)
        let older = DurableQueueItem(
            id: stableID,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 1_000),
            orderingKey: 100,
            terminalKey: terminalKey,
            payload: RecordingQueuePayload(value: "old-rpe")
        )
        try await queue.enqueue(older)
        let capturedRevision = older.revision

        let newer = DurableQueueItem(
            id: stableID,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 1_001),
            orderingKey: 200,
            terminalKey: terminalKey,
            payload: RecordingQueuePayload(value: "new-rpe")
        )
        let newerAccepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
            [newer],
            terminalKey: terminalKey,
            accountUserID: account
        )
        XCTAssertTrue(newerAccepted)

        let staleMigration = older.replacingPayload(
            RecordingQueuePayload(value: "stale-migration"),
            terminalKey: terminalKey
        )
        let staleMigrationApplied = try await queue.enqueueIfCurrent(
            staleMigration,
            expectedRevision: capturedRevision
        )
        XCTAssertFalse(staleMigrationApplied)
        let currentSnapshot = await queue.item(id: stableID, accountUserID: account)
        let current = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(current.payload, RecordingQueuePayload(value: "new-rpe"))
        XCTAssertEqual(current.orderingKey, 200)

        // The same ordering survives a file reload, rather than depending on
        // queue enumeration/backoff order.
        let relaunched = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let restoredSnapshot = await relaunched.item(id: stableID, accountUserID: account)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertEqual(restored.payload, RecordingQueuePayload(value: "new-rpe"))

        // The shared item may upload and disappear before an older combined
        // legacy item is replayed. Its semantic claim must survive removal,
        // otherwise migration would recreate the stale RPE on relaunch.
        try await queue.remove(id: stableID, accountUserID: account)
        let staleReplayAccepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
            [older],
            terminalKey: terminalKey,
            accountUserID: account
        )
        XCTAssertFalse(staleReplayAccepted)
        let staleReplay = await queue.item(id: stableID, accountUserID: account)
        XCTAssertNil(staleReplay)
        let watermark = await queue.orderingWatermark(
            for: stableID,
            accountUserID: account
        )
        XCTAssertEqual(watermark?.orderingKey, 200)
        let relaunchedAfterRemoval = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let staleAfterRelaunch = await relaunchedAfterRemoval.item(
            id: stableID,
            accountUserID: account
        )
        XCTAssertNil(staleAfterRelaunch)
    }

    func testTerminalDeleteIsAtomicDurableAndBlocksPostDeleteReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let terminalKey = recordingID
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let edit = DurableQueueItem(
            accountUserID: account,
            orderingKey: 100,
            terminalKey: terminalKey,
            payload: RecordingQueuePayload(value: "edit")
        )
        try await queue.enqueue(edit)
        let fileURL = directory.appendingPathComponent("recording-edits.json")
        let durableBeforeDelete = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let deleteItem = DurableQueueItem(
            id: RecordingEditQueueIdentity.delete(recordingID),
            accountUserID: account,
            terminalKey: terminalKey,
            payload: RecordingQueuePayload(value: "delete")
        )
        do {
            _ = try await queue.enqueueTerminalDelete(
                deleteItem,
                terminalKey: terminalKey
            )
            XCTFail("a persistence failure must not install a delete intent")
        } catch {
            // The transaction must leave the old edit durable and in memory.
        }
        // The failed persistence left the in-memory edit and no phantom
        // delete, so the caller can safely roll back without data loss.
        let failedDeleteEdit = await queue.item(id: edit.id, accountUserID: account)
        XCTAssertEqual(
            try XCTUnwrap(failedDeleteEdit).payload,
            RecordingQueuePayload(value: "edit")
        )

        try FileManager.default.removeItem(at: fileURL)
        try durableBeforeDelete.write(to: fileURL, options: [.atomic])
        let deleteInstalled = try await queue.enqueueTerminalDelete(
            deleteItem,
            terminalKey: terminalKey
        )
        XCTAssertTrue(deleteInstalled)
        let reloaded = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let durableDeleteSnapshot = await reloaded.item(
            id: deleteItem.id,
            accountUserID: account
        )
        let durableDelete = try XCTUnwrap(durableDeleteSnapshot)
        let removedEdit = await reloaded.item(id: edit.id, accountUserID: account)
        XCTAssertNil(removedEdit)

        let deleteCompleted = try await reloaded.completeTerminalDelete(
            id: durableDelete.id,
            accountUserID: account,
            expectedRevision: durableDelete.revision,
            terminalKey: terminalKey,
            operationID: UUID(uuidString: "00000000-0000-0000-0000-0000000006D1")!
        )
        XCTAssertTrue(deleteCompleted)
        let terminalToken = await reloaded.terminalizedToken(
            for: terminalKey,
            accountUserID: account
        )
        XCTAssertNotNil(terminalToken)
        let replay = DurableQueueItem(
            accountUserID: account,
            orderingKey: 999,
            terminalKey: terminalKey,
            payload: RecordingQueuePayload(value: "stale-after-delete")
        )
        let replayAccepted = try await reloaded.enqueueUnlessTerminalizedKeepingNewest(
            [replay],
            terminalKey: terminalKey,
            accountUserID: account
        )
        XCTAssertFalse(replayAccepted)

        let relaunched = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let relaunchedToken = await relaunched.terminalizedToken(
            for: terminalKey,
            accountUserID: account
        )
        XCTAssertEqual(relaunchedToken, terminalToken)
        let terminalCleared = try await relaunched.clearTerminalized(
            key: terminalKey,
            accountUserID: account,
            expectedOperationID: terminalToken
        )
        XCTAssertTrue(terminalCleared)
    }

    func testReplacementAfterOlderClaimDoesNotInheritFailureAndSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = UUID()
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let queueID = RecordingEditQueueIdentity.recording(recordingID)
        let key = QueueUploadKey(itemID: queueID, accountUserID: account)
        var claims = QueueUploadClaimCoordinator()
        let olderClaim = try XCTUnwrap(claims.claim(key))
        let now = Date(timeIntervalSince1970: 10_000)
        let older = DurableQueueItem(
            id: queueID,
            accountUserID: account,
            createdAt: now,
            payload: RecordingQueuePayload(value: "old")
        )
        try await queue.enqueue(older)
        let claimedItem = await queue.activeItem(
            id: queueID,
            accountUserID: account,
            dueAt: now
        )
        let claimed = try XCTUnwrap(claimedItem)

        let replacement = DurableQueueItem(
            id: queueID,
            accountUserID: account,
            createdAt: now.addingTimeInterval(1),
            payload: RecordingQueuePayload(value: "new")
        )
        try await queue.enqueue(replacement)

        let staleFailureApplied = try await queue.markFailure(
            id: queueID,
            accountUserID: account,
            error: "old request failed",
            classification: .retryable,
            now: now.addingTimeInterval(2),
            expectedRevision: claimed.revision
        )
        XCTAssertFalse(staleFailureApplied)
        let stalePermanentFailureApplied = try await queue.markFailure(
            id: queueID,
            accountUserID: account,
            error: "old request was permanently rejected",
            classification: .permanent,
            now: now.addingTimeInterval(3),
            expectedRevision: claimed.revision
        )
        XCTAssertFalse(stalePermanentFailureApplied)

        let currentItem = await queue.item(id: queueID, accountUserID: account)
        let current = try XCTUnwrap(currentItem)
        XCTAssertEqual(current.payload, RecordingQueuePayload(value: "new"))
        XCTAssertEqual(current.attempts, 0)
        XCTAssertNil(current.permanentAttempts)
        XCTAssertNil(current.quarantined)
        XCTAssertEqual(current.nextAttemptAt, replacement.nextAttemptAt)
        let notYetDue = await queue.items(for: account, dueAt: now)
        XCTAssertTrue(notYetDue.isEmpty)

        // The replacement cannot claim while the old request owns the key,
        // but becomes immediately claimable once the old request releases.
        XCTAssertNil(claims.claim(key))
        claims.release(olderClaim)
        XCTAssertNotNil(claims.claim(key))

        let reloaded = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let restoredItem = await reloaded.activeItem(
            id: queueID,
            accountUserID: account,
            dueAt: now.addingTimeInterval(1)
        )
        let restored = try XCTUnwrap(restoredItem)
        XCTAssertEqual(restored.payload, RecordingQueuePayload(value: "new"))
        XCTAssertEqual(restored.attempts, 0)
    }

    func testLegacyMigrationReplacementSetIsAtomicOnPersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let legacyFirst = DurableQueueItem(
            id: firstID,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 1_000),
            payload: RecordingQueuePayload(value: "combined-first")
        )
        let legacySecond = DurableQueueItem(
            id: secondID,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 1_001),
            payload: RecordingQueuePayload(value: "combined-second")
        )
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        try await queue.enqueue([legacyFirst, legacySecond])
        let fileURL = directory.appendingPathComponent("recording-edits.json")
        let durableBeforeMigration = try Data(contentsOf: fileURL)
        let replacements = [
            DurableQueueConditionalReplacement(
                item: legacyFirst.replacingPayload(
                    RecordingQueuePayload(value: "metadata-first"),
                    terminalKey: recordingID
                ),
                expectedRevision: legacyFirst.revision
            ),
            DurableQueueConditionalReplacement(
                item: DurableQueueItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000006F1")!,
                    accountUserID: account,
                    createdAt: legacySecond.createdAt,
                    orderingKey: 200,
                    terminalKey: recordingID,
                    payload: RecordingQueuePayload(value: "shared-rpe")
                ),
                expectedRevision: nil
            ),
            DurableQueueConditionalReplacement(
                item: legacySecond.replacingPayload(
                    RecordingQueuePayload(value: "metadata-second"),
                    terminalKey: otherID
                ),
                expectedRevision: legacySecond.revision
            )
        ]

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        do {
            _ = try await queue.replaceIfCurrent(replacements)
            XCTFail("a failed persistence must not partially normalize legacy items")
        } catch {
            // The old combined set remains the recovery source.
        }
        let failedFirst = await queue.item(id: firstID, accountUserID: account)?.payload
        let failedSecond = await queue.item(id: secondID, accountUserID: account)?.payload
        let failedShared = await queue.item(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000006F1")!,
            accountUserID: account
        )
        XCTAssertEqual(failedFirst, legacyFirst.payload)
        XCTAssertEqual(failedSecond, legacySecond.payload)
        XCTAssertNil(failedShared)

        try FileManager.default.removeItem(at: fileURL)
        try durableBeforeMigration.write(to: fileURL, options: [.atomic])
        let migrated = try await queue.replaceIfCurrent(replacements)
        XCTAssertTrue(migrated)
        let migratedFirst = await queue.item(id: firstID, accountUserID: account)?.payload
        let migratedSecond = await queue.item(id: secondID, accountUserID: account)?.payload
        let migratedShared = await queue.item(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000006F1")!,
            accountUserID: account
        )?.payload
        XCTAssertEqual(migratedFirst, RecordingQueuePayload(value: "metadata-first"))
        XCTAssertEqual(migratedSecond, RecordingQueuePayload(value: "metadata-second"))
        XCTAssertEqual(migratedShared, RecordingQueuePayload(value: "shared-rpe"))
    }

    func testLegacyMigrationConflictLeavesEveryOtherCombinedItemReconstructible() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let first = DurableQueueItem(
            id: UUID(),
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 2_000),
            payload: RecordingQueuePayload(value: "legacy-first")
        )
        let second = DurableQueueItem(
            id: UUID(),
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 2_001),
            payload: RecordingQueuePayload(value: "legacy-second")
        )
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        try await queue.enqueue([first, second])
        let newerSecond = DurableQueueItem(
            id: second.id,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 2_002),
            orderingKey: 2_002,
            terminalKey: otherID,
            payload: RecordingQueuePayload(value: "newer-second")
        )
        try await queue.enqueue(newerSecond)
        let replacements = [
            DurableQueueConditionalReplacement(
                item: first.replacingPayload(
                    RecordingQueuePayload(value: "metadata-first"),
                    terminalKey: recordingID
                ),
                expectedRevision: first.revision
            ),
            DurableQueueConditionalReplacement(
                item: second.replacingPayload(
                    RecordingQueuePayload(value: "metadata-second"),
                    terminalKey: otherID
                ),
                expectedRevision: second.revision
            )
        ]
        let applied = try await queue.replaceIfCurrent(replacements)
        let currentFirst = await queue.item(id: first.id, accountUserID: account)?.payload
        let currentSecond = await queue.item(id: second.id, accountUserID: account)?.payload
        XCTAssertFalse(applied)
        XCTAssertEqual(currentFirst, first.payload)
        XCTAssertEqual(currentSecond, newerSecond.payload)
    }

    func testConcurrentMigrationTransactionsPublishOnlyOneCompleteReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let legacy = DurableQueueItem(
            id: UUID(),
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 2_500),
            payload: RecordingQueuePayload(value: "legacy-combined")
        )
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        try await queue.enqueue(legacy)
        let first = DurableQueueConditionalReplacement(
            item: legacy.replacingPayload(
                RecordingQueuePayload(value: "metadata-A"),
                terminalKey: recordingID
            ),
            expectedRevision: legacy.revision
        )
        let second = DurableQueueConditionalReplacement(
            item: legacy.replacingPayload(
                RecordingQueuePayload(value: "metadata-B"),
                terminalKey: recordingID
            ),
            expectedRevision: legacy.revision
        )
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { (try? await queue.replaceIfCurrent([first])) == true }
            group.addTask { (try? await queue.replaceIfCurrent([second])) == true }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let current = await queue.item(id: legacy.id, accountUserID: account)
        XCTAssertTrue(
            current?.payload == RecordingQueuePayload(value: "metadata-A")
                || current?.payload == RecordingQueuePayload(value: "metadata-B")
        )
    }

    func testDeleteCompensationSkipsFrozenR1AfterR2UploadAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let stableID = RecordingEditQueueIdentity.sessionRPE(sessionID)
        let r1 = DurableQueueItem(
            id: stableID,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 3_000),
            orderingKey: 101,
            terminalKey: recordingID,
            payload: RecordingQueuePayload(value: "R1")
        )
        try await queue.enqueue(r1)
        try await queue.remove(id: stableID, accountUserID: account)
        let r2 = DurableQueueItem(
            id: stableID,
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 3_001),
            orderingKey: 202,
            terminalKey: otherID,
            payload: RecordingQueuePayload(value: "R2")
        )
        try await queue.enqueue(r2)
        try await queue.remove(id: stableID, accountUserID: account)

        let watermark = await queue.orderingWatermark(
            for: stableID,
            accountUserID: account
        )
        XCTAssertEqual(
            RecordingDeleteCompensationPolicy.decision(
                state: .pending,
                compensationOrderingKey: 101,
                currentOrderingKey: nil,
                watermarkOrderingKey: watermark?.orderingKey
            ),
            .skipSuperseded
        )
        let relaunched = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json"
        )
        let relaunchedWatermark = await relaunched.orderingWatermark(
            for: stableID,
            accountUserID: account
        )
        XCTAssertEqual(relaunchedWatermark?.orderingKey, 202)
        XCTAssertEqual(
            RecordingDeleteCompensationPolicy.decision(
                state: .pending,
                compensationOrderingKey: 101,
                currentOrderingKey: nil,
                watermarkOrderingKey: relaunchedWatermark?.orderingKey
            ),
            .skipSuperseded
        )
        XCTAssertEqual(
            RecordingDeleteCompensationPolicy.decision(
                state: .applied,
                compensationOrderingKey: 101,
                currentOrderingKey: 202,
                watermarkOrderingKey: nil
            ),
            .skipAlreadyApplied
        )
    }

    func testRestoreRequestUsesExactObservedTombstoneAcrossDelayedABA() {
        let old = "2026-08-20T01:02:03.123456Z"
        let newer = "2026-08-20T01:02:04.123456Z"
        let observation = RecordingRestoreObservation(
            recordingID: recordingID,
            deletedAtToken: old
        )
        let requestItems = RecordingRestoreRequestPolicy.queryItems(for: observation)
        XCTAssertEqual(requestItems?.first?.name, "id")
        XCTAssertEqual(requestItems?.first?.value, "eq.\(recordingID.uuidString.lowercased())")
        XCTAssertEqual(requestItems?.dropFirst().first?.value, "eq.\(old)")
        XCTAssertEqual(
            RecordingRestoreRequestPolicy.deletedAtFilterValue(for: old),
            "eq.\(old)"
        )
        XCTAssertNotEqual(
            RecordingRestoreRequestPolicy.deletedAtFilterValue(for: old),
            RecordingRestoreRequestPolicy.deletedAtFilterValue(for: newer)
        )
        XCTAssertTrue(
            RecordingRestoreRequestPolicy.acceptsBackendTombstone(
                observedToken: old,
                backendToken: old
            )
        )
        XCTAssertFalse(
            RecordingRestoreRequestPolicy.acceptsBackendTombstone(
                observedToken: old,
                backendToken: newer
            )
        )
        XCTAssertNil(RecordingRestoreRequestPolicy.deletedAtFilterValue(for: "bad\nvalue"))
    }

    func testQuarantineDiscardOnlyOwnsExactDeleteOperationAcrossABA() {
        let account = UUID()
        let oldOperation = UUID()
        let newOperation = UUID()
        _ = RecordingEditDeleteToken(
            id: oldOperation,
            recordingID: recordingID,
            accountUserID: account,
            accountEpoch: 10
        )
        let newToken = RecordingEditDeleteToken(
            id: newOperation,
            recordingID: recordingID,
            accountUserID: account,
            accountEpoch: 12
        )
        XCTAssertFalse(
            RecordingDeleteDiscardPolicy.ownsExactDelete(
                operationID: oldOperation,
                tombstone: newToken,
                terminalOperationID: newOperation
            )
        )
        XCTAssertTrue(
            RecordingDeleteDiscardPolicy.ownsExactDelete(
                operationID: newOperation,
                tombstone: newToken,
                terminalOperationID: nil
            )
        )
        XCTAssertTrue(
            RecordingDeleteDiscardPolicy.ownsExactDelete(
                operationID: oldOperation,
                tombstone: nil,
                terminalOperationID: oldOperation
            )
        )
    }

    func testWatermarksAreBoundedAndFloorBlocksEvictedStaleReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json",
            orderingWatermarkLimit: 2
        )
        var identities: [UUID] = []
        for ordering in 1...4 {
            let identity = UUID()
            identities.append(identity)
            try await queue.enqueue(
                DurableQueueItem(
                    id: identity,
                    accountUserID: account,
                    createdAt: Date(timeIntervalSince1970: Double(ordering)),
                    orderingKey: UInt64(ordering),
                    terminalKey: UUID(),
                    payload: RecordingQueuePayload(value: "R\(ordering)")
                )
            )
            try await queue.remove(id: identity, accountUserID: account)
        }
        let watermarkCount = await queue.orderingWatermarkCount(for: account)
        XCTAssertEqual(watermarkCount, 2)
        let stale = DurableQueueItem(
            id: identities[0],
            accountUserID: account,
            createdAt: Date(timeIntervalSince1970: 1),
            orderingKey: 1,
            terminalKey: recordingID,
            payload: RecordingQueuePayload(value: "stale")
        )
        let staleAccepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
            [stale],
            terminalKey: recordingID,
            accountUserID: account
        )
        let staleItem = await queue.item(id: identities[0], accountUserID: account)
        XCTAssertFalse(staleAccepted)
        XCTAssertNil(staleItem)
    }

    func testTerminalHistoryGCIsBoundedWithoutReopeningOlderEditorReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json",
            orderingWatermarkLimit: 2,
            terminalHistoryLimit: 2
        )
        var firstKey = recordingID
        for ordering in 1...3 {
            let key = ordering == 1 ? firstKey : UUID()
            let editor = DurableQueueItem(
                id: UUID(),
                accountUserID: account,
                orderingKey: UInt64(ordering),
                terminalKey: key,
                payload: RecordingQueuePayload(value: "edit-\(ordering)")
            )
            try await queue.enqueue(editor)
            let delete = DurableQueueItem(
                id: UUID(),
                accountUserID: account,
                terminalKey: key,
                payload: RecordingQueuePayload(value: "delete-\(ordering)")
            )
            let installed = try await queue.enqueueTerminalDelete(delete, terminalKey: key)
            let durableDelete = await queue.item(id: delete.id, accountUserID: account)
            XCTAssertTrue(installed)
            let completed = try await queue.completeTerminalDelete(
                id: try XCTUnwrap(durableDelete).id,
                accountUserID: account,
                expectedRevision: try XCTUnwrap(durableDelete).revision,
                terminalKey: key,
                operationID: UUID()
            )
            XCTAssertTrue(completed)
            firstKey = key
        }
        let terminalCount = await queue.terminalizedCount(for: account)
        XCTAssertEqual(terminalCount, 2)
        let stale = DurableQueueItem(
            id: UUID(),
            accountUserID: account,
            orderingKey: 1,
            terminalKey: recordingID,
            payload: RecordingQueuePayload(value: "stale-after-terminal-GC")
        )
        let accepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
            [stale],
            terminalKey: recordingID,
            accountUserID: account
        )
        XCTAssertFalse(accepted)
        let staleItem = await queue.item(id: stale.id, accountUserID: account)
        XCTAssertNil(staleItem)
    }

    func testBackwardQueueWithoutOrderingFloorsDerivesSafeReplayFloor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let identity = UUID()
        let createdAt = Date(timeIntervalSince1970: 4_000)
        let revision = UUID()
        let watermark = DurableQueueOrderingWatermark(
            queueItemID: identity,
            accountUserID: account,
            orderingKey: 400,
            createdAt: createdAt,
            revision: revision
        )
        let terminalOperation = UUID()
        let legacyTerminal = DurableQueueTerminal(
            key: recordingID,
            accountUserID: account,
            operationID: terminalOperation,
            completedAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyTerminalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(legacyTerminal))
        ) as! [String: Any]
        legacyTerminalObject.removeValue(forKey: "completedAt")
        let data = try JSONSerialization.data(withJSONObject: [
            "items": [],
            "breadcrumbs": [],
            "terminalized": [legacyTerminalObject],
            "orderingWatermarks": [
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoder.encode(watermark))
                )
            ]
        ])
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: directory.appendingPathComponent("recording-edits.json"),
            options: [.atomic]
        )
        let queue = try DurableQueue<RecordingQueuePayload>(
            directoryURL: directory,
            filename: "recording-edits.json",
            orderingWatermarkLimit: 2
        )
        let stale = DurableQueueItem(
            id: identity,
            accountUserID: account,
            createdAt: createdAt,
            orderingKey: 399,
            terminalKey: otherID,
            payload: RecordingQueuePayload(value: "stale")
        )
        let accepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
            [stale],
            terminalKey: otherID,
            accountUserID: account
        )
        XCTAssertFalse(accepted)
        let restoredTerminalOperation = await queue.terminalizedToken(
            for: recordingID,
            accountUserID: account
        )
        XCTAssertEqual(restoredTerminalOperation, terminalOperation)
    }
}

private struct RecordingQueuePayload: Codable, Equatable, Sendable {
    let value: String
}

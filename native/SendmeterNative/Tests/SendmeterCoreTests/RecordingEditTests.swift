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
}

private struct RecordingQueuePayload: Codable, Equatable, Sendable {
    let value: String
}

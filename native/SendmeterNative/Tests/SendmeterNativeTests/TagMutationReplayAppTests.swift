import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #918: tag rename / hide / unhide now replay through the EXISTING durable
/// queue (`DirectWriteReplay.swift`) instead of a fire-and-forget request. These
/// tests drive a REAL `AppModel` against a stubbed PostgREST transport and prove
/// the acceptance criteria at the app/repository boundary:
///
/// * AC1 persistence: an offline rename/hide is accepted only because its intent
///   is durable, and a fresh model over the same on-disk cache + queue (process
///   death) completes the intended mutation exactly once,
/// * AC2 exactly-once + ordering: a rename whose acknowledgement was lost is
///   recognised from the server's own state instead of being repeated, the
///   registry never grows a duplicate row, no recording reference is dropped,
///   and a LATER rename is the one that survives (the still-pending earlier one
///   is composed into it),
/// * AC3 device-local policy: a rename moves the side mode locally and uploads
///   nothing but the rename (no side_mode, no settings write),
/// * AC4 hidden tags leave the pickable list while their recordings stay,
/// * AC5 residue + account scope: a pending cache-only registry row is adopted
///   only on the server's own proof (and otherwise stays visibly unsynced), and
///   another account can never replay this account's intent.
final class TagMutationReplayAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container, so a shared user id would leak
    /// one test's rows into the next.
    private let userID = UUID()

    // MARK: - AC1/AC2: rename persistence round-trip across process death

    @MainActor
    func testOfflineRenameReplaysAfterProcessDeathExactlyOnce() async throws {
        let server = FakeTagPostgREST()
        let first = UUID()
        let second = UUID()
        let sloper = UUID()
        server.seedRecordings([
            (first, "Half Crimp"), (second, "Half Crimp"), (sloper, "Sloper")
        ])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(
            model.tagEntries.map(\.name).sorted(),
            ["Half Crimp", "Sloper"],
            "fixture: the recordings are the tag registry"
        )

        server.goOffline()
        await model.renameTag(oldName: "Half Crimp", newName: "Half Crimp 20mm")

        XCTAssertEqual(
            model.recordings.filter { $0.tag == "Half Crimp 20mm" }.count,
            2,
            "the optimistic repoint shows immediately"
        )
        XCTAssertEqual(server.renameRequestCount, 0, "nothing reached the server while offline")
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        // AC1: the account and the immutable intended mutation are on disk.
        let queueFile = try Self.queueFileContents()
        XCTAssertTrue(queueFile.contains(userID.uuidString), "the intent is scoped to this account")
        XCTAssertTrue(queueFile.contains("Half Crimp"), "the name to repoint FROM is persisted")
        XCTAssertTrue(queueFile.contains("Half Crimp 20mm"), "the intended name is persisted")

        // Process death: a fresh instance reads the same on-disk state.
        let relaunched = try await makeSignedInModel(server: server)
        await relaunched.refreshAll(showSpinner: false)
        XCTAssertEqual(
            relaunched.recordings.filter { $0.tag == "Half Crimp 20mm" }.count,
            2,
            "the repointed rows are restored from the cache before any network call"
        )

        server.goOnline()
        await relaunched.retryAllQueuedWrites()
        try await waitForQueueCount(relaunched, expected: 0)

        XCTAssertEqual(server.renameRequestCount, 1, "AC2: the rename runs exactly once")
        XCTAssertEqual(server.tag(of: first), "Half Crimp 20mm")
        XCTAssertEqual(server.tag(of: second), "Half Crimp 20mm")
        XCTAssertEqual(server.tag(of: sloper), "Sloper", "an unrelated tag is untouched")
        XCTAssertEqual(
            relaunched.recordings.filter { $0.tag == "Half Crimp 20mm" }.count,
            2,
            "AC2: no recording reference is lost"
        )
        XCTAssertTrue(server.tagNames.isEmpty, "no registry row survives the old name")
        XCTAssertEqual(
            relaunched.pendingCacheWriteCount,
            0,
            "no cache-only row is left behind without replay intent"
        )
    }

    // MARK: - AC2: a lost acknowledgement is not repeated

    @MainActor
    func testLostRenameAcknowledgementRetriesIdempotently() async throws {
        let server = FakeTagPostgREST()
        let first = UUID()
        let second = UUID()
        server.seedRecordings([(first, "Repeaters"), (second, "Repeaters")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.loseNextRenameAcknowledgement()
        await model.renameTag(oldName: "Repeaters", newName: "Repeaters 7:3")
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.renameRequestCount, 1)
        XCTAssertEqual(server.tag(of: first), "Repeaters 7:3", "the server DID apply the rename")
        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "the intent stays durable: the acknowledgement never arrived"
        )

        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.renameRequestCount,
            1,
            "AC2: the replay reads the server's own end state and sends nothing"
        )
        XCTAssertEqual(server.tagNames, [], "AC2: no duplicate or stale registry row")
        XCTAssertEqual(model.recordings.filter { $0.tag == "Repeaters 7:3" }.count, 2)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    @MainActor
    func testLostHideAcknowledgementRetriesIdempotently() async throws {
        let server = FakeTagPostgREST()
        server.seedRecordings([(UUID(), "Slopers"), (UUID(), "Crimp")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        server.loseNextTagUpsertAcknowledgement()
        await model.setTagHidden(name: "Slopers", hidden: true)
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.tagUpsertCount, 1, "the server applied the visibility upsert")
        XCTAssertEqual(model.pendingCacheWriteCount, 1)

        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.tagUpsertCount,
            1,
            "AC2: the visibility replay sends nothing — the row already carries the flag"
        )
        XCTAssertEqual(server.tagRow(named: "Slopers")?["hidden"] as? Bool, true)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertTrue(model.hiddenTagNames.contains("Slopers"))
    }

    // MARK: - AC2: an older acknowledgement cannot overwrite a later rename

    @MainActor
    func testOlderRenameAcknowledgementCannotOverwriteALaterRename() async throws {
        let server = FakeTagPostgREST()
        let first = UUID()
        let second = UUID()
        server.seedRecordings([(first, "Hang 1"), (second, "Hang 1")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // Hold the first rename so the newer one is issued while its
        // acknowledgement is still in flight.
        server.holdNextRenameRequest()
        await model.renameTag(oldName: "Hang 1", newName: "Hang 2")
        try await waitForHeldRequest(server)

        await model.renameTag(oldName: "Hang 2", newName: "Hang 3")
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "Hang 3" }.count,
            2,
            "the newest local rename is the published one"
        )

        server.releaseHeldRequest()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.tag(of: first),
            "Hang 3",
            "AC2: the later rename is the one that survives"
        )
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "Hang 3" }.count,
            2,
            "AC2: the older acknowledgement must not re-publish its own (older) name"
        )
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "Hang 2" }.count,
            0,
            "AC2: the superseded name is never left in the list"
        )
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertTrue(server.tagNames.isEmpty)
    }

    // MARK: - AC2: a later rename chains onto the pending one

    @MainActor
    func testLaterRenameChainsOntoTheStillPendingRename() async throws {
        let server = FakeTagPostgREST()
        let first = UUID()
        server.seedRecordings([(first, "Block 1")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // First rename fails offline: it stays pending with a backoff, so a
        // naive queue would replay the SECOND rename first and lose the later
        // user's word to the older one.
        server.goOffline()
        await model.renameTag(oldName: "Block 1", newName: "Block 2")
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        await model.renameTag(oldName: "Block 2", newName: "Block 3")
        try await waitForQueueCount(model, expected: 1)

        let queueFile = try Self.queueFileContents()
        XCTAssertEqual(
            queueFile.components(separatedBy: "\"knownNames\"").count - 1,
            1,
            "AC2: the second rename replaces the pending intent instead of racing it"
        )
        XCTAssertTrue(
            queueFile.contains("Block 2"),
            "AC2: the name the tag passed through is kept as a repoint source"
        )

        server.goOnline()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.tag(of: first), "Block 3", "the later rename wins on the server")
        XCTAssertEqual(model.recordings.filter { $0.tag == "Block 3" }.count, 1)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    // MARK: - AC3: the side mode is device-local policy

    @MainActor
    func testRenameKeepsTheSideModeDeviceLocalAndUploadsNothingElse() async throws {
        let server = FakeTagPostgREST()
        let recording = UUID()
        server.seedRecordings([(recording, "Pinch 918")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        defer {
            TagSideModeStore.remove(for: "Pinch 918")
            TagSideModeStore.remove(for: "Pinch 918 Renamed")
        }

        model.setTagSideMode(name: "Pinch 918", mode: .unilateralOnly)
        XCTAssertEqual(model.sideMode(for: "Pinch 918"), .unilateralOnly)

        let requestCountBefore = server.recordedRequests.count
        server.goOffline()
        await model.renameTag(oldName: "Pinch 918", newName: "Pinch 918 Renamed")
        server.goOnline()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            model.sideMode(for: "Pinch 918 Renamed"),
            .unilateralOnly,
            "AC3: the device-local mode moves with the rename"
        )
        XCTAssertEqual(
            TagSideModeStore.storedMode(for: "Pinch 918 Renamed"),
            .unilateralOnly,
            "AC3: the mode is stored on the device, not on the account"
        )
        XCTAssertEqual(
            model.sideMode(for: "Pinch 918"),
            ExerciseSideMode.defaultMode,
            "AC3: the old name keeps no mode"
        )
        XCTAssertEqual(
            TagSideModeStore.storedMode(for: "Pinch 918"),
            ExerciseSideMode.defaultMode,
            "AC3: the old name keeps no stored mode"
        )
        XCTAssertEqual(
            model.recordings.first?.side,
            .unspecified,
            "AC3: no recording side is rewritten by a rename"
        )

        let writes = server.recordedRequests
            .dropFirst(requestCountBefore)
            .filter { ["POST", "PATCH", "PUT", "DELETE"].contains($0.method) }
        XCTAssertFalse(writes.isEmpty, "fixture: the drain did write")
        XCTAssertTrue(
            writes.allSatisfy { !$0.body.contains("side_mode") },
            "AC3: the side mode is never part of a request"
        )
        XCTAssertTrue(
            writes.allSatisfy { !$0.path.contains("user_settings") },
            "AC3: a rename never writes a settings row"
        )
        XCTAssertFalse(
            writes.contains { $0.path.contains("tindeq_tags") },
            "AC3: a rename never upserts a visibility row"
        )
    }

    // MARK: - AC4: hidden tags leave the chips, not the history

    @MainActor
    func testOfflineHideReplaysAndKeepsHiddenTagsOutOfTheChips() async throws {
        let server = FakeTagPostgREST()
        server.seedRecordings([
            (UUID(), "Slopers 918"), (UUID(), "Slopers 918"), (UUID(), "Crimp 918")
        ])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.visibleTagNames, ["Crimp 918", "Slopers 918"])

        server.goOffline()
        await model.setTagHidden(name: "Slopers 918", hidden: true)

        XCTAssertEqual(model.visibleTagNames, ["Crimp 918"], "AC4: a hidden tag leaves the chips")
        XCTAssertTrue(model.hiddenTagNames.contains("Slopers 918"))
        let entry = try XCTUnwrap(model.tagEntries.first { $0.name == "Slopers 918" })
        XCTAssertEqual(entry.count, 2, "AC4: the tag keeps its reps in the exercise list")
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "Slopers 918" }.count,
            2,
            "AC4: its recordings stay in the history"
        )
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        server.goOnline()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.tagUpsertCount, 1)
        XCTAssertEqual(server.tagRow(named: "Slopers 918")?["hidden"] as? Bool, true)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertEqual(model.visibleTagNames, ["Crimp 918"], "AC4: still out of the chips after the sync")
        XCTAssertEqual(model.recordings.filter { $0.tag == "Slopers 918" }.count, 2)

        // Unhiding is the same durable path, and it puts the tag back.
        await model.setTagHidden(name: "Slopers 918", hidden: false)
        try await waitForQueueCount(model, expected: 0)
        XCTAssertEqual(server.tagRow(named: "Slopers 918")?["hidden"] as? Bool, false)
        XCTAssertEqual(model.visibleTagNames, ["Crimp 918", "Slopers 918"])
    }

    // MARK: - AC2: collision and invalid names against the current rules

    @MainActor
    func testRenameOntoAnExistingNameMergesWithOneRowPerName() async throws {
        let server = FakeTagPostgREST()
        let source = UUID()
        let target = UUID()
        server.seedRecordings([(source, "Sloper 918"), (target, "Slopers 918")])
        server.seedTag(name: "Slopers 918", hidden: true)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(
            model.visibleTagNames,
            ["Sloper 918"],
            "fixture: the collision target is hidden"
        )

        server.goOffline()
        await model.renameTag(oldName: "Sloper 918", newName: "Slopers 918")
        server.goOnline()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.tag(of: source), "Slopers 918")
        XCTAssertEqual(server.tag(of: target), "Slopers 918")
        XCTAssertEqual(
            server.rows(named: "Slopers 918").count,
            1,
            "AC2: the merge leaves exactly one registry row for the target name"
        )
        XCTAssertTrue(server.rows(named: "Sloper 918").isEmpty, "AC2: the old row is gone")
        XCTAssertEqual(
            server.tagRow(named: "Slopers 918")?["hidden"] as? Bool,
            true,
            "the current rule: the surviving target row's hidden state wins"
        )
        XCTAssertEqual(
            model.tagEntries.first { $0.name == "Slopers 918" }?.count,
            2,
            "AC2: both recordings are now one tag — nothing is lost"
        )
        XCTAssertEqual(model.toastMessage, "Merged into “Slopers 918”")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    @MainActor
    func testInvalidRenameNameIsRejectedWithoutADurableIntent() async throws {
        let server = FakeTagPostgREST()
        server.seedRecordings([(UUID(), "Pinch 918")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        await model.renameTag(oldName: "Pinch 918", newName: "   ")

        XCTAssertEqual(model.recordings.first?.tag, "Pinch 918", "nothing moved")
        XCTAssertEqual(model.queuedWriteCount, 0, "no intent is enqueued for a name that cannot work")
        XCTAssertEqual(server.renameRequestCount, 0)

        // The repository rule the guard mirrors: the RPC refuses an empty name.
        let repository = makeRepository(
            session: Self.makeSession(userID: userID),
            server: server
        )
        do {
            try await repository.renameTag(oldName: "Pinch 918", newName: "  ")
            XCTFail("an empty tag name must be refused")
        } catch let error as PostgRESTError {
            XCTAssertEqual(error.statusCode, 422)
            XCTAssertEqual(error.message, "Tag name can't be empty")
        }
    }

    @MainActor
    func testRenamingATagToItsOwnNameSendsNothing() async throws {
        let server = FakeTagPostgREST()
        let recording = UUID()
        server.seedRecordings([(recording, "Crimp 918")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        await model.renameTag(oldName: "Crimp 918", newName: "Crimp 918")
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(
            server.renameRequestCount,
            0,
            "the DB function returns early for the same name, so nothing is sent"
        )
        XCTAssertEqual(model.recordings.first?.tag, "Crimp 918")
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    @MainActor
    func testRenameThatWouldLeaveAReferenceBehindIsNeverConfirmed() async throws {
        let server = FakeTagPostgREST()
        let first = UUID()
        let second = UUID()
        server.seedRecordings([(first, "Lose Nothing 918"), (second, "Lose Nothing 918")])
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // A rename whose repoint did not cover one of the user's references.
        server.dropNextRenameRepoint(for: second)
        await model.renameTag(oldName: "Lose Nothing 918", newName: "Lose Nothing 918 v2")
        try await waitForQueueCount(model, expected: 1)
        try await waitForRecordedAttempt(model)

        XCTAssertEqual(server.tag(of: first), "Lose Nothing 918 v2")
        XCTAssertEqual(server.tag(of: second), "Lose Nothing 918", "fixture: one reference was left behind")
        XCTAssertEqual(
            model.queuedWriteCount,
            1,
            "AC2: the rename is not confirmed while a reference is still behind"
        )
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "Lose Nothing 918 v2" }.count,
            2,
            "AC2: the local repoint is not reverted and no reference is lost"
        )

        // The next attempt re-reads the server and repoints from the name it
        // still serves, so the rename converges instead of lying.
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)
        XCTAssertEqual(server.tag(of: second), "Lose Nothing 918 v2")
        XCTAssertEqual(server.renameRequestCount, 2)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
        XCTAssertEqual(model.recordings.filter { $0.tag == "Lose Nothing 918 v2" }.count, 2)
    }

    // MARK: - AC5: pre-#918 residue and account scope

    @MainActor
    func testPendingRegistryResidueIsAdoptedOnlyOnServerProof() async throws {
        let server = FakeTagPostgREST()
        let recording = UUID()
        server.seedRecordings([(recording, "Crimp 918"), (UUID(), "Slopers 918")])
        server.seedTag(name: "Slopers 918", hidden: true)
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // The pre-#918 residue: a cache-only registry row with no queue intent,
        // left behind by an older build whose request never confirmed.
        let workspace = CachedWorkspace(store: try LocalCacheStore(databaseURL: Self.cacheDatabaseURL()))
        try workspace.upsertLocal(
            TagMetadata(name: "Slopers 918", hidden: true),
            accountUserID: userID,
            entityType: .tagMetadata,
            entityID: "Slopers 918"
        )
        try workspace.upsertLocal(
            TagMetadata(name: "Ghost 918", hidden: true),
            accountUserID: userID,
            entityType: .tagMetadata,
            entityID: "Ghost 918"
        )

        await model.drainQueue()
        await model.refreshAll(showSpinner: false)

        // The server already serves the Slopers row with the same flag: the
        // write landed, so the residue row is confirmed rather than left
        // counted for ever.
        let slopersEntry = try XCTUnwrap(model.tagEntries.first { $0.name == "Slopers 918" })
        XCTAssertTrue(slopersEntry.hidden)
        XCTAssertEqual(
            model.pendingCacheWriteCount,
            1,
            "AC5: the unresolvable row stays visible as unsynced instead of being cleared on a guess"
        )
        XCTAssertTrue(
            model.hiddenTagNames.contains("Ghost 918"),
            "AC5: the local row is kept — nothing is dropped"
        )
        // Re-doing the action resolves it: the new intent's replay confirms it.
        await model.setTagHidden(name: "Ghost 918", hidden: true)
        try await waitForQueueCount(model, expected: 0)
        XCTAssertEqual(server.tagRow(named: "Ghost 918")?["hidden"] as? Bool, true)
        XCTAssertEqual(model.pendingCacheWriteCount, 0)
    }

    @MainActor
    func testAnotherAccountCannotReplayThisAccountsTagIntent() async throws {
        let server = FakeTagPostgREST()
        let recording = UUID()
        server.seedRecordings([(recording, "Repeaters 918")])
        let owner = try await makeSignedInModel(server: server)
        await owner.refreshAll(showSpinner: false)

        server.goOffline()
        await owner.renameTag(oldName: "Repeaters 918", newName: "Repeaters 918 v2")
        try await waitForQueueCount(owner, expected: 1)
        try await waitForRecordedAttempt(owner)

        // A second account signs in on the same device.
        let other = try await makeSignedInModel(server: server, userID: UUID())
        await other.refreshAll(showSpinner: false)
        server.goOnline()
        await other.retryAllQueuedWrites()

        XCTAssertEqual(
            server.renameRequestCount,
            0,
            "AC1: another account never replays this intent"
        )
        XCTAssertEqual(server.tag(of: recording), "Repeaters 918")
        XCTAssertEqual(other.queuedWriteCount, 0)
        XCTAssertEqual(other.pendingCacheWriteCount, 0)
        XCTAssertTrue(other.recordings.isEmpty, "the other account sees none of the owner's rows")

        // The owner's intent is still durable and replays under its own account.
        await owner.retryAllQueuedWrites()
        try await waitForQueueCount(owner, expected: 0)
        XCTAssertEqual(server.renameRequestCount, 1)
        XCTAssertEqual(server.tag(of: recording), "Repeaters 918 v2")
    }

    // MARK: - Model harness (mirrors the other app-target suites)

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue never reached \(expected); last observed \(model.queuedWriteCount)")
    }

    /// Waits until the queue item has recorded at least one failed attempt, i.e.
    /// the spawned upload has settled instead of racing the assertions.
    @MainActor
    private func waitForRecordedAttempt(_ model: AppModel) async throws {
        for _ in 0..<400 {
            if (model.queuedWriteDiagnostics.first?.attempts ?? 0) >= 1 { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the queue item never recorded an attempt")
    }

    private func waitForHeldRequest(_ server: FakeTagPostgREST) async throws {
        for _ in 0..<600 {
            if server.isHoldingRequest { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the stubbed server never held the expected request")
    }

    @MainActor
    private func makeSupabaseClient(storage: any AuthLocalStorage) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "https://example.test")!,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: storage,
                    autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    @MainActor
    private func makeRepository(
        session: Auth.Session,
        server: FakeTagPostgREST
    ) -> SendmeterRepository {
        let suite = "TagMutationReplayAppTests.repo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = { session }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
    }

    @MainActor
    private func makeSignedInModel(
        server: FakeTagPostgREST,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "TagMutationReplayAppTests.signed-in.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = InMemoryAuthStorage()
        let session = Self.makeSession(userID: accountID)
        try storage.store(
            key: "sb-example-auth-token",
            value: JSONEncoder().encode(session)
        )

        let client = makeSupabaseClient(storage: storage)
        let auth = AuthService(
            client: client,
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
        let model = AppModel(
            auth: auth,
            repository: makeRepository(session: session, server: server),
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession())
        )

        var waited = 0
        while model.currentUserID == nil, waited < 200 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    private static func makeSession(userID: UUID) -> Auth.Session {
        let payload = Data(#"{"session_id": "session-1", "iat": 1_000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let token = "header.\(payload).signature"
        let user = Auth.User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return Auth.Session(
            accessToken: token,
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }

    // MARK: - On-disk state (the app container paths AppModel uses)

    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
    }

    private static func cacheDatabaseURL() -> URL {
        supportDirectory().appendingPathComponent("local-cache.sqlite", isDirectory: false)
    }

    /// The raw durable queue file: the evidence that the intent (account +
    /// identity + immutable mutation) is on disk before any acceptance.
    private static func queueFileContents() throws -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json", isDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// The stubbed tag backend: the real registry (row per hidden tag / per tag with
/// a carried side mode), the recordings the rename repoints, the
/// `rename_tindeq_tag` semantics (repoint, drop the old row, only carry a row
/// across when the old name had one), an offline mode, a
/// "the write applied but the acknowledgement was lost" mode, a request hold so
/// an in-flight acknowledgement can be observed while newer local state exists,
/// and a request log so a test can prove what was NOT uploaded.
private final class FakeTagPostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    struct RequestRecord {
        let method: String
        let path: String
        let query: String
        let body: String
    }

    private let lock = NSLock()
    private let condition = NSCondition()
    private var recordings: [[String: Any]] = []
    private var tags: [[String: Any]] = []
    private var online = true
    private var dropsNextRenameAcknowledgement = false
    private var dropsNextTagUpsertAcknowledgement = false
    private var pendingRepointDrop: String?
    private var renameRequests = 0
    private var tagUpserts = 0
    private var requests: [RequestRecord] = []
    private var pendingRenameHolds = 0
    private var holding = false
    private var releaseGeneration = 0

    func goOffline() {
        lock.lock()
        online = false
        lock.unlock()
    }

    func goOnline() {
        lock.lock()
        online = true
        lock.unlock()
    }

    /// The server applies the next rename, then the response never arrives.
    func loseNextRenameAcknowledgement() {
        lock.lock()
        dropsNextRenameAcknowledgement = true
        lock.unlock()
    }

    /// The server applies the next visibility upsert, then the response never
    /// arrives.
    func loseNextTagUpsertAcknowledgement() {
        lock.lock()
        dropsNextTagUpsertAcknowledgement = true
        lock.unlock()
    }

    /// The next rename leaves one recording behind, exactly like a repoint that
    /// did not cover every reference.
    func dropNextRenameRepoint(for recordingID: UUID) {
        lock.lock()
        pendingRepointDrop = recordingID.uuidString.lowercased()
        lock.unlock()
    }

    func holdNextRenameRequest() {
        condition.lock()
        pendingRenameHolds += 1
        condition.unlock()
    }

    func releaseHeldRequest() {
        condition.lock()
        holding = false
        releaseGeneration += 1
        condition.broadcast()
        condition.unlock()
    }

    var isHoldingRequest: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holding
    }

    var renameRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return renameRequests
    }

    var tagUpsertCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tagUpserts
    }

    var recordedRequests: [RequestRecord] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// The name every recording row currently carries.
    func tag(of recordingID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recordings.first { ($0["id"] as? String) == recordingID.uuidString.lowercased() }
            .flatMap { $0["tag"] as? String }
    }

    var tagNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tags.compactMap { $0["name"] as? String }.sorted()
    }

    func tagRow(named name: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return tags.first { ($0["name"] as? String) == name }
    }

    func rows(named name: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return tags.filter { ($0["name"] as? String) == name }
    }

    func seedRecordings(_ seeded: [(UUID, String)]) {
        lock.lock()
        recordings = seeded.enumerated().map { index, entry in
            [
                "id": entry.0.uuidString.lowercased(),
                "tag": entry.1,
                "updated_at": Self.timestamp(offset: index),
                "recorded_at": Self.timestamp(offset: index),
                "duration_ms": 1_000,
                "peak_kg": 20,
                "avg_kg": 15,
                "sample_count": 1,
                "note": NSNull(),
                "deleted_at": NSNull(),
            ]
        }
        lock.unlock()
    }

    func seedTag(name: String, hidden: Bool) {
        lock.lock()
        tags.append([
            "name": name,
            "hidden": hidden,
            "updated_at": Self.timestamp(offset: 100),
        ])
        lock.unlock()
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeTagProtocol.self]
        FakeTagProtocol.server = self
        return URLSession(configuration: configuration)
    }

    /// Nil means "fail at the transport layer" (offline, or a lost response).
    func reply(for request: URLRequest, body: Data?) -> Reply? {
        let path = request.url?.path ?? ""
        waitIfHoldingRename(path: path)
        lock.lock()
        defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        requests.append(
            RequestRecord(
                method: method,
                path: path,
                query: request.url?.query ?? "",
                body: body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            )
        )
        guard online else { return nil }

        if path.hasSuffix("/rpc/rename_tindeq_tag") {
            renameRequests += 1
            let payload = Self.object(from: body) ?? [:]
            let oldName = (payload["old_name"] as? String) ?? ""
            let newName = ((payload["new_name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else {
                return Reply(status: 422, body: Data(#"{"message":"Tag name can't be empty"}"#.utf8))
            }
            if newName != oldName {
                let carriedRow = tags.contains { ($0["name"] as? String) == oldName }
                let drop = pendingRepointDrop
                pendingRepointDrop = nil
                for index in recordings.indices where (recordings[index]["tag"] as? String) == oldName {
                    if let drop, (recordings[index]["id"] as? String) == drop { continue }
                    recordings[index]["tag"] = newName
                    recordings[index]["updated_at"] = Self.timestamp(offset: 200)
                }
                if carriedRow, !tags.contains(where: { ($0["name"] as? String) == newName }) {
                    tags.append([
                        "name": newName,
                        "hidden": false,
                        "updated_at": Self.timestamp(offset: 200),
                    ])
                }
                tags.removeAll { ($0["name"] as? String) == oldName }
            }
            if dropsNextRenameAcknowledgement {
                dropsNextRenameAcknowledgement = false
                return nil
            }
            return Reply(status: 204, body: Data())
        }

        if path.hasSuffix("/tindeq_tags") {
            switch method {
            case "GET":
                let ordered = tags.sorted {
                    let lhs = ($0["updated_at"] as? String) ?? ""
                    let rhs = ($1["updated_at"] as? String) ?? ""
                    if lhs != rhs { return lhs < rhs }
                    return (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "")
                }
                return Reply(status: 200, body: Self.json(ordered))
            case "POST", "PATCH":
                tagUpserts += 1
                let payload = Self.object(from: body) ?? [:]
                let name = (payload["name"] as? String) ?? ""
                let hidden = (payload["hidden"] as? Bool) ?? false
                if let index = tags.firstIndex(where: { ($0["name"] as? String) == name }) {
                    tags[index]["hidden"] = hidden
                    tags[index]["updated_at"] = Self.timestamp(offset: 300)
                } else {
                    tags.append([
                        "name": name,
                        "hidden": hidden,
                        "updated_at": Self.timestamp(offset: 300),
                    ])
                }
                if dropsNextTagUpsertAcknowledgement {
                    dropsNextTagUpsertAcknowledgement = false
                    return nil
                }
                return Reply(status: 201, body: Data())
            default:
                return Reply(status: 405, body: Data())
            }
        }

        if path.hasSuffix("/tindeq_recordings") {
            let ordered = recordings.sorted {
                let lhs = ($0["updated_at"] as? String) ?? ""
                let rhs = ($1["updated_at"] as? String) ?? ""
                if lhs != rhs { return lhs < rhs }
                return (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "")
            }
            return Reply(status: 200, body: Self.json(ordered))
        }

        return Reply(status: 200, body: Data("[]".utf8))
    }

    private func waitIfHoldingRename(path: String) {
        guard path.hasSuffix("/rpc/rename_tindeq_tag") else { return }
        condition.lock()
        guard pendingRenameHolds > 0 else {
            condition.unlock()
            return
        }
        pendingRenameHolds -= 1
        holding = true
        condition.broadcast()
        let generation = releaseGeneration
        var waited = 0.0
        while holding, releaseGeneration == generation, waited < 10 {
            condition.wait(until: Date().addingTimeInterval(0.05))
            waited += 0.05
        }
        holding = false
        condition.unlock()
    }

    private static func object(from body: Data?) -> [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func json(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    }

    private static func timestamp(offset: Int = 0) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(
            from: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
        )
    }
}

private final class FakeTagProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeTagPostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body to URLProtocol as a stream, never as
        // `httpBody`; the JSON payload must be drained from the stream here.
        let body = Self.drain(request.httpBodyStream)
        guard let server = Self.server, let reply = server.reply(for: request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// In-memory auth storage (duplicated from the other app-target suites; those
/// copies are file-private).
private final class InMemoryAuthStorage: AuthLocalStorage {
    private var store: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        store[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        store[key]
    }

    func remove(key: String) throws {
        store.removeValue(forKey: key)
    }
}

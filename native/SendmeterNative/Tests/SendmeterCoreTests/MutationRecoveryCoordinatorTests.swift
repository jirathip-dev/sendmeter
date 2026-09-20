import Foundation
import XCTest
@testable import SendmeterCore

/// #935: behaviour tests for the durable mutation recovery owner.
///
/// They run on the HOST against the REAL durable queue — `DurableQueue`, the
/// app's single `pending-writes.json` format — with the network uploader
/// injected as a closure. No app model, no UIKit/SwiftUI, no simulator and no
/// Bluetooth initialisation is involved (AC2), and the queue's own
/// persistence, revision, backoff and quarantine semantics are the production
/// ones (AC1: there is no second queue to test against).
@MainActor
final class MutationRecoveryCoordinatorTests: XCTestCase {
    private struct TestPayload: Codable, Equatable, Sendable {
        let value: String
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Harness

    private func makeQueue() throws -> DurableQueue<TestPayload> {
        try DurableQueue<TestPayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
    }

    /// The live account state a boundary re-checks. Production reads
    /// `AppModel.currentUserID`/`accountEpoch`; here the test owns the same two
    /// values, so an account switch or an epoch bump is exactly what the fence
    /// observes.
    private final class LiveAccount: @unchecked Sendable {
        var userID: UUID?
        var epoch: UInt64

        init(userID: UUID?, epoch: UInt64) {
            self.userID = userID
            self.epoch = epoch
        }
    }

    private func boundary(
        for live: LiveAccount,
        captured: AccountScopedFetch
    ) -> WorkspaceAccountBoundary {
        WorkspaceAccountBoundary(fetch: captured) {
            live.userID == captured.accountUserID && live.epoch == captured.accountEpoch
        }
    }

    private func fetch(for live: LiveAccount) -> AccountScopedFetch {
        AccountScopedFetch(
            accountUserID: live.userID ?? UUID(),
            accountEpoch: live.epoch
        )
    }

    private func item(
        _ value: String,
        account: UUID,
        createdAt: Date = Date(),
        quarantined: QueueRejection? = nil
    ) -> DurableQueueItem<TestPayload> {
        DurableQueueItem(
            accountUserID: account,
            createdAt: createdAt,
            quarantined: quarantined,
            payload: TestPayload(value: value)
        )
    }

    // MARK: - AC1: one drain pass, one queue, one acknowledgement

    func testDrainAttemptsEveryDueItemOnceInQueueOrderAndAcknowledgesOnce() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let earlier = item("earlier", account: account, createdAt: Date(timeIntervalSince1970: 1_000))
        let later = item("later", account: account, createdAt: Date(timeIntervalSince1970: 2_000))
        _ = try await queue.enqueue(later)
        _ = try await queue.enqueue(earlier)

        var attempts: [UUID] = []
        var acknowledgements = 0
        let report = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                try? await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: { acknowledgements += 1 }
        )

        XCTAssertEqual(report.dueItems, 2)
        XCTAssertEqual(report.uploaded, 2)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.didAdoptResidues)
        XCTAssertFalse(report.accountChanged)
        XCTAssertEqual(
            attempts,
            [earlier.id, later.id],
            "the queue's own (nextAttemptAt, createdAt) order decides replay order"
        )
        XCTAssertEqual(acknowledgements, 1, "one pass publishes ONE acknowledgement")
        let remaining = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertTrue(remaining.isEmpty)
    }

    /// The residue adopters run BEFORE the due snapshot: a cache-only row has no
    /// replay intent, so a pass that snapshotted first could never address an
    /// item the adopters enqueue. The item is constructed INSIDE the adoption —
    /// the production shape — so its own `createdAt`/`nextAttemptAt` are newer
    /// than anything the pass captured at entry.
    func testDrainAdoptsResiduesBeforeItSnapshotsTheDueSet() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        var attempts: [UUID] = []
        var adoptedID: UUID?

        let report = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: {
                let adopted = DurableQueueItem(
                    accountUserID: account,
                    payload: TestPayload(value: "adopted-residue")
                )
                adoptedID = adopted.id
                _ = try? await queue.enqueue(adopted)
                return true
            },
            upload: { item, _ in
                attempts.append(item.id)
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertEqual(adoptedID, attempts.first, "the item the adopters presented is in this pass")
        XCTAssertEqual(attempts.count, 1, "exactly the residue this pass adopted")
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(report.dueItems, 1)
    }

    func testDrainReportsARefusedResidueAdoptionAndUploadsNothing() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        _ = try await queue.enqueue(item("due", account: account))
        var attempts = 0

        let report = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { false },
            upload: { _, _ in
                attempts += 1
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertFalse(report.didAdoptResidues)
        XCTAssertEqual(attempts, 0, "a refused adoption stops the pass before any upload")
    }

    // MARK: - AC4: lost acknowledgement

    /// The server applied the write but its response never arrived. The pass
    /// must leave exactly ONE durable intent, with its stable identity, so the
    /// next pass replays THAT identity instead of minting a second one.
    func testLostAcknowledgementKeepsOneDurableIntentWithStableIdentity() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = item("lost-ack", account: account)
        _ = try await queue.enqueue(intent)
        let originalRevision = intent.revision

        var attempts: [UUID] = []
        // Pass 1: the upload "succeeded" server-side, but the acknowledgement
        // (the durable removal) never happened.
        let first = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )
        XCTAssertEqual(first.uploaded, 1)

        let stillDurable = await queue.recoveryItem(id: intent.id, accountUserID: account)
        XCTAssertEqual(stillDurable?.id, intent.id, "no data loss: the intent is still durable")
        XCTAssertEqual(
            stillDurable?.revision,
            originalRevision,
            "a replay keeps the SAME identity/revision instead of a second intent"
        )
        let afterFirstPass = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertEqual(afterFirstPass.count, 1, "exactly one durable intent, never two")

        // Pass 2: the same identity replays and now the acknowledgement lands.
        let second = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                try? await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(attempts, [intent.id, intent.id], "the same identity, never a duplicate one")
        let drained = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertTrue(drained.isEmpty)
    }

    // MARK: - AC4: concurrent drains

    /// Two drains run at once over ONE identity. The upload path is
    /// single-flight (the app's own claim coordinator, used here exactly as the
    /// app uses it): the second pass must observe the owner and NOT adopt the
    /// item again.
    func testConcurrentDrainsAdoptTheSameIdentityOnlyOnce() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = item("concurrent", account: account)
        _ = try await queue.enqueue(intent)

        var claims = QueueUploadClaimCoordinator()
        var attempts: [UUID] = []
        var releaseFirstUpload: CheckedContinuation<Void, Never>?
        var firstUploadHeld = false
        let coordinator = MutationRecoveryCoordinator()
        let captured = fetch(for: live)
        let accountBoundary = boundary(for: live, captured: captured)

        @MainActor
        func upload(
            _ item: DurableQueueItem<TestPayload>,
            _ mode: QueueUploadMode
        ) async -> MutationUploadOutcome {
            let key = QueueUploadKey(itemID: item.id, accountUserID: item.accountUserID)
            guard let claim = claims.claim(key) else {
                // Another producer owns this identity: the deliberate no-op.
                return .noOp
            }
            attempts.append(key.itemID)
            if attempts.count == 1 {
                firstUploadHeld = true
                await withCheckedContinuation { continuation in
                    releaseFirstUpload = continuation
                }
            }
            claims.release(claim)
            try? await queue.remove(
                id: item.id,
                accountUserID: item.accountUserID,
                reason: "uploaded"
            )
            return MutationUploadOutcome(uploaded: true, failure: nil)
        }

        let first = Task {
            await coordinator.drain(
                boundary: accountBoundary,
                mode: .automatic,
                in: queue,
                adoptResidues: { true },
                upload: upload,
                acknowledge: {}
            )
        }
        for _ in 0..<600 where !firstUploadHeld {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(firstUploadHeld, "the first pass never reached its upload")

        let secondReport = await coordinator.drain(
            boundary: accountBoundary,
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: upload,
            acknowledge: {}
        )
        XCTAssertEqual(secondReport.uploaded, 0, "the identity is owned by the in-flight pass")
        XCTAssertEqual(
            secondReport.dueItems,
            1,
            "the due snapshot is a starting set, never a claim"
        )
        XCTAssertEqual(attempts.count, 1, "no double adoption while the first upload is in flight")

        releaseFirstUpload?.resume()
        let firstReport = await first.value
        XCTAssertEqual(firstReport.uploaded, 1)
        XCTAssertEqual(attempts, [intent.id], "one identity, one adoption")
        let remaining = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - AC4: cancellation

    func testCancelledPassStopsStartingUploadsAndLeavesTheRemainderDurable() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let first = item("first", account: account, createdAt: Date(timeIntervalSince1970: 1_000))
        let second = item("second", account: account, createdAt: Date(timeIntervalSince1970: 2_000))
        let third = item("third", account: account, createdAt: Date(timeIntervalSince1970: 3_000))
        for item in [first, second, third] { _ = try await queue.enqueue(item) }

        var cancelled = false
        var attempts: [UUID] = []
        let coordinator = MutationRecoveryCoordinator()
        let report = await coordinator.drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            isCancelled: { cancelled },
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                cancelled = true
                try? await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertTrue(report.isCancelled)
        XCTAssertEqual(attempts, [first.id], "a cancelled pass starts no further uploads")
        let remainder = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertEqual(
            remainder.map(\.id),
            [second.id, third.id],
            "no data loss: the remainder stays durable"
        )

        // The next pass picks the remainder up, each identity exactly once.
        var resumed: [UUID] = []
        let resumedReport = await coordinator.drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                resumed.append(item.id)
                try? await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )
        XCTAssertEqual(resumed, [second.id, third.id])
        XCTAssertEqual(resumedReport.uploaded, 2)
    }

    // MARK: - AC4: permanent rejection (backoff + quarantine budget)

    /// #675/#935: the failure path is ONE place. An automatic attempt spends the
    /// bounded permanent budget and quarantines at the bound; a manual retry is
    /// an explicit user action and never does.
    func testPermanentRejectionsQuarantineAtTheBoundedBudgetButManualRetriesNeverDo() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let automatic = item("automatic", account: account)
        let manual = item("manual", account: account)
        _ = try await queue.enqueue(automatic)
        _ = try await queue.enqueue(manual)
        let coordinator = MutationRecoveryCoordinator()
        let failure = MutationUploadFailure(
            classification: .permanent,
            code: "23505",
            detail: "duplicate key value violates unique constraint"
        )

        for _ in 0..<(DurableQueueItem<TestPayload>.maxPermanentAttempts - 1) {
            let applied = await coordinator.recordFailure(
                item: automatic,
                failure: failure,
                mode: .automatic,
                in: queue
            )
            XCTAssertTrue(applied)
        }
        let notYet = await queue.recoveryItem(id: automatic.id, accountUserID: account)
        XCTAssertNil(notYet?.quarantined, "the bounded budget is not spent yet")

        let applied = await coordinator.recordFailure(
            item: automatic,
            failure: failure,
            mode: .automatic,
            in: queue
        )
        XCTAssertTrue(applied)
        let quarantined = await queue.recoveryItem(id: automatic.id, accountUserID: account)
        XCTAssertEqual(quarantined?.quarantined?.kind, .permanent)
        XCTAssertEqual(quarantined?.quarantined?.code, "23505")
        XCTAssertEqual(
            quarantined?.quarantined?.detail,
            "duplicate key value violates unique constraint",
            "the diagnostic is the recorded failure, not a summary"
        )

        // #675 F5: the manual retry never spends the budget, however many times
        // the explicit action is repeated.
        for _ in 0..<(DurableQueueItem<TestPayload>.maxPermanentAttempts + 3) {
            _ = await coordinator.recordFailure(
                item: manual,
                failure: failure,
                mode: .manual,
                in: queue
            )
        }
        let stillActive = await queue.recoveryItem(id: manual.id, accountUserID: account)
        XCTAssertNil(
            stillActive?.quarantined,
            "an explicit user retry must never be what quarantines an entry"
        )

        // The quarantined entry is invisible to the automatic drain forever
        // after: no automatic attempt may re-arm it.
        var attempts: [UUID] = []
        _ = await coordinator.drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )
        XCTAssertFalse(attempts.contains(automatic.id), "a quarantined entry is never auto-retried")
    }

    /// The failure record is fenced by the identity's captured revision, so an
    /// old request cannot spend a newer replacement's budget or stamp its error
    /// against it.
    func testFailureRecordIsFencedByTheCapturedRevision() async throws {
        let queue = try makeQueue()
        let account = UUID()
        let stale = item("stale", account: account)
        _ = try await queue.enqueue(stale)
        let replacement = DurableQueueItem(
            id: stale.id,
            accountUserID: account,
            payload: TestPayload(value: "replacement")
        )
        let replaced = try await queue.enqueueIfCurrent(
            replacement,
            expectedRevision: stale.revision
        )
        XCTAssertTrue(replaced, "the newer replacement won the identity")

        let applied = await MutationRecoveryCoordinator().recordFailure(
            item: stale,
            failure: MutationUploadFailure(classification: .permanent, code: "23505", detail: "old"),
            mode: .automatic,
            in: queue
        )
        XCTAssertFalse(applied, "an old request must not touch the replacement")
        let current = await queue.recoveryItem(id: stale.id, accountUserID: account)
        XCTAssertEqual(current?.attempts, 0)
        XCTAssertNil(current?.quarantined)
        XCTAssertNil(current?.lastFailure)
    }

    // MARK: - AC4: account switch

    func testAccountSwitchStopsThePassLeavingTheOldAccountsIntentsDurable() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let first = item("first", account: account, createdAt: Date(timeIntervalSince1970: 1_000))
        let second = item("second", account: account, createdAt: Date(timeIntervalSince1970: 2_000))
        _ = try await queue.enqueue(first)
        _ = try await queue.enqueue(second)
        let coordinator = MutationRecoveryCoordinator()
        let captured = fetch(for: live)

        var attempts: [UUID] = []
        let report = await coordinator.drain(
            boundary: boundary(for: live, captured: captured),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                // The account switches while the first upload is in flight.
                live.userID = UUID()
                live.epoch += 1
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertTrue(report.accountChanged)
        XCTAssertEqual(attempts, [first.id], "the pass starts no upload for a stale account")
        let stillDurable = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertEqual(
            stillDurable.map(\.id),
            [first.id, second.id],
            "no data loss: the old account's intents stay durable for its next sign-in"
        )
    }

    func testANewAccountsPassNeverAdoptsThePreviousAccountsIntents() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let previousAccount = live.userID!
        let previousIntent = item("previous-account", account: previousAccount)
        _ = try await queue.enqueue(previousIntent)
        live.userID = UUID()
        live.epoch += 1
        let nextAccount = live.userID!
        let nextIntent = item("next-account", account: nextAccount)
        _ = try await queue.enqueue(nextIntent)

        var attempts: [UUID] = []
        let report = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertEqual(attempts, [nextIntent.id], "the pass is account-scoped by construction")
        XCTAssertEqual(report.dueItems, 1)
        let previousRemainder = await queue.recoveryActiveItems(accountUserID: previousAccount)
        XCTAssertEqual(previousRemainder.map(\.id), [previousIntent.id])
    }

    // MARK: - The manual retry loop

    func testManualRetryWaitsForTheInFlightOwnerAndThenUploadsOnce() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = item("owned-elsewhere", account: account)
        _ = try await queue.enqueue(intent)
        let key = QueueUploadKey(itemID: intent.id, accountUserID: account)

        var claimed = true
        var waitedForOwner = 0
        var attempts: [UUID] = []
        let outcome = await MutationRecoveryCoordinator().retryOne(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue,
            isClaimed: { _ in claimed },
            waitForOwner: { _ in
                waitedForOwner += 1
                claimed = false
            },
            upload: { item, mode in
                XCTAssertEqual(mode, .manual, "an explicit retry bypasses ordinary backoff")
                attempts.append(item.id)
                try? await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
                return MutationUploadOutcome(uploaded: true, failure: nil)
            }
        )

        XCTAssertEqual(outcome, .uploaded)
        XCTAssertEqual(waitedForOwner, 1, "the owner is awaited before the re-read")
        XCTAssertEqual(attempts, [intent.id])
        XCTAssertFalse(claimed)
        XCTAssertEqual(key.itemID, intent.id)
    }

    func testManualRetryStopsOnAQuarantinedIdentity() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = item(
            "quarantined",
            account: account,
            quarantined: QueueRejection(
                kind: .permanent,
                at: Date(timeIntervalSince1970: 5_000),
                code: "23505",
                detail: "duplicate key"
            )
        )
        _ = try await queue.enqueue(intent)

        var attempts = 0
        let outcome = await MutationRecoveryCoordinator().retryOne(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue,
            isClaimed: { _ in false },
            waitForOwner: { _ in },
            upload: { _, _ in
                attempts += 1
                return MutationUploadOutcome(uploaded: true, failure: nil)
            }
        )

        XCTAssertEqual(outcome, .notAttempted)
        XCTAssertEqual(attempts, 0, "quarantine is terminal for the manual drain path")
    }

    /// #920 AC4: one pass per account. A second claim while a pass owns the
    /// account is refused, and only the owner may release it.
    func testRetryGateCoalescesASecondPassAndOnlyItsOwnerReleasesIt() {
        let account = UUID()
        let fetch = AccountScopedFetch(accountUserID: account, accountEpoch: 1)
        var gate = MutationRetryGate()

        guard let owner = gate.claim(fetch) else {
            return XCTFail("the first pass must own the account")
        }
        XCTAssertNil(gate.claim(fetch), "a second tap coalesces onto the running pass")

        let other = MutationRetryOwnership(fetch: fetch)
        XCTAssertFalse(gate.owns(other, isCurrent: true), "an older pass cannot finish a newer one")
        XCTAssertFalse(
            gate.finish(other, isCurrent: true),
            "a non-owner cannot release the pass"
        )
        XCTAssertTrue(gate.owns(owner, isCurrent: true))
        XCTAssertFalse(
            gate.owns(owner, isCurrent: false),
            "an account switch makes the pass stale"
        )
        XCTAssertFalse(
            gate.finish(owner, isCurrent: false),
            "a stale account cannot finish the next account's progress"
        )
        XCTAssertTrue(gate.finish(owner, isCurrent: true))
        XCTAssertTrue(gate.owns(owner, isCurrent: true) == false)
        XCTAssertNotNil(gate.claim(fetch), "the gate is reusable once released")
    }

    // MARK: - Quarantine recovery (#675 F7/N1)

    private func quarantinedItem(
        _ value: String,
        account: UUID,
        at: Date = Date(timeIntervalSince1970: 5_000)
    ) -> DurableQueueItem<TestPayload> {
        item(
            value,
            account: account,
            quarantined: QueueRejection(
                kind: .permanent,
                at: at,
                code: "23505",
                detail: "duplicate key value violates unique constraint"
            )
        )
    }

    /// #675 F7 + N1: a failed manual retry re-stamps the PRIOR rejection
    /// verbatim (kind, code, detail AND `at`) instead of leaving the entry
    /// active on the hot drain path.
    func testFailedManualQuarantineRetryRestampsThePriorRejectionVerbatim() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let rejectionAt = Date(timeIntervalSince1970: 5_000)
        let intent = quarantinedItem("rejected", account: account, at: rejectionAt)
        _ = try await queue.enqueue(intent)
        var attempts = 0

        let report = await MutationRecoveryCoordinator().retryQuarantined(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue,
            prepare: { true },
            upload: { _, _ in
                attempts += 1
                return MutationUploadOutcome(
                    uploaded: false,
                    failure: MutationUploadFailure(
                        classification: .retryable,
                        code: nil,
                        detail: "the network is unreachable"
                    )
                )
            },
            acknowledge: {}
        )

        XCTAssertEqual(report.attempted, 1)
        XCTAssertEqual(report.recovered, 0)
        XCTAssertEqual(attempts, 1)
        let requarantined = await queue.recoveryItem(id: intent.id, accountUserID: account)
        XCTAssertEqual(requarantined?.quarantined?.kind, .permanent)
        XCTAssertEqual(requarantined?.quarantined?.code, "23505")
        XCTAssertEqual(
            requarantined?.quarantined?.detail,
            "duplicate key value violates unique constraint"
        )
        XCTAssertEqual(
            requarantined?.quarantined?.at,
            rejectionAt,
            "the diagnostic survives a transient manual failure verbatim"
        )

        // Never auto-retried again (#675 F7).
        var automaticAttempts: [UUID] = []
        _ = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                automaticAttempts.append(item.id)
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )
        XCTAssertFalse(automaticAttempts.contains(intent.id))
    }

    func testFreshPermanentRejectionOnTheManualRetryReplacesTheStamp() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = quarantinedItem("still-bad", account: account)
        _ = try await queue.enqueue(intent)

        let report = await MutationRecoveryCoordinator().retryQuarantined(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue,
            prepare: { true },
            upload: { _, _ in
                MutationUploadOutcome(
                    uploaded: false,
                    failure: MutationUploadFailure(
                        classification: .permanent,
                        code: "23514",
                        detail: "check constraint violated by the new payload"
                    )
                )
            },
            acknowledge: {}
        )

        XCTAssertEqual(report.attempted, 1)
        let restamped = await queue.recoveryItem(id: intent.id, accountUserID: account)
        XCTAssertEqual(
            restamped?.quarantined?.code,
            "23514",
            "a FRESH permanent rejection replaces the prior diagnostic"
        )
        XCTAssertEqual(
            restamped?.quarantined?.detail,
            "check constraint violated by the new payload"
        )
    }

    func testSuccessfulManualQuarantineRetryClearsTheStampAndTheEntry() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = quarantinedItem("recoverable", account: account)
        _ = try await queue.enqueue(intent)
        let coordinator = MutationRecoveryCoordinator()

        var uploads = 0
        let report = await coordinator.retryQuarantined(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue,
            prepare: { true },
            upload: { item, _ in
                uploads += 1
                XCTAssertEqual(
                    item.id,
                    intent.id,
                    "the pass hands over the entry's stable identity (the uploader re-reads the durable item)"
                )
                try? await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertEqual(report.attempted, 1)
        XCTAssertEqual(report.recovered, 1)
        XCTAssertEqual(uploads, 1)
        let quarantined = await queue.recoveryQuarantinedItems(accountUserID: account)
        XCTAssertTrue(quarantined.isEmpty)
        let active = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertTrue(active.isEmpty)
    }

    func testQuarantineRetrySkipsEntriesWhenItsPreparationRefuses() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = quarantinedItem("prepared", account: account)
        _ = try await queue.enqueue(intent)
        var uploads = 0

        let report = await MutationRecoveryCoordinator().retryQuarantined(
            id: nil,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue,
            prepare: { false },
            upload: { _, _ in
                uploads += 1
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertFalse(report.didPrepare)
        XCTAssertEqual(uploads, 0)
        let stillQuarantined = await queue.recoveryItem(id: intent.id, accountUserID: account)
        XCTAssertNotNil(
            stillQuarantined?.quarantined,
            "a refused preparation must not clear a rejection stamp"
        )
    }

    // MARK: - Quarantine discard

    func testDiscardRemovesTheEntryOnlyUnderItsCapturedRevision() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = quarantinedItem("discardable", account: account)
        _ = try await queue.enqueue(intent)
        let coordinator = MutationRecoveryCoordinator()

        // A newer replacement owns the identity: the stale snapshot must lose.
        let replacement = DurableQueueItem(
            id: intent.id,
            accountUserID: account,
            payload: TestPayload(value: "replacement")
        )
        _ = try await queue.enqueueIfCurrent(replacement, expectedRevision: intent.revision)
        let stale = await coordinator.discardQuarantined(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue
        )
        XCTAssertEqual(stale?.discarded, false)
        let survivor = await queue.recoveryItem(id: intent.id, accountUserID: account)
        XCTAssertEqual(survivor?.revision, replacement.revision)
    }

    func testDiscardRemovesAQuarantinedEntryAndReportsTheCapturedItem() async throws {
        let queue = try makeQueue()
        let live = LiveAccount(userID: UUID(), epoch: 1)
        let account = live.userID!
        let intent = quarantinedItem("gone", account: account)
        _ = try await queue.enqueue(intent)

        let discard = await MutationRecoveryCoordinator().discardQuarantined(
            id: intent.id,
            boundary: boundary(for: live, captured: fetch(for: live)),
            in: queue
        )

        XCTAssertEqual(discard?.discarded, true)
        XCTAssertEqual(discard?.item?.id, intent.id)
        let remaining = await queue.recoveryItem(id: intent.id, accountUserID: account)
        XCTAssertNil(remaining)
    }

    // MARK: - AC3: an existing persisted queue file stays readable

    /// The queue file this fixture describes was written by the app BEFORE this
    /// extraction (an item with no `revision`/`orderingKey` predates the replay
    /// envelope, and the quarantined entry carries a #675 stamp). It must stay
    /// readable, keep its replay ORDER and its stable identity, and the
    /// quarantined entry must stay out of the automatic drain.
    func testPersistedQueueFixtureStaysReadableWithOrderingAndStableIdentity() async throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(
                forResource: "mutation-recovery-legacy-queue",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let account = try XCTUnwrap(
            UUID(uuidString: "93500000-0000-0000-0000-0000000000aa")
        )
        let firstID = try XCTUnwrap(UUID(uuidString: "93500000-0000-0000-0000-0000000000b1"))
        let secondID = try XCTUnwrap(UUID(uuidString: "93500000-0000-0000-0000-0000000000b2"))
        let quarantinedID = try XCTUnwrap(UUID(uuidString: "93500000-0000-0000-0000-0000000000b3"))
        try FileManager.default.copyItem(
            at: fixture,
            to: directory.appendingPathComponent("pending-writes.json")
        )

        let queue = try makeQueue()
        let live = LiveAccount(userID: account, epoch: 1)
        var attempts: [UUID] = []
        let report = await MutationRecoveryCoordinator().drain(
            boundary: boundary(for: live, captured: fetch(for: live)),
            mode: .automatic,
            in: queue,
            adoptResidues: { true },
            upload: { item, _ in
                attempts.append(item.id)
                return MutationUploadOutcome(uploaded: true, failure: nil)
            },
            acknowledge: {}
        )

        XCTAssertEqual(
            attempts,
            [firstID, secondID],
            "the persisted order (nextAttemptAt, then createdAt) survives the extraction"
        )
        XCTAssertEqual(report.dueItems, 2)
        XCTAssertFalse(
            attempts.contains(quarantinedID),
            "a persisted #675 quarantine is still never auto-retried"
        )
        let quarantined = await queue.recoveryQuarantinedItems(accountUserID: account)
        XCTAssertEqual(quarantined.map(\.id), [quarantinedID])
        XCTAssertEqual(quarantined.first?.quarantined?.code, "23505")
        XCTAssertEqual(
            quarantined.first?.quarantined?.detail,
            "duplicate key value violates unique constraint"
        )
        let active = await queue.recoveryActiveItems(accountUserID: account)
        XCTAssertEqual(
            active.map(\.id),
            [firstID, secondID],
            "stable identity: the persisted ids are the ones the owner replays"
        )
        XCTAssertNotNil(
            active.first?.revision,
            "a pre-revision item decodes with a fresh claim token, never a missing one"
        )
    }
}

import XCTest
@testable import SendmeterCore

/// #920: the pending/sync status is derived in ONE place, from acknowledged
/// answers only. These pin the four honest states, the retry availability, and
/// the copy rules that keep a local save from reading as a remote sync.
final class MutationSyncStatusTests: XCTestCase {

    // MARK: - AC1: the four states, and never "Synced" from an uninitialized zero

    func testUnloadedCountsAreNotLoadedRatherThanSynced() {
        // The pre-#920 defect: a zero queue count plus a zero pending-cache
        // count before either had been read rendered as "Synced".
        let status = MutationSyncStatus.resolve(MutationSyncStatusInputs())
        XCTAssertEqual(status.state, .notLoaded)
        XCTAssertNotEqual(status.statusLabel, "Synced")
        XCTAssertEqual(status.retry, .hidden)
        XCTAssertNil(status.quarantinedCount)
    }

    func testUnreadQuarantineListKeepsTheStatusNotLoaded() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(hasLoadedPendingWrites: true, quarantinedCount: nil)
        )
        XCTAssertEqual(status.state, .notLoaded)
        XCTAssertNotEqual(status.statusLabel, "Synced")
    }

    func testReadAndEmptyIsTheOnlySynced() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(hasLoadedPendingWrites: true, quarantinedCount: 0)
        )
        XCTAssertEqual(status.state, .synced)
        XCTAssertEqual(status.statusLabel, "Synced")
        XCTAssertEqual(status.retry, .unavailable(.nothingPending))
        XCTAssertFalse(
            (status.retryUnavailableExplanation ?? "").contains("Synced"),
            "the disabled-retry note explains the absence of work, not a sync claim"
        )
        XCTAssertNotNil(status.retryUnavailableExplanation)
    }

    func testQueueWorkIsAwaitingUpload() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                queuedCount: 2,
                quarantinedCount: 0
            )
        )
        XCTAssertEqual(status.state, .awaitingUpload)
        XCTAssertEqual(status.statusLabel, "2 waiting to upload")
        XCTAssertEqual(status.retry, .ready)
        XCTAssertTrue(status.explanation.contains("queued upload"))
        XCTAssertFalse(status.explanation.lowercased().contains("synced"))
    }

    func testCacheOnlyWorkIsAwaitingUploadAndSaysItIsNotUploadedYet() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                unsyncedCacheCount: 1,
                quarantinedCount: 0
            )
        )
        XCTAssertEqual(status.state, .awaitingUpload)
        XCTAssertEqual(status.statusLabel, "1 waiting to upload")
        XCTAssertEqual(status.retry, .ready)
        XCTAssertTrue(status.explanation.contains("saved on this iPhone"))
        XCTAssertTrue(status.explanation.contains("not uploaded yet"))
    }

    func testMixedWorkNamesBothChannels() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                queuedCount: 3,
                unsyncedCacheCount: 2,
                quarantinedCount: 0
            )
        )
        XCTAssertEqual(status.state, .awaitingUpload)
        XCTAssertEqual(status.pendingCount, 5)
        XCTAssertEqual(status.statusLabel, "5 waiting to upload")
        XCTAssertTrue(status.explanation.contains("3 queued uploads"))
        XCTAssertTrue(status.explanation.contains("2 local changes"))
    }

    func testQuarantinedWorkIsNeedsAttentionNotAwaitingUpload() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                queuedCount: 1,
                quarantinedCount: 2
            )
        )
        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.statusLabel, "2 rejected")
        // The quarantine keeps its own row-level Retry/Discard: the queue
        // retry never claims to cover it.
        XCTAssertEqual(status.retry, .ready)
        XCTAssertTrue(status.explanation.contains("server rejected"))
    }

    func testQuarantineWithNothingQueuedHidesTheQueueRetry() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                quarantinedCount: 1
            )
        )
        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.retry, .hidden)
    }

    // MARK: - AC2: a retry is offered only for work it reaches

    func testResidueThatSurvivedARetryLosesTheRetryAndExplainsWhy() {
        let outcome = MutationRetryOutcome(
            accountUserID: UUID(),
            queuedBefore: 1,
            queuedAfter: 0,
            unsyncedBefore: 2,
            unsyncedAfter: 1,
            quarantinedAfter: 0
        )
        XCTAssertEqual(outcome.unresolvedResidueCount, 1)
        XCTAssertTrue(outcome.changedAnything)

        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                unsyncedCacheCount: 1,
                quarantinedCount: 0,
                lastRetryOutcome: outcome
            )
        )
        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.retry, .unavailable(.noUploadPath))
        XCTAssertEqual(status.statusLabel, "1 stayed on this iPhone")
        let explanation = status.retryUnavailableExplanation
        XCTAssertNotNil(explanation)
        XCTAssertTrue(explanation?.contains("Retrying cannot move") ?? false)
    }

    func testTransientQueueFailureKeepsTheRetryReady() {
        // The queue still holds the work, so another tap is meaningful even
        // though the last pass moved nothing.
        let outcome = MutationRetryOutcome(
            accountUserID: UUID(),
            queuedBefore: 1,
            queuedAfter: 1,
            unsyncedBefore: 1,
            unsyncedAfter: 1,
            quarantinedAfter: 0
        )
        XCTAssertEqual(outcome.unresolvedResidueCount, 0, "a queue-held failure is not a residue")
        XCTAssertFalse(outcome.changedAnything)
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                queuedCount: 1,
                unsyncedCacheCount: 1,
                quarantinedCount: 0,
                lastRetryOutcome: outcome
            )
        )
        XCTAssertEqual(status.state, .awaitingUpload)
        XCTAssertEqual(status.retry, .ready)
    }

    func testResidueIsRetryableBeforeAnyPassHasRun() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                unsyncedCacheCount: 1,
                quarantinedCount: 0
            )
        )
        XCTAssertEqual(status.retry, .ready, "the first pass can still adopt the row")
    }

    // MARK: - AC4: coalescing progress and account scope

    func testARunningPassIsPublishedAsInFlightAndNotRetryable() {
        let status = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                queuedCount: 2,
                quarantinedCount: 0,
                isRetrying: true
            )
        )
        XCTAssertEqual(status.retry, .inFlight)
        XCTAssertNil(status.retryUnavailableExplanation)
    }

    func testStaleOutcomeDoesNotDisableAnotherAccountsResidueRetry() {
        // The outcome carries its own account, so a pass for account A cannot
        // disable B's retry: B's inputs carry only B's own measured pass.
        let accountA = UUID()
        let accountB = UUID()
        let outcomeA = MutationRetryOutcome(
            accountUserID: accountA,
            queuedBefore: 1,
            queuedAfter: 0,
            unsyncedBefore: 1,
            unsyncedAfter: 1,
            quarantinedAfter: 0
        )
        XCTAssertEqual(outcomeA.accountUserID, accountA)
        XCTAssertEqual(outcomeA.unresolvedResidueCount, 1)

        let statusB = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                unsyncedCacheCount: 1,
                quarantinedCount: 0,
                lastRetryOutcome: nil
            )
        )
        XCTAssertEqual(statusB.retry, .ready)
        XCTAssertNotEqual(statusB.state, .needsAttention)

        let statusA = MutationSyncStatus.resolve(
            MutationSyncStatusInputs(
                hasLoadedPendingWrites: true,
                unsyncedCacheCount: 1,
                quarantinedCount: 0,
                lastRetryOutcome: outcomeA
            )
        )
        XCTAssertEqual(statusA.retry, .unavailable(.noUploadPath))
    }
}

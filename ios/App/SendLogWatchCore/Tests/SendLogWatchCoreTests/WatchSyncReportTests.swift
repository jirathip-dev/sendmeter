import XCTest
import SendLogWatchCore

private func pairing(
    supported: Bool = true,
    activated: Bool = true,
    paired: Bool = true,
    appInstalled: Bool = true
) -> WatchPairing {
    WatchPairing(
        supported: supported, activated: activated,
        paired: paired, appInstalled: appInstalled
    )
}

/// Issue #21: the watch's offline upload queues piggyback their depth on the
/// messages it already sends (#228's channel), so a workout stuck on the wrist
/// is visible from the phone. These cover the wire contract and the verdict —
/// the view only maps a status to text.
final class PendingSyncStampingTests: XCTestCase {
    private let identity = BuildIdentity(version: "1.4.0", build: "57")

    func testRoundTripsThroughAMessage() {
        let msg = WatchBuildReport.stamped(
            ["kind": "liveWorkout", "status": "live"], with: identity, pendingSync: 3
        )
        XCTAssertEqual(msg["kind"] as? String, "liveWorkout")
        XCTAssertEqual(WatchBuildReport.pendingSync(in: msg), 3)
        // The build report still rides the same message untouched.
        XCTAssertEqual(WatchBuildReport.identity(in: msg), identity)
    }

    func testAnEmptyQueueIsReportedRatherThanOmitted() {
        // Zero is a fact worth sending: "the queue drained" is exactly what
        // distinguishes a healthy watch from one that never reported.
        let msg = WatchBuildReport.stamped(["kind": "requestSession"], with: identity, pendingSync: 0)
        XCTAssertEqual(WatchBuildReport.pendingSync(in: msg), 0)
    }

    func testUnknownCountLeavesTheMessageUntouched() {
        // Reporting is observability: it must never be able to damage the
        // message it rides on.
        let msg = WatchBuildReport.stamped(["kind": "requestSession"], with: nil, pendingSync: nil)
        XCTAssertEqual(msg.count, 1)
        XCTAssertNil(WatchBuildReport.pendingSync(in: msg))
    }

    func testCountRidesEvenWhenTheBuildIsUnknown() {
        // The two facts are independent — a build that failed to read must not
        // take the queue depth down with it.
        let msg = WatchBuildReport.stamped(["kind": "liveForce"], with: nil, pendingSync: 2)
        XCTAssertEqual(WatchBuildReport.pendingSync(in: msg), 2)
        XCTAssertNil(WatchBuildReport.identity(in: msg))
    }

    func testUnstampedMessageYieldsNoCount() {
        // A pre-#21 watch reports nothing, which must read as unknown rather
        // than as an empty queue.
        XCTAssertNil(WatchBuildReport.pendingSync(in: ["kind": "liveForce", "kg": 12.5]))
    }

    func testNegativeCountsAreRefusedOnBothSides() {
        let msg = WatchBuildReport.stamped(["kind": "liveForce"], with: nil, pendingSync: -1)
        XCTAssertNil(msg[WatchBuildReport.pendingSyncKey])
        XCTAssertNil(WatchBuildReport.pendingSync(in: [WatchBuildReport.pendingSyncKey: -4]))
    }

    func testReadsANumberThatCameBackAsADouble() {
        // WatchConnectivity round-trips numbers as NSNumber; the bridged
        // Swift type on the far side isn't guaranteed to be Int.
        XCTAssertEqual(WatchBuildReport.pendingSync(in: [WatchBuildReport.pendingSyncKey: 4.0]), 4)
    }

    func testStrippingLeavesTheOriginalPayloadShape() {
        // The live-workout / live-force payloads are forwarded to the WebView
        // as-is; no report field may leak into those message types.
        let stamped = WatchBuildReport.stamped(
            ["kind": "liveForce", "kg": 12.5], with: identity, pendingSync: 3
        )
        let stripped = WatchBuildReport.stripped(stamped)
        XCTAssertEqual(stripped.count, 2)
        XCTAssertEqual(stripped["kg"] as? Double, 12.5)
        XCTAssertNil(stripped[WatchBuildReport.pendingSyncKey])
        XCTAssertNil(stripped[WatchBuildReport.versionKey])
        XCTAssertNil(stripped[WatchBuildReport.buildKey])
    }
}

final class WatchSyncStatusTests: XCTestCase {
    func testEmptyQueueIsNotTheSameAsNeverReported() {
        // The whole honest-states rule for #21: a watch that has never told us
        // anything must not render as a drained queue.
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 0, pairing: pairing()), .empty
        )
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: nil, pairing: pairing()), .notReported
        )
    }

    func testAFewItemsArePendingRatherThanBackedUp() {
        // Normal right after a basement session — the queue drains on the next
        // launch or foreground.
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 1, pairing: pairing()), .pending
        )
        XCTAssertEqual(
            WatchBuildReport.syncStatus(
                pendingSync: WatchBuildReport.backedUpThreshold - 1, pairing: pairing()
            ),
            .pending
        )
    }

    func testEnoughItemsReadAsBackedUp() {
        XCTAssertEqual(
            WatchBuildReport.syncStatus(
                pendingSync: WatchBuildReport.backedUpThreshold, pairing: pairing()
            ),
            .backedUp
        )
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 42, pairing: pairing()), .backedUp
        )
    }

    func testPairingProblemsBeatAnyStoredCount() {
        // A count from a watch that has since been unpaired is history, not
        // the state of a paired device.
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 3, pairing: pairing(paired: false)), .notPaired
        )
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 0, pairing: pairing(supported: false)),
            .notPaired
        )
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 3, pairing: pairing(appInstalled: false)),
            .appNotInstalled
        )
    }

    func testPreActivationIsUnknownRatherThanEmpty() {
        // isPaired/isWatchAppInstalled mean nothing before activation, so the
        // honest answer is "can't tell", not "nothing pending".
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: 0, pairing: pairing(activated: false)),
            .unknown
        )
    }

    func testNegativeCountIsTreatedAsNoReading() {
        XCTAssertEqual(
            WatchBuildReport.syncStatus(pendingSync: -1, pairing: pairing()), .notReported
        )
    }
}

final class PendingSyncStalenessTests: XCTestCase {
    private let now: Double = 1_780_000_000

    func testAFreshReportIsNotStale() {
        XCTAssertFalse(
            WatchBuildReport.isPendingSyncStale(reportedAt: now - 60, now: now)
        )
        XCTAssertFalse(
            WatchBuildReport.isPendingSyncStale(
                reportedAt: now - WatchBuildReport.pendingSyncStaleAfterS + 1, now: now
            )
        )
    }

    func testAnOldReportIsStale() {
        // Three days on, "4 pending" describes a queue that may well have
        // drained since — the count is still all we have, but it isn't current.
        XCTAssertTrue(
            WatchBuildReport.isPendingSyncStale(reportedAt: now - 3 * 24 * 60 * 60, now: now)
        )
    }

    func testNoReportIsNotCalledStale() {
        // Nothing was ever reported: `notReported` is the honest state, and
        // calling it stale on top would be a second, contradictory claim.
        XCTAssertFalse(WatchBuildReport.isPendingSyncStale(reportedAt: nil, now: now))
        XCTAssertFalse(WatchBuildReport.isPendingSyncStale(reportedAt: 0, now: now))
    }
}

final class PendingSyncCacheTests: XCTestCase {
    func testNilUntilAQueueHasCounted() {
        // "We have never counted" must not be reported as "zero pending".
        let cache = PendingSyncCache()
        XCTAssertNil(cache.total)
        cache.record(0, for: .workouts)
        XCTAssertEqual(cache.total, 0)
    }

    func testSumsTheQueuesTheWatchDrains() {
        // The watch's own Home screen shows workouts + gauge sessions as one
        // number; the phone must not disagree with the wrist.
        let cache = PendingSyncCache()
        cache.record(2, for: .workouts)
        cache.record(3, for: .tindeqSessions)
        XCTAssertEqual(cache.total, 5)
    }

    func testLatestCountPerQueueWins() {
        let cache = PendingSyncCache()
        cache.record(4, for: .workouts)
        cache.record(1, for: .workouts)
        XCTAssertEqual(cache.total, 1)
    }

    func testAQueueThatHasNotCountedYetJustContributesNothing() {
        // An under-count beats reporting nothing at all — the first drain
        // publishes both queues anyway.
        let cache = PendingSyncCache()
        cache.record(2, for: .tindeqSessions)
        XCTAssertEqual(cache.total, 2)
    }

    func testNegativeCountsCannotPoisonTheTotal() {
        let cache = PendingSyncCache()
        cache.record(-5, for: .workouts)
        cache.record(2, for: .tindeqSessions)
        XCTAssertEqual(cache.total, 2)
    }

    func testResetClearsBackToUnknown() {
        let cache = PendingSyncCache()
        cache.record(1, for: .workouts)
        cache.reset()
        XCTAssertNil(cache.total)
    }

    // MARK: #475 — quarantined count is tracked separately from `total`

    func testQuarantinedCountIsNilUntilReported() {
        let cache = PendingSyncCache()
        XCTAssertNil(cache.quarantinedTotal)
        cache.recordQuarantined(0)
        XCTAssertEqual(cache.quarantinedTotal, 0)
    }

    func testQuarantinedCountDoesNotFoldIntoTheSyncingTotal() {
        // A quarantined item is not "pending" — it will never leave via a
        // normal drain, so it must not inflate the number that reads as
        // "will sync" to the user.
        let cache = PendingSyncCache()
        cache.record(2, for: .workouts)
        cache.recordQuarantined(3)
        XCTAssertEqual(cache.total, 2)
        XCTAssertEqual(cache.quarantinedTotal, 3)
    }

    func testNegativeQuarantinedCountsAreRefused() {
        let cache = PendingSyncCache()
        cache.recordQuarantined(-1)
        XCTAssertEqual(cache.quarantinedTotal, 0)
    }

    func testResetAlsoClearsQuarantinedBackToUnknown() {
        let cache = PendingSyncCache()
        cache.recordQuarantined(2)
        cache.reset()
        XCTAssertNil(cache.quarantinedTotal)
    }
}

/// Issue #475 F1: quarantine is invisible today because nothing reads
/// `PendingSyncCache.quarantinedTotal` anywhere in the app. These pin the
/// wire contract and verdict that fix that — same channel, same
/// honest-states rules as the #21 pending-sync report above, but a
/// distinct key and a distinct verdict type, since "quarantined" must never
/// be presented as "will sync".
final class QuarantinedSyncStampingTests: XCTestCase {
    private let identity = BuildIdentity(version: "1.4.0", build: "57")

    func testRoundTripsThroughAMessageAlongsidePendingSync() {
        let msg = WatchBuildReport.stamped(
            ["kind": "liveWorkout", "status": "live"],
            with: identity,
            pendingSync: 3,
            quarantinedSync: 1
        )
        XCTAssertEqual(WatchBuildReport.pendingSync(in: msg), 3)
        XCTAssertEqual(WatchBuildReport.quarantinedSync(in: msg), 1)
        XCTAssertEqual(WatchBuildReport.identity(in: msg), identity)
    }

    func testAZeroQuarantinedCountIsReportedRatherThanOmitted() {
        // Zero is a fact worth sending: it's what distinguishes "checked,
        // nothing stuck" from "never checked".
        let msg = WatchBuildReport.stamped(["kind": "requestSession"], with: identity, quarantinedSync: 0)
        XCTAssertEqual(WatchBuildReport.quarantinedSync(in: msg), 0)
    }

    func testUnknownQuarantinedCountLeavesTheMessageUntouched() {
        let msg = WatchBuildReport.stamped(["kind": "requestSession"], with: nil, quarantinedSync: nil)
        XCTAssertEqual(msg.count, 1)
        XCTAssertNil(WatchBuildReport.quarantinedSync(in: msg))
    }

    func testNegativeQuarantinedCountsAreRefusedOnBothSides() {
        let msg = WatchBuildReport.stamped(["kind": "liveForce"], with: nil, quarantinedSync: -1)
        XCTAssertNil(msg[WatchBuildReport.quarantinedSyncKey])
        XCTAssertNil(WatchBuildReport.quarantinedSync(in: [WatchBuildReport.quarantinedSyncKey: -4]))
    }

    func testReadsAQuarantinedCountThatCameBackAsADouble() {
        XCTAssertEqual(WatchBuildReport.quarantinedSync(in: [WatchBuildReport.quarantinedSyncKey: 2.0]), 2)
    }

    func testUnstampedMessageYieldsNoQuarantinedCount() {
        XCTAssertNil(WatchBuildReport.quarantinedSync(in: ["kind": "liveForce", "kg": 12.5]))
    }

    func testStrippingRemovesTheQuarantineKeyToo() {
        let stamped = WatchBuildReport.stamped(
            ["kind": "liveForce", "kg": 12.5],
            with: identity,
            pendingSync: 3,
            quarantinedSync: 1
        )
        let stripped = WatchBuildReport.stripped(stamped)
        XCTAssertEqual(stripped.count, 2)
        XCTAssertEqual(stripped["kg"] as? Double, 12.5)
        XCTAssertNil(stripped[WatchBuildReport.quarantinedSyncKey])
        XCTAssertNil(stripped[WatchBuildReport.pendingSyncKey])
    }
}

final class WatchQuarantineStatusTests: XCTestCase {
    func testNoneIsNotTheSameAsNeverReported() {
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 0, pairing: pairing()), .none
        )
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: nil, pairing: pairing()), .notReported
        )
    }

    func testAnyPositiveCountReadsAsStuck() {
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 1, pairing: pairing()), .stuck
        )
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 42, pairing: pairing()), .stuck
        )
    }

    func testPairingProblemsBeatAnyStoredCount() {
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 3, pairing: pairing(paired: false)),
            .notPaired
        )
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 0, pairing: pairing(supported: false)),
            .notPaired
        )
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 3, pairing: pairing(appInstalled: false)),
            .appNotInstalled
        )
    }

    func testPreActivationIsUnknownRatherThanNone() {
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: 0, pairing: pairing(activated: false)),
            .unknown
        )
    }

    func testNegativeCountIsTreatedAsNoReading() {
        XCTAssertEqual(
            WatchBuildReport.quarantineStatus(quarantinedSync: -1, pairing: pairing()), .notReported
        )
    }
}

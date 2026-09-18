import Foundation
import XCTest
@testable import SendLogWatchCore

/// A one-shot async latch. The stub performer parks here so a second ask
/// provably arrives while the first flight is still running.
private actor ReadinessPassLatch {
    private var isParked = false
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func park() async {
        isParked = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parkedContinuation = continuation
        }
    }

    func waitUntilParked() async {
        guard !isParked else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        parkedContinuation?.resume()
        parkedContinuation = nil
    }
}

/// #913 producer/consumer coverage for the phone side of a watch-originated
/// readiness refresh.
///
/// Every leg uses the production serialization (`ReadinessRefreshRequest
/// .message()` / `ReadinessRefreshResult(message:)`), the production watch
/// stamp (`WatchBuildReport.stamped`), the production phone bridge, and the
/// production watch-side gates and context merge. No test hand-authors the
/// wire dictionary a real watch sends, so a serializer change breaks these
/// tests instead of silently passing a lookalike payload.
@MainActor
final class ReadinessWatchBridgeTests: XCTestCase {
    private let accountA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let accountB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    /// Exactly what the watch's `ReadinessManager.send` hands to
    /// WatchConnectivity: the request dictionary plus the owner/build stamp.
    private func watchMessage(
        requestId: String,
        reason: ReadinessRefreshReason = .foreground,
        sentAt: TimeInterval = 1_000,
        accountUserID: UUID?
    ) -> [String: Any] {
        let request = ReadinessRefreshRequest(
            requestId: requestId,
            reason: reason,
            sentAt: sentAt
        )
        return WatchBuildReport.stamped(
            request.message(),
            with: BuildIdentity(version: "1.4.0", build: "91"),
            accountUserID: accountUserID
        )
    }

    private func scopedBridge(_ accountUserId: UUID?) -> ReadinessWatchBridge {
        let bridge = ReadinessWatchBridge()
        bridge.setAccountScope(accountUserId)
        return bridge
    }

    // MARK: - AC1: a phone-produced result round-trips into the watch receiver

    func testWatchAskRoundTripsThroughTheBridgeIntoTheWatchResultGate() async throws {
        let bridge = scopedBridge(accountA)
        let ask = watchMessage(
            requestId: "req-round-trip",
            reason: .statusRefresh,
            sentAt: 1_700_000_000,
            accountUserID: accountA
        )

        var performed: [String] = []
        let answered = await bridge.handle(ask, accountStamp: accountA) { request in
            performed.append(request.requestId)
            return .success(
                freshness: .fresh,
                snapshot: ReadinessSnapshot(
                    date: "2026-09-18",
                    readiness: 78,
                    zone: "push",
                    computedAt: 1_700_000_050
                )
            )
        }
        let result = try XCTUnwrap(answered)

        XCTAssertEqual(performed, ["req-round-trip"])
        XCTAssertEqual(result.requestId, "req-round-trip")
        XCTAssertEqual(result.reason, .statusRefresh)
        XCTAssertEqual(result.sentAt, 1_700_000_000)
        XCTAssertEqual(result.accountUserId, accountA)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.freshness, .fresh)
        XCTAssertGreaterThanOrEqual(result.startedAt, 1_700_000_000)
        XCTAssertGreaterThanOrEqual(result.completedAt, result.startedAt)
        XCTAssertTrue(result.succeeded)

        // The consumer half: the phone's answer decodes through the same
        // decoder the watch's ReadinessManager uses, and passes the same gate
        // for the exact request the watch is still waiting on.
        let decoded = try XCTUnwrap(ReadinessRefreshResult(message: result.message()))
        XCTAssertEqual(decoded, result)
        XCTAssertTrue(
            ReadinessResultGate.shouldApply(
                decoded,
                activeRequestId: "req-round-trip",
                lastAppliedCompletedAt: nil,
                currentAccountUserId: accountA,
                activeRequestAccountUserId: accountA
            )
        )
        XCTAssertEqual(decoded.snapshot?.date, "2026-09-18")
        XCTAssertEqual(decoded.snapshot?.readiness, 78)
        XCTAssertEqual(decoded.snapshot?.zone, "push")
        XCTAssertEqual(decoded.snapshot?.computedAt, 1_700_000_050)
        // ...and a watch signed in as another account rejects the same reply
        // rather than adopting a foreign account's score.
        XCTAssertFalse(
            ReadinessResultGate.shouldApply(
                decoded,
                activeRequestId: "req-round-trip",
                lastAppliedCompletedAt: nil,
                currentAccountUserId: accountB,
                activeRequestAccountUserId: accountB
            )
        )
    }

    func testPhonePushDecodesThroughTheWatchGateAndKeepsTheSignedInContext() async throws {
        let publication = ReadinessPhonePublication.result(
            date: "2026-09-18",
            readiness: 74,
            zone: "push",
            computedAt: 1_756_000_000,
            freshness: .cached,
            accountUserId: accountA,
            now: 1_756_000_100
        )

        // Producer: the phone merges the typed publication into its
        // signed-in relay instead of replacing it.
        var context = ReadinessApplicationContext()
        _ = context.update([
            "event": "signedIn",
            "accessToken": "token-a",
            "userId": accountA.uuidString,
            "expiresAt": 1_900_000_000,
        ])
        let merged = context.update(publication.message())

        // Consumer: the merged payload decodes as a result (the pre-#913 flat
        // push could not) and is applied by a watch with no active request,
        // because the account stamp is what authorizes it.
        let decoded = try XCTUnwrap(ReadinessRefreshResult(message: merged))
        XCTAssertEqual(decoded.requestId, publication.requestId)
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.freshness, .cached)
        XCTAssertEqual(decoded.accountUserId, accountA)
        XCTAssertEqual(
            decoded.snapshot,
            ReadinessSnapshot(
                date: "2026-09-18",
                readiness: 74,
                zone: "push",
                computedAt: 1_756_000_000
            )
        )
        XCTAssertTrue(
            ReadinessResultGate.shouldApply(
                decoded,
                activeRequestId: nil,
                lastAppliedCompletedAt: nil,
                currentAccountUserId: accountA
            )
        )
        XCTAssertEqual(merged["event"] as? String, "signedIn")
        XCTAssertEqual(merged["accessToken"] as? String, "token-a")
        XCTAssertEqual(merged["userId"] as? String, accountA.uuidString)

        // A second delivery of the same publication (direct reply plus
        // latest application context) is inert.
        XCTAssertFalse(
            ReadinessResultGate.shouldApply(
                decoded,
                activeRequestId: nil,
                lastAppliedCompletedAt: decoded.completedAt,
                currentAccountUserId: accountA,
                lastAppliedAccountUserId: accountA
            )
        )
    }

    func testAnOlderPhonePushCannotReplaceANewerAppliedOne() async throws {
        let newer = ReadinessPhonePublication.result(
            date: "2026-09-18",
            readiness: 80,
            zone: "push",
            computedAt: 1_756_000_200,
            freshness: .fresh,
            accountUserId: accountA,
            now: 1_756_000_200
        )
        let older = ReadinessPhonePublication.result(
            date: "2026-09-18",
            readiness: 61,
            zone: "maintain",
            computedAt: 1_755_900_000,
            freshness: .cached,
            accountUserId: accountA,
            now: 1_755_900_000
        )

        XCTAssertTrue(
            ReadinessResultGate.shouldApply(
                newer,
                activeRequestId: nil,
                lastAppliedCompletedAt: nil,
                currentAccountUserId: accountA
            )
        )
        XCTAssertFalse(
            ReadinessResultGate.shouldApply(
                older,
                activeRequestId: nil,
                lastAppliedCompletedAt: newer.completedAt,
                currentAccountUserId: accountA,
                lastAppliedAccountUserId: accountA
            )
        )
    }

    // MARK: - AC2: immediate and queued asks reach the handler; typed outcomes

    func testSignedOutPhoneAnswersTypedAuthRequiredInsteadOfAnEmptyAck() async throws {
        // Never scoped to an account: the phone is signed out.
        let bridge = ReadinessWatchBridge()
        var passCount = 0
        let answered = await bridge.handle(
            watchMessage(requestId: "req-signed-out", accountUserID: accountA),
            accountStamp: accountA
        ) { _ in
            passCount += 1
            return .success(freshness: .fresh, snapshot: nil)
        }
        let result = try XCTUnwrap(answered)

        XCTAssertEqual(passCount, 0)
        XCTAssertEqual(result.status, .authRequired)
        XCTAssertEqual(result.errorCode, "auth-required")
        XCTAssertEqual(result.errorMessage, ReadinessRefreshCopy.authRequired)
        XCTAssertNil(result.accountUserId)
        // The unstamped answer is still adoptable for the exact request it
        // names, so the watch shows the actionable copy instead of hanging.
        XCTAssertTrue(
            ReadinessResultGate.shouldApply(
                result,
                activeRequestId: "req-signed-out",
                lastAppliedCompletedAt: nil,
                currentAccountUserId: accountA,
                activeRequestAccountUserId: accountA
            )
        )
        XCTAssertEqual(ReadinessRefreshResult(message: result.message()), result)
    }

    func testUserFacingOutcomesRenderCopyForEveryFailurePath() async throws {
        let bridge = scopedBridge(accountA)
        let ask = watchMessage(requestId: "req-health", accountUserID: accountA)
        let answered = await bridge.handle(ask, accountStamp: accountA) { _ in
            .healthUnavailable()
        }
        let result = try XCTUnwrap(answered)

        XCTAssertEqual(result.status, .authRequired)
        XCTAssertEqual(result.errorCode, "health-required")
        XCTAssertEqual(result.errorMessage, ReadinessRefreshCopy.authRequired)
        XCTAssertEqual(ReadinessRefreshResult(message: result.message())?.errorMessage, result.errorMessage)

        XCTAssertEqual(ReadinessRefreshOutcome.failed().status, .failed)
        XCTAssertEqual(ReadinessRefreshOutcome.failed().errorMessage, ReadinessRefreshCopy.failed)
        XCTAssertEqual(ReadinessRefreshOutcome.cancelled().status, .cancelled)
        XCTAssertEqual(ReadinessRefreshOutcome.cancelled().errorMessage, ReadinessRefreshCopy.cancelled)
        XCTAssertEqual(ReadinessRefreshOutcome.unsupported().status, .unsupported)
        XCTAssertEqual(ReadinessRefreshOutcome.unsupported().errorMessage, ReadinessRefreshCopy.unsupported)
    }

    // MARK: - AC3: duplicates, ownership, and account transitions

    func testDuplicateReplayIsAnsweredWithoutASecondPass() async throws {
        let bridge = scopedBridge(accountA)
        // The immediate ask and the guaranteed queued fallback carry the same
        // request identity.
        let immediate = watchMessage(requestId: "req-dupe", sentAt: 2_000, accountUserID: accountA)
        let queued = watchMessage(requestId: "req-dupe", sentAt: 2_000, accountUserID: accountA)

        var passCount = 0
        let performer: ReadinessWatchBridge.Performer = { _ in
            passCount += 1
            return .success(
                freshness: .cached,
                snapshot: ReadinessSnapshot(date: "2026-09-18", readiness: 61, zone: "maintain")
            )
        }

        let firstResult = await bridge.handle(immediate, accountStamp: accountA, perform: performer)
        let secondResult = await bridge.handle(queued, accountStamp: accountA, perform: performer)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(passCount, 1)
        XCTAssertEqual(first, second)
    }

    func testConcurrentDuplicateJoinsTheRunningFlight() async throws {
        let bridge = scopedBridge(accountA)
        let ask = watchMessage(requestId: "req-join", sentAt: 2_500, accountUserID: accountA)
        let latch = ReadinessPassLatch()

        var passCount = 0
        let performer: ReadinessWatchBridge.Performer = { _ in
            passCount += 1
            await latch.park()
            return .success(
                freshness: .fresh,
                snapshot: ReadinessSnapshot(date: "2026-09-18", readiness: 70, zone: "push")
            )
        }

        async let firstHandle = bridge.handle(ask, accountStamp: accountA, perform: performer)
        await latch.waitUntilParked()
        async let secondHandle = bridge.handle(ask, accountStamp: accountA, perform: performer)
        await latch.release()

        let firstValue = await firstHandle
        let secondValue = await secondHandle
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(passCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshot?.readiness, 70)
    }

    func testRequestOwnedByAnotherAccountIsNotExecuted() async throws {
        let bridge = scopedBridge(accountA)
        var passCount = 0
        let answered = await bridge.handle(
            watchMessage(requestId: "req-foreign", accountUserID: accountB),
            accountStamp: accountB
        ) { _ in
            passCount += 1
            return .success(freshness: .fresh, snapshot: nil)
        }
        let result = try XCTUnwrap(answered)

        XCTAssertEqual(passCount, 0)
        XCTAssertEqual(result.status, .authRequired)
        XCTAssertEqual(result.accountUserId, accountA)
        // The watch signed in as B rejects the foreign-account answer instead
        // of applying a score that is not its own.
        XCTAssertFalse(
            ReadinessResultGate.shouldApply(
                result,
                activeRequestId: "req-foreign",
                lastAppliedCompletedAt: nil,
                currentAccountUserId: accountB,
                activeRequestAccountUserId: accountB
            )
        )
    }

    func testUnstampedRequestHasNoOwnershipProof() async throws {
        let bridge = scopedBridge(accountA)
        var passCount = 0
        let answered = await bridge.handle(
            watchMessage(requestId: "req-unstamped", accountUserID: nil),
            accountStamp: nil
        ) { _ in
            passCount += 1
            return .success(freshness: .fresh, snapshot: nil)
        }
        let result = try XCTUnwrap(answered)

        XCTAssertEqual(passCount, 0)
        XCTAssertEqual(result.status, .authRequired)
        XCTAssertEqual(result.accountUserId, accountA)
    }

    func testAccountSwitchDuringFlightFencesTheLateResultAndItsReplay() async throws {
        let bridge = scopedBridge(accountA)
        let ask = watchMessage(requestId: "req-switch", sentAt: 3_000, accountUserID: accountA)
        let latch = ReadinessPassLatch()
        let performer: ReadinessWatchBridge.Performer = { _ in
            await latch.park()
            return .success(
                freshness: .fresh,
                snapshot: ReadinessSnapshot(date: "2026-09-18", readiness: 90, zone: "push")
            )
        }

        async let pending = bridge.handle(ask, accountStamp: accountA, perform: performer)
        await latch.waitUntilParked()
        bridge.setAccountScope(accountB)
        await latch.release()

        let fencedValue = await pending
        let fenced = try XCTUnwrap(fencedValue)
        XCTAssertEqual(fenced.status, .cancelled)
        XCTAssertEqual(fenced.errorCode, "cancelled")
        XCTAssertNotEqual(fenced.snapshot?.readiness, 90)

        // The fenced answer is not replayable to the replacement account: the
        // same request identity still runs a real pass for B.
        var passes = 0
        let replacement = await bridge.handle(
            watchMessage(requestId: "req-switch", sentAt: 3_001, accountUserID: accountB),
            accountStamp: accountB
        ) { _ in
            passes += 1
            return .success(
                freshness: .fresh,
                snapshot: ReadinessSnapshot(date: "2026-09-18", readiness: 12, zone: "recover")
            )
        }
        let replacementResult = try XCTUnwrap(replacement)
        XCTAssertEqual(passes, 1)
        XCTAssertEqual(replacementResult.accountUserId, accountB)
        XCTAssertEqual(replacementResult.snapshot?.readiness, 12)
    }

    // MARK: - Identity is never invented

    func testMalformedReadinessMessageIsNotTurnedIntoAResult() async {
        let bridge = scopedBridge(accountA)
        var passCount = 0
        let performer: ReadinessWatchBridge.Performer = { _ in
            passCount += 1
            return .success(freshness: .fresh, snapshot: nil)
        }

        // No request identity at all: the watch could not match an answer to
        // any in-flight ask, so the transport keeps routing this itself.
        let noRequestId = await bridge.handle(
            ["kind": ReadinessRefreshRequest.kind, "reason": "foreground"],
            accountStamp: accountA,
            perform: performer
        )
        XCTAssertNil(noRequestId)
        // A different message kind is not this bridge's business either.
        let otherKind = await bridge.handle(
            ["kind": "workoutCompleted", "requestId": "not-a-request"],
            accountStamp: accountA,
            perform: performer
        )
        XCTAssertNil(otherKind)
        XCTAssertEqual(passCount, 0)
    }
}

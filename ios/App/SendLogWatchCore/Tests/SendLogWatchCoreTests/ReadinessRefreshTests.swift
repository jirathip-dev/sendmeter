import Foundation
import XCTest
@testable import SendLogWatchCore

final class ReadinessRefreshTests: XCTestCase {
    func testActivationAndReachabilityChooseOnlyOneDeliveryPath() {
        XCTAssertEqual(
            ReadinessTransportPath.choose(activated: false, reachable: true),
            .waitForActivation
        )
        XCTAssertEqual(
            ReadinessTransportPath.choose(activated: true, reachable: false),
            .queueFallback
        )
        XCTAssertEqual(
            ReadinessTransportPath.choose(activated: true, reachable: true),
            .sendImmediate
        )
    }

    func testStaleTokenRetryIsSingleFlightAndDoesNotRetryOrdinaryErrors() {
        XCTAssertTrue(
            ReadinessRefreshRetryPolicy.shouldRelayAuth(
                errorDescription: "Postgrest PGRST301 JWT expired",
                alreadyRetried: false
            )
        )
        XCTAssertFalse(
            ReadinessRefreshRetryPolicy.shouldRelayAuth(
                errorDescription: "Postgrest PGRST301 JWT expired",
                alreadyRetried: true
            )
        )
        XCTAssertFalse(
            ReadinessRefreshRetryPolicy.shouldRelayAuth(
                errorDescription: "Network connection lost",
                alreadyRetried: false
            )
        )
    }

    func testRequestMessageIsVersionTolerantAndRoundTrips() {
        let request = ReadinessRefreshRequest(
            requestId: "req-1",
            reason: .foreground,
            sentAt: 100,
            schemaVersion: 1
        )

        var message = request.message()
        message["futureField"] = "ignored"
        let decoded = ReadinessRefreshRequest(message: message)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            ReadinessRefreshRequest(message: [
                "kind": ReadinessRefreshRequest.kind,
                "requestId": "old-phone",
                "reason": "future-reason",
                "sentAt": NSNumber(value: 101),
            ])?.reason,
            .statusRefresh
        )
    }

    func testResultMessageOmitsNilSnapshotFieldsAndIsAValidWCPropertyList() {
        let request = ReadinessRefreshRequest(requestId: "req-2", reason: .statusRefresh, sentAt: 200)
        let result = ReadinessRefreshResult(
            request: request,
            startedAt: 201,
            completedAt: 202,
            status: .success,
            freshness: .cached,
            snapshot: ReadinessSnapshot(date: "2026-08-09", readiness: nil, zone: nil)
        )

        let message = result.message()
        let snapshot = try? XCTUnwrap(message["snapshot"] as? [String: Any])
        XCTAssertNil(snapshot?["readiness"])
        XCTAssertNil(snapshot?["zone"])
        XCTAssertNil(snapshot?["computedAt"])
        XCTAssertNotNil(
            try? PropertyListSerialization.data(
                fromPropertyList: message,
                format: .binary,
                options: 0
            )
        )

        let decoded = ReadinessRefreshResult(message: message)
        XCTAssertEqual(decoded, result)
    }

    func testReadinessResultMergesIntoSignedInApplicationContext() {
        var context = ReadinessApplicationContext()
        let signedIn: [String: Any] = [
            "event": "signedIn",
            "accessToken": "access-token-1",
            "userId": "user-1",
            "expiresAt": 900.0,
        ]
        XCTAssertEqual(context.update(signedIn)["accessToken"] as? String, "access-token-1")

        let request = ReadinessRefreshRequest(requestId: "merge-1", reason: .foreground, sentAt: 500)
        let readiness = ReadinessRefreshResult(
            request: request,
            startedAt: 501,
            completedAt: 502,
            status: .success,
            freshness: .fresh,
            snapshot: ReadinessSnapshot(date: "2026-08-09", readiness: 82, zone: "maintain")
        )
        let merged = context.update(readiness.message())

        XCTAssertEqual(merged["event"] as? String, "signedIn")
        XCTAssertEqual(merged["accessToken"] as? String, "access-token-1")
        XCTAssertEqual(merged["userId"] as? String, "user-1")
        XCTAssertEqual(merged["kind"] as? String, ReadinessRefreshResult.kind)
        XCTAssertEqual((merged["snapshot"] as? [String: Any])?["readiness"] as? Int, 82)
        XCTAssertNotNil(
            try? PropertyListSerialization.data(
                fromPropertyList: merged,
                format: .binary,
                options: 0
            )
        )

        // A later token relay for the same account keeps the latest result.
        let refreshed = context.update([
            "event": "signedIn",
            "accessToken": "access-token-2",
            "userId": "user-1",
            "expiresAt": 1_000.0,
        ])
        XCTAssertEqual(refreshed["accessToken"] as? String, "access-token-2")
        XCTAssertEqual(refreshed["kind"] as? String, ReadinessRefreshResult.kind)
    }

    func testColdStartReconcilesCombinedAuthAndReadinessBeforePublication() {
        let request = ReadinessRefreshRequest(requestId: "cold-1", reason: .foreground, sentAt: 700)
        let result = ReadinessRefreshResult(
            request: request,
            startedAt: 701,
            completedAt: 702,
            status: .success,
            freshness: .fresh,
            snapshot: ReadinessSnapshot(date: "2026-08-09", readiness: 77, zone: "push")
        )
        var persisted: [String: Any] = [
            "event": "signedIn",
            "accessToken": "persisted-access-token",
            "userId": "persisted-user",
            "expiresAt": 1_500.0,
            "relayId": "old-relay",
            "relayedAt": 703.0,
        ]
        for (key, value) in result.message() {
            persisted[key] = value
        }

        var context = ReadinessApplicationContext()
        let cold = context.reconcile(persisted)

        XCTAssertFalse(context.isSignedOut)
        XCTAssertEqual(cold["event"] as? String, "signedIn")
        XCTAssertEqual(cold["accessToken"] as? String, "persisted-access-token")
        XCTAssertEqual(cold["userId"] as? String, "persisted-user")
        XCTAssertEqual(cold["kind"] as? String, ReadinessRefreshResult.kind)
        XCTAssertNil(cold["relayId"])
        XCTAssertNil(cold["relayedAt"])
        XCTAssertNil(context.authPayload?["kind"])
        XCTAssertEqual(context.readinessPayload?["kind"] as? String, ReadinessRefreshResult.kind)
        XCTAssertNotNil(
            try? PropertyListSerialization.data(
                fromPropertyList: cold,
                format: .binary,
                options: 0
            )
        )

        // A result published immediately after the cold seed still carries
        // the persisted auth context instead of clobbering it.
        let followUp = context.update(
            ReadinessRefreshResult(
                request: ReadinessRefreshRequest(requestId: "cold-2", reason: .statusRefresh, sentAt: 704),
                startedAt: 705,
                completedAt: 706,
                status: .success,
                freshness: .cached,
                snapshot: ReadinessSnapshot(date: "2026-08-09", readiness: 76, zone: "maintain")
            ).message()
        )
        XCTAssertEqual(followUp["event"] as? String, "signedIn")
        XCTAssertEqual(followUp["accessToken"] as? String, "persisted-access-token")
        XCTAssertEqual((followUp["snapshot"] as? [String: Any])?["readiness"] as? Int, 76)
    }

    func testSignedOutApplicationContextClearsAuthAndReadinessBeforeNextAccount() {
        var context = ReadinessApplicationContext()
        _ = context.update([
            "event": "signedIn",
            "accessToken": "old-access-token",
            "userId": "old-user",
            "expiresAt": 900.0,
        ])
        let request = ReadinessRefreshRequest(requestId: "merge-2", reason: .foreground, sentAt: 600)
        _ = context.update(
            ReadinessRefreshResult(
                request: request,
                startedAt: 601,
                completedAt: 602,
                status: .success,
                freshness: .fresh,
                snapshot: ReadinessSnapshot(date: "2026-08-09", readiness: 61, zone: "recover")
            ).message()
        )

        let signedOut = context.update(["event": "signedOut"])
        XCTAssertEqual(signedOut["event"] as? String, "signedOut")
        XCTAssertNil(signedOut["accessToken"])
        XCTAssertNil(signedOut["kind"])
        XCTAssertNil(context.authPayload)
        XCTAssertNil(context.readinessPayload)
        XCTAssertTrue(context.isSignedOut)

        // A late result delivered after the persisted signedOut context cannot
        // recreate a readiness-only application context.
        let late = context.update([
            "kind": ReadinessRefreshResult.kind,
            "requestId": "late",
            "status": "success",
            "freshness": "fresh",
        ])
        XCTAssertEqual(late["event"] as? String, "signedOut")
        XCTAssertNil(late["kind"])

        let nextAccount = context.update([
            "event": "signedIn",
            "accessToken": "new-access-token",
            "userId": "new-user",
            "expiresAt": 1_200.0,
        ])
        XCTAssertEqual(nextAccount["accessToken"] as? String, "new-access-token")
        XCTAssertNil(nextAccount["kind"])
        XCTAssertNil(nextAccount["snapshot"])
        XCTAssertFalse(context.isSignedOut)
    }

    func testCoalescerRunsAtMostOneFollowUpAndKeepsStrongestReason() {
        var coalescer = ReadinessRefreshCoalescer()
        XCTAssertEqual(coalescer.request(reason: .launch), .start)
        XCTAssertTrue(coalescer.isRunning)

        XCTAssertEqual(coalescer.request(reason: .foreground), .queued)
        XCTAssertEqual(coalescer.request(reason: .launch), .queued)
        XCTAssertEqual(coalescer.request(reason: .statusRefresh), .queued)
        XCTAssertEqual(coalescer.request(reason: .foreground), .queued)

        XCTAssertEqual(coalescer.complete(), .rerun(.statusRefresh))
        XCTAssertEqual(coalescer.request(reason: .statusRefresh), .start)
        XCTAssertEqual(coalescer.complete(), .idle)
        XCTAssertFalse(coalescer.isRunning)
    }

    func testCancellationDropsQueuedFollowUp() {
        var coalescer = ReadinessRefreshCoalescer()
        XCTAssertEqual(coalescer.request(reason: .foreground), .start)
        XCTAssertEqual(coalescer.request(reason: .statusRefresh), .queued)
        coalescer.cancel()

        XCTAssertEqual(coalescer.request(reason: .launch), .start)
        XCTAssertEqual(coalescer.complete(), .idle)
    }

    func testTerminalFallbackTimeoutCanStartANewFlight() {
        var coalescer = ReadinessRefreshCoalescer()
        XCTAssertEqual(coalescer.request(reason: .foreground), .start)
        XCTAssertEqual(coalescer.request(reason: .statusRefresh), .queued)

        // The watch's fallback timeout cancels the old transport flight. A
        // later foreground trigger must start, not queue behind, that dead
        // request.
        coalescer.cancel()
        XCTAssertFalse(coalescer.isRunning)
        XCTAssertEqual(coalescer.request(reason: .foreground), .start)
    }

    func testResultGateRejectsLateAndOutOfOrderResults() {
        let firstRequest = ReadinessRefreshRequest(requestId: "first", reason: .foreground, sentAt: 300)
        let secondRequest = ReadinessRefreshRequest(requestId: "second", reason: .foreground, sentAt: 301)
        let first = ReadinessRefreshResult(
            request: firstRequest,
            startedAt: 302,
            completedAt: 303,
            status: .success,
            freshness: .fresh
        )
        let second = ReadinessRefreshResult(
            request: secondRequest,
            startedAt: 304,
            completedAt: 305,
            status: .success,
            freshness: .fresh
        )
        let oldDuplicate = ReadinessRefreshResult(
            request: firstRequest,
            startedAt: 302,
            completedAt: 302.5,
            status: .success,
            freshness: .fresh
        )

        XCTAssertFalse(ReadinessResultGate.shouldApply(first, activeRequestId: second.requestId, lastAppliedCompletedAt: nil))
        XCTAssertTrue(ReadinessResultGate.shouldApply(second, activeRequestId: second.requestId, lastAppliedCompletedAt: nil))
        XCTAssertFalse(ReadinessResultGate.shouldApply(oldDuplicate, activeRequestId: nil, lastAppliedCompletedAt: second.completedAt))
        // The same reply can arrive through both direct reply and latest
        // application context; after first application it must be ignored.
        XCTAssertFalse(ReadinessResultGate.shouldApply(second, activeRequestId: nil, lastAppliedCompletedAt: second.completedAt))
    }

    func testFailureAndCancellationRemainTyped() {
        let request = ReadinessRefreshRequest(requestId: "req-3", reason: .foreground, sentAt: 400)
        let result = ReadinessRefreshResult(
            request: request,
            startedAt: 401,
            completedAt: 402,
            status: .authRequired,
            freshness: .offline,
            errorCode: "auth-required",
            errorMessage: "Open the iPhone app"
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(ReadinessRefreshResult(message: result.message())?.status, .authRequired)
        XCTAssertEqual(ReadinessRefreshResult(message: result.message())?.freshness, .offline)
        XCTAssertEqual(ReadinessRefreshResult(message: result.message())?.errorCode, "auth-required")
    }
}

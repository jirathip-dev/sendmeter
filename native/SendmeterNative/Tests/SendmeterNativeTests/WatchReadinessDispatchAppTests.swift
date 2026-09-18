import Foundation
import SendLogWatchCore
import SendmeterCore
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter

/// #913 app-target coverage for the phone's WatchConnectivity dispatch.
///
/// These tests drive the real `WatchConnectivityService` — its production
/// message switch, its production wire serialization, and its real
/// `ReadinessWatchBridge` — in-process, because a simulator cannot pair a
/// watch. A watch ask must come back as a typed result (never the pre-#913
/// empty acknowledgement), and the phone's own recompute push must be a typed
/// result instead of the flat dictionary the watch rejected.
@MainActor
final class WatchReadinessDispatchAppTests: XCTestCase {
    private let accountUserID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    /// Exactly what the watch's `ReadinessManager.send` builds: the request
    /// dictionary plus the owner/build stamp, through the production types.
    private func watchMessage(
        requestId: String,
        reason: ReadinessRefreshReason = .foreground,
        sentAt: TimeInterval = 9_000,
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

    private func successOutcome(readiness: Int = 81) -> ReadinessRefreshOutcome {
        .success(
            freshness: .fresh,
            snapshot: SendLogWatchCore.ReadinessSnapshot(
                date: "2026-09-18",
                readiness: readiness,
                zone: "push",
                computedAt: 1_756_000_000
            )
        )
    }

    private func signedInSession() -> Auth.Session {
        let user = Auth.User(
            id: accountUserID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return Auth.Session(
            accessToken: "header.readiness-test.signature",
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }

    private func readinessMetric(readiness: Int = 82) -> HealthMetric {
        HealthMetric(
            date: "2026-09-18",
            readiness: readiness,
            zone: "push",
            computedAt: Date(timeIntervalSince1970: 1_756_000_000),
            hrvSDNNMilliseconds: 71,
            restingHeartRate: 48,
            sleepHours: 7.5,
            sleepDeepHours: 1.2,
            sleepREMHours: 1.6,
            bodyMassKilograms: 68,
            respiratoryRate: 14
        )
    }

    /// `handle` must never block the WatchConnectivity delegate, so its answer
    /// arrives from the service's own main-actor task. Yield the main actor
    /// until the effect lands; bounded, so a regression fails instead of
    /// hanging the run.
    private func settle(until condition: () -> Bool, turns: Int = 5_000) async {
        for _ in 0..<turns {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("the dispatch effect never landed")
    }

    func testImmediateAskIsAnsweredWithAPublishedTypedResult() async throws {
        let service = WatchConnectivityService()
        service.setAccountScope(accountUserID)
        // Production order: the phone relays its session first (the readiness
        // result merges into that relay, never replacing it).
        service.relaySession(signedInSession())
        var performed: [String] = []
        service.onReadinessRefresh = { request in
            performed.append(request.requestId)
            return .success(
                freshness: .fresh,
                snapshot: SendLogWatchCore.ReadinessSnapshot(
                    date: "2026-09-18",
                    readiness: 81,
                    zone: "push",
                    computedAt: 1_756_000_000
                )
            )
        }

        var replies: [[String: Any]] = []
        service.handle(
            watchMessage(requestId: "app-req-1", accountUserID: accountUserID),
            replyHandler: { replies.append($0) }
        )
        await settle(until: { !replies.isEmpty })

        let reply = try XCTUnwrap(replies.first)
        XCTAssertFalse(reply.isEmpty)
        let decoded = try XCTUnwrap(ReadinessRefreshResult(message: reply))
        XCTAssertEqual(decoded.requestId, "app-req-1")
        XCTAssertEqual(decoded.reason, .foreground)
        XCTAssertEqual(decoded.sentAt, 9_000)
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.freshness, .fresh)
        XCTAssertEqual(decoded.accountUserId, accountUserID)
        XCTAssertEqual(decoded.snapshot?.readiness, 81)
        XCTAssertEqual(decoded.snapshot?.zone, "push")
        XCTAssertEqual(performed, ["app-req-1"])

        // The same typed result is the latest application context, so an
        // offline or cold watch recovers it on its next activation.
        let published = try XCTUnwrap(
            ReadinessRefreshResult(message: service.pendingApplicationContext)
        )
        XCTAssertEqual(published.requestId, "app-req-1")
        XCTAssertEqual(published.status, .success)
        XCTAssertEqual(published.accountUserId, accountUserID)
    }

    func testQueuedAskWithoutReplyHandlerStillPublishesATypedResult() async throws {
        let service = WatchConnectivityService()
        service.setAccountScope(accountUserID)
        service.relaySession(signedInSession())
        service.onReadinessRefresh = { _ in self.successOutcome() }

        // The guaranteed-delivery fallback (`transferUserInfo`) carries no
        // reply handler: its answer is the published context, never silence.
        service.handle(
            watchMessage(requestId: "app-req-queued", accountUserID: accountUserID),
            replyHandler: nil
        )
        await settle(until: {
            (service.pendingApplicationContext["requestId"] as? String) == "app-req-queued"
        })

        let published = try XCTUnwrap(
            ReadinessRefreshResult(message: service.pendingApplicationContext)
        )
        XCTAssertEqual(published.requestId, "app-req-queued")
        XCTAssertEqual(published.status, .success)
        XCTAssertEqual(published.snapshot?.readiness, 81)
        XCTAssertEqual(published.accountUserId, accountUserID)
    }

    func testDuplicateAskForTheSameRequestRunsOnePass() async throws {
        let service = WatchConnectivityService()
        service.setAccountScope(accountUserID)
        var passCount = 0
        service.onReadinessRefresh = { _ in
            passCount += 1
            return self.successOutcome(readiness: 74)
        }

        var replies: [[String: Any]] = []
        let ask = watchMessage(requestId: "app-req-dupe", accountUserID: accountUserID)
        service.handle(ask, replyHandler: { replies.append($0) })
        await settle(until: { replies.count == 1 })
        // The watch can resend the same identity (its queued fallback, or a
        // retry). That must reuse the answer, not run a second HealthKit pass.
        service.handle(ask, replyHandler: { replies.append($0) })
        await settle(until: { replies.count == 2 })

        XCTAssertEqual(passCount, 1)
        let firstReply = try XCTUnwrap(replies.first)
        let lastReply = try XCTUnwrap(replies.last)
        let first = try XCTUnwrap(ReadinessRefreshResult(message: firstReply))
        let second = try XCTUnwrap(ReadinessRefreshResult(message: lastReply))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snapshot?.readiness, 74)
    }

    func testSignedOutPhoneAnswersTypedAuthRequired() async throws {
        // Never scoped to an account: the phone has no session to refresh with.
        let service = WatchConnectivityService()
        var performed = 0
        service.onReadinessRefresh = { _ in
            performed += 1
            return self.successOutcome()
        }

        var replies: [[String: Any]] = []
        service.handle(
            watchMessage(requestId: "app-req-signed-out", accountUserID: accountUserID),
            replyHandler: { replies.append($0) }
        )
        await settle(until: { !replies.isEmpty })

        let reply = try XCTUnwrap(replies.first)
        XCTAssertFalse(reply.isEmpty)
        let decoded = try XCTUnwrap(ReadinessRefreshResult(message: reply))
        XCTAssertEqual(decoded.requestId, "app-req-signed-out")
        XCTAssertEqual(decoded.status, .authRequired)
        XCTAssertEqual(decoded.errorCode, "auth-required")
        XCTAssertEqual(decoded.errorMessage, ReadinessRefreshCopy.authRequired)
        XCTAssertFalse(decoded.succeeded)
        XCTAssertEqual(performed, 0)
    }

    func testPhoneRecomputePushIsATypedResultInsteadOfTheLegacyFlatDictionary() async throws {
        let service = WatchConnectivityService()
        service.setAccountScope(accountUserID)
        service.relaySession(signedInSession())

        service.publishReadiness(readinessMetric(readiness: 82), freshness: .fresh)

        let context = service.pendingApplicationContext
        let decoded = try XCTUnwrap(ReadinessRefreshResult(message: context))
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.freshness, .fresh)
        XCTAssertEqual(decoded.accountUserId, accountUserID)
        XCTAssertEqual(decoded.snapshot?.date, "2026-09-18")
        XCTAssertEqual(decoded.snapshot?.readiness, 82)
        XCTAssertEqual(decoded.snapshot?.zone, "push")
        XCTAssertEqual(decoded.snapshot?.computedAt, 1_756_000_000)
        XCTAssertFalse(decoded.requestId.isEmpty)
        // The merge keeps the signed-in relay: a score must never cost the
        // watch its session.
        XCTAssertEqual(context["event"] as? String, "signedIn")
        XCTAssertEqual(context["userId"] as? String, accountUserID.uuidString)
        XCTAssertEqual(
            context["accessToken"] as? String,
            "header.readiness-test.signature"
        )
        // ...and the pre-#913 flat keys are not the wire contract any more.
        XCTAssertNil(context["computed_at"])
        XCTAssertNil(context["readiness"])
        XCTAssertNil(context["zone"])
    }
}

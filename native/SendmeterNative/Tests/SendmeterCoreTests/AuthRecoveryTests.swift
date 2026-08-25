import Foundation
import XCTest
@testable import SendmeterCore

private final class TestContinuousClock: AuthMonotonicClock, @unchecked Sendable {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

final class AuthRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keyPrefix: String!

    override func setUp() {
        super.setUp()
        keyPrefix = "sendmeter.tests.auth-recovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: keyPrefix)
        defaults.removePersistentDomain(forName: keyPrefix)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: keyPrefix)
        defaults = nil
        keyPrefix = nil
        super.tearDown()
    }

    func testRestoredSessionWithoutOurMarkerIsDroppedAsStaleInstall() {
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: keyPrefix)
        let descriptor = AuthSessionDescriptor(
            userID: "user-1",
            sessionID: "session-1",
            issuedAt: 100,
            expiresAt: 1_000
        )
        let launch = store.beginLaunch(hasStoredSession: true)

        XCTAssertTrue(launch.restoredSessionNeedsFreshSignIn)
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: descriptor,
                hasInstallationMarker: launch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .dropStaleInstall
        )
    }

    func testAcceptedIdentityCanBeRestoredButDifferentIdentityCannot() {
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: keyPrefix)
        let first = AuthSessionDescriptor(userID: "user-1", sessionID: "session-1")
        let second = AuthSessionDescriptor(userID: "user-1", sessionID: "session-2")
        let launch = store.beginLaunch(hasStoredSession: false)
        store.accept(first)

        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: first,
                hasInstallationMarker: launch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .dropStaleInstall,
            "The first launch had no marker before it was created; a carried-in session must not be presented."
        )

        let relaunch = store.beginLaunch(hasStoredSession: true)
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: first,
                hasInstallationMarker: relaunch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .accept
        )
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: second,
                hasInstallationMarker: relaunch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .dropStaleInstall
        )
    }

    func testExplicitSignInEstablishesIdentityAndRejectionPreventsRetryLoop() {
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: keyPrefix)
        let descriptor = AuthSessionDescriptor(userID: "user-1", sessionID: "poison")
        let launch = store.beginLaunch(hasStoredSession: false)
        store.accept(descriptor)

        XCTAssertTrue(store.markRejected(descriptor))
        XCTAssertFalse(store.markRejected(descriptor))
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: descriptor,
                hasInstallationMarker: launch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .dropPreviouslyRejected
        )

        let replacement = AuthSessionDescriptor(userID: "user-1", sessionID: "fresh")
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .signedIn,
                descriptor: replacement,
                hasInstallationMarker: launch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .accept
        )
        store.accept(replacement)
        XCTAssertEqual(store.acceptedSessionKey(), replacement.stableKey)
    }

    func testDescriptorNeverPersistsOrIncludesTheAccessToken() {
        let descriptor = AuthSessionDescriptor(
            userID: "user-1",
            sessionID: "session-1",
            issuedAt: 100,
            expiresAt: 1_000
        )
        let token = "header.payload.secret"
        XCTAssertFalse(descriptor.stableKey.contains(token))
        XCTAssertFalse(descriptor.stableKey.contains("secret"))
    }

    func testFriendlyAuthCodesAndFutureIATAreRecoverable() {
        for code in ["invalid_claim", "bad_jwt", "invalid_jwt", "refresh_token_already_used"] {
            let decision = AuthRecoveryPolicy.decision(errorCode: code, message: nil)
            XCTAssertEqual(decision.action, .clearPoisonedSession, code)
            XCTAssertEqual(decision.friendlyErrorClass, .authExpired, code)
        }

        let future = AuthRecoveryPolicy.decision(
            errorCode: "invalid_claim",
            message: "JWT issued at future"
        )
        XCTAssertEqual(future.action, .clearPoisonedSession)
        XCTAssertEqual(future.friendlyErrorClass, .authExpired)
    }

    func testNonExpiredAuthFailureDoesNotClearSession() {
        let decision = AuthRecoveryPolicy.decision(
            errorCode: "invalid_credentials",
            message: "Invalid login credentials"
        )
        XCTAssertEqual(decision.action, .none)
        XCTAssertEqual(decision.friendlyErrorClass, .authRejected)
    }

    func testClockSkewGetsSettingsNudgeAndFutureTokenGetsFreshSignIn() {
        let clock = AuthRecoveryPolicy.decision(
            errorCode: nil,
            message: nil,
            clockAssessment: .deviceClockAhead
        )
        XCTAssertEqual(clock.action, .none)
        XCTAssertEqual(clock.friendlyErrorClass, .authClockSkew)
        XCTAssertTrue(UserFacingError.message(for: .authClockSkew).contains("Set Automatically"))

        let future = AuthRecoveryPolicy.decision(
            errorCode: nil,
            message: nil,
            clockAssessment: .tokenIssuedInFuture
        )
        XCTAssertEqual(future.action, .clearPoisonedSession)
        XCTAssertEqual(future.friendlyErrorClass, .authExpired)
    }
}

final class AuthClockSkewTests: XCTestCase {
    private let serverDate = Date(timeIntervalSince1970: 1_000_000)

    func testNoServerEvidenceNeverCallsTheDeviceClockWrong() {
        XCTAssertEqual(
            AuthClockSkewPolicy.evaluate(
                deviceDate: serverDate.addingTimeInterval(86_400),
                trustedServerDate: nil,
                tokenIssuedAt: serverDate.timeIntervalSince1970 + 86_400
            ),
            .insufficientEvidence
        )
    }

    func testOrdinaryDriftIsHealthyButLargeDeviceLeadIsNot() {
        XCTAssertEqual(
            AuthClockSkewPolicy.evaluate(
                deviceDate: serverDate.addingTimeInterval(30),
                trustedServerDate: serverDate,
                tokenIssuedAt: nil
            ),
            .healthy
        )
        XCTAssertEqual(
            AuthClockSkewPolicy.evaluate(
                deviceDate: serverDate.addingTimeInterval(6 * 60),
                trustedServerDate: serverDate,
                tokenIssuedAt: nil
            ),
            .deviceClockAhead
        )
    }

    func testFutureTokenIsOnlyFlaggedAgainstTrustedServerTime() {
        XCTAssertEqual(
            AuthClockSkewPolicy.evaluate(
                deviceDate: serverDate,
                trustedServerDate: serverDate,
                tokenIssuedAt: serverDate.timeIntervalSince1970 + 3 * 60
            ),
            .tokenIssuedInFuture
        )
    }

    func testStoreUsesMonotonicEvidenceOnlyWithinThisBoot() {
        let prefix = "sendmeter.tests.clock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let clock = TestContinuousClock(now: 10)
        let first = ServerClockStore(defaults: defaults, keyPrefix: prefix, clock: clock)
        first.record(serverDate: serverDate)

        XCTAssertEqual(
            first.trustedServerDate(nowContinuousTime: 40),
            serverDate.addingTimeInterval(30)
        )
        // Separate transport instances in one process must read the same
        // last-known-good anchor; the process boot id still rejects a stale
        // anchor after a real relaunch.
        let second = ServerClockStore(defaults: defaults, keyPrefix: prefix, clock: clock)
        XCTAssertEqual(
            second.trustedServerDate(nowContinuousTime: 40),
            serverDate.addingTimeInterval(30)
        )
    }

    func testContinuousClockCountsSuspensionWhileWallClockMovesWithIt() {
        let prefix = "sendmeter.tests.clock.sleep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let clock = TestContinuousClock(now: 10)
        let store = ServerClockStore(defaults: defaults, keyPrefix: prefix, clock: clock)
        store.record(serverDate: serverDate)

        // Both clocks advance across the simulated sleep. With an
        // awake-only uptime clock, the server anchor would remain at +10 and
        // falsely diagnose this correct device clock as being 10 minutes fast.
        clock.now = 610
        XCTAssertEqual(
            store.assessment(
                deviceDate: serverDate.addingTimeInterval(600),
                tokenIssuedAt: nil
            ),
            .healthy
        )
    }

    func testStaleServerAnchorBecomesInsufficientEvidence() {
        let prefix = "sendmeter.tests.clock.stale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let store = ServerClockStore(defaults: defaults, keyPrefix: prefix)
        store.record(serverDate: serverDate, observedAtContinuousTime: 10)

        XCTAssertNil(
            store.trustedServerDate(
                nowContinuousTime: 10 + AuthClockSkewPolicy.defaultEvidenceMaxAge + 1
            )
        )
    }

    func testHTTPDateParserAcceptsRFCDate() {
        let date = ServerClockStore.date(fromHTTPDate: "Thu, 01 Jan 1970 00:00:00 GMT")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 0))
    }

    func testExistingKeychainSessionIsGrandfatheredOnlyOnFirstGuardLaunch() {
        let prefix = "sendmeter.tests.guard.grandfather.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: prefix)
        let descriptor = AuthSessionDescriptor(userID: "existing-user", sessionID: "existing")
        let firstLaunch = store.beginLaunch(
            hasStoredSession: true,
            storedSessionDescriptor: descriptor
        )

        XCTAssertFalse(firstLaunch.restoredSessionNeedsFreshSignIn)
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: descriptor,
                hasInstallationMarker: firstLaunch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys(),
                grandfatheredSessionKey: firstLaunch.grandfatheredSessionKey
            ),
            .accept
        )

        let relaunch = store.beginLaunch(hasStoredSession: true)
        XCTAssertNil(relaunch.grandfatheredSessionKey)
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: descriptor,
                hasInstallationMarker: relaunch.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys()
            ),
            .accept
        )
    }

    func testExactSessionRecoveryRejectsReplacementButRetriesSameSession() {
        let expected = AuthSessionDescriptor(userID: "user-1", sessionID: "old")
        let replacement = AuthSessionDescriptor(userID: "user-1", sessionID: "new")

        XCTAssertTrue(
            AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: expected,
                current: expected
            )
        )
        XCTAssertFalse(
            AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: expected,
                current: replacement
            )
        )
        let staleGeneration = AuthSessionDescriptor(
            userID: "user-1",
            sessionID: "same-family",
            issuedAt: 100
        )
        let refreshedGeneration = AuthSessionDescriptor(
            userID: "user-1",
            sessionID: "same-family",
            issuedAt: 200
        )
        XCTAssertFalse(
            AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: staleGeneration,
                current: refreshedGeneration
            ),
            "The recovery boundary must not sign out T2 when a stale T1 has the same session family key."
        )
        XCTAssertTrue(
            AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: AuthSessionDescriptor(userID: "user-1", sessionID: "legacy"),
                current: AuthSessionDescriptor(
                    userID: "user-1",
                    sessionID: "legacy",
                    issuedAt: 200
                )
            ),
            "Legacy descriptors without issuedAt still use their exact stable identity."
        )
        XCTAssertFalse(
            AuthRecoveryEpochPolicy.shouldBegin(
                hasActiveSession: true,
                recoveryInProgress: true
            )
        )
        XCTAssertTrue(
            AuthRecoveryEpochPolicy.shouldBegin(
                hasActiveSession: true,
                recoveryInProgress: false
            )
        )
        XCTAssertTrue(
            AuthRecoveryEpochPolicy.shouldResetForSignedOut(hasActiveSession: true)
        )
        XCTAssertFalse(
            AuthRecoveryEpochPolicy.shouldResetForSignedOut(hasActiveSession: false)
        )
    }

    func testUnreadableFirstLaunchDefersMarkerUntilInitialIdentityArrives() {
        let prefix = "sendmeter.tests.guard.deferred.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: prefix)
        let firstLaunch = store.beginLaunch(hasStoredSession: false)
        XCTAssertFalse(firstLaunch.hadInstallationMarker)
        XCTAssertNil(store.acceptedSessionKey())

        let session = AuthSessionDescriptor(userID: "user-1", sessionID: "later")
        XCTAssertTrue(store.acceptInitialSessionIfUnresolved(session))
        let resolved = store.launchStateSnapshot()
        XCTAssertTrue(resolved.hadInstallationMarker)
        XCTAssertEqual(store.acceptedSessionKey(), session.stableKey)
        XCTAssertEqual(
            AuthSessionGuardPolicy.decision(
                event: .initialSession,
                descriptor: session,
                hasInstallationMarker: resolved.hadInstallationMarker,
                acceptedSessionKey: store.acceptedSessionKey(),
                rejectedSessionKeys: store.rejectedSessionKeys(),
                grandfatheredSessionKey: resolved.grandfatheredSessionKey
            ),
            .accept
        )
    }

    func testRejectedMarkerIsDedupeOnlyAndDoesNotBlockASecondRemovalAttempt() {
        let prefix = "sendmeter.tests.guard.retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: prefix)
        let descriptor = AuthSessionDescriptor(userID: "user-1", sessionID: "poison")

        XCTAssertTrue(store.markRejected(descriptor))
        XCTAssertFalse(store.markRejected(descriptor))
        XCTAssertTrue(
            AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: descriptor,
                current: descriptor
            ),
            "A repeated durable marker must not suppress local Keychain removal retry."
        )
    }

    func testBareUnauthorizedStatusIsRecoverableButClockAdviceIsNotDestructive() {
        let bare401 = AuthRecoveryPolicy.decision(
            errorCode: nil,
            message: "Unauthorized",
            statusCode: 401
        )
        XCTAssertEqual(bare401.action, .clearPoisonedSession)
        XCTAssertEqual(bare401.friendlyErrorClass, .authExpired)

        let clock = AuthRecoveryPolicy.decision(
            errorCode: nil,
            message: nil,
            clockAssessment: .deviceClockAhead
        )
        XCTAssertEqual(clock.action, .none)
        XCTAssertEqual(clock.friendlyErrorClass, .authClockSkew)

        let rejected = AuthRecoveryPolicy.decision(
            errorCode: nil,
            message: "Unauthorized",
            clockAssessment: .deviceClockAhead,
            statusCode: 401
        )
        XCTAssertEqual(rejected.action, .clearPoisonedSession)
        XCTAssertEqual(rejected.friendlyErrorClass, .authExpired)
    }
}

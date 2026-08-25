import Foundation
import XCTest
@testable import SendmeterCore

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
        XCTAssertEqual(clock.action, .clearPoisonedSession)
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
        let first = ServerClockStore(defaults: defaults, keyPrefix: prefix)
        first.record(serverDate: serverDate, observedAtUptime: 10)

        XCTAssertEqual(
            first.trustedServerDate(nowUptime: 40),
            serverDate.addingTimeInterval(30)
        )
        let second = ServerClockStore(defaults: defaults, keyPrefix: prefix)
        XCTAssertNil(second.trustedServerDate(nowUptime: 40))
    }

    func testHTTPDateParserAcceptsRFCDate() {
        let date = ServerClockStore.date(fromHTTPDate: "Thu, 01 Jan 1970 00:00:00 GMT")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 0))
    }
}

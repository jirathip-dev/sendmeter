import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import Supabase

private final class WiringClock: AuthMonotonicClock, @unchecked Sendable {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

private final class StubURLProtocol: URLProtocol {
    struct Reply {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var reply = Reply(
        statusCode: 200,
        headers: [:],
        body: Data("[]".utf8)
    )

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let reply = Self.reply
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.statusCode,
            httpVersion: nil,
            headerFields: reply.headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: reply.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RemovalState: @unchecked Sendable {
    var current: AuthSessionDescriptor?
    var attempts = 0

    init(current: AuthSessionDescriptor?) {
        self.current = current
    }
}

private struct RemovalFailure: Error {}

final class AuthRecoveryWiringTests: XCTestCase {
    private struct EmptyPayload: Decodable {}

    private func makeSession(
        userID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sessionID: String = "session-1",
        expiresAt: TimeInterval? = nil
    ) -> Auth.Session {
        let payload = Data(
            #"{"session_id": "\#(sessionID)", "iat": 1_000}"#.utf8
        )
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
            expiresAt: expiresAt ?? Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }

    @MainActor
    private func makeAuthService(
        serverClock: ServerClockStore? = nil,
        sessionGuard: AuthSessionGuardStore? = nil
    ) -> AuthService {
        AuthService(
            client: SupabaseClient(
                supabaseURL: URL(string: "https://example.test")!,
                supabaseKey: "test-key"
            ),
            diagnostics: AuthDiagnosticsStore(),
            serverClock: serverClock,
            sessionGuard: sessionGuard
        )
    }

    private func makeTransport(
        session: Auth.Session,
        serverClock: ServerClockStore,
        urlSession: URLSession
    ) -> PostgRESTClient {
        PostgRESTClient(
            projectURL: URL(string: "https://example.test")!,
            apiKey: "test-key",
            sessionProvider: { session },
            serverClock: serverClock,
            session: urlSession
        )
    }

    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testTransportRecordsDateOn2xxSharesStoreAndIgnoresNon2xxDate() async throws {
        let prefix = "sendmeter.tests.transport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let clock = WiringClock(now: 100)
        let serverClock = ServerClockStore(
            defaults: defaults,
            keyPrefix: prefix,
            clock: clock
        )
        let session = makeSession()
        let urlSession = makeURLSession()
        let first = makeTransport(
            session: session,
            serverClock: serverClock,
            urlSession: urlSession
        )
        let second = makeTransport(
            session: session,
            serverClock: serverClock,
            urlSession: urlSession
        )

        StubURLProtocol.reply = StubURLProtocol.Reply(
            statusCode: 200,
            headers: ["Date": "Thu, 01 Jan 1970 00:16:40 GMT"],
            body: Data("[]".utf8)
        )
        let _: [EmptyPayload] = try await first.request(
            path: "rest/v1/sessions",
            method: .get
        )
        XCTAssertEqual(
            serverClock.trustedServerDate(nowContinuousTime: 100),
            Date(timeIntervalSince1970: 1_000)
        )

        clock.now = 101
        StubURLProtocol.reply = StubURLProtocol.Reply(
            statusCode: 200,
            headers: ["Date": "Thu, 01 Jan 1970 00:16:41 GMT"],
            body: Data("[]".utf8)
        )
        let _: [EmptyPayload] = try await second.request(
            path: "rest/v1/sessions",
            method: .get
        )
        XCTAssertEqual(
            serverClock.trustedServerDate(nowContinuousTime: 101),
            Date(timeIntervalSince1970: 1_001)
        )

        StubURLProtocol.reply = StubURLProtocol.Reply(
            statusCode: 401,
            headers: ["Date": "Thu, 01 Jan 1970 00:30:00 GMT"],
            body: Data(#"{"message":"Unauthorized"}"#.utf8)
        )
        do {
            let _: [EmptyPayload] = try await first.request(
                path: "rest/v1/sessions",
                method: .get
            )
            XCTFail("Expected the bare 401 to throw")
        } catch let error as PostgRESTError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.friendlyErrorClass, .authExpired)
            XCTAssertEqual(
                error.sessionDescriptor,
                AuthSessionDescriptor(
                    userID: session.user.id.uuidString,
                    accessToken: session.accessToken,
                    expiresAt: session.expiresAt
                )
            )
            XCTAssertEqual(
                UserFacingError.message(for: error),
                UserFacingError.message(for: .authExpired)
            )
        }
        XCTAssertEqual(
            serverClock.trustedServerDate(nowContinuousTime: 101),
            Date(timeIntervalSince1970: 1_001),
            "A non-2xx response must not become clock evidence."
        )
        XCTAssertEqual(
            AuthRecoveryPolicy.decision(
                errorCode: nil,
                message: nil,
                statusCode: 401
            ),
            AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authExpired
            )
        )
    }

    @MainActor
    func testLocalRemovalRetriesAfterAFailedAttemptUntilTheExactSessionIsGone() async {
        let expected = AuthSessionDescriptor(userID: "user-1", sessionID: "poison")
        let state = RemovalState(current: expected)

        await AuthSessionRemovalRetry.removeUntilCleared(
            expected: expected,
            current: { state.current },
            remove: {
                state.attempts += 1
                if state.attempts == 2 {
                    state.current = nil
                } else {
                    throw RemovalFailure()
                }
            }
        )

        XCTAssertEqual(state.attempts, 2)
        XCTAssertNil(state.current)
    }

    @MainActor
    func testAuthServiceSurfacesClockAheadAdvisoryWithoutDroppingSession() async throws {
        let prefix = "sendmeter.tests.auth-advisory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let clock = WiringClock(now: 100)
        let serverDate = Date(timeIntervalSince1970: 1_000)
        let serverClock = ServerClockStore(
            defaults: defaults,
            keyPrefix: prefix,
            clock: clock
        )
        serverClock.record(serverDate: serverDate)
        let service = makeAuthService(
            serverClock: serverClock,
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: prefix + ".guard")
        )
        let session = makeSession(expiresAt: Date().timeIntervalSince1970 + 3_600)

        let advisory = service.clockAdvisoryMessage(
            for: session,
            deviceDate: serverDate.addingTimeInterval(10 * 60),
            nowContinuousTime: 100
        )
        XCTAssertEqual(
            advisory,
            UserFacingError.message(for: .authClockSkew)
        )
        XCTAssertTrue(advisory?.contains("Set Automatically") == true)

        let prepared = try await service.prepareIncomingSession(
            session,
            event: .initialSession
        )
        XCTAssertEqual(prepared.accessToken, session.accessToken)
        XCTAssertEqual(prepared.user.id, session.user.id)
    }

    @MainActor
    func testAuthServiceDefersLaunchMarkerUntilLaterInitialSession() async throws {
        let prefix = "sendmeter.tests.auth-launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: prefix)!
        defer { defaults.removePersistentDomain(forName: prefix) }
        let store = AuthSessionGuardStore(defaults: defaults, keyPrefix: prefix)

        _ = makeAuthService(sessionGuard: store)
        XCTAssertFalse(store.launchStateSnapshot().hadInstallationMarker)
        XCTAssertNil(store.acceptedSessionKey())

        let laterLaunch = makeAuthService(sessionGuard: store)
        XCTAssertFalse(laterLaunch.sessionIsFresh())
        XCTAssertFalse(store.launchStateSnapshot().hadInstallationMarker)

        let session = makeSession(
            sessionID: "arrived-after-unreadable-launch",
            expiresAt: Date().timeIntervalSince1970 + 3_600
        )
        let prepared = try await laterLaunch.prepareIncomingSession(
            session,
            event: .initialSession
        )
        XCTAssertEqual(prepared.accessToken, session.accessToken)
        XCTAssertTrue(store.launchStateSnapshot().hadInstallationMarker)
        XCTAssertEqual(
            store.acceptedSessionKey(),
            AuthSessionDescriptor(
                userID: session.user.id.uuidString,
                accessToken: session.accessToken,
                expiresAt: session.expiresAt
            ).stableKey
        )
    }

    @MainActor
    func testAuthServiceClassifiesBareHTTP401WithoutClearingOtherFailures() {
        let service = makeAuthService()
        func httpError(statusCode: Int) -> HTTPError {
            HTTPError(
                data: Data(#"{"message":"failure"}"#.utf8),
                response: HTTPURLResponse(
                    url: URL(string: "https://example.test/auth/v1/token")!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        XCTAssertEqual(
            service.recoveryDecision(for: httpError(statusCode: 401)),
            AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: .authExpired
            )
        )
        XCTAssertEqual(
            service.recoveryDecision(for: httpError(statusCode: 403)).action,
            .none
        )
        XCTAssertEqual(
            service.recoveryDecision(for: httpError(statusCode: 422)).action,
            .none
        )
        XCTAssertEqual(
            service.recoveryDecision(for: URLError(.notConnectedToInternet)).action,
            .none
        )
    }
}

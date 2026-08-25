import AuthenticationServices
@_spi(Experimental) import Auth
import Foundation
import SendmeterCore
import SendLogWatchCore
import Supabase
import UIKit

public enum SupabaseConfiguration {
    // SAFETY: This is a fixed, RFC-compliant Supabase endpoint controlled by the app.
    public static let projectURL = URL(string: "https://zznsqmcewtzlnfoiefkk.supabase.co")!
    public static let publishableKey = "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp"
    // SAFETY: This is a fixed, RFC-compliant app callback URL controlled by the app.
    public static let redirectURL = URL(string: "com.jirathip.sendlog://login-callback")!
}

public enum SupabaseEnvironment {
    public static let client = SupabaseClient(
        supabaseURL: SupabaseConfiguration.projectURL,
        supabaseKey: SupabaseConfiguration.publishableKey
    )
}

@MainActor
public enum PasskeyPresentation {
    public static func anchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return scenes.first?.windows.first ?? UIWindow()
    }
}

@MainActor
public final class AuthService {
    public let client: SupabaseClient
    /// Bounded, best-effort-persisted ring of auth events, read behind
    /// Settings' technical-details gate (#679/#757). Mirrors the quarantine
    /// breadcrumb store.
    public let diagnostics: AuthDiagnosticsStore
    /// Successful HTTP responses update this store's server-time evidence;
    /// auth recovery consults it without treating the device wall clock as
    /// authoritative.
    public let serverClock: ServerClockStore
    private let sessionGuard: AuthSessionGuardStore
    /// Dedupe for `ensureFreshSession`: while a refresh is in flight, concurrent
    /// callers share that one refresh instead of racing one each (repo rule: a
    /// dedupe guard is set BEFORE the first await). Because `AuthService` is
    /// `@MainActor`, accessing the field is serialized with the guard body.
    private var sessionRefreshTask: Task<Auth.Session, Error>?
    /// Dedupe the local self-heal sign-out. The rejection marker is persisted
    /// before this task is created, so a relaunch cannot retry the same poison.
    private var poisonedSessionRecoveryTask: Task<Void, Never>?

    public init(
        client: SupabaseClient = SupabaseEnvironment.client,
        diagnostics: AuthDiagnosticsStore? = nil,
        serverClock: ServerClockStore? = nil,
        sessionGuard: AuthSessionGuardStore? = nil
    ) {
        self.client = client
        self.diagnostics = diagnostics
            ?? AuthDiagnosticsStore(fileURL: Self.defaultDiagnosticsFileURL())
        self.serverClock = serverClock ?? ServerClockStore()
        let sessionGuard = sessionGuard ?? AuthSessionGuardStore()
        self.sessionGuard = sessionGuard
        let storedSession = client.auth.currentSession
        _ = sessionGuard.beginLaunch(
            hasStoredSession: storedSession != nil,
            storedSessionDescriptor: storedSession.map(Self.descriptor(for:))
        )
    }

    /// The on-device path the ring persists to. `nil` if there is no writable
    /// Application Support directory (the ring then stays in-memory only).
    public static func defaultDiagnosticsFileURL() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = support.appendingPathComponent("SendmeterNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auth-events.json")
    }

    // MARK: Session-freshness guard (#679)

    /// The ONE token-bearing seam. Repository calls obtaining a bearer token
    /// route through here (see `PostgRESTClient.sessionProvider`) so the access
    /// token is never read off a possibly-expired session.
    ///
    /// - Reads the stored session synchronously (no await) and returns it
    ///   unchanged when fresh — the common path costs no network and touches no
    ///   captured state.
    /// - When stale or missing, asks the EXISTING `SupabaseClient` auth for the
    ///   session; that getter refreshes via the main client's own refresh token
    ///   (the only such holder — #265). This method never stores or relays a
    ///   refresh token; nothing here is a second holder.
    /// - A dedupe guard is set before the first `await` so concurrent callers
    ///   share one refresh rather than racing one each.
    @discardableResult
    public func ensureFreshSession() async throws -> Auth.Session {
        if let current = client.auth.currentSession {
            let clockDecision = AuthRecoveryPolicy.decision(
                errorCode: nil,
                message: nil,
                clockAssessment: clockAssessment(for: current)
            )
            if clockDecision.action == .clearPoisonedSession {
                await clearPoisonedSession(
                    descriptor(for: current)
                )
                throw AuthRecoveryError(
                    friendlyErrorClass: clockDecision.friendlyErrorClass
                )
            }
            if !SessionFreshness.needsRefresh(expiresAt: current.expiresAt) {
                return current
            }
        }
        if let inFlight = sessionRefreshTask {
            return try await inFlight.value
        }
        let operationDescriptor = client.auth.currentSession.map(descriptor(for:))
        let task = Task { try await client.auth.session }
        sessionRefreshTask = task
        defer {
            // `Task` is a struct, so it has no `===` identity; and clearing is
            // safe unconditionally because `AuthService` is `@MainActor` and
            // the check-and-set above runs with no `await` between the nil
            // check and the assignment. A new task is only created when
            // `sessionRefreshTask` is nil (after this defer), so no other
            // caller can observe a replacement between here and the clear.
            sessionRefreshTask = nil
        }
        do {
            let session = try await task.value
            let clockDecision = AuthRecoveryPolicy.decision(
                errorCode: nil,
                message: nil,
                clockAssessment: clockAssessment(for: session)
            )
            if clockDecision.action == .clearPoisonedSession {
                await clearPoisonedSession(
                    descriptor(for: session)
                )
                throw AuthRecoveryError(
                    friendlyErrorClass: clockDecision.friendlyErrorClass
                )
            }
            // The refresh boundary (supabase-swift's `.tokenRefreshed`) is
            // recorded by `AppModel.handleAuthEvent`; this guard records only
            // failures so a single refresh is never counted twice.
            return session
        } catch {
            let decision = recoveryDecision(for: error)
            if decision.action == .clearPoisonedSession,
               let operationDescriptor {
                await clearPoisonedSession(
                    operationDescriptor
                )
                record(.failure, diagnosticDetail(for: error))
                throw AuthRecoveryError(friendlyErrorClass: decision.friendlyErrorClass)
            }
            record(.failure, diagnosticDetail(for: error))
            throw error
        }
    }

    /// Validates a session delivered by the SDK's auth event stream before it
    /// is presented to AppModel or relayed to the watch. Initial-session
    /// restoration is the only path subject to the durable install marker;
    /// explicit auth boundaries establish a new accepted identity.
    public func prepareIncomingSession(
        _ incoming: Auth.Session,
        event: NativeAuthEvent
    ) async throws -> Auth.Session {
        let incomingDescriptor = descriptor(for: incoming)
        let rejectedSessionKeys = sessionGuard.rejectedSessionKeys()
        if event == .initialSession,
           !sessionGuard.launchStateSnapshot().hadInstallationMarker,
           !rejectedSessionKeys.contains(incomingDescriptor.stableKey) {
            // A background/locked launch may have seen no Keychain session at
            // init time. Resolve the first identity at the actual auth-event
            // boundary instead of consuming the one-time marker window early.
            sessionGuard.acceptInitialSessionIfUnresolved(incomingDescriptor)
        }
        let launchState = sessionGuard.launchStateSnapshot()
        let guardDecision = AuthSessionGuardPolicy.decision(
            event: event,
            descriptor: incomingDescriptor,
            hasInstallationMarker: launchState.hadInstallationMarker,
            acceptedSessionKey: sessionGuard.acceptedSessionKey(),
            rejectedSessionKeys: rejectedSessionKeys,
            grandfatheredSessionKey: launchState.grandfatheredSessionKey
        )
        switch guardDecision {
        case .dropStaleInstall, .dropPreviouslyRejected:
            await clearPoisonedSession(
                incomingDescriptor
            )
            throw AuthRecoveryError(friendlyErrorClass: .authExpired)
        case .accept:
            break
        }

        let session: Auth.Session
        if event == .initialSession,
           SessionFreshness.needsRefresh(expiresAt: incoming.expiresAt) {
            session = try await ensureFreshSession()
        } else {
            session = incoming
        }
        let clockDecision = AuthRecoveryPolicy.decision(
            errorCode: nil,
            message: nil,
            clockAssessment: clockAssessment(for: session)
        )
        if clockDecision.action == .clearPoisonedSession {
            await clearPoisonedSession(
                descriptor(for: session)
            )
            throw AuthRecoveryError(
                friendlyErrorClass: clockDecision.friendlyErrorClass
            )
        }
        sessionGuard.accept(descriptor(for: session))
        return session
    }

    /// Whether the stored session is fresh enough to use without going back to
    /// the client. Reads `currentSession` (non-refreshing) — never touches the
    /// network. Mirrors the `SessionFreshness` pure decision.
    public func sessionIsFresh(now: Date = Date()) -> Bool {
        guard let current = client.auth.currentSession else { return false }
        return !SessionFreshness.needsRefresh(expiresAt: current.expiresAt, now: now)
    }

    /// Records an auth event into the diagnostics ring. Called by AppModel for
    /// the authStateChanges categories (sign-in/refresh/sign-out) and by this
    /// service for failures, so the ring is driven by real boundaries.
    public func recordAuthEvent(_ category: AuthEventCategory, detail: String? = nil) {
        diagnostics.record(
            AuthEventEntry(category: category, detail: detail, occurredAt: Date())
        )
    }

    /// A device clock lead is advisory: keep the accepted session alive and
    /// give the app a stable, user-visible Settings nudge. Server rejection or
    /// a future-issued token still takes the destructive recovery branch in
    /// `ensureFreshSession`/`prepareIncomingSession`.
    public func clockAdvisoryMessage(
        for session: Auth.Session,
        deviceDate: Date = Date(),
        nowContinuousTime: TimeInterval? = nil
    ) -> String? {
        guard clockAssessment(
            for: session,
            deviceDate: deviceDate,
            nowContinuousTime: nowContinuousTime
        ) == .deviceClockAhead else {
            return nil
        }
        return UserFacingError.message(for: .authClockSkew)
    }

    private func record(_ category: AuthEventCategory, _ detail: String? = nil) {
        recordAuthEvent(category, detail: detail)
    }

    /// Wraps an auth call so any thrown error lands in the ring as a `.failure`
    /// (with the reason) before re-throwing to the caller.
    private func guardedAuthCall<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let operationDescriptor = client.auth.currentSession.map(descriptor(for:))
        do {
            return try await operation()
        } catch {
            let decision = recoveryDecision(for: error)
            if decision.action == .clearPoisonedSession,
               let operationDescriptor {
                await clearPoisonedSession(
                    operationDescriptor
                )
                record(.failure, diagnosticDetail(for: error))
                throw AuthRecoveryError(friendlyErrorClass: decision.friendlyErrorClass)
            }
            record(.failure, diagnosticDetail(for: error))
            throw error
        }
    }

    /// A data request can be the first call to expose a bearer token that the
    /// server no longer accepts. Route that response through the same exact-
    /// session self-heal as GoTrue auth calls; AppModel's auth event then
    /// clears visible state while preserving this account's cache and queue.
    public func recoverFromAuthFailure(_ error: Error) async {
        let decision = recoveryDecision(for: error)
        guard decision.action == .clearPoisonedSession,
              let expected = (error as? PostgRESTError)?.sessionDescriptor else {
            return
        }
        await clearPoisonedSession(expected)
        record(.failure, diagnosticDetail(for: error))
    }

    private func diagnosticDetail(for error: Error) -> String {
        switch error {
        case let authError as AuthError:
            let code = authError.errorCode.rawValue
            let detail = authError.message
            return "Auth \(code): \(detail)"
        case let postgRESTError as PostgRESTError:
            let code = postgRESTError.code.map { " code=\($0)" } ?? ""
            let details = postgRESTError.details.map { " details=\($0)" } ?? ""
            let hint = postgRESTError.hint.map { " hint=\($0)" } ?? ""
            return "PostgREST status=\(postgRESTError.statusCode)\(code): \(postgRESTError.message)\(details)\(hint)"
        default:
            return error.localizedDescription
        }
    }

    private func descriptor(for session: Auth.Session) -> AuthSessionDescriptor {
        Self.descriptor(for: session)
    }

    private static func descriptor(for session: Auth.Session) -> AuthSessionDescriptor {
        AuthSessionDescriptor(
            userID: session.user.id.uuidString,
            accessToken: session.accessToken,
            expiresAt: session.expiresAt
        )
    }

    private func clockAssessment(
        for session: Auth.Session,
        deviceDate: Date = Date(),
        nowContinuousTime: TimeInterval? = nil
    ) -> AuthClockSkewAssessment {
        serverClock.assessment(
            deviceDate: deviceDate,
            tokenIssuedAt: descriptor(for: session).issuedAt,
            nowContinuousTime: nowContinuousTime
        )
    }

    func recoveryDecision(for error: Error) -> AuthRecoveryDecision {
        if let recovery = error as? AuthRecoveryError {
            return AuthRecoveryDecision(
                action: .clearPoisonedSession,
                friendlyErrorClass: recovery.friendlyErrorClass
            )
        }
        switch error {
        case let authError as AuthError:
            let assessment: AuthClockSkewAssessment = client.auth.currentSession.map {
                clockAssessment(for: $0)
            }
                ?? .insufficientEvidence
            return AuthRecoveryPolicy.decision(
                errorCode: authError.errorCode.rawValue,
                message: authError.message,
                clockAssessment: assessment
            )
        case let postgRESTError as PostgRESTError:
            let assessment: AuthClockSkewAssessment = client.auth.currentSession.map {
                clockAssessment(for: $0)
            }
                ?? .insufficientEvidence
            return AuthRecoveryPolicy.decision(
                errorCode: postgRESTError.code,
                message: postgRESTError.message,
                clockAssessment: assessment,
                statusCode: postgRESTError.statusCode
            )
        case let httpError as HTTPError:
            let assessment: AuthClockSkewAssessment = client.auth.currentSession.map {
                clockAssessment(for: $0)
            }
                ?? .insufficientEvidence
            return AuthRecoveryPolicy.decision(
                errorCode: nil,
                message: httpError.localizedDescription,
                clockAssessment: assessment,
                statusCode: httpError.response.statusCode
            )
        default:
            // Offline/timeout failures are not auth failures. Keep their
            // stable class for the normal banner and preserve their bounded
            // raw detail only in the support ring; never run the auth recovery
            // policy on a generic transport error.
            return AuthRecoveryDecision(
                action: .none,
                friendlyErrorClass: UserFacingError.classification(for: error)
            )
        }
    }

    /// Clears exactly the current poisoned SDK session. It does not delete
    /// account-scoped cache or queues; AppModel's signed-out event advances
    /// accountEpoch and preserves those durable stores for a later same-user
    /// sign-in. The current-session identity is rechecked before the async
    /// sign-out, so an account switch cannot sign out the new account.
    private func clearPoisonedSession(
        _ expectedDescriptor: AuthSessionDescriptor
    ) async {
        guard let current = client.auth.currentSession,
              AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                  expected: expectedDescriptor,
                  current: descriptor(for: current)
              ) else {
            return
        }
        if let inFlight = poisonedSessionRecoveryTask {
            await inFlight.value
            return
        }
        // This marker is a durable event/retry-loop guard only. A repeated
        // launch or auth event must still attempt local credential removal if
        // the previous sign-out failed; `false` is intentionally ignored.
        _ = sessionGuard.markRejected(expectedDescriptor)
        let client = self.client
        let task = Task { @MainActor in
            // `.local` removes only this device's session and intentionally
            // avoids a server/global revoke while a fresh sign-in is offered.
            await AuthSessionRemovalRetry.removeUntilCleared(
                expected: expectedDescriptor,
                current: {
                    client.auth.currentSession.map(Self.descriptor(for:))
                },
                remove: {
                    _ = try await client.auth.signOut(scope: .local)
                }
            )
        }
        poisonedSessionRecoveryTask = task
        await task.value
        poisonedSessionRecoveryTask = nil
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Auth.Session {
        // Success is recorded at the authStateChanges boundary (`.signedIn`)
        // by `AppModel.handleAuthEvent`; here we only record the failure path.
        return try await guardedAuthCall {
            try await client.auth.signIn(email: email, password: password)
        }
    }

    @discardableResult
    public func signUp(email: String, password: String) async throws -> Auth.Session? {
        try await guardedAuthCall {
            try await client.auth.signUp(email: email, password: password).session
        }
    }

    public func sendMagicLink(email: String) async throws {
        try await guardedAuthCall {
            try await client.auth.signInWithOTP(
                email: email,
                redirectTo: SupabaseConfiguration.redirectURL
            )
        }
    }

    /// #722 (parity with web #542): send a password reset email for the
    /// signed-in user's address. The link returns via the app's custom scheme
    /// (`SupabaseConfiguration.redirectURL`) so it reopens the app into the
    /// `PasswordRecoveryView` flow.
    public func resetPassword(email: String) async throws {
        try await guardedAuthCall {
            try await client.auth.resetPasswordForEmail(
                email,
                redirectTo: SupabaseConfiguration.redirectURL
            )
        }
    }

    public func signInWithPasskey() async throws {
        _ = try await guardedAuthCall {
            try await client.auth.signInWithPasskey(
                presentationAnchor: PasskeyPresentation.anchor()
            )
        }
    }

    public func registerPasskey() async throws {
        try await guardedAuthCall {
            _ = try await client.auth.registerPasskey(
                presentationAnchor: PasskeyPresentation.anchor()
            )
        }
    }

    /// Lists the passkeys registered for the signed-in user (#712). Reads the
    /// same server-side source as the web's `supabase.auth.passkey.list()`.
    @_spi(Experimental)
    public func listPasskeys() async throws -> [PasskeyListItem] {
        try await guardedAuthCall {
            try await client.auth.listPasskeys()
        }
    }

    /// Removes a passkey server-side (#712). Deleting the credential is what
    /// actually unregisters it — hiding it locally would leave it usable.
    public func deletePasskey(id: UUID) async throws {
        try await guardedAuthCall {
            try await client.auth.deletePasskey(id: id)
        }
    }

    /// Exchange an Apple identity token for a Supabase session (#631). The
    /// RAW nonce is passed — Supabase re-hashes it and compares against the
    /// (already-hashed) nonce Apple echoed into the token, mirroring the
    /// web's `src/lib/appleAuth.ts` exchange.
    public func signInWithApple(idToken: String, rawNonce: String) async throws {
        try await guardedAuthCall {
            _ = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken,
                    nonce: rawNonce
                )
            )
        }
    }

    public func handleDeepLink(_ url: URL) async throws {
        try await guardedAuthCall {
            _ = try await client.auth.session(from: url)
        }
    }

    public func updatePassword(_ password: String) async throws {
        try await guardedAuthCall {
            _ = try await client.auth.update(user: UserAttributes(password: password))
        }
    }

    public func signOut() async throws {
        // Success is recorded at the authStateChanges boundary (`.signedOut`)
        // by `AppModel.handleAuthEvent`; here we only record the failure path.
        try await guardedAuthCall {
            try await client.auth.signOut()
        }
    }
}

// MARK: - Minimal, typed PostgREST transport

public enum HTTPVerb: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct PostgRESTError: Error, Codable, LocalizedError, Sendable {
    public let code: String?
    public let message: String
    public let details: String?
    public let hint: String?
    public let statusCode: Int
    /// The non-secret identity of the bearer used for the failed request.
    /// Recovery must compare this with the current session before removing
    /// anything; a delayed response from an old account/request is not allowed
    /// to sign out a newer session.
    public let sessionDescriptor: AuthSessionDescriptor?

    public var errorDescription: String? { message }

    public init(
        code: String?,
        message: String,
        details: String?,
        hint: String?,
        statusCode: Int,
        sessionDescriptor: AuthSessionDescriptor? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.hint = hint
        self.statusCode = statusCode
        self.sessionDescriptor = sessionDescriptor
    }
}

/// Local Keychain removal is idempotent: the durable rejection marker only
/// deduplicates the event, it must never suppress a later removal attempt.
/// Keep the bounded retry loop in the application target so the compiled
/// wiring test can exercise the same behavior used by AuthService.
@MainActor
enum AuthSessionRemovalRetry {
    private static let maxAttempts = 3

    static func removeUntilCleared(
        expected: AuthSessionDescriptor,
        current: @escaping @MainActor () -> AuthSessionDescriptor?,
        remove: @escaping @MainActor () async throws -> Void
    ) async {
        for attempt in 0..<Self.maxAttempts {
            guard AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: expected,
                current: current()
            ) else {
                return
            }
            try? await remove()
            guard AuthSessionRecoveryPolicy.shouldAttemptLocalRemoval(
                expected: expected,
                current: current()
            ) else {
                return
            }
            if attempt + 1 < Self.maxAttempts {
                await Task.yield()
            }
        }
    }
}

// MARK: - #675 offline-queue rejection classification

extension PostgRESTError: ServerRejectionClassifying {
    /// The native port of the web's `classifyHandledFailure` line (monitoring.ts)
    /// as far as the offline queue cares. All the rules live in the pure
    /// `ServerRejectionClassifier` in Core (unit-tested by `swift test`);
    /// this conformance just feeds it this error's code + status.
    public var rejectionClass: RejectionClass {
        ServerRejectionClassifier.classify(code: code, statusCode: statusCode)
    }
}

extension PostgRESTError: FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        let authClassification = UserFacingError.friendlyErrorClass(
            forAuthErrorCode: code ?? "",
            message: message
        )
        if authClassification != .authFailed {
            return authClassification
        }
        switch rejectionClass {
        case .auth: return .authExpired
        case .parked: return .accessDenied
        case .permanent:
            return .serverRejected
        case .retryable:
            switch BackendFailureReason(errorDescription: message) {
            case .authExpired: return .authExpired
            case .unreachable: return .offline
            case .unknown: return .unknown
            }
        }
    }
}

extension AuthError: @retroactive FriendlyErrorClassifying {
    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .weakPassword:
            return .weakPassword
        case .sessionMissing:
            return .authExpired
        case let .jwtVerificationFailed(message):
            return UserFacingError.friendlyErrorClass(
                forAuthErrorCode: "invalid_jwt",
                message: message
            )
        case let .api(message, errorCode, _, _):
            return UserFacingError.friendlyErrorClass(
                forAuthErrorCode: errorCode.rawValue,
                message: message
            )
        case .pkceGrantCodeExchange, .implicitGrantRedirect:
            return .authFailed
        }
    }
}

private struct RemoteErrorBody: Decodable {
    let code: String?
    let message: String?
    let details: String?
    let hint: String?
}

public struct OneOrMany<Value: Decodable>: Decodable {
    public let values: [Value]

    public init(from decoder: Decoder) throws {
        if let one = try? Value(from: decoder) {
            self.values = [one]
            return
        }
        self.values = try [Value](from: decoder)
    }

    public var first: Value? { values.first }
}

public actor PostgRESTClient {
    private let projectURL: URL
    private let apiKey: String
    private let authClient: AuthClient
    /// The seam every token-bearing call uses to obtain the bearer token. It
    /// defaults to the (auto-refreshing) `authClient.session`, but the app
    /// wires it to `AuthService.ensureFreshSession()` so repository calls go
    /// through the single session-freshness guard (#679).
    private let sessionProvider: @Sendable () async throws -> Auth.Session
    private let serverClock: ServerClockStore?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        projectURL: URL = SupabaseConfiguration.projectURL,
        apiKey: String = SupabaseConfiguration.publishableKey,
        authClient: AuthClient = SupabaseEnvironment.client.auth,
        sessionProvider: (@Sendable () async throws -> Auth.Session)? = nil,
        serverClock: ServerClockStore? = nil,
        session: URLSession = .shared
    ) {
        self.projectURL = projectURL
        self.apiKey = apiKey
        self.authClient = authClient
        self.sessionProvider = sessionProvider ?? { try await authClient.session }
        self.serverClock = serverClock
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = LocalDateSupport.iso8601Date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
        self.decoder = decoder
    }

    public func encode<Body: Encodable>(_ body: Body) throws -> Data {
        try encoder.encode(body)
    }

    public func request<Response: Decodable>(
        path: String,
        method: HTTPVerb,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        prefer: String? = nil
    ) async throws -> Response {
        let authSession = try await sessionProvider()
        let accessToken = authSession.accessToken
        let sessionDescriptor = AuthSessionDescriptor(
            userID: authSession.user.id.uuidString,
            accessToken: authSession.accessToken,
            expiresAt: authSession.expiresAt
        )
        guard var components = URLComponents(
            url: projectURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PostgRESTError(
                code: nil,
                message: "Could not construct backend URL",
                details: nil,
                hint: nil,
                statusCode: 0,
                sessionDescriptor: sessionDescriptor
            )
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw PostgRESTError(
                code: nil,
                message: "Could not construct backend URL",
                details: nil,
                hint: nil,
                statusCode: 0,
                sessionDescriptor: sessionDescriptor
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PostgRESTError(
                code: nil,
                message: "Backend returned a non-HTTP response",
                details: nil,
                hint: nil,
                statusCode: 0,
                sessionDescriptor: sessionDescriptor
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let remote = try? decoder.decode(RemoteErrorBody.self, from: data)
            throw PostgRESTError(
                code: remote?.code,
                message: remote?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                details: remote?.details,
                hint: remote?.hint,
                statusCode: http.statusCode,
                sessionDescriptor: sessionDescriptor
            )
        }
        if let date = http.value(forHTTPHeaderField: "Date") {
            serverClock?.recordHTTPDateHeader(date)
        }

        if data.isEmpty {
            throw PostgRESTError(
                code: nil,
                message: "Backend returned an empty response",
                details: nil,
                hint: nil,
                statusCode: http.statusCode,
                sessionDescriptor: sessionDescriptor
            )
        }
        return try decoder.decode(Response.self, from: data)
    }

    public func requestVoid(
        path: String,
        method: HTTPVerb,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        prefer: String? = nil
    ) async throws {
        let authSession = try await sessionProvider()
        let accessToken = authSession.accessToken
        let sessionDescriptor = AuthSessionDescriptor(
            userID: authSession.user.id.uuidString,
            accessToken: authSession.accessToken,
            expiresAt: authSession.expiresAt
        )
        guard var components = URLComponents(
            url: projectURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PostgRESTError(
                code: nil,
                message: "Could not construct backend URL",
                details: nil,
                hint: nil,
                statusCode: 0,
                sessionDescriptor: sessionDescriptor
            )
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw PostgRESTError(
                code: nil,
                message: "Could not construct backend URL",
                details: nil,
                hint: nil,
                statusCode: 0,
                sessionDescriptor: sessionDescriptor
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PostgRESTError(
                code: nil,
                message: "Backend returned a non-HTTP response",
                details: nil,
                hint: nil,
                statusCode: 0,
                sessionDescriptor: sessionDescriptor
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let remote = try? decoder.decode(RemoteErrorBody.self, from: data)
            throw PostgRESTError(
                code: remote?.code,
                message: remote?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                details: remote?.details,
                hint: remote?.hint,
                statusCode: http.statusCode,
                sessionDescriptor: sessionDescriptor
            )
        }
        if let date = http.value(forHTTPHeaderField: "Date") {
            serverClock?.recordHTTPDateHeader(date)
        }
    }
}

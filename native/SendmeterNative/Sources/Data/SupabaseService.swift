import AuthenticationServices
@_spi(Experimental) import Auth
import Foundation
import SendmeterCore
import SendLogWatchCore
import Supabase
import UIKit

public enum SupabaseConfiguration {
    public static let projectURL = URL(string: "https://zznsqmcewtzlnfoiefkk.supabase.co")!
    public static let publishableKey = "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp"
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
    /// Bounded, best-effort-persisted ring of auth events for Settings →
    /// troubleshooting (#679). Mirrors the quarantine breadcrumb store.
    public let diagnostics: AuthDiagnosticsStore
    /// Dedupe for `ensureFreshSession`: while a refresh is in flight, concurrent
    /// callers share that one refresh instead of racing one each (repo rule: a
    /// dedupe guard is set BEFORE the first await). Because `AuthService` is
    /// `@MainActor`, accessing the field is serialized with the guard body.
    private var sessionRefreshTask: Task<Auth.Session, Error>?

    public init(
        client: SupabaseClient = SupabaseEnvironment.client,
        diagnostics: AuthDiagnosticsStore? = nil
    ) {
        self.client = client
        self.diagnostics = diagnostics
            ?? AuthDiagnosticsStore(fileURL: Self.defaultDiagnosticsFileURL())
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
        if let current = client.auth.currentSession,
           !SessionFreshness.needsRefresh(expiresAt: current.expiresAt) {
            return current
        }
        if let inFlight = sessionRefreshTask {
            return try await inFlight.value
        }
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
            // The refresh boundary (supabase-swift's `.tokenRefreshed`) is
            // recorded by `AppModel.handleAuthEvent`; this guard records only
            // failures so a single refresh is never counted twice.
            return session
        } catch {
            record(.failure, "Session refresh failed: \(error.localizedDescription)")
            throw error
        }
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

    private func record(_ category: AuthEventCategory, _ detail: String? = nil) {
        recordAuthEvent(category, detail: detail)
    }

    /// Wraps an auth call so any thrown error lands in the ring as a `.failure`
    /// (with the reason) before re-throwing to the caller.
    private func guardedAuthCall<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            record(.failure, error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Auth.Session {
        // Success is recorded at the authStateChanges boundary (`.signedIn`)
        // by `AppModel.handleAuthEvent`; here we only record the failure path.
        try await guardedAuthCall {
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
        try await guardedAuthCall {
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

    public var errorDescription: String? { message }

    public init(
        code: String?,
        message: String,
        details: String?,
        hint: String?,
        statusCode: Int
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.hint = hint
        self.statusCode = statusCode
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
        case .sessionMissing, .jwtVerificationFailed:
            return .authExpired
        case .api(_, let errorCode, _, _):
            return UserFacingError.friendlyErrorClass(forAuthErrorCode: errorCode.rawValue)
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
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        projectURL: URL = SupabaseConfiguration.projectURL,
        apiKey: String = SupabaseConfiguration.publishableKey,
        authClient: AuthClient = SupabaseEnvironment.client.auth,
        sessionProvider: (@Sendable () async throws -> Auth.Session)? = nil,
        session: URLSession = .shared
    ) {
        self.projectURL = projectURL
        self.apiKey = apiKey
        self.authClient = authClient
        self.sessionProvider = sessionProvider ?? { try await authClient.session }
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
        let accessToken = try await sessionProvider().accessToken
        guard var components = URLComponents(
            url: projectURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PostgRESTError(
                code: nil,
                message: "Could not construct backend URL",
                details: nil,
                hint: nil,
                statusCode: 0
            )
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw PostgRESTError(
                code: nil,
                message: "Could not construct backend URL",
                details: nil,
                hint: nil,
                statusCode: 0
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PostgRESTError(
                code: nil,
                message: "Backend returned a non-HTTP response",
                details: nil,
                hint: nil,
                statusCode: 0
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let remote = try? decoder.decode(RemoteErrorBody.self, from: data)
            throw PostgRESTError(
                code: remote?.code,
                message: remote?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                details: remote?.details,
                hint: remote?.hint,
                statusCode: http.statusCode
            )
        }

        if data.isEmpty {
            throw PostgRESTError(
                code: nil,
                message: "Backend returned an empty response",
                details: nil,
                hint: nil,
                statusCode: http.statusCode
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
        let accessToken = try await sessionProvider().accessToken
        guard var components = URLComponents(
            url: projectURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw URLError(.badURL) }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let remote = try? decoder.decode(RemoteErrorBody.self, from: data)
            throw PostgRESTError(
                code: remote?.code,
                message: remote?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                details: remote?.details,
                hint: remote?.hint,
                statusCode: http.statusCode
            )
        }
    }
}

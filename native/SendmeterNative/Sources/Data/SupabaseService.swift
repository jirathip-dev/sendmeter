import AuthenticationServices
@_spi(Experimental) import Auth
import Foundation
import SendmeterCore
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

    public init(client: SupabaseClient = SupabaseEnvironment.client) {
        self.client = client
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Auth.Session {
        try await client.auth.signIn(email: email, password: password)
    }

    @discardableResult
    public func signUp(email: String, password: String) async throws -> Auth.Session? {
        try await client.auth.signUp(email: email, password: password).session
    }

    public func sendMagicLink(email: String) async throws {
        try await client.auth.signInWithOTP(
            email: email,
            redirectTo: SupabaseConfiguration.redirectURL
        )
    }

    public func signInWithPasskey() async throws {
        try await client.auth.signInWithPasskey(
            presentationAnchor: PasskeyPresentation.anchor()
        )
    }

    public func registerPasskey() async throws {
        _ = try await client.auth.registerPasskey(
            presentationAnchor: PasskeyPresentation.anchor()
        )
    }

    /// Exchange an Apple identity token for a Supabase session (#631). The
    /// RAW nonce is passed — Supabase re-hashes it and compares against the
    /// (already-hashed) nonce Apple echoed into the token, mirroring the
    /// web's `src/lib/appleAuth.ts` exchange.
    public func signInWithApple(idToken: String, rawNonce: String) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken,
                nonce: rawNonce
            )
        )
    }

    public func handleDeepLink(_ url: URL) async throws {
        _ = try await client.auth.session(from: url)
    }

    public func updatePassword(_ password: String) async throws {
        _ = try await client.auth.update(user: UserAttributes(password: password))
    }

    public func signOut() async throws {
        try await client.auth.signOut()
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
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        projectURL: URL = SupabaseConfiguration.projectURL,
        apiKey: String = SupabaseConfiguration.publishableKey,
        authClient: AuthClient = SupabaseEnvironment.client.auth,
        session: URLSession = .shared
    ) {
        self.projectURL = projectURL
        self.apiKey = apiKey
        self.authClient = authClient
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
        let accessToken = try await authClient.session.accessToken
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
        let accessToken = try await authClient.session.accessToken
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

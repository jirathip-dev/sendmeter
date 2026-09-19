import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #926 AC3: a finished manual workout is ONE save. The UI guards the double
/// tap (`isSaving`, the engine cleared on success, the End control leaving with
/// the cover); this pins the layer beneath it — saving the same draft twice
/// cannot produce two durable intentions or two pending session rows, so a
/// repeat that ever escaped the UI still cannot save the workout twice.
///
/// The save runs through the REAL `AppModel` against an offline stubbed
/// PostgREST transport (the #916 harness seams): the queue file, the pending
/// cache rows and the restored session list are where a duplicate would show.
final class ManualWorkoutSaveOnceAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container.
    private let userID = UUID()

    @MainActor
    func testSavingTheSameFinishedWorkoutTwiceKeepsOneDurableSave() async throws {
        let server = FakeWorkoutSavePostgREST()
        let model = try await makeSignedInModel(server: server)
        let draft = try finishedWorkoutDraft()

        server.goOffline()
        await model.saveWorkout(draft) // the End tap
        await model.saveWorkout(draft) // the repeated tap the UI must never reach

        try await waitForQueueCount(model, expected: 1)
        try await waitForWorkoutSession(model, id: draft.sessionID, expected: 1)

        XCTAssertEqual(model.queuedWriteCount, 1, "one workout occupies one save slot")
        XCTAssertEqual(
            try Self.queuedWorkoutItems(for: draft.sessionID),
            1,
            "the durable intent — the queue item keyed by the workout's session identity — exists exactly once"
        )

        // Process death: a fresh instance reads the same on-disk state — the
        // save is still exactly one intent for exactly one pending workout.
        let relaunched = try await makeSignedInModel(server: server)
        try await waitForWorkoutSession(relaunched, id: draft.sessionID, expected: 1)
        XCTAssertEqual(
            try Self.queuedWorkoutItems(for: draft.sessionID),
            1,
            "the restart restores exactly one intent"
        )
    }

    // MARK: - Fixtures

    @MainActor
    private func finishedWorkoutDraft() throws -> WorkoutDraft {
        let start = Date()
        var engine = PhoneWorkoutEngine(accountUserID: userID, phase: .power, startedAt: start)
        try engine.startAttempt(at: start)
        return try engine.finish(at: start.addingTimeInterval(120))
    }

    // MARK: - Model harness (mirrors the #916 app-target seams)

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue never reached \(expected); last observed \(model.queuedWriteCount)")
    }

    @MainActor
    private func waitForWorkoutSession(_ model: AppModel, id: UUID, expected: Int) async throws {
        for _ in 0..<400 {
            if model.sessions.filter({ $0.id == id }).count == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            "the workout session never reached \(expected) rows; last observed "
                + "\(model.sessions.filter { $0.id == id }.count)"
        )
    }

    @MainActor
    private func makeSupabaseClient(storage: any AuthLocalStorage) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "https://example.test")!,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: storage,
                    autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    @MainActor
    private func makeRepository(
        session: Auth.Session,
        server: FakeWorkoutSavePostgREST
    ) -> SendmeterRepository {
        let suite = "ManualWorkoutSaveOnceAppTests.repo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = { session }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
    }

    @MainActor
    private func makeSignedInModel(
        server: FakeWorkoutSavePostgREST,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "ManualWorkoutSaveOnceAppTests.signed-in.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = InMemoryAuthStorage()
        let session = Self.makeSession(userID: accountID)
        try storage.store(
            key: "sb-example-auth-token",
            value: JSONEncoder().encode(session)
        )

        let client = makeSupabaseClient(storage: storage)
        let auth = AuthService(
            client: client,
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
        let model = AppModel(
            auth: auth,
            repository: makeRepository(session: session, server: server),
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession())
        )

        var waited = 0
        while model.currentUserID == nil, waited < 200 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    private static func makeSession(userID: UUID) -> Auth.Session {
        let payload = Data(#"{"session_id": "session-1", "iat": 1_000}"#.utf8)
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
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }

    // MARK: - On-disk state (the app container paths AppModel uses)

    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
    }

    /// The durable queue file holds every account's entries. The workout's
    /// intent is the item whose identity IS the session identity the save is
    /// keyed by — count those, not raw substring hits (the payload carries the
    /// same id inside the draft, so a substring count doubles per item).
    private static func queuedWorkoutItems(for sessionID: UUID) throws -> Int {
        let url = supportDirectory().appendingPathComponent("pending-writes.json")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return 0 }
        return items.filter {
            ($0["id"] as? String)?.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame
        }.count
    }
}

/// The stubbed backend for this suite: anything unanswered fails at the
/// transport layer while `goOffline()` is in effect, and an online request
/// that is not part of the save path answers with an empty list.
private final class FakeWorkoutSavePostgREST: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true

    func goOffline() {
        lock.lock()
        online = false
        lock.unlock()
    }

    func goOnline() {
        lock.lock()
        online = true
        lock.unlock()
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeWorkoutSaveProtocol.self]
        FakeWorkoutSaveProtocol.server = self
        return URLSession(configuration: configuration)
    }

    struct Reply {
        let status: Int
        let body: Data
    }

    /// Nil means "fail at the transport layer" (offline).
    func reply(for request: URLRequest, body: Data?) -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        guard online else { return nil }
        return Reply(status: 200, body: Data("[]".utf8))
    }
}

private final class FakeWorkoutSaveProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeWorkoutSavePostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.drain(request.httpBodyStream)
        guard let server = Self.server, let reply = server.reply(for: request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// In-memory auth storage (duplicated from the other app-target suites; those
/// copies are file-private).
private final class InMemoryAuthStorage: AuthLocalStorage {
    private var store: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        store[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        store[key]
    }

    func remove(key: String) throws {
        store.removeValue(forKey: key)
    }
}

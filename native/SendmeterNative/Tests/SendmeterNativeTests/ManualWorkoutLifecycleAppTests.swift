import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #936: the manual-workout lifecycle belongs to the APP-LEVEL owner
/// (`AppModel.manualWorkoutLifecycle`), not to the Workout tab's view state.
///
/// These tests drive the real `AppModel` (against an offline-stubbed PostgREST
/// transport, the #916/#926 app-target seams) and assert what the owner's
/// choices DO at the app layer: the workout survives the tab view's state being
/// thrown away, a second start cannot replace it, an accepted End writes
/// exactly one durable intent, a refused End writes nothing, and the account
/// boundary tears the workout down through the same owner.
///
/// What this layer cannot observe is disclosed in `.report-1.md`: the Live
/// Activity card and the rest deadline are app-target adapters whose effect
/// payloads are pinned deterministically in
/// `SendmeterCoreTests/ManualWorkoutLifecycleCoordinatorTests`.
final class ManualWorkoutLifecycleAppTests: XCTestCase {
    /// A fresh account per test: the cache and the pending-write queue are
    /// account-scoped files in the app container.
    private let userID = UUID()

    @MainActor
    func testTheOwnerKeepsOneWorkoutAndOneFinishAcrossViewRecreation() async throws {
        let server = FakeManualWorkoutLifecyclePostgREST()
        let model = try await makeSignedInModel(server: server)
        let start = Date()

        let started = model.startManualWorkout(at: start)
        guard case .changed = started.decision else {
            return XCTFail("a signed-in Start must arm the workout, got \(started.decision)")
        }
        let running = try XCTUnwrap(model.manualWorkoutLifecycle.workout)
        XCTAssertEqual(running.draft.accountUserID, userID)

        // SwiftUI recreation: this view's state is gone by construction. The
        // owner's is not — the tab resumes the SAME workout...
        _ = model.resumeManualWorkout()
        XCTAssertEqual(
            model.manualWorkoutLifecycle.workoutStartedAt,
            start,
            "resume must hand back the running workout, not create one"
        )
        // ...and a re-created view's Start cannot replace it.
        let restarted = model.startManualWorkout(at: start.addingTimeInterval(600))
        guard case .ignored = restarted.decision else {
            return XCTFail("a start during an in-progress workout must be ignored")
        }
        XCTAssertEqual(model.manualWorkoutLifecycle.workoutStartedAt, start)
        XCTAssertEqual(model.manualWorkoutLifecycle.workout, running)

        // One completed attempt, then End.
        try model.toggleManualWorkoutAttempt(at: start)
        try model.toggleManualWorkoutAttempt(at: start.addingTimeInterval(90))
        XCTAssertEqual(model.manualWorkoutLifecycle.workout?.draft.attempts.count, 1)

        server.goOffline()
        let finished = model.endManualWorkout(at: start.addingTimeInterval(120))
        guard case let .persist(draft, _) = finished.decision else {
            return XCTFail("End with a completed attempt must hand over one draft, got \(finished.decision)")
        }
        XCTAssertNil(model.manualWorkoutLifecycle.workout, "the accepted finish clears the workout")
        XCTAssertTrue(model.manualWorkoutLifecycle.isSaving)

        // A repeated End — the tap the UI must never reach — hands over nothing.
        guard case .ignored = model.endManualWorkout(at: Date()).decision else {
            return XCTFail("a repeated End must not hand over a second draft")
        }

        try await waitForQueueCount(model, expected: 1)
        try await waitForWorkoutSession(model, id: draft.sessionID, expected: 1)
        try await waitForSaveToComplete(model)

        XCTAssertEqual(
            try Self.queuedWorkoutItems(for: draft.sessionID),
            1,
            "the finish occupies exactly one durable intent"
        )
        XCTAssertEqual(model.queuedWriteCount, 1, "one workout, one save slot")
    }

    @MainActor
    func testAnEndWithNoCompletedAttemptIsRefusedAndTheWorkoutStaysArmed() async throws {
        let server = FakeManualWorkoutLifecyclePostgREST()
        let model = try await makeSignedInModel(server: server)
        let start = Date()

        _ = model.startManualWorkout(at: start)
        let running = try XCTUnwrap(model.manualWorkoutLifecycle.workout)

        let outcome = model.endManualWorkout(at: start.addingTimeInterval(30))

        guard case let .refused(message) = outcome.decision else {
            return XCTFail("an End with no completed attempt must be refused, got \(outcome.decision)")
        }
        XCTAssertEqual(message, UserFacingError.message(for: .missingAttempt), "the #926 copy, in full")
        XCTAssertEqual(model.manualWorkoutLifecycle.workout, running, "the refused workout stays armed")
        XCTAssertFalse(model.manualWorkoutLifecycle.isSaving, "a refused End never starts a save")
        XCTAssertEqual(model.queuedWriteCount, 0, "a refused End writes nothing")
    }

    @MainActor
    func testTheAccountBoundaryTearsTheWorkoutDownThroughTheOwner() async throws {
        let server = FakeManualWorkoutLifecyclePostgREST()
        let model = try await makeSignedInModel(server: server)

        _ = model.startManualWorkout(at: Date())
        XCTAssertNotNil(model.manualWorkoutLifecycle.workout)

        await model.signOut()
        try await waitForSignedOut(model)

        XCTAssertNil(
            model.manualWorkoutLifecycle.workout,
            "the account boundary tears the workout down through the owner"
        )
        XCTAssertFalse(model.manualWorkoutLifecycle.isSaving)
        XCTAssertNil(model.manualWorkoutLifecycle.workoutStartedAt)
    }

    // MARK: - Fixtures and waits

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
    private func waitForSaveToComplete(_ model: AppModel) async throws {
        for _ in 0..<400 {
            if !model.manualWorkoutLifecycle.isSaving { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the finish's save never reported back to the lifecycle owner")
    }

    @MainActor
    private func waitForSignedOut(_ model: AppModel) async throws {
        for _ in 0..<600 {
            if model.currentUserID == nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("sign-out never cleared the visible account")
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
        server: FakeManualWorkoutLifecyclePostgREST
    ) -> SendmeterRepository {
        let suite = "ManualWorkoutLifecycleAppTests.repo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = { session }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: session.accessToken,
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
    }

    @MainActor
    private func makeSignedInModel(
        server: FakeManualWorkoutLifecyclePostgREST
    ) async throws -> AppModel {
        let suite = "ManualWorkoutLifecycleAppTests.signed-in.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = InMemoryAuthStorage()
        let session = Self.makeSession(userID: userID)
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

        // SplashView calls this on first presentation; the test-hosted model has
        // no view hierarchy, so the bootstrap's splash floor would otherwise
        // hold `bootState` at `.loading` for ever.
        model.splashPresented(at: Date())
        try await waitUntil("the seeded session became currentUserID", timeout: 90) {
            model.currentUserID == self.userID
        }
        // The account boundary (and its epoch) belongs to the bootstrap: writing
        // the workout before it settles would be writing into a generation the
        // model is about to replace.
        try await waitUntil("the account bootstrap finished", timeout: 120) {
            model.bootState == .signedIn && model.hasLoadedSessions && !model.isRefreshing
        }
        return model
    }

    @MainActor
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
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

    /// The workout's durable intent is the queue item whose identity IS the
    /// session identity the save is keyed by — count those, not raw substring
    /// hits (the payload carries the same id inside the draft).
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

/// The stubbed backend: anything unanswered fails at the transport layer while
/// `goOffline()` is in effect; the auth boundary answers the sign-out the SDK
/// expects (204) and every other online request answers an empty collection.
private final class FakeManualWorkoutLifecyclePostgREST: @unchecked Sendable {
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
        configuration.protocolClasses = [FakeManualWorkoutLifecycleProtocol.self]
        FakeManualWorkoutLifecycleProtocol.server = self
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
        let path = request.url?.path ?? ""
        if path.contains("/auth/v1/logout") {
            return Reply(status: 204, body: Data())
        }
        return Reply(status: 200, body: Data("[]".utf8))
    }
}

private final class FakeManualWorkoutLifecycleProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeManualWorkoutLifecyclePostgREST?

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

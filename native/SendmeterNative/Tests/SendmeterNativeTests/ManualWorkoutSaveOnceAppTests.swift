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
///
/// #989: every read here is a deadline-bound wait. The queue file is shared
/// by every model in the process, and the reads below assert it (or the
/// published session list) immediately after a save; the fixed-budget poll
/// this file used could give up on a slow/contended runner, and an immediate
/// file read could sample the file before this run's item was persisted — a
/// rerun-to-green proves nothing either way. A wait that never sees the
/// expected state still fails and reports what was observed (`waitUntil`
/// carries the #978 observed-state shape; the account is already unique per
/// test).
final class ManualWorkoutSaveOnceAppTests: XCTestCase {
    /// #989/#978: every wait is bounded by a wall-clock deadline, never by a
    /// fixed iteration budget. The deadline decides only how long a wait may
    /// take; what is asserted never changes, and expiry reports the state
    /// actually observed.
    private static let waitDeadline: Duration = .seconds(60)

    /// Polls `isSatisfied` until it holds or `timeout` elapses, then fails the
    /// test with the elapsed time and the state `observed`.
    @MainActor
    private func waitUntil(
        _ expectation: String,
        timeout: Duration = ManualWorkoutSaveOnceAppTests.waitDeadline,
        isSatisfied: @MainActor () -> Bool,
        observed: @MainActor () -> String
    ) async throws {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if isSatisfied() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard isSatisfied() else {
            let elapsed = ContinuousClock.now - started
            XCTFail("timed out after \(elapsed) waiting for \(expectation); observed \(observed())")
            return
        }
    }

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
        // #989: the durable file itself is the assertion's subject and it can
        // lag the in-memory publications, so wait for the item to settle at
        // exactly one before asserting it (no wait-into-green: an item that
        // never lands still fails this test on the wait's expiry).
        try await waitForQueuedWorkoutItems(for: draft.sessionID, expected: 1)

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
        // #989: the relaunch reads the same shared file; wait for it to
        // settle again before asserting the restored intent.
        try await waitForQueuedWorkoutItems(for: draft.sessionID, expected: 1)
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
        try await waitUntil(
            "the queued write count to reach \(expected)",
            isSatisfied: { model.queuedWriteCount == expected },
            observed: { Self.modelQueueState(model) }
        )
    }

    @MainActor
    private func waitForWorkoutSession(_ model: AppModel, id: UUID, expected: Int) async throws {
        try await waitUntil(
            "the workout session to reach \(expected) row(s)",
            isSatisfied: { model.sessions.filter({ $0.id == id }).count == expected },
            observed: { Self.modelQueueState(model, id: id) }
        )
    }

    /// #989: deadline-bound wait for the DURABLE file — the queue item keyed
    /// by the workout's session identity — to hold `expected` item(s). The
    /// save persists the file through its own queue actor and the file is
    /// shared with every other model in the process, so an immediate read can
    /// sample it before this run's item lands (measured at an unchanged head:
    /// the in-memory count said 1 while the file read said 0). Waiting does
    /// not weaken the assertion — the count must settle at exactly `expected`
    /// — it only stops the read from racing the persist. Expiry reports the
    /// file's actual content.
    @MainActor
    private func waitForQueuedWorkoutItems(for sessionID: UUID, expected: Int) async throws {
        try await waitUntil(
            "the durable queue file to hold \(expected) item(s) for the workout's session identity",
            isSatisfied: { Self.queuedWorkoutItemCount(for: sessionID) == expected },
            observed: { Self.queueFileState(for: sessionID) }
        )
    }

    /// The state the model-side waits expired on: the published count, this
    /// workout's rows in the session list, and the durable queue file.
    @MainActor
    private static func modelQueueState(_ model: AppModel, id: UUID? = nil) -> String {
        var fields = [
            "queuedWriteCount=\(model.queuedWriteCount)",
            "hasLoadedPendingWrites=\(model.hasLoadedPendingWrites)",
            "sessions=\(model.sessions.count)",
            "pendingSessions=\(model.sessions.filter { $0.pending }.count)"
        ]
        if let id {
            let rows = model.sessions.filter { $0.id == id }
            fields.append("matchingRows=\(rows.count)")
            let summary = rows
                .map { "\($0.id.uuidString.prefix(8))/\($0.type)\($0.pending ? "|pending" : "")" }
                .joined(separator: ", ")
            fields.append("rows=[\(summary)]")
        }
        fields.append(queueFileState(for: id))
        return fields.joined(separator: ", ")
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

        // The auth observation task delivers `.initialSession` from local
        // storage. #989/#978: wait against a WALL-CLOCK deadline, not a fixed
        // iteration budget — the old shape (`waited < 200` × `Task.yield()`)
        // gave up on a contended runner without ever observing the state it
        // timed out on. The assertion below is unchanged.
        try await waitUntil(
            "the seeded auth session to become currentUserID",
            isSatisfied: { model.currentUserID != nil },
            observed: { Self.authState(model) }
        )
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    /// The state a `currentUserID` wait expired on.
    @MainActor
    private static func authState(_ model: AppModel) -> String {
        "currentUserID=\(model.currentUserID?.uuidString ?? "nil")"
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

    /// The same identity filter as `queuedWorkoutItems`, but an unreadable
    /// file reads as 0 so a wait can poll it and report the file state on
    /// expiry instead of throwing mid-poll (the assertion still uses
    /// `queuedWorkoutItems`, which throws on an unreadable file). A `nil`
    /// session reads only the file's total item count.
    private static func queuedWorkoutItemCount(for sessionID: UUID?) -> Int {
        let url = supportDirectory().appendingPathComponent("pending-writes.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return 0 }
        guard let sessionID else { return items.count }
        return items.filter {
            ($0["id"] as? String)?.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame
        }.count
    }

    /// The queue file as a wait observed it — bounded to counts and this
    /// session's own identity, so a file that has accumulated other runs'
    /// items stays readable in a failure message.
    private static func queueFileState(for sessionID: UUID?) -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json")
        guard let data = try? Data(contentsOf: url) else {
            return "pending-writes.json unreadable/absent"
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else {
            return "pending-writes.json \(data.count) bytes, undecodable"
        }
        let ids = items.compactMap { $0["id"] as? String }
        let accounts = Set(items.compactMap { $0["accountUserID"] as? String }).count
        let breadcrumbs = (root["breadcrumbs"] as? [Any])?.count ?? 0
        var state = "pending-writes.json \(data.count) bytes, items=\(items.count)"
            + ", accounts=\(accounts), breadcrumbs=\(breadcrumbs)"
        if let sessionID {
            let mine = ids.filter {
                $0.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame
            }.count
            state += ", mine=\(mine)"
        }
        return state
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

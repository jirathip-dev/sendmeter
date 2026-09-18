import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #942: the app-side merge path, driven through a REAL `AppModel` and a
/// stubbed PostgREST transport — History's plan → the optimistic local fold →
/// the durable queue → the `merge_tindeq_sessions` RPC → the server-reconciled
/// row. The RPC's own guardrails (RLS, atomicity) are proven by
/// supabase/tests/merge_tindeq_sessions.sql; these tests prove the client half:
/// one live entry locally, no duplicates, the recordings still under the
/// surviving group, and a queued merge that survives being offline.
final class TindeqSessionMergeAppTests: XCTestCase {
    /// A fresh account per test: the on-device cache and pending-write queue
    /// are account-scoped files in the app container, so a shared user id
    /// would leak one test's merge into the next.
    private let userID = UUID()
    private let survivorID = UUID(uuidString: "94200000-0000-0000-0000-000000000011")!
    private let secondID = UUID(uuidString: "94200000-0000-0000-0000-000000000012")!
    private let thirdID = UUID(uuidString: "94200000-0000-0000-0000-000000000013")!
    private let survivorGroup = UUID(uuidString: "94200000-0000-0000-0000-0000000000a1")!
    private let secondGroup = UUID(uuidString: "94200000-0000-0000-0000-0000000000a2")!
    private let thirdGroup = UUID(uuidString: "94200000-0000-0000-0000-0000000000a3")!

    // MARK: - AC1 / AC2: three same-day entries fold into one

    @MainActor
    func testMergeFoldsThreeSameDayEntriesIntoOneAndKeepsEveryRecording() async throws {
        let server = FakePostgREST(
            userID: userID,
            sessions: sessionFixtures(),
            recordings: recordingFixtures(),
            mergeResult: """
            [{"group_id":"\(survivorGroup.uuidString.lowercased())","duration_min":61,
              "recording_count":3,"note":"3 recordings · FDP, MWF"}]
            """
        )
        let model = try await makeSignedInModel(server: server)
        await refresh(model)

        XCTAssertEqual(model.sessions.count, 3, "fixture: three same-day Tindeq entries")
        XCTAssertEqual(model.recordings.count, 3, "fixture: one recording per entry")

        let merged = await model.mergeTindeqSessions(model.sessions)

        XCTAssertTrue(merged)
        XCTAssertEqual(model.sessions.count, 1, "AC1: exactly one entry survives")
        let survivor = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(survivor.id, survivorID, "the earliest-started entry keeps its identity")
        XCTAssertEqual(survivor.date, "2026-01-20")
        XCTAssertEqual(survivor.durationMinutes, 61, "duration is the full span (10:00:00 → 11:01:00)")
        XCTAssertEqual(survivor.note, "3 recordings · FDP, MWF", "the note lists every recording")
        XCTAssertFalse(model.sessions.contains { $0.id == secondID || $0.id == thirdID })

        // AC2: the detail surface groups by `session.groupID` — every merged
        // recording is now under the surviving group, so all three render.
        XCTAssertEqual(
            model.recordings.filter { $0.groupID == survivor.groupID }.count,
            3,
            "AC2: the merged session's detail shows every recording"
        )

        try await waitForQueueToDrain(model)
        XCTAssertEqual(model.queuedWriteCount, 0, "the durable merge left the queue")

        // The request the app actually sent: the plan's identity + RPE choice.
        let body = try XCTUnwrap(server.lastMergeBody)
        XCTAssertEqual(
            (body["p_session_ids"] as? [String])?.count,
            3,
            "the RPC receives every selected session"
        )
        XCTAssertEqual(
            (body["p_survivor_id"] as? String)?.lowercased(),
            survivorID.uuidString.lowercased()
        )
        XCTAssertEqual(body["p_rpe"] as? Double, 6, "the selected confirmation is kept")
        XCTAssertEqual(
            body["p_rpe_confirmed"] as? Bool,
            true,
            "a session already confirmed by the user keeps its confirmed RPE"
        )
        XCTAssertEqual(server.mergeRequestCount, 1)

        // The upload reconciled the optimistic row with the RPC's own numbers.
        let reconciled = try XCTUnwrap(model.sessions.first)
        XCTAssertFalse(reconciled.pending, "the upload reconciled the row")
        XCTAssertEqual(reconciled.durationMinutes, 61)
        XCTAssertEqual(reconciled.note, "3 recordings · FDP, MWF")
    }

    // MARK: - AC4: offline queueing, then reconnect

    @MainActor
    func testOfflineMergeIsQueuedAndAppliedOnReconnectWithoutDuplicates() async throws {
        let server = FakePostgREST(
            userID: userID,
            sessions: sessionFixtures(),
            recordings: recordingFixtures(),
            mergeResult: """
            [{"group_id":"\(survivorGroup.uuidString.lowercased())","duration_min":61,
              "recording_count":3,"note":"3 recordings · FDP, MWF"}]
            """
        )
        let model = try await makeSignedInModel(server: server)
        await refresh(model)
        XCTAssertEqual(model.sessions.count, 3)

        // Offline: the RPC cannot land, but the merge must still be applied
        // locally and stay queued.
        server.goOffline()
        let merged = await model.mergeTindeqSessions(model.sessions)

        XCTAssertTrue(merged, "an offline merge is accepted: it is queued")
        XCTAssertEqual(model.sessions.count, 1, "the merged entry shows while offline")
        XCTAssertEqual(server.mergeRequestCount, 0, "nothing reached the server")
        try await waitForQueueCount(model, expected: 1)

        // An authoritative refresh while the merge is still queued must not
        // resurrect the merged-away entries (the server still returns them).
        await refresh(model)
        XCTAssertEqual(
            model.sessions.count,
            1,
            "AC4: a refresh during the pending merge keeps the fold"
        )

        // Reconnect: the queued merge uploads verbatim, exactly once.
        server.goOnline()
        await model.retryAllQueuedWrites()
        try await waitForQueueCount(model, expected: 0)

        XCTAssertEqual(server.mergeRequestCount, 1, "AC4: the merge is applied once, not duplicated")
        XCTAssertEqual(model.sessions.count, 1, "AC4: still one entry after the upload")
        XCTAssertEqual(
            model.recordings.filter { $0.groupID == survivorGroup }.count,
            3
        )
    }

    // MARK: - AC3: ineligible selections never build a request

    @MainActor
    func testIneligibleSelectionsAreRefusedWithoutContactingTheServer() async throws {
        let server = FakePostgREST(
            userID: userID,
            sessions: sessionFixtures(),
            recordings: recordingFixtures(),
            mergeResult: "[]"
        )
        let model = try await makeSignedInModel(server: server)
        await refresh(model)

        let survivor = try XCTUnwrap(model.sessions.first { $0.id == survivorID })
        let second = try XCTUnwrap(model.sessions.first { $0.id == secondID })
        var crossDay = second
        crossDay.date = "2026-01-19"
        var nonTindeq = second
        nonTindeq.type = "fingerboard"
        var pending = second
        pending.pending = true

        XCTAssertNil(model.mergePreview([survivor, crossDay]))
        XCTAssertNil(model.mergePreview([survivor, nonTindeq]))
        XCTAssertNil(model.mergePreview([survivor, pending]))
        XCTAssertNil(model.mergePreview([survivor]))

        let crossDayMerged = await model.mergeTindeqSessions([survivor, crossDay])
        let nonTindeqMerged = await model.mergeTindeqSessions([survivor, nonTindeq])
        let pendingMerged = await model.mergeTindeqSessions([survivor, pending])

        XCTAssertFalse(crossDayMerged)
        XCTAssertFalse(nonTindeqMerged)
        XCTAssertFalse(pendingMerged)
        XCTAssertEqual(server.mergeRequestCount, 0, "AC3: a refused selection never reaches the RPC")
        XCTAssertEqual(model.sessions.count, 3, "AC3: a refused merge changes nothing locally")
    }

    // MARK: - Fixtures

    private func sessionFixtures() -> String {
        """
        [
          \(sessionJSON(id: survivorID, group: survivorGroup, duration: 30, rpe: 6, confirmed: true, note: "1 recording · FDP")),
          \(sessionJSON(id: secondID, group: secondGroup, duration: 20, rpe: 5.5, confirmed: false, note: "1 recording · FDP")),
          \(sessionJSON(id: thirdID, group: thirdGroup, duration: 15, rpe: 7, confirmed: false, note: "1 recording · MWF"))
        ]
        """
    }

    private func sessionJSON(
        id: UUID,
        group: UUID,
        duration: Int,
        rpe: Double,
        confirmed: Bool,
        note: String
    ) -> String {
        """
        {"id":"\(id.uuidString.lowercased())","date":"2026-01-20","type":"tindeq",
         "type_label":"Tindeq","duration_min":\(duration),"rpe":\(rpe),
         "rpe_confirmed":\(confirmed),"load":\(Int(Double(duration) * rpe)),
         "note":"\(note)","phase":"capacity","group_id":"\(group.uuidString.lowercased())",
         "workout_source":null,"updated_at":"2026-01-20T12:00:00Z","deleted_at":null}
        """
    }

    private func recordingFixtures() -> String {
        """
        [
          \(recordingJSON(id: "94200000-0000-0000-0000-0000000000c1", at: "2026-01-20T10:00:00Z", tag: "FDP", group: survivorGroup)),
          \(recordingJSON(id: "94200000-0000-0000-0000-0000000000c3", at: "2026-01-20T10:30:00Z", tag: "FDP", group: secondGroup)),
          \(recordingJSON(id: "94200000-0000-0000-0000-0000000000c4", at: "2026-01-20T11:00:00Z", tag: "MWF", group: thirdGroup))
        ]
        """
    }

    private func recordingJSON(id: String, at: String, tag: String, group: UUID) -> String {
        """
        {"id":"\(id)","deleted_at":null,"updated_at":"2026-01-20T12:00:00Z",
         "recorded_at":"\(at)","duration_ms":60000,"peak_kg":32,"avg_kg":28,
         "sample_count":2,"note":"","tag":"\(tag)","side":"left",
         "group_id":"\(group.uuidString.lowercased())","source":"dynamometer"}
        """
    }

    // MARK: - Model harness (mirrors GuidedForceSideBehaviorTests seams)

    @MainActor
    private func refresh(_ model: AppModel) async {
        await model.refreshAll(showSpinner: false)
    }

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue never reached \(expected); last observed \(model.queuedWriteCount)")
    }

    @MainActor
    private func waitForQueueToDrain(_ model: AppModel) async throws {
        try await waitForQueueCount(model, expected: 0)
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
    private func makeRepository(session: Auth.Session, server: FakePostgREST) -> SendmeterRepository {
        let suite = "TindeqSessionMergeAppTests.repo.\(UUID().uuidString)"
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
    private func makeSignedInModel(server: FakePostgREST) async throws -> AppModel {
        let suite = "TindeqSessionMergeAppTests.signed-in.\(UUID().uuidString)"
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
}

/// The stubbed backend: canned GET bodies per path, a capture of the merge
/// RPC body, and an offline mode that fails every request at the transport
/// layer (exactly what a queued offline merge sees).
private final class FakePostgREST: @unchecked Sendable {
    private let lock = NSLock()
    private let userID: UUID
    private let sessions: String
    private let recordings: String
    private let mergeResult: String
    private var online = true
    private var bodies: [Data] = []

    init(userID: UUID, sessions: String, recordings: String, mergeResult: String) {
        self.userID = userID
        self.sessions = sessions
        self.recordings = recordings
        self.mergeResult = mergeResult
    }

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

    var mergeRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bodies.count
    }

    var lastMergeBody: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = bodies.last else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakePostgRESTProtocol.self]
        FakePostgRESTProtocol.server = self
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
        let query = request.url?.query ?? ""
        let method = request.httpMethod ?? "GET"

        if path.hasSuffix("/rpc/merge_tindeq_sessions") {
            bodies.append(body ?? Data())
            return Reply(status: 200, body: Data(mergeResult.utf8))
        }
        if path.hasSuffix("/sessions") {
            return Reply(status: 200, body: Data(sessions.utf8))
        }
        if path.hasSuffix("/tindeq_recordings") {
            // The curve warm-up asks for `samples`; those rows are not part of
            // this fixture set, so answer with none.
            if method == "GET", query.contains("samples") {
                return Reply(status: 200, body: Data("[]".utf8))
            }
            if method == "GET" {
                return Reply(status: 200, body: Data(recordings.utf8))
            }
            return Reply(status: 200, body: Data("[]".utf8))
        }
        return Reply(status: 200, body: Data("[]".utf8))
    }
}

private final class FakePostgRESTProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakePostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body to URLProtocol as a stream, never as
        // `httpBody` — the RPC body must be drained from the stream here.
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

/// In-memory auth storage (duplicated from AuthRecoveryWiringTests /
/// GuidedForceSideBehaviorTests; those copies are file-private).
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

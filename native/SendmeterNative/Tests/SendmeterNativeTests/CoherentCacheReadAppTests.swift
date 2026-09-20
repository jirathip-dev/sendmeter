import SwiftUI
import UIKit
import XCTest

@_spi(Experimental) import Auth
import SendmeterCore
import SendmeterWeather
import Supabase

@testable import Sendmeter

/// #922: the production hydration/publication path performs its full-workspace
/// cache reads on the storage side, and one refresh reads the workspace exactly
/// twice.
///
/// These tests drive a REAL signed-in `AppModel` through its bootstrap and
/// refresh funnel; the only substitutions are the network transport (a stub
/// that answers well-formed empty deltas, so the suite is hermetic) and the
/// cache storage seams (a file-backed store the test seeds, plus the probe's
/// storage-side gate).
@MainActor
final class CoherentCacheReadAppTests: XCTestCase {
    private let userID = UUID()

    // MARK: - Storage-side gate (the delay fixture)

    /// Holds the storage side of a cache read until the test releases it. The
    /// `autoRelease` fallback in each test keeps a broken build failing an
    /// assertion instead of hanging the run.
    private actor Gate {
        private var isOpen = false
        private var entries = 0
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entries += 1
            let waiters = entryWaiters
            entryWaiters = []
            waiters.forEach { $0.resume() }
            if isOpen { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitForEntry() async {
            if entries > 0 { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            isOpen = true
            let waiters = openWaiters
            openWaiters = []
            waiters.forEach { $0.resume() }
        }

        func entryCount() -> Int { entries }
    }

    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("coherent-read-\(UUID().uuidString).sqlite")
    }

    /// Hops onto the main actor in a loop from a DETACHED task and records the
    /// longest gap between two consecutive hops. A blocked main thread shows up
    /// as one gap at least as long as the block, which is exactly the claim
    /// "a storage delay must not stall the UI actor".
    private static func sampleMainActor(
        for seconds: TimeInterval,
        into sampler: MainActorStallSampler
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            await MainActor.run { sampler.recordHop(at: Date()) }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func autoRelease(_ gate: Gate, after seconds: UInt64) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            await gate.open()
        }
    }

    // MARK: - AC2: one refresh is exactly two full-workspace reads

    func testOneRefreshPinsItsFullWorkspaceReadBound() async throws {
        let databaseURL = makeDatabaseURL()
        try seedCache(at: databaseURL)
        let server = CoherentProbePostgREST()
        let model = try await makeSignedInModel(
            server: server,
            databaseURL: databaseURL,
            beforeSnapshotRead: {}
        )

        let before = model.cacheSnapshotReadCount
        await model.refreshAll()
        let after = model.cacheSnapshotReadCount

        XCTAssertEqual(
            after - before,
            2,
            "one refresh is the hydration read + the publication read; the "
                + "restore's identity set is derived from those reads"
        )
    }

    // MARK: - AC1: the full-workspace read never runs on the main actor

    func testTheFullWorkspaceReadNeverRunsOnTheMainActor() async throws {
        let databaseURL = makeDatabaseURL()
        try seedCache(at: databaseURL)
        let server = CoherentProbePostgREST()
        let model = try await makeSignedInModel(
            server: server,
            databaseURL: databaseURL,
            beforeSnapshotRead: {}
        )

        await model.refreshAll()

        XCTAssertEqual(
            model.lastCacheSnapshotReadOnMainThread,
            false,
            "the blocking read + bulk decode/sort must run on the storage side"
        )
    }

    // MARK: - AC1: a storage delay does not stall the UI actor

    func testAStorageDelayDoesNotStallTheUIActor() async throws {
        let gate = Gate()
        let release = autoRelease(gate, after: 8)
        defer { release.cancel() }
        let databaseURL = makeDatabaseURL()
        try seedCache(at: databaseURL)
        let server = CoherentProbePostgREST()
        let model = try await makeSignedInModel(
            server: server,
            databaseURL: databaseURL,
            beforeSnapshotRead: { await gate.wait() }
        )

        let refresh = Task { await model.refreshAll() }
        await gate.waitForEntry()
        let entriesWhileHeld = await gate.entryCount()
        XCTAssertGreaterThanOrEqual(entriesWhileHeld, 1, "storage must be busy")

        // Storage is now held open. Sample the main actor for 2 s: the UI actor
        // must keep running.
        let sampler = MainActorStallSampler()
        await Self.sampleMainActor(for: 2.0, into: sampler)
        let maxGap = sampler.maxGap
        let hops = sampler.hopCount
        XCTAssertGreaterThan(hops, 20, "the main actor must keep running (hops: \(hops))")
        XCTAssertLessThan(
            maxGap,
            0.5,
            "a held storage read must not block the main actor (longest gap \(maxGap)s)"
        )

        await gate.open()
        await refresh.value
        XCTAssertEqual(model.lastCacheSnapshotReadOnMainThread, false)
    }

    // MARK: - Harness

    /// Seeds a small account-scoped cache the way a previous run would leave it
    /// (no recordings, so the refresh has no tag-curve warm work that could
    /// issue a concurrent read).
    private func seedCache(at databaseURL: URL) throws {
        let store = try LocalCacheStore(databaseURL: databaseURL)
        let workspace = CachedWorkspace(store: store)
        for index in 0..<3 {
            let session = SendmeterCore.Session(
                id: UUID(),
                date: "2026-09-2\(index)",
                type: "fingerboard",
                typeLabel: "Fingerboard",
                durationMinutes: 30 + index,
                rpe: 7,
                note: "seeded \(index)",
                phase: .capacity
            )
            try workspace.upsertLocal(
                session,
                accountUserID: userID,
                entityType: .sessions,
                entityID: session.id.uuidString
            )
        }
        try workspace.setCursor(
            "2026-09-01T00:00:00.000000Z",
            accountUserID: userID,
            entityType: .sessions
        )
    }

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

    private func makeSignedInModel(
        server: CoherentProbePostgREST,
        databaseURL: URL,
        beforeSnapshotRead: @escaping @Sendable () async -> Void
    ) async throws -> AppModel {
        let suite = "CoherentCacheReadAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = CoherentInMemoryAuthStorage()
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
        let provider: (@Sendable () async throws -> Auth.Session) = { session }
        let repository = SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
        let seams = CacheStorageSeams(
            // The store the test seeded, not the app container's file.
            openStore: { _ in try LocalCacheStore(databaseURL: databaseURL) },
            beforeSnapshotRead: beforeSnapshotRead
        )
        let model = AppModel(
            auth: auth,
            repository: repository,
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession()),
            cacheStorageSeams: seams
        )
        var waited = 0
        while model.currentUserID == nil, waited < 400 {
            waited += 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        // Let the bootstrap pass settle so a test's own refreshAll is the only
        // pass measuring reads.
        waited = 0
        while model.isLoadingData, waited < 400 {
            waited += 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.cacheReadiness, CacheReadiness.ready, "the flight must have opened the seeded store")
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

// MARK: - Doubles (duplicated from the other app-target suites, which keep
// their own copies file-private)

private final class CoherentInMemoryAuthStorage: AuthLocalStorage {
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

/// Answers every request with a well-formed, authoritative empty delta, so the
/// suite is hermetic and no live service is reached.
private final class CoherentProbePostgREST: @unchecked Sendable {
    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoherentProbeProtocol.self]
        CoherentProbeProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest) -> (status: Int, body: Data)? {
        // The purge-generation endpoint answers a scalar; every other delta
        // endpoint decodes an array.
        if request.url?.path.contains("purge") == true
            || request.url?.query?.contains("sync_generation") == true {
            return (200, Data("0".utf8))
        }
        return (200, Data("[]".utf8))
    }
}

private final class CoherentProbeProtocol: URLProtocol {
    static var server: CoherentProbePostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Self.server?.reply(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// The sampler's hop recorder is lock-guarded rather than actor-isolated so it
// can be called synchronously from inside `MainActor.run` — an extra hop would
// itself create the gap the sampler is trying to measure.
private final class MainActorStallSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var gaps: [TimeInterval] = []
    private var last: Date?
    private var hops = 0

    func recordHop(at date: Date) {
        lock.lock()
        if let last { gaps.append(date.timeIntervalSince(last)) }
        last = date
        hops += 1
        lock.unlock()
    }

    var maxGap: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return gaps.max() ?? 0
    }

    var hopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hops
    }
}

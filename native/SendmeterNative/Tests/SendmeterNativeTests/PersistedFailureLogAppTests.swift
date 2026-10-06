import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #992: launch-path and sync/replay failures must be visible in a log read
/// with persisted levels only (no `--info`/`--debug`), carrying the failing
/// operation, the error domain + code, and whether the failure was surfaced
/// to the user. The issue's own contract says source-token checks do not
/// prove behaviour, so these tests drive a REAL `AppModel` against a stubbed
/// PostgREST transport and observe the lines at the seam every emission goes
/// through (`AppModel.persistedFailureSink` — production defaults to the
/// `os.Logger` sink):
///
/// * a failed launch-path refresh emits a `launch-failure` line whose fields
///   name the step, the bridged error domain/code, the taxonomy class and
///   `surfaced: true` (the banner really carries the failure),
/// * a partial refresh (one group failed while the others published) carries
///   `surfaced: false`,
/// * a failed durable-queue upload emits a `sync-replay-failure` line with
///   `surfaced: false` (an automatic drain is deliberately silent),
/// * a successful cold refresh emits no failure line at all.
///
/// The simulator persistence half (the actual unified-log read) is recorded
/// under `docs/evidence/issue-992/` — this suite proves the emitted fields,
/// not the os_log store.
final class PersistedFailureLogAppTests: XCTestCase {
    /// A fresh account per test: the cache and queue are account-scoped files
    /// in the app container, so a shared user id would leak rows between tests.
    private let userID = UUID()

    // MARK: - launch failure: fields + the user-surfaced half

    @MainActor
    func testFailedLaunchRefreshEmitsALineNamingTheStepClassAndSurfaced() async throws {
        let server = FakeFailureLogPostgREST()
        server.goOffline()
        let model = try await makeSignedInModel(server: server)
        let capture = FailureLineCapture()
        model.persistedFailureSink = PersistedFailureSink(capture.sink)

        await model.refreshAll(showSpinner: false)

        // With the whole transport down every slice fails; the recorded
        // representative is the first failed slice in the plan's stable order
        // (`sessions`).
        let line = try await waitForLine(
            capture,
            where: { $0.operation == "refresh-slice:sessions" }
        )
        XCTAssertEqual(line.channel, .launchFailure)
        XCTAssertEqual(
            line.level,
            .notice,
            "the line must persist by default (log show without --debug)"
        )
        XCTAssertEqual(line.domain, NSURLErrorDomain)
        XCTAssertEqual(line.code, URLError.Code.notConnectedToInternet.rawValue)
        XCTAssertEqual(line.classification, "offline")
        XCTAssertTrue(
            line.surfaced,
            "with nothing loaded this failure is the banner case"
        )
        XCTAssertTrue(
            line.message.hasPrefix("launch failure step=refresh-slice:sessions ")
        )
        XCTAssertTrue(line.message.contains("domain=NSURLErrorDomain"))
        XCTAssertTrue(line.message.contains("surfaced=true"))

        // The user-surface witness: the banner really carries this failure —
        // the log line is not claiming a surface nothing produced.
        XCTAssertEqual(model.errorMessage, UserFacingError.message(for: .offline))
        XCTAssertEqual(model.dashboardLoadFailureClass, .offline)
    }

    // MARK: - launch failure: the suppressed case

    @MainActor
    func testPartialRefreshFailureCarriesSurfacedFalseBehindLastGoodData() async throws {
        let server = FakeFailureLogPostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertTrue(
            model.hasLoadedSessions && model.forceModel.hasLoadedRecordings,
            "fixture: the first load must publish authoritative last-good data"
        )
        let capture = FailureLineCapture()
        model.persistedFailureSink = PersistedFailureSink(capture.sink)

        // #842/#923: only the health-metrics slice fails; every other group
        // publishes, so the pass is partial and the global banner must stay
        // away — the scoped failure row is the surface instead.
        server.failRequests(containing: "rest/v1/health_metrics")
        await model.refreshAll(showSpinner: false)

        let line = try await waitForLine(
            capture,
            where: { $0.operation == "refresh-slice:healthMetrics" }
        )
        XCTAssertEqual(line.channel, .launchFailure)
        XCTAssertEqual(line.level, .notice)
        XCTAssertEqual(line.domain, NSURLErrorDomain)
        XCTAssertEqual(line.code, URLError.Code.notConnectedToInternet.rawValue)
        XCTAssertEqual(line.classification, "offline")
        XCTAssertFalse(
            line.surfaced,
            "a partial pass that published the other groups is suppressed behind last-good data"
        )
        XCTAssertTrue(line.message.contains("surfaced=false"))

        // Witness: the scoped failure row IS what the partial pass left
        // behind (that is the surface the suppressed line points at).
        XCTAssertEqual(
            model.lastPartialRefreshFailure?.groups,
            [.healthMetrics]
        )
    }

    // MARK: - sync/replay: a failed durable-queue upload

    @MainActor
    func testFailedQueueUploadEmitsASyncReplayLineThatIsNotSurfaced() async throws {
        let server = FakeFailureLogPostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        let capture = FailureLineCapture()
        model.persistedFailureSink = PersistedFailureSink(capture.sink)

        server.goOffline()
        let preset = Self.preset(name: "Persisted Failure Probe")
        let accepted = await model.savePreset(preset, isNew: true)
        XCTAssertTrue(accepted, "an offline save is accepted: its intent is durable")
        try await waitForQueueCount(model, expected: 1)

        let line = try await waitForLine(
            capture,
            where: { $0.operation == "queue-upload:preset" }
        )
        XCTAssertEqual(line.channel, .syncReplayFailure)
        XCTAssertEqual(
            line.level,
            .notice,
            "a sync/replay failure must persist by default too"
        )
        XCTAssertEqual(line.domain, NSURLErrorDomain)
        XCTAssertEqual(line.code, URLError.Code.notConnectedToInternet.rawValue)
        XCTAssertEqual(line.classification, "offline")
        XCTAssertFalse(
            line.surfaced,
            "an automatic drain is deliberately silent; the pending count is its surface"
        )
        XCTAssertTrue(
            line.message.hasPrefix("sync/replay failure op=queue-upload:preset ")
        )
        XCTAssertTrue(line.message.contains("surfaced=false"))
    }

    // MARK: - the happy path stays quiet

    @MainActor
    func testSuccessfulColdRefreshEmitsNoFailureLine() async throws {
        let server = FakeFailureLogPostgREST()
        let model = try await makeSignedInModel(server: server)
        let capture = FailureLineCapture()
        model.persistedFailureSink = PersistedFailureSink(capture.sink)

        await model.refreshAll(showSpinner: false)
        // Let the bootstrap refresh that shares this funnel settle before
        // asserting silence.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(
            capture.lines.isEmpty,
            "a successful cold launch must emit no failure lines: \(capture.lines.map(\.message))"
        )
    }

    // MARK: - F2: the production default itself must be witnessed

    /// The adversarial review's F2 mutation substituted the model's default
    /// sink with a no-op and no suite blinked. This is the witness: a freshly
    /// built model must still hold the production binding — substituting a
    /// capture (or a no-op) flips `isProduction` false, so that mutation goes
    /// RED here.
    @MainActor
    func testFreshModelStillCarriesTheProductionFailureSink() async throws {
        let server = FakeFailureLogPostgREST()
        let model = try await makeSignedInModel(server: server)

        XCTAssertTrue(
            model.persistedFailureSink.isProduction,
            """
            a freshly built AppModel must keep the production failure sink; \
            if this fails, the default was tampered with or replaced by a \
            no-op and every persisted failure line would be silent on-device \
            while the rest of the suite stays green (F2)
            """
        )
    }

    /// #992 round 2: the production path end-to-end. No sink substitution — a
    /// real failure driven through the fresh model's default (production)
    /// binding must land in the emission audit, so a production emitter
    /// silenced by mutation (M2: dead closure, `isProduction` still true)
    /// cannot leave this suite green.
    @MainActor
    func testRealFailureThroughTheProductionSinkReachesTheAuditRing() async throws {
        let server = FakeFailureLogPostgREST()
        server.goOffline()
        let model = try await makeSignedInModel(server: server)
        XCTAssertTrue(
            model.persistedFailureSink.isProduction,
            "this witness must run against the production binding (no substitution)"
        )

        await model.refreshAll(showSpinner: false)

        let audited = await waitForAuditedLine(where: { $0.operation == "refresh-slice:sessions" })
        let line = try XCTUnwrap(
            audited,
            "the real failure never reached the emission audit — the production path is silent (M2)"
        )
        XCTAssertEqual(line.channel, .launchFailure)
        XCTAssertEqual(line.level, .notice)
        XCTAssertEqual(line.domain, NSURLErrorDomain)
        XCTAssertEqual(line.code, URLError.Code.notConnectedToInternet.rawValue)
        XCTAssertEqual(line.classification, "offline")
        XCTAssertTrue(line.surfaced)
    }

    // MARK: - #1020: every failed slice is named, with its schema detail

    /// #1020 AC3: the owner's capture named only `refresh-slice:sessions`
    /// although every slice failed, and nothing said WHY. Now each failed
    /// slice gets its own line carrying the decode kind + codingPath keys —
    /// the schema identifiers, never the value — and only the representative
    /// line carries the banner.
    @MainActor
    func testEveryFailedSliceGetsItsOwnLineNamingTheCodingPath() async throws {
        let server = FakeFailureLogPostgREST()
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertTrue(
            model.hasLoadedSessions && model.forceModel.hasLoadedRecordings,
            "fixture: the first load must publish authoritative last-good data"
        )
        let capture = FailureLineCapture()
        model.persistedFailureSink = PersistedFailureSink(capture.sink)
        // Two slices answer with rows this build cannot decode: a tag whose
        // `updated_at` is not a timestamp, and a preset with no `id`.
        let unreadableStamp = "owner-value-1020"
        server.answerRequests(
            containing: "rest/v1/tindeq_tags",
            with: #"[{"name":"crimp","hidden":false,"updated_at":"\#(unreadableStamp)"}]"#
        )
        server.answerRequests(containing: "rest/v1/tindeq_presets", with: #"[{"name":"crimp"}]"#)

        await model.refreshAll(showSpinner: false)

        let tags = try await waitForLine(capture, where: { $0.operation == "refresh-slice:tagMetadata" })
        let presets = try await waitForLine(capture, where: { $0.operation == "refresh-slice:presets" })
        XCTAssertEqual(tags.classification, "dataUnreadable")
        XCTAssertEqual(tags.detail, "decode=dataCorrupted path=*.updated_at")
        XCTAssertEqual(presets.detail, "decode=keyNotFound path=*.id")
        XCTAssertTrue(
            tags.message.hasPrefix("launch failure step=refresh-slice:tagMetadata "),
            tags.message
        )
        XCTAssertTrue(tags.message.hasSuffix(" decode=dataCorrupted path=*.updated_at"), tags.message)
        XCTAssertEqual(
            capture.lines.map(\.operation).sorted(),
            ["refresh-slice:presets", "refresh-slice:tagMetadata"],
            "one line per failed slice, no more: \(capture.lines.map(\.message))"
        )
        XCTAssertEqual(
            capture.lines.filter(\.surfaced).count,
            0,
            "a partial pass behind last-good data surfaces nothing"
        )
        for line in capture.lines {
            XCTAssertFalse(line.message.contains(unreadableStamp), "a row value reached the log: \(line.message)")
            XCTAssertFalse(line.message.contains("crimp"), "user content reached the log: \(line.message)")
        }
        // AC2 witness: every other slice still published.
        XCTAssertEqual(
            model.lastPartialRefreshFailure?.groups,
            [.presets, .tagMetadata],
            "only the two unreadable slices' groups are held back"
        )
    }

    // MARK: - #1020 RED witness: the second launch at real microsecond stamps

    /// #1020: build 57 showed the unreadable-data banner on EVERY launch after
    /// the first sync, with no row of the owner's account failing to decode.
    /// The server answers with real PostgREST microsecond stamps and honours
    /// the cursor filter on those true microseconds, as Postgres does. Before
    /// the fix the client truncated each stamp to milliseconds, so the second
    /// refresh's `updated_at.gt.<cursor>` re-served the row the cursor stands
    /// on and every slice failed closed with `cursorDidNotAdvance`.
    @MainActor
    func testSecondLaunchAtMicrosecondServerStampsRefreshesWithoutAFailure() async throws {
        let server = FakeFailureLogPostgREST()
        server.serveMicrosecondSessions([
            ("10200000-0000-0000-0000-000000000001", "2026-10-05T23:22:09.731904+00:00"),
            ("10200000-0000-0000-0000-000000000002", "2026-10-05T23:22:10.123456+00:00")
        ])
        let model = try await makeSignedInModel(server: server)
        let capture = FailureLineCapture()
        model.persistedFailureSink = PersistedFailureSink(capture.sink)

        await model.refreshAll(showSpinner: false)
        XCTAssertEqual(model.sessions.count, 2, "fixture: launch 1 reads the account")
        await model.refreshAll(showSpinner: false)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(
            server.sawCompositeSessionCursor,
            "fixture: the second pass must resume at the persisted cursor"
        )
        XCTAssertEqual(
            capture.lines.map(\.message),
            [],
            "the resumed refresh at microsecond stamps must not fail"
        )
        XCTAssertNil(model.errorMessage, "no unreadable-data banner on the second launch")
        XCTAssertNil(model.lastPartialRefreshFailure)
        XCTAssertEqual(model.sessions.count, 2)
    }

    // MARK: - Line capture (the seam the app routes every emission through)

    @MainActor
    private final class FailureLineCapture {
        private(set) var lines: [PersistedFailureLine] = []

        func sink(_ line: PersistedFailureLine) {
            lines.append(line)
        }
    }

    @MainActor
    private func waitForLine(
        _ capture: FailureLineCapture,
        where predicate: (PersistedFailureLine) -> Bool
    ) async throws -> PersistedFailureLine {
        for _ in 0..<600 {
            if let match = capture.lines.first(where: predicate) {
                return match
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try XCTUnwrap(
            capture.lines.first(where: predicate),
            "no persisted failure line matched within the deadline; captured: \(capture.lines.map(\.message))"
        )
    }

    /// Waits for a line that reached the PRODUCTION path's emission audit
    /// (no substituted sink involved) — the #992 round-2 witness seam.
    @MainActor
    private func waitForAuditedLine(
        where predicate: (PersistedFailureLine) -> Bool
    ) async -> PersistedFailureLine? {
        for _ in 0..<600 {
            if let match = PersistedFailureLog.recentEmissions(limit: 32).last(where: predicate) {
                return match
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    @MainActor
    private func waitForQueueCount(_ model: AppModel, expected: Int) async throws {
        for _ in 0..<400 {
            if model.queuedWriteCount == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("queue never reached \(expected); last observed \(model.queuedWriteCount)")
    }

    // MARK: - Model harness (mirrors the other app-target suites' seams)

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
        server: FakeFailureLogPostgREST
    ) -> SendmeterRepository {
        let suite = "PersistedFailureLogAppTests.repo.\(UUID().uuidString)"
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
        server: FakeFailureLogPostgREST,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "PersistedFailureLogAppTests.signed-in.\(UUID().uuidString)"
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

    // MARK: - Fixtures

    private static func preset(name: String, id: UUID = UUID()) -> TindeqPreset {
        TindeqPreset(
            id: id,
            name: name,
            holdSeconds: 7,
            holdSecondsBySet: [7],
            repetitions: 6,
            sets: 3,
            restBetweenRepetitionsSeconds: 3,
            restBetweenSetsSeconds: 180,
            targetKilograms: 60,
            targetPercentage: 80,
            percentageBasis: .personalRecord,
            percentageStep: 2,
            setupNote: "fixture"
        )
    }
}

// MARK: - Stubbed transport

/// The stubbed backend for #992: an authoritative empty account while online
/// (every request answers `[]`, the `hasLoadedSessions` shape the other suites
/// use for a fresh account), and a full transport blackout while offline. The
/// blackout fails the request with `URLError(.notConnectedToInternet)` — the
/// persisted line must carry exactly the bridged domain/code a device would
/// produce, not a source-token approximation.
private final class FakeFailureLogPostgREST: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true
    private var failingPaths: Set<String> = []
    private var cannedBodies: [String: String] = [:]
    private var microsecondSessions: [(id: String, stamp: String)] = []
    private(set) var sawCompositeSessionCursor = false

    func goOffline() {
        lock.lock()
        online = false
        lock.unlock()
    }

    /// Fails every request whose path contains `fragment` at the transport
    /// layer (the `URLError(.notConnectedToInternet)` shape) while every
    /// other request keeps answering — the partial-pass setup behind #842's
    /// suppressed banner: one slice fails, the rest publish.
    func failRequests(containing fragment: String) {
        lock.lock()
        failingPaths.insert(fragment)
        lock.unlock()
    }

    /// #1020: answers every request whose path contains `fragment` with
    /// `body` — a server row in a shape this build cannot decode.
    func answerRequests(containing fragment: String, with body: String) {
        lock.lock()
        cannedBodies[fragment] = body
        lock.unlock()
    }

    /// #1020: serves `sessions` rows with real PostgREST microsecond
    /// `updated_at` text and applies the reader's cursor filter on the TRUE
    /// microseconds (a fixed-width stamp compares exactly as the instant), as
    /// Postgres does — never on a client-decoded `Date`.
    func serveMicrosecondSessions(_ rows: [(id: String, stamp: String)]) {
        lock.lock()
        microsecondSessions = rows
        lock.unlock()
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeFailureLogProtocol.self]
        FakeFailureLogProtocol.server = self
        return URLSession(configuration: configuration)
    }

    /// Nil means "fail at the transport layer" (the offline blackout).
    func reply(for request: URLRequest) -> (status: Int, body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard online else { return nil }
        let path = request.url?.path ?? ""
        guard !failingPaths.contains(where: { path.contains($0) }) else { return nil }
        if let body = cannedBodies.first(where: { path.contains($0.key) })?.value {
            return (200, Data(body.utf8))
        }
        if path.hasSuffix("rest/v1/sessions"), !microsecondSessions.isEmpty {
            return (200, Data(sessionsPage(for: request).utf8))
        }
        return (200, Data("[]".utf8))
    }

    private func sessionsPage(for request: URLRequest) -> String {
        let items = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        // `2026-10-05T23:22:10.123456+00:00` -> `2026-10-05T23:22:10.123456Z`,
        // the fixed-width form the cursor persists: text order == time order.
        func exact(_ stamp: String) -> String { String(stamp.dropLast("+00:00".count)) + "Z" }
        var visible = microsecondSessions
        if let composite = items.first(where: { $0.name == "or" })?.value,
           let gt = composite.range(of: "(updated_at.gt."),
           let comma = composite.range(of: ",and(updated_at.eq."),
           let idGT = composite.range(of: ",id.gt.", options: .backwards) {
            sawCompositeSessionCursor = true
            let cursorStamp = String(composite[gt.upperBound..<comma.lowerBound])
            let cursorID = String(composite[idGT.upperBound...].dropLast(2)).lowercased()
            visible = visible.filter { row in
                exact(row.stamp) > cursorStamp || (exact(row.stamp) == cursorStamp && row.id > cursorID)
            }
        } else if let legacy = items.first(where: { $0.name == "updated_at" })?.value,
                  legacy.hasPrefix("gte.") {
            let cursorStamp = String(legacy.dropFirst("gte.".count))
            visible = visible.filter { exact($0.stamp) >= cursorStamp }
        }
        visible.sort { (exact($0.stamp), $0.id) < (exact($1.stamp), $1.id) }
        return "[" + visible.map { row in
            """
            {"id":"\(row.id)","date":"2026-10-05","type":"hangboard","type_label":"Hangboard",\
            "duration_min":30,"rpe":7,"rpe_confirmed":true,"load":210,"note":"","phase":"strength",\
            "group_id":null,"workout_source":null,"updated_at":"\(row.stamp)","deleted_at":null}
            """
        }.joined(separator: ",") + "]"
    }
}

private final class FakeFailureLogProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeFailureLogPostgREST?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server,
              let reply = server.reply(for: request),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

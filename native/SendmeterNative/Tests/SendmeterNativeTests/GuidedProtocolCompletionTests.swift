import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #940 + #941: the protocol-completion contract at the layers that can be
/// driven without a gauge.
///
/// - #941: finishing a guided protocol (the DONE panel's Done, the top-bar
///   End, the resume card's End) ends the PROTOCOL only — the gauge session
///   stays live on the same group, and the explicit end (#627) is what logs
///   the single Tindeq History entry.
/// - #940: the completion cue fires exactly once per run and never again when
///   the minimized presentation is reopened.
///
/// These live in the app-target bundle because `GuidedForceProtocolSession`
/// and `AppModel` are app-target-only types; the harness mirrors
/// `GuidedForceSideBehaviorTests` (stubbed Supabase transport, in-memory
/// storage), with every wait bounded by a WALL-CLOCK deadline (#978).
///
/// #989: two residuals of the #978 hardening. (1) The seeded account is now
/// UNIQUE PER MODEL. The fixture used to hardcode one UUID while the app
/// writes a real, account-scoped GRDB cache inside the shared simulator app
/// container — so a reused container hydrated the previous run's `tindeq`
/// session row and the run counted rows it never created (measured 1→2→3→4
/// across runs, resetting only when the container was cleared). (2) Every
/// entry-count read is a deadline-bound wait. The count is a published
/// snapshot and a concurrent hydration can replace the published list before
/// its rows are re-added, so the AC1/AC2 reads wait for the count instead of
/// asserting a single instant. Neither change touches what is asserted.
final class GuidedProtocolCompletionTests: XCTestCase {
    /// #978: every wait in this file is bounded by a wall-clock deadline, never
    /// by a fixed iteration budget. The old shapes expired on a contended
    /// runner — `makeSignedInModel` gave up after 200 `Task.yield()`s, and the
    /// published-collection assertions had no wait at all — and the required
    /// hosted job failed on merged staging content for every PR (`:88`/`:98`,
    /// `XCTAssertEqual failed: ("1") is not equal to ("2")`). The deadline
    /// decides only how long a wait may take; what is asserted never changes.
    /// On expiry the state actually observed and the elapsed time are
    /// reported, so a real #941 regression stays distinguishable from slowness.
    private static let waitDeadline: Duration = .seconds(60)

    /// Polls `isSatisfied` until it holds or `timeout` elapses, then fails the
    /// test with the elapsed time and the state `observed`.
    @MainActor
    private func waitUntil(
        _ expectation: String,
        timeout: Duration = GuidedProtocolCompletionTests.waitDeadline,
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

    // MARK: - #941 AC4: protocol completion must not end the gauge session

    @MainActor
    func test941ProtocolCompletionDoesNotEndTheGaugeSession() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.quickPreset()
        let session = Self.makeSession(model: model, preset: preset)

        // The protocol's first rep mints the live group through the REAL
        // lazy-mint save boundary.
        let groupID = try await saveRep(model: model, preset: preset, session: session, setNumber: 1)
        let entriesBefore = tindeqEntryCount(model)

        // Drive the real run to its complete stage, then finish it the way
        // the DONE panel's Done action does.
        try await complete(session)
        await session.stopOrFinish()

        XCTAssertTrue(session.isEnded, "the finish must end the protocol")
        XCTAssertTrue(
            model.gaugeSessionTracker.isActive,
            "#941 AC4: protocol completion must leave the gauge session live"
        )
        XCTAssertEqual(
            model.gaugeSessionTracker.active?.groupID,
            groupID,
            "the live session is the SAME group the protocol recorded into"
        )
        XCTAssertEqual(
            tindeqEntryCount(model),
            entriesBefore,
            "#941 AC4: the protocol finish must not log a Tindeq History entry"
        )
    }

    // MARK: - #941 AC1/AC2: back-to-back protocols, one entry per session

    @MainActor
    func test941BackToBackProtocolsLogOneEntryWhenTheSessionEndsExplicitly() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.quickPreset()

        // Protocol 1: save a rep, run to complete, finish.
        let first = Self.makeSession(model: model, preset: preset)
        let groupID = try await saveRep(model: model, preset: preset, session: first, setNumber: 1)
        try await complete(first)
        await first.stopOrFinish()
        XCTAssertTrue(first.isEnded)

        // Protocol 2 joins the SAME live group — no explicit end in between.
        let second = Self.makeSession(model: model, preset: preset)
        let secondGroup = try await saveRep(model: model, preset: preset, session: second, setNumber: 1)
        XCTAssertEqual(secondGroup, groupID, "a second protocol joins the same gauge group")
        try await complete(second)
        await second.stopOrFinish()
        XCTAssertTrue(second.isEnded)

        XCTAssertTrue(model.gaugeSessionTracker.isActive, "the session survives both protocols")
        // #989 audit: this read needs no entry wait. The account is fresh per
        // model and no protocol finish has logged anything yet, so the count
        // is 0 whether or not a hydration of the (empty) account cache has
        // landed — there is no published row for the race to hide. The waits
        // belong on the reads that assert a row THIS run created, below.
        XCTAssertEqual(
            tindeqEntryCount(model),
            0,
            "#941 AC1: no protocol finish may log a History entry on its own"
        )
        // #978: the group's rows are published by the model's own publication
        // path and re-published after a hydration of the on-disk cache, so wait
        // (deadline-bound) for both before asserting the grouping.
        try await waitForGroupRecordings(model, groupID: groupID, count: 2)
        let groupRecordings = model.recordings.filter { $0.groupID == groupID }
        XCTAssertEqual(groupRecordings.count, 2, "both protocols' recordings are in the one group")

        // The explicit end (the Force tab's Finish pill / #627 path).
        await model.endGaugeSession()

        XCTAssertFalse(model.gaugeSessionTracker.isActive, "the explicit end closes the session")
        // #989: the end's own save path publishes the entry and a concurrent
        // hydration of the account cache can replace the published list
        // before the optimistic row is re-added, so wait (deadline-bound) for
        // the entry to reach the count this assertion means — one. A count
        // that never arrives still fails, and expiry reports what was
        // observed.
        try await waitForTindeqEntries(
            model,
            count: 1,
            "the explicit end's Tindeq History entry"
        )
        let entries = model.sessions.filter { $0.type == "tindeq" }
        XCTAssertEqual(entries.count, 1, "#941 AC1: one gauge session ⇒ exactly one Tindeq entry")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.groupID, groupID)
        // #978: the same published collection, re-read after the end; the rows
        // must still be there, so wait for them rather than racing a
        // concurrent hydration.
        try await waitForGroupRecordings(model, groupID: groupID, count: 2)
        XCTAssertEqual(
            model.recordings.filter { $0.groupID == groupID }.count,
            2,
            "the single entry still owns both protocols' recordings"
        )
        XCTAssertEqual(
            entry.note,
            GaugeSessionNote.build(recordings: groupRecordings),
            "the note is built from every recording in the group"
        )

        // #941 AC2: a later protocol after the explicit end must not re-log
        // the closed group — completing it leaves its new group unlogged.
        let third = Self.makeSession(model: model, preset: preset)
        let thirdGroup = try await saveRep(model: model, preset: preset, session: third, setNumber: 1)
        XCTAssertNotEqual(thirdGroup, groupID, "a new session after the end mints a new group")
        try await complete(third)
        await third.stopOrFinish()
        // #989: the same published collection, re-read after the third
        // protocol's save path — wait for the closed session's entry instead
        // of asserting a single instant a hydration can replace. The
        // assertion's meaning is unchanged: the count must settle at exactly
        // one (the closed session's), so a duplicate still fails.
        try await waitForTindeqEntries(
            model,
            count: 1,
            "the closed session's one Tindeq History entry"
        )
        XCTAssertEqual(
            tindeqEntryCount(model),
            1,
            "#941 AC2: a later completion must not duplicate the closed session's entry"
        )
    }

    // MARK: - #940 AC3: the completion cue fires exactly once per run

    @MainActor
    func test940CompletionHapticFiresExactlyOncePerRunAndNotOnReopen() async throws {
        let model = try await makeSignedInModel()
        let session = Self.makeSession(model: model, preset: Self.quickPreset())

        // Advance to the stage BEFORE the terminal complete stage, so the next
        // advance is exactly the completion transition.
        var steps = 0
        while !session.run.isComplete, steps < session.run.stages.count - 2 {
            steps += 1
            await session.skip(at: Date())
        }
        XCTAssertFalse(session.run.isComplete, "the run must not be complete yet")

        let before = Haptics.shared.debugEmissionCount
        await session.skip(at: Date())
        let afterCompletion = Haptics.shared.debugEmissionCount

        XCTAssertTrue(session.run.isComplete)
        XCTAssertEqual(
            afterCompletion - before,
            1,
            "#940: exactly one cue fires on the transition into the complete stage"
        )

        // Reopening the minimized cover re-runs `begin()` on the same session.
        session.begin()
        XCTAssertEqual(
            Haptics.shared.debugEmissionCount,
            afterCompletion,
            "#940: reopening the complete run must not repeat the completion cue"
        )
    }

    // MARK: - Harness

    /// Drive the REAL run to its terminal complete stage. Each step is the
    /// session's own skip/advance path, so the completion transition (and its
    /// cue) is the production one.
    @MainActor
    private func complete(_ session: GuidedForceProtocolSession) async throws {
        let limit = session.run.stages.count + 2
        var steps = 0
        while !session.run.isComplete, steps < limit {
            steps += 1
            await session.skip(at: Date())
        }
        XCTAssertTrue(session.run.isComplete, "the run never reached its complete stage")
    }

    /// One protocol rep's REAL save boundary: the same `saveForceSummary`
    /// call `GuidedForceProtocolSession.preserve` makes, so the gauge session
    /// is minted (or joined) exactly the way a live protocol does it.
    @MainActor
    private func saveRep(
        model: AppModel,
        preset: TindeqPreset,
        session: GuidedForceProtocolSession,
        setNumber: Int
    ) async throws -> UUID {
        let saved = await model.saveForceSummary(
            Self.summary(),
            tag: "FDP",
            side: .left,
            zone: nil,
            preset: preset,
            protocolRunID: session.run.runID,
            setNumber: setNumber,
            repetitionNumber: 1
        )
        XCTAssertTrue(saved, "the rep save must persist")
        return try XCTUnwrap(
            model.gaugeSessionTracker.active?.groupID,
            "the first rep mints the live gauge group"
        )
    }

    @MainActor
    private func tindeqEntryCount(_ model: AppModel) -> Int {
        model.sessions.filter { $0.type == "tindeq" }.count
    }

    /// #989: deadline-bound wait for the published Tindeq History entries to
    /// hold `count` rows — the same shape #978 applied to the group rows.
    /// `tindeqEntryCount` reads a published snapshot and a concurrent
    /// hydration can replace it before the optimistic rows are re-added, so
    /// the AC1/AC2 reads wait for the count instead of asserting an instant.
    /// The deadline decides only how long that may take; a count that never
    /// arrives still fails, with the state observed at expiry.
    @MainActor
    private func waitForTindeqEntries(
        _ model: AppModel,
        count: Int,
        _ expectation: String
    ) async throws {
        try await waitUntil(
            expectation,
            isSatisfied: { model.sessions.filter { $0.type == "tindeq" }.count == count },
            observed: { Self.tindeqEntryState(model) }
        )
    }

    /// The state a wait for the Tindeq History entries expired on: every
    /// published session with its type, group and pending/rejected state, the
    /// live gauge group, the queued-write count and the durable queue file.
    /// Together these separate "the entry was never logged" from "logged but
    /// not published", and a hydrated row that belongs to another run's
    /// container state from one this run created.
    @MainActor
    private static func tindeqEntryState(_ model: AppModel) -> String {
        let rows = model.sessions
            .map { entry in
                var row = "\(shortID(entry.id))[\(entry.type)]"
                if let group = entry.groupID { row += "@\(shortID(group))" }
                if entry.pending { row += "|pending" }
                if entry.rejected { row += "|rejected" }
                return row
            }
            .joined(separator: ", ")
        let entries = model.sessions.filter { $0.type == "tindeq" }
        let fields = [
            "tindeqEntries=\(entries.count)",
            "sessions=\(model.sessions.count)",
            "rows=[\(rows)]",
            "liveGroup=\(shortID(model.gaugeSessionTracker.active?.groupID))",
            "queuedWrites=\(model.queuedWriteCount)",
            durableQueueState()
        ]
        return fields.joined(separator: ", ")
    }

    /// #978: deadline-bound wait for the published recordings to hold `count`
    /// rows of `groupID`. The save publishes an optimistic row on the model's
    /// own publication path and a hydration of the on-disk cache replaces
    /// `recordings` before re-adding the rows the cache overlaid, so a durable
    /// row can be briefly absent from the published list. The deadline decides
    /// only how long that may take — a row that never arrives still fails.
    @MainActor
    private func waitForGroupRecordings(
        _ model: AppModel,
        groupID: UUID?,
        count: Int
    ) async throws {
        try await waitUntil(
            "the published recordings to hold \(count) row(s) for the live group",
            isSatisfied: { model.recordings.filter { $0.groupID == groupID }.count == count },
            observed: { Self.recordingGroupState(model, groupID: groupID) }
        )
    }

    /// The state a wait for the group's rows expired on: every published
    /// recording with its group, the group the tracker is live on, the session
    /// list, and the durable queue file behind all three. Together these
    /// separate a row that was never persisted from one that is persisted but
    /// not published, and a row published under the wrong group from a missing
    /// one.
    @MainActor
    private static func recordingGroupState(_ model: AppModel, groupID: UUID?) -> String {
        let rows = model.recordings
            .map { "\(shortID($0.id))@\(shortID($0.groupID))/\($0.tag)" }
            .joined(separator: ", ")
        let groupRows = model.recordings.filter { $0.groupID == groupID }.count
        let tindeqEntries = model.sessions.filter { $0.type == "tindeq" }.count
        let fields = [
            "liveGroup=\(shortID(model.gaugeSessionTracker.active?.groupID))",
            "expected=\(shortID(groupID))",
            "groupRows=\(groupRows)",
            "recordings=[\(rows)]",
            "sessions=\(model.sessions.count)",
            "tindeqEntries=\(tindeqEntries)",
            "queuedWrites=\(model.queuedWriteCount)",
            durableQueueState()
        ]
        return fields.joined(separator: ", ")
    }

    private static func shortID(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "nil"
    }

    /// The durable queue file as a relaunch would read it: the queue is the
    /// only local copy that survives the process, so an item missing here was
    /// never persisted while an item present here and absent from `recordings`
    /// is a publication gap, not a lost write.
    private static func durableQueueState() -> String {
        let url = supportDirectory().appendingPathComponent("pending-writes.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return "pending-writes.json absent/unreadable" }
        return "pending-writes.json \(data.count) bytes, \(items.count) item(s)"
    }

    /// The app container paths `AppModel` uses for the durable queue and cache.
    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
    }

    @MainActor
    private static func makeSession(
        model: AppModel,
        preset: TindeqPreset
    ) -> GuidedForceProtocolSession {
        GuidedForceProtocolSession(
            model: model,
            preset: preset,
            targetPlan: .empty,
            tag: "FDP",
            startingSide: .left,
            fallbackSide: .left,
            selection: .free,
            references: nil
        )
    }

    private static func quickPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Completion Test",
            holdSeconds: 10,
            repetitions: 1,
            sets: 1,
            restBetweenRepetitionsSeconds: 0,
            restBetweenSetsSeconds: 0,
            prepareSeconds: 5
        )
    }

    private static func summary(peakKilograms: Double = 30) -> ForceSummary {
        ForceSummary(
            durationMilliseconds: 10_000,
            peakKilograms: peakKilograms,
            averageKilograms: peakKilograms - 2,
            samples: (0..<20).map { index in
                TindeqSample(
                    milliseconds: Double(index) * 500,
                    kilograms: peakKilograms - 6 + Double(index) * 0.3
                )
            }
        )
    }

    // MARK: - In-memory auth seam (duplicated from GuidedForceSideBehaviorTests;
    // those helpers are file-private)

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

    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var reply = (
            statusCode: 200,
            body: Data("[]".utf8)
        )

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let client else { return }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: Self.reply.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Self.reply.body)
            client.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
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
    private func makeRepository(session: Auth.Session? = nil) -> SendmeterRepository {
        let suite = "GuidedProtocolCompletionTests.repo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = {
            guard let session else { throw AuthError.sessionMissing }
            return session
        }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: makeURLSession()
            )
        )
    }

    /// Builds a signed-in AppModel with an in-memory seeded session so the
    /// real gauge-session save/end guards (`currentUserID`, account scope)
    /// pass. The auth observation task delivers `.initialSession` from local
    /// storage; the wait for it is deadline-bound (#978) below.
    @MainActor
    private func makeSignedInModel() async throws -> AppModel {
        let suite = "GuidedProtocolCompletionTests.signed-in.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = InMemoryAuthStorage()
        let session = Self.makeSession()
        try storage.store(
            // The SDK's default storage key namespaces by project ref:
            // `sb-<host>-auth-token` (SupabaseClient.init).
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
            repository: makeRepository(session: session),
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: makeURLSession())
        )

        // The auth observation task delivers `.initialSession` from local
        // storage. #978: wait against a WALL-CLOCK deadline — the old shape
        // (`waited < 200` × `Task.yield()`) spent a fixed iteration budget and
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

    /// The state an expiry of the `currentUserID` wait observed: what the model
    /// has published about its account and its first load.
    @MainActor
    private static func authState(_ model: AppModel) -> String {
        let fields = [
            "currentUserID=\(model.currentUserID?.uuidString ?? "nil")",
            "accountScope=\(String(describing: model.accountScope))",
            "hasLoadedSessions=\(model.hasLoadedSessions)"
        ]
        return fields.joined(separator: ", ")
    }

    /// #989: the seeded account is UNIQUE PER MODEL. The fixture used to
    /// hardcode one account while `AppModel` writes a real, account-scoped
    /// GRDB cache inside the shared simulator app container, so a reused
    /// container hydrated the previous run's `tindeq` session row into
    /// `model.sessions` and every entry-count read counted rows this run never
    /// created (measured 1→2→3→4 across runs; green again only after the
    /// container was cleared). A fresh account per model cannot observe
    /// another run's rows. Callers that need a shared account across two
    /// models pass `userID:` explicitly.
    private static func makeSession(
        userID: UUID = UUID(),
        sessionID: String = "session-1"
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
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }
}

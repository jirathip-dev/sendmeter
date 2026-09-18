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
/// storage, no sleeps).
final class GuidedProtocolCompletionTests: XCTestCase {
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
        XCTAssertEqual(
            tindeqEntryCount(model),
            0,
            "#941 AC1: no protocol finish may log a History entry on its own"
        )
        let groupRecordings = model.recordings.filter { $0.groupID == groupID }
        XCTAssertEqual(groupRecordings.count, 2, "both protocols' recordings are in the one group")

        // The explicit end (the Force tab's Finish pill / #627 path).
        await model.endGaugeSession()

        XCTAssertFalse(model.gaugeSessionTracker.isActive, "the explicit end closes the session")
        let entries = model.sessions.filter { $0.type == "tindeq" }
        XCTAssertEqual(entries.count, 1, "#941 AC1: one gauge session ⇒ exactly one Tindeq entry")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.groupID, groupID)
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
    /// storage; wait deterministically (yield loop, no sleeps).
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

        var waited = 0
        while model.currentUserID == nil, waited < 200 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    private static func makeSession(
        userID: UUID = UUID(uuidString: "94000000-0000-0000-0000-000000000940")!,
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

import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// REAL behavior tests for #874: an explicit Left must survive the guided
/// launch→resolve→session boundary, and a bilateral-only exercise must carry
/// `.both` semantics (never an invalid Left/Right) through the same boundary.
///
/// These live in the app-target bundle (not the SwiftPM Core test target)
/// because `GuidedForceProtocolSession` and `AppModel.resolveForceTargetPlan`
/// are app-target-only types — the SwiftPM Core module cannot compile them.
/// Deterministic: no sleeps, no network (stubbed Supabase client + in-memory
/// storage), matching the existing AuthRecoveryWiringTests seams.
final class GuidedForceSideBehaviorTests: XCTestCase {
    // MARK: - AC1: explicit Left through the session boundary

    @MainActor
    func testAC1GuidedSessionKeepsExplicitLeftThroughLaunchBoundary() throws {
        let model = AppModel(
            auth: makeAuthService(),
            repository: makeRepository(),
            realtime: RealtimeService(client: makeSupabaseClient(storage: InMemoryAuthStorage()))
        )
        let preset = Self.alternatingPreset()
        let session = GuidedForceProtocolSession(
            model: model,
            preset: preset,
            targetPlan: .empty,
            tag: "Test",
            startingSide: .left,
            fallbackSide: .left,
            selection: .free,
            references: nil
        )
        let firstWork = try XCTUnwrap(session.run.stages.first(where: { $0.kind == .work }))
        XCTAssertEqual(firstWork.side, .left)
        XCTAssertEqual(session.fallbackSide, .left)
        // Save attribution rule (same as the session's preserve()): a specified
        // stage side wins; the fallback side only fills unspecified stages.
        let savedSide = firstWork.side == .unspecified ? session.fallbackSide : firstWork.side
        XCTAssertEqual(savedSide, .left)
        XCTAssertFalse(session.run.stages.contains { $0.side == .both })
    }

    // MARK: - AC1: real async target resolution keeps Left and never keys Both

    @MainActor
    func testAC1ResolveForceTargetPlanRealAsyncKeysLeftNotBoth() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.targetedAlternatingPreset()

        let plan = await model.resolveForceTargetPlan(
            preset: preset,
            tag: "Test Tag",
            startingSide: .left,
            fallbackSide: .left
        )

        let keys = Array(plan.targets.keys)
        XCTAssertTrue(
            keys.contains(ForceTargetKey(setNumber: 1, side: .left)),
            "alternating + startingSide .left must produce a .left-keyed band; got \(keys)"
        )
        XCTAssertFalse(
            keys.contains { $0.side == .both },
            "explicit Left must never key a .both band; got \(keys)"
        )
    }

    // MARK: - AC1: the REAL launch boundary (producer → async resolve → session)

    @MainActor
    func testAC1RealLaunchBoundaryKeepsExplicitLeftEndToEnd() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.targetedAlternatingPreset()

        // Drive the exact chain `launch()` uses: the picker side + the active
        // exercise's side mode are normalized by the producer snapshot, then
        // handed through the real async resolver, then into the session.
        let session = await ForceView.makeGuidedLaunchSession(
            model: model,
            preset: preset,
            tag: "Test Tag",
            sideMode: .unilateralOrBilateral,
            side: .left,
            selection: .free,
            zoneCurve: nil
        )
        // Producer: an explicit Left under a Left-allowing mode stays Left.
        XCTAssertEqual(session.fallbackSide, .left, "producer must keep explicit Left")
        // The run's first work stage is Left.
        let firstWork = try XCTUnwrap(session.run.stages.first(where: { $0.kind == .work }))
        XCTAssertEqual(firstWork.side, .left)
        // The real async resolver keyed a Left band and never a Both band.
        let keys = Array(session.targetPlan.targets.keys)
        XCTAssertTrue(
            keys.contains(ForceTargetKey(setNumber: 1, side: .left)),
            "real launch chain must produce a .left-keyed band; got \(keys)"
        )
        XCTAssertFalse(
            keys.contains { $0.side == .both },
            "real launch chain must never key .both for explicit Left; got \(keys)"
        )
        // Save attribution on the produced session stays Left.
        let savedSide = firstWork.side == .unspecified ? session.fallbackSide : firstWork.side
        XCTAssertEqual(savedSide, .left)
    }

    // MARK: - AC5: bilateral-only exercises carry .both via fallbackSide, never .left

    @MainActor
    func testAC5BilateralOnlySessionCarriesBothViaFallbackSideNeverLeft() throws {
        let model = AppModel(
            auth: makeAuthService(),
            repository: makeRepository(),
            realtime: RealtimeService(client: makeSupabaseClient(storage: InMemoryAuthStorage()))
        )
        // The launch snapshot normalizes invalid Left for a bilateral-only
        // exercise to .both — the session's fallbackSide therefore carries
        // .both semantics and never .left.
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.bilateralOnly, .left), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .left), .both)

        let launchSide = ExerciseSidePolicy.normalizeSide(.bilateralOnly, .left)
        let startSide: TindeqSide = launchSide == .right ? .right : .left
        let session = GuidedForceProtocolSession(
            model: model,
            preset: Self.bilateralOnlyPreset(),
            targetPlan: .empty,
            tag: "Test",
            startingSide: startSide,
            fallbackSide: launchSide,
            selection: .free,
            references: nil
        )
        XCTAssertEqual(session.fallbackSide, .both)
        let firstWork = try XCTUnwrap(session.run.stages.first(where: { $0.kind == .work }))
        XCTAssertNotEqual(firstWork.side, .left)
        let savedSide = firstWork.side == .unspecified ? session.fallbackSide : firstWork.side
        XCTAssertEqual(savedSide, .both)
        XCTAssertNotEqual(savedSide, .left)
    }

    // MARK: - #901: Left/Right must NOT alternate; only Both switches sides

    @MainActor
    func test901RealLaunchBoundaryLeftSelectionNeverAlternates() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.targetedAlternatingPreset()

        let session = await ForceView.makeGuidedLaunchSession(
            model: model,
            preset: preset,
            tag: "Test Tag",
            sideMode: .unilateralOrBilateral,
            side: .left,
            selection: .free,
            zoneCurve: nil
        )
        // Every work stage runs Left only — no opposite-side work, no
        // switch-hands stages — even though the preset alternates.
        let work = session.run.stages.filter { $0.kind == .work }
        XCTAssertFalse(work.isEmpty)
        XCTAssertTrue(
            work.allSatisfy { $0.side == .left },
            "a Left selection must run Left only; got \(work.map(\.side))"
        )
        XCTAssertFalse(session.run.stages.contains { $0.side == .right })
        XCTAssertFalse(
            session.run.stages.contains { $0.kind == .switchSide },
            "a Left selection must never produce a switch-hands prompt"
        )

        // The target plan resolves the selected side only.
        let keys = Array(session.targetPlan.targets.keys)
        XCTAssertTrue(
            keys.contains(ForceTargetKey(setNumber: 1, side: .left)),
            "real launch chain must produce a .left-keyed band; got \(keys)"
        )
        XCTAssertFalse(
            keys.contains { $0.side == .right },
            "a Left selection must never resolve a Right band; got \(keys)"
        )

        // Save attribution on the produced session stays Left.
        let firstWork = try XCTUnwrap(work.first)
        let savedSide = firstWork.side == .unspecified ? session.fallbackSide : firstWork.side
        XCTAssertEqual(savedSide, .left)
    }

    @MainActor
    func test901RealLaunchBoundaryRightSelectionNeverAlternates() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.targetedAlternatingPreset()

        let session = await ForceView.makeGuidedLaunchSession(
            model: model,
            preset: preset,
            tag: "Test Tag",
            sideMode: .unilateralOrBilateral,
            side: .right,
            selection: .free,
            zoneCurve: nil
        )
        let work = session.run.stages.filter { $0.kind == .work }
        XCTAssertFalse(work.isEmpty)
        XCTAssertTrue(work.allSatisfy { $0.side == .right })
        XCTAssertFalse(session.run.stages.contains { $0.side == .left })
        XCTAssertFalse(session.run.stages.contains { $0.kind == .switchSide })

        let keys = Array(session.targetPlan.targets.keys)
        XCTAssertTrue(keys.contains(ForceTargetKey(setNumber: 1, side: .right)))
        XCTAssertFalse(keys.contains { $0.side == .left })

        let firstWork = try XCTUnwrap(work.first)
        let savedSide = firstWork.side == .unspecified ? session.fallbackSide : firstWork.side
        XCTAssertEqual(savedSide, .right)
    }

    @MainActor
    func test901RealLaunchBoundaryBothKeepsAlternatingPair() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.targetedAlternatingPreset()

        let session = await ForceView.makeGuidedLaunchSession(
            model: model,
            preset: preset,
            tag: "Test Tag",
            sideMode: .unilateralOrBilateral,
            side: .both,
            selection: .free,
            zoneCurve: nil
        )
        // Both keeps the alternating schedule exactly as today: both sides
        // present in work stages, switch-hands stages present, starting
        // side honored (Both starts Left at this launch boundary).
        XCTAssertEqual(session.fallbackSide, .both)
        let work = session.run.stages.filter { $0.kind == .work }
        XCTAssertFalse(work.isEmpty)
        XCTAssertTrue(work.contains { $0.side == .left })
        XCTAssertTrue(work.contains { $0.side == .right })
        XCTAssertEqual(work.first?.side, .left)
        XCTAssertTrue(
            session.run.stages.contains { $0.kind == .switchSide },
            "Both-mode must keep its switch-hands stages"
        )

        // Both keeps the per-side target pair.
        let keys = Array(session.targetPlan.targets.keys)
        XCTAssertTrue(keys.contains(ForceTargetKey(setNumber: 1, side: .left)))
        XCTAssertTrue(keys.contains(ForceTargetKey(setNumber: 1, side: .right)))
        XCTAssertFalse(keys.contains { $0.side == .both })
    }

    @MainActor
    func test901RealLaunchBoundaryUnspecifiedKeepsLegacyAlternation() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.targetedAlternatingPreset()

        let session = await ForceView.makeGuidedLaunchSession(
            model: model,
            preset: preset,
            tag: "Test Tag",
            sideMode: .unilateralOrBilateral,
            side: .unspecified,
            selection: .free,
            zoneCurve: nil
        )
        // Historical/unchosen sides are never reinterpreted (#901): the
        // legacy alternating schedule stays.
        let work = session.run.stages.filter { $0.kind == .work }
        XCTAssertTrue(work.contains { $0.side == .left })
        XCTAssertTrue(work.contains { $0.side == .right })
        XCTAssertTrue(session.run.stages.contains { $0.kind == .switchSide })
    }

    // MARK: - Fixtures

    private static func alternatingPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Alternating Test",
            holdSeconds: 10,
            repetitions: 2,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            alternateSides: true,
            prepareSeconds: 5
        )
    }

    private static func targetedAlternatingPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Targeted Alternating Test",
            holdSeconds: 10,
            repetitions: 1,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            targetKilograms: 80,
            alternateSides: true,
            prepareSeconds: 5
        )
    }

    private static func bilateralOnlyPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Bilateral Test",
            holdSeconds: 10,
            repetitions: 2,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            alternateSides: false,
            prepareSeconds: 5
        )
    }

    // MARK: - In-memory auth seam (mirrors AuthRecoveryWiringTests)

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
    private func makeAuthService() -> AuthService {
        let suite = "GuidedForceSideBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AuthService(
            client: makeSupabaseClient(storage: InMemoryAuthStorage()),
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
    }

    @MainActor
    private func makeRepository(session: Auth.Session? = nil) -> SendmeterRepository {
        let suite = "GuidedForceSideBehaviorTests.repo.\(UUID().uuidString)"
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
    /// real `resolveForceTargetPlan` guard (`currentUserID`) passes. The auth
    /// observation task delivers `.initialSession` from local storage; we wait
    /// deterministically (yield loop, no sleeps) for `currentUserID`.
    @MainActor
    private func makeSignedInModel() async throws -> AppModel {
        let suite = "GuidedForceSideBehaviorTests.signed-in.\(UUID().uuidString)"
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
        userID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sessionID: String = "session-1",
        expiresAt: TimeInterval? = nil
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
            expiresAt: expiresAt ?? Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }
}

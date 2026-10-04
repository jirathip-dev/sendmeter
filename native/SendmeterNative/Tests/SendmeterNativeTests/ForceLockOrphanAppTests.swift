import Foundation
import SwiftUI
import UIKit
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #1004 (session-lock layer): the app-boundary proof for the orphaned-lock
/// release.
///
/// The Core suite proves the decision (an ended session is the orphan and
/// requires the release). This suite proves the two things only the app
/// target can: a REAL `GuidedForceProtocolSession` reaches `isEnded` through
/// its own terminal flight and maps to the orphan read the Force surface
/// renders, and running the release over it — the same `teardown()` join the
/// release action performs — leaves the user's un-synced data exactly where
/// it was (the pending durable row stays queued, the recording stays
/// published, no device-held summary is touched). It also renders the
/// release affordance itself for the evidence set.
///
/// The harness mirrors the sibling app suites (stubbed Supabase transport,
/// in-memory auth storage, wall-clock-bounded waits — #978); those helpers
/// are file-private there, so this suite keeps its own.
@MainActor
final class ForceLockOrphanAppTests: XCTestCase {
    private enum RenderEvidenceError: Error {
        case noWindowScene
    }

    /// The hard data fence: the release over an ENDED session must not touch
    /// the user's un-synced data.
    ///
    /// The transport refuses (offline), so the save stays in the durable
    /// queue as a PENDING row; the release joins the session's already
    /// settled terminal flight. The queue file is read in the same
    /// main-actor turn immediately before and immediately after that join,
    /// so the assertion measures the release itself: no queued row may be
    /// removed or replaced by it.
    func testTheReleaseOverAnEndedSessionLeavesThePendingRowUntouched() async throws {
        let model = try await makeSignedInModel()
        let preset = Self.quickPreset()
        let session = Self.makeSession(model: model, preset: preset)

        // Offline: every upload refuses, so the save must remain a PENDING
        // (un-synced) durable row — the exact row the fence protects.
        StubURLProtocol.reply = (
            statusCode: 500,
            body: Data(#"{"message":"host offline"}"#.utf8)
        )
        defer {
            StubURLProtocol.reply = (statusCode: 200, body: Data("[]".utf8))
        }

        // FIX ROUND 1 — the determinism seam (hosted CI run 37179622828
        // attempt 1: "timed out after 15s waiting for the offline save to
        // publish its recording; observed recordings=[]"). The save publishes
        // the recording LOCALLY — `cacheUpsertLocal` marks the pending row in
        // the app's store (AppModel.swift:4516) and `insertPendingRecording` +
        // `mergeRecordings` publish it in memory (:4531/:4533) — but the
        // local write silently no-ops until the store's preparation flight has
        // opened it (`guard let cachedWorkspace else { return nil }`, :2343),
        // and every refresh pass re-derives the published list FROM the store
        // (:2216, overlay rebuild :2230). Two app-owned asynchronous steps can
        // therefore land around the save: the store open (a save before it
        // misses its local row) and the account bootstrap's refresh pass
        // (:1971/:1976 — its hydration can have read the store before the
        // save's local write and assign after it, republishing a list without
        // the row). The old fence could only poll the outcome in a 15-second
        // wall-clock budget — green on a warm container, red on the runner's
        // cold one. This fence now makes publication deterministic instead:
        // it joins the SAME store-preparation flight every lifecycle
        // entrypoint joins (#921, :2680), waits for the bootstrap pass the
        // harness's own seeded session starts to reach its recorded failure
        // (the offline stub guarantees one, and it is recorded only after
        // that pass has published), then drives its OWN publication — an
        // awaited offline refresh pass — so the reads below observe state the
        // test established, not a race.
        StubURLProtocol.reply = (
            statusCode: 500,
            body: Data(#"{"message":"host offline"}"#.utf8)
        )
        defer {
            StubURLProtocol.reply = (statusCode: 200, body: Data("[]".utf8))
        }

        await model.prepareCacheIfNeeded()
        XCTAssertTrue(
            model.cacheReadiness.isReady,
            "the local store must be open for the save to have a published copy; cacheReadiness=\(model.cacheReadiness)"
        )
        try await waitUntil(
            "the account bootstrap's refresh pass to finish",
            isSatisfied: {
                model.lastPartialRefreshFailure != nil
                    || model.dashboardLoadFailureClass != nil
            },
            observed: {
                "lastPartialRefreshFailure=\(String(describing: model.lastPartialRefreshFailure)) "
                    + "dashboardLoadFailureClass=\(String(describing: model.dashboardLoadFailureClass))"
            }
        )

        let idsBeforeSave = try Self.durableQueueItemIDs(
            Self.durableQueueData(),
            payloadCase: "recording"
        )
        let persisted = await model.saveForceSummary(
            Self.summary(),
            tag: "FDP",
            side: .left,
            zone: nil,
            preset: preset,
            protocolRunID: session.run.runID,
            setNumber: 1,
            repetitionNumber: 1
        )
        XCTAssertTrue(persisted, "an offline save must still persist durably")

        // The saved recording is the NEW recording-payload row in the queue
        // file — the artifact this test owns, read in the same main-actor turn
        // around the save. The queue item's id IS the recording's id
        // (`DurableQueueItem(id: recording.id, ...)`), so one identity
        // crosses all three surfaces: durable row, published recording,
        // device bookkeeping.
        let idsAfterSave = try Self.durableQueueItemIDs(
            Self.durableQueueData(),
            payloadCase: "recording"
        )
        let newIDs = Set(idsAfterSave).subtracting(idsBeforeSave)
        guard newIDs.count == 1, let recordingID = newIDs.first else {
            XCTFail(
                "the offline save must leave exactly one new recording row in the durable queue; before=\(idsBeforeSave) after=\(idsAfterSave) new=\(newIDs)"
            )
            return
        }

        // Drive the publication the test owns: an awaited offline refresh pass
        // over the store the save wrote. Its hydration reads the store AFTER
        // the save's local write, so the store-backed list it publishes
        // carries the pending row — and because every later pass reads that
        // same store, the row is stable from here on without any deadline.
        await model.refreshAll(showSpinner: false)
        XCTAssertTrue(
            model.recordings.contains { $0.id == recordingID },
            "the save's pending recording must be published once the store and the bootstrap pass are settled — the subject the release must keep; recordings=\(model.recordings.map(\.id))"
        )

        // End the protocol the way the resume card's End does: the terminal
        // claim settles, the session is ended, and nothing on the surface can
        // resume or end it any more.
        await session.stopOrFinish()
        XCTAssertTrue(session.isEnded, "fixture: the terminal claim ends the session")

        let read = ForceGuidedLockReadState(
            sessionPresent: true,
            sessionEnded: session.isEnded,
            launchInFlight: false
        )
        let owner = ForceLockOrphanPolicy.owner(read)
        XCTAssertEqual(
            owner,
            .endedSession,
            "a REAL ended session is the orphan the release renders on"
        )
        XCTAssertTrue(ForceLockOrphanPolicy.requiresRelease(owner))

        // THE FENCE, measured around the release's only model-facing step:
        // join the settled terminal flight ("Clear Finished Session").
        let idsPreRelease = (try? Self.durableQueueItemIDs(Self.durableQueueData())) ?? []
        XCTAssertTrue(
            idsPreRelease.contains(recordingID),
            "fixture: the un-synced row is still queued at the fence; queue=\(idsPreRelease)"
        )
        await session.teardown()
        XCTAssertTrue(session.isEnded, "the release never resurrects the session")
        let idsPostRelease = (try? Self.durableQueueItemIDs(Self.durableQueueData())) ?? []
        XCTAssertTrue(
            Set(idsPreRelease).isSubset(of: Set(idsPostRelease)),
            "the release must not remove or replace a pending durable row; before=\(idsPreRelease) after=\(idsPostRelease)"
        )
        XCTAssertTrue(
            idsPostRelease.contains(recordingID),
            "the un-synced row stays queued across the release"
        )

        // The recording stays published to the app, and nothing the device
        // holds is cleared.
        XCTAssertTrue(
            model.recordings.contains { $0.id == recordingID },
            "the un-synced recording stays published; recordings=\(model.recordings.map(\.id))"
        )
        XCTAssertNil(model.tindeq.completedSummary, "no device-held pull is cleared by the release")
        XCTAssertNil(model.tindeq.interruptedRecording)
        XCTAssertFalse(model.tindeq.hasUnsavedRecording)

        // Idempotent: any later lifecycle teardown is a no-op on the same
        // settled session — it cannot remove what the first release kept.
        await session.teardown()
        let idsFinal = (try? Self.durableQueueItemIDs(Self.durableQueueData())) ?? []
        XCTAssertTrue(
            Set(idsPostRelease).isSubset(of: Set(idsFinal)),
            "a later teardown must not shorten the queue either; before=\(idsPostRelease) after=\(idsFinal)"
        )
    }

    /// A live session must never read as the orphan: its own resume/end
    /// affordances exist, so the release stays hidden.
    func testALiveSessionIsNeverReadAsTheOrphan() async throws {
        let model = try await makeSignedInModel()
        let session = Self.makeSession(model: model, preset: Self.quickPreset())
        XCTAssertFalse(session.isEnded)

        let owner = ForceLockOrphanPolicy.owner(
            ForceGuidedLockReadState(
                sessionPresent: true,
                sessionEnded: session.isEnded,
                launchInFlight: false
            )
        )

        XCTAssertEqual(owner, .resumableSession)
        XCTAssertFalse(ForceLockOrphanPolicy.requiresRelease(owner))
    }

    /// Rendered evidence (NOT device evidence): the release affordance, the
    /// REAL component, framed on the grouped background the Force tab renders
    /// it on, captured at phone width into the app container.
    func testCaptureReleaseAffordanceFrame() throws {
        let image = try capture(
            VStack(alignment: .leading, spacing: 16) {
                GuidedSessionReleaseCard {}
                Spacer()
            }
            .padding(16)
            .background(Color(uiColor: .systemGroupedBackground)),
            style: .light,
            typeSize: .large
        )

        let directory = try Self.evidenceOutputDirectory()
        guard let data = image.pngData() else {
            XCTFail("could not encode the release frame")
            return
        }
        let url = directory.appendingPathComponent("guided-session-release-card.png")
        try data.write(to: url)
        print(
            "EVIDENCE_FRAME guided-session-release-card "
                + "\(Int(image.size.width))x\(Int(image.size.height))px \(url.path)"
        )
    }

    /// Hosts a REAL view in a real window on the app's own scene and renders
    /// the window hierarchy at 3× (the same capture discipline as the sibling
    /// evidence test — a SwiftUI surface is UICollectionView-backed in a
    /// List, so a bare layer render misses its cells).
    private func capture<V: View>(
        _ view: V,
        style: UIUserInterfaceStyle,
        typeSize: DynamicTypeSize
    ) throws -> UIImage {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            throw RenderEvidenceError.noWindowScene
        }
        let size = CGSize(width: 402, height: 874) // iPhone 17 Pro logical size
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        let hosting = UIHostingController(
            rootView: view
                .environmentObject(AppThemeController())
                .environment(\.dynamicTypeSize, typeSize)
        )
        hosting.overrideUserInterfaceStyle = style
        hosting.view.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    // MARK: - The durable queue file (the only local copy that survives the process)

    private static func durableQueueData() throws -> Data {
        let url = supportDirectory()
            .appendingPathComponent("pending-writes.json", isDirectory: false)
        return try Data(contentsOf: url)
    }

    /// Every queued item's identity, read from the queue file's own JSON.
    /// With `payloadCase`, only items whose `PendingWrite` enum payload is
    /// that case (the single-key encoding, e.g. `{"recording": …}`) are
    /// returned — a save's row is the `recording` case.
    private static func durableQueueItemIDs(
        _ data: Data,
        payloadCase: String? = nil
    ) throws -> [UUID] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            if let payloadCase {
                guard let payload = item["payload"] as? [String: Any],
                      payload[payloadCase] != nil
                else { return nil }
            }
            return (item["id"] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    private static func evidenceOutputDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("issue-1004-session-lock-evidence", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: - Deadline-bound waits (duplicated from GuidedProtocolCompletionTests)

    private static let waitDeadline: Duration = .seconds(60)

    /// Polls `isSatisfied` until it holds or `timeout` elapses, then fails the
    /// test with the elapsed time and the state `observed`.
    private func waitUntil(
        _ expectation: String,
        timeout: Duration = ForceLockOrphanAppTests.waitDeadline,
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

    // MARK: - Model + session fixtures (duplicated from the sibling app suites;
    // those helpers are file-private)
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
        let suite = "ForceLockOrphanAppTests.repo.\(UUID().uuidString)"
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
        let suite = "ForceLockOrphanAppTests.signed-in.\(UUID().uuidString)"
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

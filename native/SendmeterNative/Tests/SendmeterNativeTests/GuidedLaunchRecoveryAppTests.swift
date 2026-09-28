import Foundation
import SwiftUI
import UIKit
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #1004: the two app-boundary proofs the issue demands.
///
/// * **An old payload must not brick the app.** A stored recording row in the
///   PREVIOUS build's shape is seeded into the real account-scoped cache before
///   the model opens it; the app must launch (hydrate + reconcile through the
///   real refresh), keep serving the readable history, set the unreadable row
///   aside with its raw payload preserved, and still be able to start a guided
///   session.
/// * **A failed target resolution clears the in-flight flag and surfaces a
///   retryable failure.** The stall is injected in the transport, so the real
///   chain runs: `ForceView.resolveGuidedLaunch` → `makeGuidedLaunchSession` →
///   `AppModel.resolveForceTargetPlan` → `forceReferences` →
///   `SendmeterRepository.fetchRecordingSamples`. The retry is then driven
///   through the same chain with the preset the failure carries.
@MainActor
final class GuidedLaunchRecoveryAppTests: XCTestCase {
    private let userID = UUID()

    /// Holds the exact store the seam opened, so the test can inspect what the
    /// quarantine did with the raw payload.
    private final class StoreBox: @unchecked Sendable {
        var store: LocalCacheStore?
    }

    private static let legacyRecordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private var storeBox = StoreBox()

    private enum RenderEvidenceError: Error {
        case noWindowScene
    }

    /// The sibling app suites' storage double is file-private; each suite keeps
    /// its own so nothing here can depend on another file's test internals.
    private final class RecoveryInMemoryAuthStorage: AuthLocalStorage {
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

    /// A payload in the PREVIOUS build's shape, as a build that predates
    /// `protocolMode`/`capacityEvidence`/`completionStatus` wrote it. It is
    /// written through the store's own server-upsert path, so the bytes in the
    /// cache are exactly what this struct encodes.
    private struct LegacyRecordingPayload: Codable, Equatable {
        let id: UUID
        let recordedAt: String
        let durationMilliseconds: Int
        let maxKilograms: Double
        let sampleCount: Int
        let note: String
        let tag: String
        let side: String
        let zone: String
    }

    /// One definition, used by both the seeding seam and the assertion, so the
    /// bytes written and the bytes expected cannot drift.
    private static var legacyPayload: LegacyRecordingPayload {
        LegacyRecordingPayload(
            id: Self.legacyRecordingID,
            recordedAt: "2024-05-01T10:00:00Z",
            durationMilliseconds: 5_000,
            maxKilograms: 21.5,
            sampleCount: 120,
            note: "old build",
            tag: "campus",
            side: "left",
            zone: "strength"
        )
    }

    // MARK: - AC: an old payload does not brick the app

    func testALegacyStoredPayloadIsSetAsideAndTheAppStillStartsASession() async throws {
        let server = FakeRecoveryPostgREST()
        server.seedHistory(tag: "FDP", side: "left")
        let model = try await makeSignedInModel(server: server)

        await model.refreshAll(showSpinner: false)

        // The app launched: the authoritative history reconciled through the
        // real repository / cache / model path even though the store also held
        // a row this build cannot decode.
        XCTAssertGreaterThanOrEqual(
            model.recordings.filter { $0.tag == "FDP" }.count,
            1,
            "the seeded history must still reconcile with an unreadable row in the cache"
        )

        // The unreadable row was reported and repaired, not silently dropped.
        let report = try XCTUnwrap(
            model.lastLocalDataRepair,
            "an undecodable stored row must be repaired on the launch path"
        )
        XCTAssertEqual(report.quarantinedCount, 1)
        XCTAssertEqual(report.healedEntityTypes, [.recordings])
        let preserved = try XCTUnwrap(report.quarantined.first)
        XCTAssertEqual(
            try JSONDecoder().decode(
                LegacyRecordingPayload.self,
                from: Data(preserved.payload.utf8)
            ),
            Self.legacyPayload,
            "the unreadable payload is preserved VERBATIM so a later build can recover it"
        )
        XCTAssertEqual(report.preservedPendingCount, 0, "the fixture row was a clean, server-owned row")
        XCTAssertTrue(
            report.message.contains("rebuilding"),
            "the notice says what happens next: got \(report.message)"
        )

        // The payload is still on disk (moved aside), and the row is gone from
        // the serve set.
        let store = try XCTUnwrap(storeBox.store)
        let quarantine = try store.quarantinedRows(accountUserID: userID)
        XCTAssertEqual(quarantine.map(\.entityID), [Self.legacyRecordingID.uuidString])
        XCTAssertEqual(
            try XCTUnwrap(quarantine.first).payload,
            preserved.payload,
            "the bytes on disk are the same bytes the repair reported"
        )
        // The heal, observed: the entity is marked for a full reconcile, and the
        // read after the repair has no unreadable rows left. (The store may
        // legally hold a NEW cursor by then — the refresh re-establishes one —
        // so the assertion is the read, not the cursor's absence.)
        let afterRepair = try store.coherentSnapshotRead(accountUserID: userID)
        XCTAssertTrue(afterRepair.invalidRows.isEmpty)
        XCTAssertFalse(
            afterRepair.snapshot.recordings.contains { $0.id == Self.legacyRecordingID },
            "the unreadable row is out of the serve set"
        )

        // And the app can start a session: the REAL launch-resolution chain
        // produces a session for the same exercise.
        let preset = Self.curveResolvedPreset()
        let resolution = await ForceView.resolveGuidedLaunch(
            model: model,
            preset: preset,
            tag: "FDP",
            sideMode: .unilateralOrBilateral,
            side: .left,
            selection: .free,
            zoneCurve: nil,
            timeout: 8
        )
        guard case .resolved(let session) = resolution else {
            XCTFail("the guided launch must still resolve after a legacy payload was set aside")
            return
        }
        XCTAssertEqual(session.preset.id, preset.id)
    }

    // MARK: - AC: a failed resolution clears the flag and the retry re-runs it

    func testAResolutionThatNeverSettlesReleasesTheFlagAndTheRetryReRunsIt() async throws {
        let server = FakeRecoveryPostgREST()
        server.seedHistory(tag: "FDP", side: "left")
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)

        // The stall: every request now hangs, and the sample fetch the REAL
        // chain needs for the curve is one of them. (No fixture assertion on
        // the pre-stall fetch count — the app container's local sample-file
        // cache can legitimately satisfy that one without the network.)
        server.setHangsRequests(true)
        let preset = Self.curveResolvedPreset()
        var lifecycle = GuidedLaunchLifecycle()
        let attempt = lifecycle.begin(preset: preset)
        XCTAssertTrue(lifecycle.inFlight)

        let resolution = await ForceView.resolveGuidedLaunch(
            model: model,
            preset: preset,
            tag: "FDP",
            sideMode: .unilateralOrBilateral,
            side: .left,
            selection: .free,
            zoneCurve: nil,
            timeout: 1
        )

        guard case .timedOut = resolution else {
            XCTFail("a resolution that never settles must time out")
            return
        }
        XCTAssertGreaterThan(
            server.hungSampleFetchCount,
            0,
            "the REAL chain must have reached the hung sample fetch, not just some background request"
        )

        // What `launch()` does with that outcome: settle the attempt.
        XCTAssertTrue(
            lifecycle.settle(
                attempt,
                outcome: .timedOut(loadFailureClass: model.dashboardLoadFailureClass)
            )
        )

        XCTAssertFalse(lifecycle.inFlight, "the in-flight flag must not outlive the attempt")
        let failure = try XCTUnwrap(lifecycle.failure, "the failure must be visible, with a retry")
        XCTAssertTrue(failure.isRetryable)
        XCTAssertFalse(failure.message.isEmpty)
        let retryPreset = try XCTUnwrap(lifecycle.retryPreset)

        // The retry re-runs the SAME attempt against a live transport.
        server.setHangsRequests(false)
        let retryAttempt = lifecycle.begin(preset: retryPreset)
        let retried = await ForceView.resolveGuidedLaunch(
            model: model,
            preset: retryPreset,
            tag: "FDP",
            sideMode: .unilateralOrBilateral,
            side: .left,
            selection: .free,
            zoneCurve: nil,
            timeout: 8
        )
        guard case .resolved(let session) = retried else {
            XCTFail("the retry must re-run the launch and resolve")
            return
        }
        XCTAssertEqual(session.preset.id, preset.id)

        lifecycle.settle(retryAttempt, outcome: .launched)
        XCTAssertFalse(lifecycle.inFlight)
        XCTAssertNil(lifecycle.failure, "a successful retry clears the failure notice")
    }

    // MARK: - Rendered evidence: the recovery affordances

    /// The issue asks for a screenshot of the recovery affordance. This is
    /// rendered evidence, not device evidence: the frames are the REAL
    /// components, captured from a hosted window at phone width and written
    /// into the app container for the lane to copy under
    /// `docs/evidence/issue-1004/`.
    func testCaptureRecoveryAffordanceFrames() async throws {
        let server = FakeRecoveryPostgREST()
        server.seedHistory(tag: "FDP", side: "left")
        let model = try await makeSignedInModel(server: server)
        await model.refreshAll(showSpinner: false)
        XCTAssertNotNil(model.lastLocalDataRepair, "fixture: the repair notice is on screen")

        var frames: [(String, UIImage)] = []
        frames.append(
            (
                "settings-local-data-repair",
                try capture(
                    SettingsView(),
                    model: model,
                    style: .light,
                    typeSize: .large,
                    scrollToBottom: true
                )
            )
        )

        // The launch-failure row: what the user sees instead of a disabled
        // control with no explanation. The card is framed on the grouped
        // background it renders on in the Force tab.
        let failure = GuidedLaunchFailure(
            reason: .deadlineExceeded(loadFailureClass: .dataUnreadable),
            preset: Self.curveResolvedPreset()
        )
        frames.append(
            (
                "guided-launch-failure-card",
                try capture(
                    VStack(alignment: .leading, spacing: 16) {
                        GuidedLaunchFailureCard(failure: failure, onRetry: {})
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(uiColor: .systemGroupedBackground)),
                    model: model,
                    style: .light,
                    typeSize: .large,
                    scrollToBottom: false
                )
            )
        )

        let directory = try Self.evidenceOutputDirectory()
        for frame in frames {
            guard let data = frame.1.pngData() else {
                XCTFail("could not encode \(frame.0)")
                continue
            }
            try data.write(to: directory.appendingPathComponent("\(frame.0).png"))
            print("EVIDENCE_FRAME \(frame.0) \(Int(frame.1.size.width))x\(Int(frame.1.size.height))px")
        }
    }

    /// Hosts a REAL view in a real window on the app's own scene and renders the
    /// window hierarchy at 3× (the same capture discipline the #920/#923
    /// evidence test uses — a SwiftUI List is UICollectionView-backed, so a
    /// bare layer render misses its cells).
    @MainActor
    private func capture<V: View>(
        _ view: V,
        model: AppModel,
        style: UIUserInterfaceStyle,
        typeSize: DynamicTypeSize,
        scrollToBottom: Bool
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
                .environment(model)
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

        if scrollToBottom, let scroll = Self.firstScrollView(in: hosting.view) {
            scroll.layoutIfNeeded()
            let bottom = max(
                0,
                scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom
            )
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            window.layoutIfNeeded()
        }

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

    @MainActor
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scroll = subview as? UIScrollView { return scroll }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    private static func evidenceOutputDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("issue-1004-evidence", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: - Fixtures

    private static func curveResolvedPreset() -> TindeqPreset {
        TindeqPreset(
            id: UUID(),
            name: "Test curve target",
            holdSeconds: 7,
            repetitions: 3,
            sets: 1,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 180,
            targetPercentage: 85,
            percentageBasis: .personalRecord,
            targetFromCurve: true,
            protocolMode: .hold
        )
    }

    // MARK: - Harness

    private func makeSignedInModel(server: FakeRecoveryPostgREST) async throws -> AppModel {
        let suite = "GuidedLaunchRecoveryAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = RecoveryInMemoryAuthStorage()
        let session = Self.makeSession(userID: userID)
        try storage.store(
            key: "sb-example-auth-token",
            value: JSONEncoder().encode(session)
        )
        let box = storeBox
        let legacyEntityID = Self.legacyRecordingID.uuidString
        let account = userID
        let legacy = Self.legacyPayload
        let seams = CacheStorageSeams(openStore: { databaseURL in
            let store = try LocalCacheStore(databaseURL: databaseURL)
            // The cache a previous build left behind: one row whose payload
            // this build cannot decode, written before the store is handed to
            // the app exactly the way an in-place upgrade leaves it.
            try store.upsertServer(
                legacy,
                accountUserID: account,
                entityType: .recordings,
                entityID: legacyEntityID,
                updatedAt: Date(timeIntervalSince1970: 1_714_550_400)
            )
            box.store = store
            return store
        })

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
            weather: WeatherService(defaults: defaults, session: server.makeURLSession()),
            cacheStorageSeams: seams
        )

        var waited = 0
        while model.currentUserID == nil, waited < 200 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
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

    private func makeRepository(
        session: Auth.Session,
        server: FakeRecoveryPostgREST
    ) -> SendmeterRepository {
        let suite = "GuidedLaunchRecoveryAppTests.repo.\(UUID().uuidString)"
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

/// The stubbed backend for this suite: one exercise's recording rows plus the
/// sample rows the reference fit consumes, with a transport stall switch so the
/// REAL resolution chain can be made to wait. Nothing here reaches a live
/// service.
private final class FakeRecoveryPostgREST: @unchecked Sendable {
    private let lock = NSLock()
    private var recordingRows: [[String: Any]] = []
    private var samplesByID: [String: [[Double]]] = [:]
    private var hangsRequests = false
    private var sampleRowFetches = 0
    private var hungSampleFetches = 0

    func seedHistory(tag: String, side: String) {
        let efforts: [(milliseconds: Int, peak: Double, average: Double)] = [
            (7_000, 39.0, 23.0),
            (30_000, 40.0, 18.0),
        ]
        var rows: [[String: Any]] = []
        var samples: [String: [[Double]]] = [:]
        for (index, effort) in efforts.enumerated() {
            let id = UUID()
            let key = id.uuidString.lowercased()
            let sampleRows = Self.samples(
                durationMilliseconds: effort.milliseconds,
                peakKilograms: effort.peak
            )
            samples[key] = sampleRows
            rows.append([
                "id": key,
                "deleted_at": NSNull(),
                "updated_at": Self.timestamp(offset: index),
                "recorded_at": Self.timestamp(offset: index),
                "duration_ms": effort.milliseconds,
                "peak_kg": effort.peak,
                "avg_kg": effort.average,
                "sample_count": sampleRows.count,
                "note": NSNull(),
                "tag": tag,
                "side": side,
                "group_id": NSNull(),
                "protocol_run_id": NSNull(),
                "set_no": NSNull(),
                "zone": NSNull(),
                "source": "dynamometer",
                "external_load_kg": NSNull(),
                "outcome": NSNull(),
                "planned_duration_ms": NSNull(),
                "actual_duration_ms": NSNull(),
                "rep_no": NSNull(),
                "protocol_mode": "hold",
                "target_kg": NSNull(),
                "target_low_kg": NSNull(),
                "target_high_kg": NSNull(),
                "cadence_out_s": NSNull(),
                "cadence_return_s": NSNull(),
                "cadence_markers": NSNull(),
                "set_metrics": NSNull(),
                "setup_note": NSNull(),
                "capacity_evidence": NSNull(),
                "completed_reps": NSNull(),
                "completion_status": NSNull(),
            ])
        }
        lock.lock()
        recordingRows = rows
        samplesByID = samples
        lock.unlock()
    }

    /// Every request now stalls in the transport. The stall is finite (the
    /// reply lands long after any deadline under test) so no request is left
    /// pending forever.
    func setHangsRequests(_ hangs: Bool) {
        lock.lock()
        hangsRequests = hangs
        lock.unlock()
    }

    var sampleRowFetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampleRowFetches
    }

    /// Hung requests that were the reference fit's sample fetch — the call the
    /// guided launch's resolution actually waits on.
    var hungSampleFetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hungSampleFetches
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeRecoveryProtocol.self]
        FakeRecoveryProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest) -> (status: Int, body: Data)? {
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        let isSampleFetch = path.hasSuffix("/tindeq_recordings") && query.contains("select=samples")
        lock.lock()
        let hangs = hangsRequests
        if hangs, isSampleFetch { hungSampleFetches += 1 }
        lock.unlock()
        guard !hangs else { return nil }

        guard path.hasSuffix("/tindeq_recordings") else {
            return (200, Data("[]".utf8))
        }
        if query.contains("select=samples") {
            let id = Self.queryValue("id", in: query)?
                .replacingOccurrences(of: "eq.", with: "")
                .lowercased() ?? ""
            lock.lock()
            let rows = samplesByID[id] ?? []
            if !rows.isEmpty { sampleRowFetches += 1 }
            lock.unlock()
            return (200, Self.json([["samples": rows]]))
        }
        lock.lock()
        let rows = recordingRows
        lock.unlock()
        return (200, Self.json(rows))
    }

    private static func samples(
        durationMilliseconds: Int,
        peakKilograms: Double
    ) -> [[Double]] {
        let criticalForce = 15.0
        let tau = 5.0
        var rows: [[Double]] = []
        var milliseconds = 0
        while milliseconds <= durationMilliseconds {
            let seconds = Double(milliseconds) / 1_000
            let kilograms = criticalForce
                + (peakKilograms - criticalForce) * exp(-seconds / tau)
            rows.append([Double(milliseconds), (kilograms * 100).rounded() / 100])
            milliseconds += 100
        }
        return rows
    }

    private static func queryValue(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(name) else { continue }
            return String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return nil
    }

    private static func json(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    }

    private static func timestamp(offset: Int = 0) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(
            from: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
        )
    }
}

private final class FakeRecoveryProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeRecoveryPostgREST?
    /// How long a stalled request waits before its (ignored) reply lands.
    private static let stallSeconds = 20.0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let reply = server.reply(for: request) {
            deliver(reply)
            return
        }
        // The stall: the reply exists only to keep the URLSession task from
        // hanging forever — every deadline under test fires long before it.
        let stalledClient = client
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.stallSeconds) { [weak self] in
            guard let self, let stalledClient else { return }
            self.deliver((200, Data("[]".utf8)), to: stalledClient)
        }
    }

    override func stopLoading() {}

    private func deliver(_ reply: (status: Int, body: Data)) {
        if let client { deliver(reply, to: client) }
    }

    private func deliver(_ reply: (status: Int, body: Data), to client: URLProtocolClient) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: reply.body)
        client.urlProtocolDidFinishLoading(self)
    }
}

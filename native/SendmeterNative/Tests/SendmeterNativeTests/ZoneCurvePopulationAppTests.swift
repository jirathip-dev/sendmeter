import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #990: the Force tab's four zone protocols (Power / Strength / Pow End /
/// Endurance) are gated on `ForceView.zoneCurve` — the cached static fit for
/// the active tag, read by
/// `ForceRecordingContextCard.armableZoneQualities`
/// (`Sources/Features/Force/ForceRecordingContextCard.swift:76-91`).
///
/// Every test here drives the REAL population path, because that is what the
/// issue's two candidate causes differ on:
///
/// 1. recordings and their sample rows are served by a stubbed PostgREST
///    backend and reconciled by `AppModel.refreshAll` through the real
///    repository / account-scoped cache / `warmTagCurvesIfMissing` /
///    `computeTagCurve` path;
/// 2. only then is the curve read back the way the Force view reads it.
///
/// No test in this file builds a `ZoneCurveInput` by hand, and none asserts on
/// the card's copy.
@MainActor
final class ZoneCurvePopulationAppTests: XCTestCase {
    private let userID = UUID()

    // MARK: - AC2: the discrimination dump

    /// The dump the issue's AC2 asks for, printed from real code (not a
    /// hand-built struct): the active tag as the view computes it, the
    /// normalized key it produces, every `(tag, modality)` pair in
    /// `forceModel.tagCurves`, and the per-recording fit-exclusion reason for
    /// the active tag.
    func testDumpCurvePopulationAndFitExclusionsForExistingHistory() async throws {
        let server = FakeZoneCurvePostgREST()
        server.seedHistory(tag: "FDP", side: "left")
        let model = try await makeSignedInModel(server: server)

        await model.refreshAll(showSpinner: false)
        _ = await waitForCurves(model, minimum: 1, timeout: 8)

        print(Self.dump(model: model, tag: "FDP", server: server))

        // The dump is only meaningful if the fixture actually crossed the real
        // read path: the recordings for the key are published, and their
        // sample rows were fetchable by the fit.
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "FDP" }.count,
            8,
            "fixture: the seeded history must be reconciled into the model"
        )
        XCTAssertGreaterThan(
            server.sampleRowFetchCount,
            0,
            "fixture: the fit must have fetched sample rows for this history"
        )
    }

    // MARK: - AC5: the discriminating test

    /// A user with existing history for the active exercise must get the
    /// cached static curve and therefore all four zone protocols armable —
    /// asserted through the population path, never a hand-built input.
    func testExistingHistoryPopulatesTheZoneCurveAndArmsEveryZone() async throws {
        let server = FakeZoneCurvePostgREST()
        server.seedHistory(tag: "FDP", side: "left")
        let model = try await makeSignedInModel(server: server)

        await model.refreshAll(showSpinner: false)
        _ = await waitForCurves(model, minimum: 1, timeout: 8)

        let curveInput = ForceModel.zoneCurveInput(in: model.forceModel.tagCurves, tag: "FDP")
        let curve = try XCTUnwrap(
            curveInput,
            "the active exercise's cached static curve must exist after the authoritative refresh; "
                + Self.dump(model: model, tag: "FDP", server: server)
        )
        XCTAssertEqual(
            Self.armableZoneQualities(curve),
            Set(ZoneQuality.allCases),
            "the four zone protocols must become armable from the real curve; got "
                + "cf=\(String(describing: curve.cf)) maxForce=\(String(describing: curve.maxForce)) "
                + "f60=\(String(describing: curve.f60Kilograms))"
        )
    }

    // MARK: - AC5: the RED discriminating test for the proven cause

    /// The same history, but with one UNRELATED slice of the authoritative
    /// sweep failing. The recordings still publish — the exercise, its PR and
    /// its history are all on screen — and the curve cache must still be
    /// populated, because a curve is a function of the RECORDINGS, not of the
    /// health-metrics slice.
    ///
    /// RED at the head this lane based on: the warm is gated on
    /// `outcomes.didFullyRefresh` (`AppModel.refreshAll`,
    /// `Sources/App/AppModel.swift:3294-3312`) while the same pass clears every
    /// published curve (`invalidateTagCurveCache()`, `:3278`), so a partial
    /// pass empties the cache and never rebuilds it. All four zone protocols
    /// then render dimmed with the "No reference curve" copy, for a user with
    /// a long history — the reported symptom.
    func testPartialRefreshStillProducesTheZoneCurveAndArmsEveryZone() async throws {
        let server = FakeZoneCurvePostgREST()
        server.seedHistory(tag: "FDP", side: "left")
        server.failSlice("/health_metrics")
        let model = try await makeSignedInModel(server: server)

        await model.refreshAll(showSpinner: false)
        _ = await waitForCurves(model, minimum: 1, timeout: 8)

        XCTAssertEqual(
            model.recordings.filter { $0.tag == "FDP" }.count,
            8,
            "the recordings slice itself succeeded and published — the history is on screen"
        )
        let curveInput = ForceModel.zoneCurveInput(in: model.forceModel.tagCurves, tag: "FDP")
        let curve = try XCTUnwrap(
            curveInput,
            "a partial refresh must not leave a user with existing history curveless; "
                + Self.dump(model: model, tag: "FDP", server: server)
        )
        XCTAssertEqual(
            Self.armableZoneQualities(curve),
            Set(ZoneQuality.allCases),
            "the four zone protocols must become armable; got "
                + "cf=\(String(describing: curve.cf)) maxForce=\(String(describing: curve.maxForce)) "
                + "f60=\(String(describing: curve.f60Kilograms))"
        )
    }

    /// Print-only probe: the same user, but with only short holds on record
    /// (5s / 7s / 10s). Whether a fit exists for that shape is the fit policy's
    /// own answer — CF/W′ regression windows start at 10s — so recording it
    /// here is what rules the FIT path in or out as this issue's cause.
    func testDumpShortHoldOnlyHistoryFitOutcome() async throws {
        let server = FakeZoneCurvePostgREST()
        server.seedHistory(tag: "FDP", side: "left", shortHoldsOnly: true)
        let model = try await makeSignedInModel(server: server)

        await model.refreshAll(showSpinner: false)
        _ = await waitForCurves(model, minimum: 1, timeout: 8)

        print(Self.dump(model: model, tag: "FDP", server: server))
        XCTAssertEqual(
            model.recordings.filter { $0.tag == "FDP" }.count,
            6,
            "fixture: the short-hold history is published"
        )
    }

    // MARK: - the gate the assertion above reproduces

    /// Mirrors `ForceRecordingContextCard.armableZoneQualities`
    /// (`Sources/Features/Force/ForceRecordingContextCard.swift:76-91`). This
    /// lane does not write that file (its gating is not the defect), so the
    /// rule is applied here to the curve the REAL path produced; the test
    /// below pins the card's source lines so the mirror cannot drift from the
    /// gate it reproduces.
    private static func armableZoneQualities(_ curveInput: ZoneCurveInput?) -> Set<ZoneQuality> {
        var result: Set<ZoneQuality> = []
        let maxForceUsable = (curveInput?.maxForce).map { $0.isFinite && $0 > 0 } ?? false
        let cfUsable = (curveInput?.cf).map { $0.isFinite && $0 > 0 } ?? false
        if maxForceUsable {
            result.insert(.power)
            result.insert(.strength)
        }
        if cfUsable {
            result.insert(.endurance)
        }
        if curveInput?.f60Kilograms != nil {
            result.insert(.powerEndurance)
        }
        return result
    }

    func testCardGateRuleIsUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Force/ForceRecordingContextCard.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for line in [
            "let maxForceUsable = (curveInput?.maxForce).map { $0.isFinite && $0 > 0 } ?? false",
            "let cfUsable = (curveInput?.cf).map { $0.isFinite && $0 > 0 } ?? false",
            "if maxForceUsable {",
            "result.insert(.powerEndurance)",
            "if curveInput?.f60Kilograms != nil {",
        ] {
            XCTAssertTrue(
                source.contains(line),
                "the card's zone gate changed — update armableZoneQualities in this file: \(line)"
            )
        }
    }

    // MARK: - dump

    private static func dump(
        model: AppModel,
        tag: String,
        server: FakeZoneCurvePostgREST
    ) -> String {
        let activeTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = activeTag.lowercased()
        let curves = model.forceModel.tagCurves
        let key = TagCurveCacheKey(tag: activeTag, modality: "static")

        var lines: [String] = []
        lines.append("=== #990 curve-population dump (seeded fixture through the real path) ===")
        lines.append("active tag as ForceView.activeTag computes it = \"\(activeTag)\"")
        lines.append("normalized lookup tag = \"\(normalized)\"  modality = \"static\"")
        lines.append("forceModel.tagCurves.count = \(curves.count)")
        if curves.isEmpty {
            lines.append("  (no cached curve at all)")
        }
        for curve in curves {
            lines.append(
                "  pair = (\"\(curve.tag)\", \"\(curve.modality)\")"
                    + " cf=\(curve.cf) wPrime=\(curve.wPrime)"
                    + " maxForce=\(curve.maxForceKilograms.map(String.init(describing:)) ?? "nil")"
                    + " hasFit=\(curve.forceCurveModel != nil)"
                    + " capabilityFit=\(curve.forceCurveModel?.capabilityFit != nil)"
            )
        }
        lines.append(
            "any cached pair matches the view's key = "
                + "\(curves.contains { TagCurveCacheKey(tag: $0.tag, modality: $0.modality) == key })"
        )
        lines.append(
            "lookup with a near-miss spelling (\"  fdp  \") = "
                + "\(ForceModel.zoneCurveInput(in: curves, tag: "  fdp  ") == nil ? "nil" : "non-nil")"
                + " — the lookup normalizes both sides, so a same-tag curve cannot miss on case/whitespace"
        )
        lines.append("sample-row fetches served by the backend = \(server.sampleRowFetchCount)")

        let forKey = model.recordings.filter {
            TagCurveCacheKey(tag: $0.tag, modality: GaugeSessionRPE.modality(of: $0)) == key
        }
        lines.append("recordings whose key matches = \(forKey.count) (of \(model.recordings.count) published)")
        for recording in forKey {
            let includes = TagCurveCachePolicy.includes(
                recordingID: recording.id,
                pendingIDs: [],
                locallyAvailableSampleIDs: []
            )
            lines.append(
                "  \(recording.id.uuidString.prefix(8))"
                    + " tag=\"\(recording.tag)\""
                    + " dur=\(recording.durationMilliseconds)ms"
                    + " peak=\(recording.peakKilograms.map(String.init(describing:)) ?? "nil")"
                    + " avg=\(recording.averageKilograms.map(String.init(describing:)) ?? "nil")"
                    + " zone=\(recording.zone.map { "\($0)" } ?? "nil")"
                    + " mode=\(recording.protocolMode.rawValue)"
                    + " note=\"\(recording.note)\""
                    + " rejected=\(recording.rejected)"
                    + " includes=\(includes)"
                    + " modalityFilter=\(recording.protocolMode != .reverseAction)"
                    + " isCurveFitCandidate=\(ZoneMix.isCurveFitCandidate(recording))"
            )
        }

        if let curve = ForceModel.cachedStaticCurve(in: curves, tag: activeTag) {
            let input = ZoneCurveInput(curve)
            lines.append("ForceView.zoneCurve = non-nil")
            lines.append(
                "ZoneCurveInput: cf=\(String(describing: input.cf))"
                    + " maxForce=\(String(describing: input.maxForce))"
                    + " wPrime=\(String(describing: input.wPrime))"
                    + " f60Kilograms=\(String(describing: input.f60Kilograms))"
            )
            lines.append("armable zone qualities = \(armableZoneQualities(input).map(\.rawValue).sorted())")
        } else {
            lines.append("ForceView.zoneCurve = nil")
            lines.append("armable zone qualities = []")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - bounded waits

    private func waitForCurves(
        _ model: AppModel,
        minimum: Int,
        timeout: TimeInterval
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = model.forceModel.tagCurves.count
        while count < minimum, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            count = model.forceModel.tagCurves.count
        }
        return count
    }

    // MARK: - app-target harness (duplicated from the sibling app suites; their
    // copies are file-private)

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
        server: FakeZoneCurvePostgREST
    ) -> SendmeterRepository {
        let suite = "ZoneCurvePopulationAppTests.repo.\(UUID().uuidString)"
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

    private func makeSignedInModel(server: FakeZoneCurvePostgREST) async throws -> AppModel {
        let suite = "ZoneCurvePopulationAppTests.signed-in.\(UUID().uuidString)"
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

/// The stubbed backend for the curve path: one exercise's recording rows plus
/// the sample rows the fit consumes (served one recording at a time, exactly
/// like `SendmeterRepository.fetchRecordingSamples`), a per-path failure switch
/// so one slice of the authoritative sweep can be taken offline, and a request
/// log so a test can state what the app actually asked for.
private final class FakeZoneCurvePostgREST: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    struct RequestRecord {
        let method: String
        let path: String
        let query: String
    }

    private let lock = NSLock()
    private var recordingRows: [[String: Any]] = []
    private var samplesByID: [String: [[Double]]] = [:]
    private var failingPaths: Set<String> = []
    private var requests: [RequestRecord] = []
    private var sampleRowFetches = 0

    /// The owner's situation: a long static history for one exercise, with the
    /// sample rows still on the server. `shortHoldsOnly` seeds the opposite
    /// shape — nothing long enough for the CF/W′ regression windows.
    func seedHistory(tag: String, side: String, shortHoldsOnly: Bool = false) {
        let efforts: [(milliseconds: Int, peak: Double, average: Double)] = shortHoldsOnly
            ? [
                (5_000, 38.0, 24.0), (5_000, 36.0, 22.0),
                (7_000, 39.0, 23.0), (7_000, 37.0, 21.0),
                (10_000, 40.0, 22.0), (10_000, 38.0, 20.0),
            ]
            : [
                (5_000, 38.0, 24.0), (5_000, 36.0, 22.0),
                (7_000, 39.0, 23.0), (7_000, 37.0, 21.0),
                (10_000, 40.0, 22.0), (10_000, 38.0, 20.0),
                (30_000, 40.0, 18.0), (45_000, 40.0, 17.0),
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

    /// Take one slice of the authoritative sweep offline (transport failure),
    /// leaving every other slice — recordings included — authoritative.
    func failSlice(_ pathSuffix: String) {
        lock.lock()
        failingPaths.insert(pathSuffix)
        lock.unlock()
    }

    var sampleRowFetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampleRowFetches
    }

    var recordedRequests: [RequestRecord] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeZoneCurveProtocol.self]
        FakeZoneCurveProtocol.server = self
        return URLSession(configuration: configuration)
    }

    /// Nil means "fail at the transport layer".
    func reply(for request: URLRequest, body: Data?) -> Reply? {
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        lock.lock()
        requests.append(
            RequestRecord(
                method: request.httpMethod ?? "GET",
                path: path,
                query: query
            )
        )
        let fails = failingPaths.contains { path.hasSuffix($0) }
        lock.unlock()
        guard !fails else { return nil }

        guard path.hasSuffix("/tindeq_recordings") else {
            return Reply(status: 200, body: Data("[]".utf8))
        }

        if query.contains("select=samples") {
            let id = Self.queryValue("id", in: query)?
                .replacingOccurrences(of: "eq.", with: "")
                .lowercased() ?? ""
            lock.lock()
            let rows = samplesByID[id] ?? []
            if !rows.isEmpty { sampleRowFetches += 1 }
            lock.unlock()
            return Reply(status: 200, body: Self.json([["samples": rows]]))
        }

        lock.lock()
        let rows = recordingRows
        lock.unlock()
        let ordered = rows.sorted { lhs, rhs in
            let left = (lhs["updated_at"] as? String) ?? ""
            let right = (rhs["updated_at"] as? String) ?? ""
            if left != right { return left < right }
            return ((lhs["id"] as? String) ?? "") < ((rhs["id"] as? String) ?? "")
        }
        return Reply(status: 200, body: Self.json(ordered))
    }

    /// A decaying maximal hold: `meanMaxForce` at short windows is well above
    /// the asymptote, so the critical-force regression and the Hill capability
    /// fit both exist, exactly as they do for real maximal holds.
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

private final class FakeZoneCurveProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeZoneCurvePostgREST?

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

import Foundation
import SwiftUI
import UIKit
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import SendmeterWeather
import Supabase

/// #920 AC6 + #923 AC4: the sync surface as RENDERED — the real Settings screen
/// (scrolled to its sync section) and a real affected editor (Manage Exercises)
/// at light, dark, and accessibility text sizes.
///
/// The views are hosted in a real `UIWindow` on the app's own scene, laid out,
/// scrolled and captured from the layer, which is the only way to render the
/// REAL `SettingsView` body (a bare `SettingsView().aboutSupportSection` read
/// happens outside a view installation and SwiftUI refuses it).
///
/// This is rendered evidence, not device evidence: the frames are written into
/// the app container and copied out to `docs/evidence/issue-920/`. The
/// physical-device VoiceOver pass stays OPEN.
final class SyncSurfacesRenderEvidenceTests: XCTestCase {
    private let userID = UUID()
    private let today = LocalDateSupport.string(from: Date())
    /// The capture order printed in the run log; the evidence doc maps it to
    /// the frame file names.
    private var frameIndex = 0

    @MainActor
    func testCaptureSettingsAndEditorFrames() async throws {
        let server = SyncSurfacesFakePostgREST()
        // A real recording so Manage Exercises has an exercise to manage, and
        // a settings row so the first-sync create-default path is out of play.
        server.setRows("tindeq_recordings", [Self.recordingRow(date: today, tag: "Crimp")])
        server.setRows("user_settings", [Self.settingsRow(phase: "capacity", start: today)])
        server.setRows("phase_periods", [Self.periodRow(phase: "capacity", startedOn: today)])
        let model = try await makeModel(server: server)
        await model.refreshAll(showSpinner: false)

        // Mixed pending work: three cache-only residues from an older version
        // (a health row, a preset, and a hidden exercise) plus a
        // settings/training-block residue a retry cannot move, so the frames
        // show BOTH the retryable state and the honest blocked state.
        let metric = Self.metric(date: LocalDateSupport.daysAgo(1), readiness: 58)
        try writeResidue(metric, entityType: .healthMetrics, entityID: metric.date)
        let preset = Self.preset(name: "Render Hang")
        try writeResidue(preset, entityType: .presets, entityID: CacheEntityID.preset(preset))
        let hidden = TagMetadata(name: "Crimp", hidden: true)
        try writeResidue(hidden, entityType: .tagMetadata, entityID: CacheEntityID.tagMetadata(hidden))
        let period = PhasePeriod(id: UUID(), phase: .strength, startedOn: today, endedOn: nil)
        try writeResidue(
            period,
            entityType: .phasePeriods,
            entityID: period.id.uuidString.lowercased()
        )
        try writeResidue(
            UserSettings(currentPhase: .strength, phaseStartDate: today),
            entityType: .settings,
            entityID: CacheEntityID.settings
        )
        await model.refreshAll(showSpinner: false)

        XCTAssertEqual(
            model.mutationSyncStatus.state,
            .awaitingUpload,
            "fixture: the pending frames show the awaiting-upload state"
        )
        XCTAssertGreaterThanOrEqual(model.mutationSyncStatus.pendingCount, 4)
        XCTAssertEqual(model.mutationSyncStatus.retry, .ready)
        XCTAssertNil(model.lastPartialRefreshFailure)

        var frames: [(name: String, image: UIImage)] = []
        frames.append(
            (
                "settings-data-sync-light",
                try capture(SettingsView(), model: model, scheme: .light, typeSize: .large)
            )
        )
        frames.append(
            (
                "settings-data-sync-dark",
                try capture(SettingsView(), model: model, scheme: .dark, typeSize: .large)
            )
        )
        frames.append(
            (
                "settings-data-sync-ax5",
                try capture(
                    SettingsView(),
                    model: model,
                    scheme: .light,
                    typeSize: .accessibility5
                )
            )
        )
        frames.append(
            (
                "tag-editor-pending-light",
                try capture(TagManagerView(), model: model, scheme: .light, typeSize: .large)
            )
        )
        frames.append(
            (
                "tag-editor-pending-dark-ax3",
                try capture(
                    TagManagerView(),
                    model: model,
                    scheme: .dark,
                    typeSize: .accessibility3
                )
            )
        )

        // One retry pass (the button's dispatch): the resolvable residues land,
        // the settings/training-block residue survives with nothing queued —
        // so the next frames show the disabled retry and its explanation.
        await model.retryAllQueuedWrites()
        XCTAssertNotNil(model.lastRetryOutcome, "fixture: the retry pass published its outcome")
        XCTAssertGreaterThan(
            model.lastRetryOutcome?.unresolvedResidueCount ?? 0,
            0,
            "fixture: a residue survived the pass"
        )
        frames.append(
            (
                "settings-retry-blocked-light",
                try capture(SettingsView(), model: model, scheme: .light, typeSize: .large)
            )
        )

        // #923 AC4: an explicit refresh that published some slices and failed
        // others reports the failed sections here, scoped, with its own retry.
        server.failRequests(to: "health_metrics")
        await model.refreshAll()
        XCTAssertNotNil(model.lastPartialRefreshFailure, "fixture: the partial failure is recorded")
        frames.append(
            (
                "settings-partial-refresh-dark-ax3",
                try capture(
                    SettingsView(),
                    model: model,
                    scheme: .dark,
                    typeSize: .accessibility3
                )
            )
        )

        let directory = try Self.evidenceOutputDirectory()
        for frame in frames {
            guard let data = frame.image.pngData() else {
                throw RenderEvidenceError.encodingFailed(frame.name)
            }
            try data.write(to: directory.appendingPathComponent("\(frame.name).png"))
        }
    }

    // MARK: - Hosted capture

    private enum RenderEvidenceError: Error {
        case encodingFailed(String)
        case noWindowScene
    }

    /// Hosts the REAL view in a real window on the app's scene, scrolls the
    /// hosting list to its end (so the sync section is on screen), lays it out
    /// and renders the window layer at 3×.
    @MainActor
    private func capture<V: View>(
        _ view: V,
        model: AppModel,
        scheme: UIUserInterfaceStyle,
        typeSize: DynamicTypeSize
    ) throws -> UIImage {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw RenderEvidenceError.noWindowScene
        }
        let size = CGSize(width: 402, height: 874) // iPhone 17 Pro logical size
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme
        let hosting = UIHostingController(
            rootView: view
                .environment(model)
                .environmentObject(AppThemeController())
                .environment(\.dynamicTypeSize, typeSize)
        )
        hosting.overrideUserInterfaceStyle = scheme
        hosting.view.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        var scrollReport = "no-scroll"
        if let scroll = Self.firstScrollView(in: hosting.view) {
            scroll.layoutIfNeeded()
            let bottom = max(
                0,
                scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom
            )
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            window.layoutIfNeeded()
            scrollReport = "content=\(Int(scroll.contentSize.height))pt offset=\(Int(scroll.contentOffset.y))pt"
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        // A SwiftUI `List` is UICollectionView-backed: its cells only appear in
        // a real screen render, so capture the window hierarchy (after screen
        // updates) instead of the bare layer tree.
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        frameIndex += 1
        print(
            "EVIDENCE_FRAME #\(frameIndex) \(Int(image.size.width))x\(Int(image.size.height))px scheme=\(scheme.rawValue) type=\(typeSize) \(scrollReport)"
        )
        return image
    }

    @MainActor
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scroll = subview as? UIScrollView {
                return scroll
            }
            if let nested = firstScrollView(in: subview) {
                return nested
            }
        }
        return nil
    }

    // MARK: - Harness

    @MainActor
    private func makeModel(server: SyncSurfacesFakePostgREST) async throws -> AppModel {
        let suite = "SyncSurfacesRenderEvidenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = SyncSurfacesInMemoryAuthStorage()
        let session = Self.makeSession(userID: userID)
        try storage.store(
            key: "sb-example-auth-token",
            value: JSONEncoder().encode(session)
        )
        let client = SupabaseClient(
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
        let model = AppModel(
            auth: auth,
            repository: repository,
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession())
        )
        var waited = 0
        while model.currentUserID == nil, waited < 400 {
            waited += 1
            await Task.yield()
        }
        XCTAssertNotNil(model.currentUserID, "seeded auth session never became currentUserID")
        return model
    }

    private func writeResidue<Value: Encodable>(
        _ value: Value,
        entityType: LocalCacheEntityType,
        entityID: String
    ) throws {
        let store = try LocalCacheStore(databaseURL: Self.cacheDatabaseURL())
        try store.upsertLocal(
            value,
            accountUserID: userID,
            entityType: entityType,
            entityID: entityID
        )
    }

    private static func evidenceOutputDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("sync-evidence", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func cacheDatabaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SendmeterNative", isDirectory: true)
            .appendingPathComponent("local-cache.sqlite", isDirectory: false)
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

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func recordingRow(date: String, tag: String) -> [String: Any] {
        [
            "id": UUID().uuidString.lowercased(),
            "deleted_at": NSNull(),
            "updated_at": timestamp(),
            "recorded_at": "\(date)T09:00:00.000Z",
            "duration_ms": 120_000,
            "peak_kg": 52.5,
            "avg_kg": 41.0,
            "sample_count": 600,
            "note": NSNull(),
            "tag": tag,
            "side": "both",
            "group_id": NSNull(),
            "protocol_run_id": NSNull(),
            "set_no": 1,
            "zone": "strength",
            "source": "manual",
            "external_load_kg": NSNull(),
            "outcome": NSNull(),
            "planned_duration_ms": NSNull(),
            "actual_duration_ms": NSNull(),
            "rep_no": 1,
            "protocol_mode": NSNull(),
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
        ]
    }

    private static func settingsRow(phase: String, start: String) -> [String: Any] {
        [
            // A non-null user_id: it is the settings delta's tie-break.
            "user_id": UUID().uuidString.lowercased(),
            "current_phase": phase,
            "phase_start_date": start,
            "updated_at": timestamp(),
        ]
    }

    private static func periodRow(phase: String, startedOn: String) -> [String: Any] {
        [
            "id": UUID().uuidString.lowercased(),
            "phase": phase,
            "started_on": startedOn,
            "ended_on": NSNull(),
            "updated_at": timestamp(),
            "deleted_at": NSNull(),
        ]
    }

    private static func metric(date: String, readiness: Int) -> HealthMetric {
        HealthMetric(
            date: date,
            readiness: readiness,
            zone: "recover",
            computedAt: Date(),
            hrvSDNNMilliseconds: 41.25,
            restingHeartRate: 50,
            sleepHours: 7.5,
            sleepDeepHours: 1.1,
            sleepREMHours: 1.6,
            bodyMassKilograms: 70,
            respiratoryRate: 14
        )
    }

    private static func preset(name: String) -> TindeqPreset {
        TindeqPreset(
            id: UUID(),
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

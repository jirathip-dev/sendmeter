import SwiftUI
import UIKit
import XCTest

@_spi(Experimental) import Auth
import SendmeterCore
import SendmeterWeather
import Supabase

@testable import Sendmeter

/// #921: the local cache is opened and migrated off the launch path, and a
/// store that is slow, missing or broken is reported honestly instead of
/// silently starving the app of its cache.
///
/// These are the app-level proofs: they drive a real `AppModel` with a real
/// (file-backed, migrated) store, and the storage side is held open by the
/// injected opener so "the store is still opening" is a state the test
/// controls rather than a timing race.
@MainActor
final class CachePreparationAppTests: XCTestCase {
    // MARK: - Doubles

    /// Records each opener invocation from *inside* the opener's own executor.
    private actor OpenLog {
        private(set) var invocationCount = 0
        private(set) var mainThreadFlags: [Bool] = []

        func record(onMainThread: Bool) {
            invocationCount += 1
            mainThreadFlags.append(onMainThread)
        }
    }

    /// The storage side of the opener: blocked until the test opens it. The
    /// `autoRelease` fallback in the tests exists so a build that *does* block
    /// the main actor fails an assertion instead of hanging the test run.
    private actor Gate {
        private var isOpen = false
        private var hasEntry = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            hasEntry = true
            let entries = entryWaiters
            entryWaiters = []
            entries.forEach { $0.resume() }
            if isOpen { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitForEntry() async {
            if hasEntry { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            isOpen = true
            let waiters = openWaiters
            openWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    /// One-way failure switch for an opener that must break once.
    private actor OpenFailureSwitch {
        private var pendingFailures: Int

        init(failures: Int) {
            self.pendingFailures = failures
        }

        func consumeFailure() -> Bool {
            guard pendingFailures > 0 else { return false }
            pendingFailures -= 1
            return true
        }
    }

    private enum OpenError: Error {
        case unreadable
    }

    /// A store file in a per-test directory, so nothing here touches the app
    /// container the other app-target suites share.
    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-prep-\(UUID().uuidString).sqlite")
    }

    private func autoRelease(_ gate: Gate, after seconds: UInt64) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            await gate.open()
        }
    }

    // MARK: - AC1: init does not block on storage; the first frame still renders

    func testTheFirstFrameRendersWhileStorageIsStillOpening() async throws {
        let log = OpenLog()
        let gate = Gate()
        let databaseURL = makeDatabaseURL()
        let seams = CacheStorageSeams(openStore: { _ in
            await log.record(onMainThread: isRunningOnMainThreadLocally())
            await gate.wait()
            return try LocalCacheStore(databaseURL: databaseURL)
        })
        let release = autoRelease(gate, after: 6)
        defer { release.cancel() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        let start = Date()
        let model = makeModel(seams: seams)
        let initSeconds = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            initSeconds,
            3.0,
            "AppModel.init must not wait on the store (measured \(initSeconds)s)"
        )
        XCTAssertEqual(model.cacheReadiness, .preparing)
        XCTAssertFalse(model.hasLoadedSessions, "an unopened cache cannot claim history")
        XCTAssertFalse(model.hasLoadedRecordings)

        await gate.waitForEntry()
        let attemptsWhileOpening = await model.cacheOpenAttempts()
        XCTAssertEqual(attemptsWhileOpening, 1)

        // The app's first frame — the `.loading` branch of the real `RootView`
        // — is drawn while the store is STILL opening.
        let frame = try renderRootView(model: model)
        XCTAssertEqual(model.cacheReadiness, .preparing, "storage must still be opening")
        XCTAssertGreaterThan(
            frame.distinctColors,
            1,
            "the first frame must contain actual content, not a blank buffer"
        )
        let attachment = XCTAttachment(data: frame.image.pngData() ?? Data())
        attachment.name = "first-frame"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Only now does storage answer.
        await gate.open()
        await model.prepareCacheIfNeeded()
        XCTAssertEqual(model.cacheReadiness, .ready)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "the flight is what creates and migrates the store"
        )
        let invocations = await log.invocationCount
        XCTAssertEqual(invocations, 1)
        let flags = await log.mainThreadFlags
        XCTAssertEqual(flags, [false], "directory + open + migration never run on the main actor")
    }

    /// The rendered, non-blank first frame of the real root view.
    private struct RenderedFrame {
        let image: UIImage
        let distinctColors: Int
    }

    private func renderRootView(model: AppModel) throws -> RenderedFrame {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        }
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(
            // The `.loading` branch of the app's real root view is the splash
            // this frame captures.
            rootView: RootView()
                .environment(model)
                .environmentObject(AppThemeController())
        )
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data else {
            throw OpenError.unreadable
        }
        guard let bytes = CFDataGetBytePtr(data) else {
            throw OpenError.unreadable
        }
        let byteCount = CFDataGetLength(data)
        var seen = Set<UInt32>()
        let pixelStep = 4
        var index = 0
        while index + 3 < byteCount {
            let color = UInt32(bytes[index]) << 16
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2])
            seen.insert(color)
            index += pixelStep
            if seen.count > 4096 { break }
        }
        return RenderedFrame(image: image, distinctColors: seen.count)
    }

    // MARK: - AC2: one flight, shared by the cache-backed entrypoints

    func testConcurrentEntrypointsShareOnePreparationFlight() async throws {
        let log = OpenLog()
        let gate = Gate()
        let databaseURL = makeDatabaseURL()
        let seams = CacheStorageSeams(openStore: { _ in
            await log.record(onMainThread: isRunningOnMainThreadLocally())
            await gate.wait()
            return try LocalCacheStore(databaseURL: databaseURL)
        })
        let release = autoRelease(gate, after: 6)
        defer { release.cancel() }

        let model = makeModel(seams: seams)
        await gate.waitForEntry()
        // The bootstrap's join, the foreground pass's join and a second boot
        // all reach the same flight while it is still running.
        async let bootstrapJoin: Void = model.prepareCacheIfNeeded()
        async let foregroundJoin: Void = model.prepareCacheIfNeeded()
        _ = await (bootstrapJoin, foregroundJoin)

        await gate.open()
        await model.prepareCacheIfNeeded()
        XCTAssertEqual(model.cacheReadiness, .ready)

        let invocations = await log.invocationCount
        XCTAssertEqual(invocations, 1, "three entrypoints must share one open")
        let attempts = await model.cacheOpenAttempts()
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - AC4: an unopenable store is honest, recoverable and never a success claim

    func testAFailingOpenerSurfacesUnavailableAndNeverClaimsLocalPersistence() async throws {
        let failures = OpenFailureSwitch(failures: 1)
        let databaseURL = makeDatabaseURL()
        let seams = CacheStorageSeams(openStore: { _ in
            if await failures.consumeFailure() { throw OpenError.unreadable }
            return try LocalCacheStore(databaseURL: databaseURL)
        })
        let model = makeModel(seams: seams)

        await model.prepareCacheIfNeeded()
        guard case .unavailable(.openFailed(let detail)) = model.cacheReadiness else {
            return XCTFail("expected an honest unavailable state, got \(model.cacheReadiness)")
        }
        XCTAssertFalse(detail.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        // Nothing may report a local persistence success from a cache that
        // never answered.
        XCTAssertEqual(model.mutationSyncStatus.state, .notLoaded)
        XCTAssertEqual(model.mutationSyncStatus.statusLabel, "Checking…")
        XCTAssertFalse(model.hasLoadedSessions)
        XCTAssertFalse(model.hasLoadedRecordings)

        // …and the failure is recoverable: the next entrypoint's flight opens
        // the store, and the cache then reports what it really holds.
        await model.prepareCacheIfNeeded()
        XCTAssertEqual(model.cacheReadiness, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let attempts = await model.cacheOpenAttempts()
        XCTAssertEqual(attempts, 2)
    }

    // MARK: - AC2 wiring: every cache-backed entrypoint joins the one flight

    func testEveryCacheBackedEntrypointJoinsThePreparationFlight() throws {
        // Supplementary to the behavioural proofs above: this asserts the
        // call-graph shape that the anonymous entrypoint tests cannot reach
        // (the signed-in bootstrap branch, and the background app-refresh).
        let source = try Self.appModelSource()
        for marker in [
            "await prepareCacheIfNeeded()",
        ] {
            XCTAssertGreaterThan(
                source.components(separatedBy: marker).count - 1,
                1,
                "\(marker) must be used by more than one entrypoint"
            )
        }
        XCTAssertTrue(
            source.contains(
                "await prepareCacheIfNeeded()\n                "
                    + "// Adopt persisted watch summaries"
            ),
            "the signed-in bootstrap branch must join the flight before cache-backed adoption"
        )
        XCTAssertTrue(
            source.contains("await prepareCacheIfNeeded()\n        guard let workspace = cachedWorkspace"),
            "the background app-refresh must join the flight before using the store"
        )
    }

    private static func appModelSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/AppModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// A hermetic `AppModel`: no live project, no shared keychain, and the session
/// storage is per-instance. These tests never sign in, so nothing here reaches
/// the network or the app container's keychain.
@MainActor
private func makeModel(seams: CacheStorageSeams) -> AppModel {
        let suite = "CachePreparationAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let server = CachePreparationProbePostgREST()
        let storage = CachePreparationInMemoryAuthStorage()
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
        let repository = SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                apiKey: "test-key",
                sessionProvider: { throw CachePreparationTestError.noSession },
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
        return AppModel(
            auth: auth,
            repository: repository,
            realtime: RealtimeService(client: client),
            weather: WeatherService(defaults: defaults, session: server.makeURLSession()),
            cacheStorageSeams: seams
        )
    }

/// Synchronous on purpose: `Thread.isMainThread` is unavailable from async
/// contexts (an error in the Swift 6 language mode) and the openers are async.
private func isRunningOnMainThreadLocally() -> Bool {
    Thread.isMainThread
}

private enum CachePreparationTestError: Error {
    case noSession
}

/// Answers every request with an authoritative empty delta, so nothing in this
/// file can reach a live service.
private final class CachePreparationProbePostgREST: @unchecked Sendable {
    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachePreparationProbeProtocol.self]
        CachePreparationProbeProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest) -> (status: Int, body: Data)? {
        if request.url?.path.contains("generation") == true {
            return (200, Data("0".utf8))
        }
        return (200, Data("[]".utf8))
    }
}

private final class CachePreparationProbeProtocol: URLProtocol {
    static var server: CachePreparationProbePostgREST?

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

private final class CachePreparationInMemoryAuthStorage: AuthLocalStorage {
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

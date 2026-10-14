import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import Supabase

/// #1021 (rollout #1028 slice 2): the Force tab's auto-reconnect, through the
/// REAL AppModel entry points (`autoReconnectProgressor`, `scenePhaseChanged`,
/// `requestDisconnect`, `requestConnect`). The transport side is the
/// `ProgressorLink` seam: a simulator has no Bluetooth radio, so a recording
/// fake stands in for `TindeqBluetooth` and counts reconnect requests.
///
/// Rules (each has its own test, so a mutation of one rule fails one test):
///   1. reconnect the last Progressor on entering Force and on foreground;
///   2. NOT after a user disconnect (until the next explicit Connect);
///   3. NOT mid-session (guided protocol, hands-free arm, live pull).
@MainActor
final class ForceAutoReconnectAppTests: XCTestCase {
    /// The recording transport fake.
    @MainActor
    private final class FakeProgressorLink {
        var status: TindeqBluetooth.Status = .idle
        var hasKnownProgressor = true
        private(set) var reconnects = 0

        func install(on model: AppModel) {
            model.progressorLink = AppModel.ProgressorLink(
                status: { [unowned self] in status },
                hasKnownProgressor: { [unowned self] in hasKnownProgressor },
                reconnect: { [unowned self] in reconnects += 1 }
            )
        }
    }

    private func makeModel(selectedTab: AppTab = .force) -> (AppModel, FakeProgressorLink) {
        let model = AppModel(
            auth: makeAuthService(),
            repository: makeRepository(),
            realtime: RealtimeService(client: makeSupabaseClient(storage: InMemoryAuthStorage()))
        )
        let link = FakeProgressorLink()
        link.install(on: model)
        model.selectedTab = selectedTab
        return (model, link)
    }

    // MARK: Rule 1 — entering Force and foreground reconnect

    func testEnteringForceReconnectsTheLastProgressor() {
        let (model, link) = makeModel()
        XCTAssertTrue(model.autoReconnectProgressor(.enteredForce))
        XCTAssertEqual(link.reconnects, 1)

        // A dropped link reconnects too.
        link.status = .interrupted("Progressor disconnected")
        XCTAssertTrue(model.autoReconnectProgressor(.enteredForce))
        XCTAssertEqual(link.reconnects, 2)
    }

    func testForegroundOnForceReconnectsThroughScenePhase() {
        let (model, link) = makeModel()
        model.scenePhaseChanged(.active)
        XCTAssertEqual(link.reconnects, 1, "foreground on the Force tab reconnects the last Progressor")
    }

    func testForegroundOnAnotherTabLeavesTheProgressorAlone() {
        let (model, link) = makeModel(selectedTab: .dashboard)
        model.scenePhaseChanged(.active)
        XCTAssertEqual(link.reconnects, 0)
    }

    func testNothingToReconnectWithoutAKnownProgressorOrWhenLinked() {
        let (model, link) = makeModel()
        link.hasKnownProgressor = false
        XCTAssertFalse(model.autoReconnectProgressor(.enteredForce))
        link.hasKnownProgressor = true
        for status in [TindeqBluetooth.Status.connected, .measuring, .connecting, .scanning, .unavailable] {
            link.status = status
            XCTAssertFalse(model.autoReconnectProgressor(.enteredForce), "\(status)")
        }
        XCTAssertEqual(link.reconnects, 0)
    }

    // MARK: Rule 2 — never after a user disconnect

    func testUserDisconnectStopsAutoReconnectUntilTheNextConnect() {
        let (model, link) = makeModel()
        model.requestDisconnect()
        XCTAssertTrue(model.userDisconnectedProgressor)
        XCTAssertFalse(model.autoReconnectProgressor(.enteredForce))
        model.scenePhaseChanged(.active)
        XCTAssertEqual(link.reconnects, 0, "a user Disconnect must not be undone by entering Force or foreground")

        // The next explicit Connect clears it.
        model.requestConnect()
        XCTAssertFalse(model.userDisconnectedProgressor)
        model.tindeq.disconnect() // stop the real transport's scan request
        XCTAssertTrue(model.autoReconnectProgressor(.enteredForce))
        XCTAssertEqual(link.reconnects, 1)
    }

    // MARK: Rule 3 — never mid-session

    func testGuidedProtocolBlocksAutoReconnect() {
        let (model, link) = makeModel()
        link.status = .interrupted("Progressor disconnected")
        model.setGuidedProtocolActive(true)
        XCTAssertFalse(model.autoReconnectProgressor(.enteredForce))
        model.scenePhaseChanged(.active)
        XCTAssertEqual(link.reconnects, 0, "a running guided protocol owns the device and its interrupted path")
        model.setGuidedProtocolActive(false)
        XCTAssertTrue(model.autoReconnectProgressor(.enteredForce))
    }

    func testHandsFreeArmBlocksAutoReconnect() {
        let (model, link) = makeModel()
        model.handsFree.onArmStream = {}
        model.handsFree.arm()
        XCTAssertTrue(model.handsFree.isArmed)
        XCTAssertFalse(model.autoReconnectProgressor(.enteredForce))
        XCTAssertEqual(link.reconnects, 0)
    }

    // MARK: P11 — "Connection lost" only for a dropped live link

    func testOnlyADroppedLiveLinkReadsAsConnectionLost() {
        let (model, link) = makeModel()
        // A cold launch with Bluetooth off / a failed first connect:
        // `.interrupted` with no live link before it — plain Disconnected.
        link.status = .interrupted("Progressor connection failed")
        XCTAssertEqual(model.forceBarDevice, .disconnected)
        XCTAssertFalse(model.progressorConnectionLost)

        // A live link that drops: "Connection lost" (through the real
        // transport status callback).
        model.tindeq.onStatusChange?(.connected)
        model.tindeq.onStatusChange?(.interrupted("Progressor disconnected"))
        link.status = .interrupted("Progressor disconnected")
        XCTAssertTrue(model.progressorConnectionLost)
        XCTAssertEqual(model.forceBarDevice, .interrupted)
        XCTAssertEqual(ForceBarPolicy.state(ForceBarInput(device: model.forceBarDevice, mode: .guided)).status, "Connection lost")

        // A duplicate `.interrupted` (#656) keeps the verdict; a reconnect
        // attempt keeps it too; a live link clears it.
        model.tindeq.onStatusChange?(.interrupted("Bluetooth is off"))
        XCTAssertTrue(model.progressorConnectionLost)
        model.tindeq.onStatusChange?(.connecting)
        XCTAssertTrue(model.progressorConnectionLost)
        model.tindeq.onStatusChange?(.connected)
        XCTAssertFalse(model.progressorConnectionLost)
    }

    func testUserDisconnectIsNeverConnectionLost() {
        let (model, link) = makeModel()
        model.requestDisconnect()
        // On a device the transport is still `.connected` when the user's
        // Disconnect cancels the link, and CoreBluetooth then reports the
        // drop as `.interrupted`. (The simulator's transport has no
        // peripheral, so replay that order through the status callback.)
        model.tindeq.onStatusChange?(.connected)
        model.tindeq.onStatusChange?(.interrupted("Progressor disconnected"))
        link.status = .interrupted("Progressor disconnected")
        XCTAssertFalse(model.progressorConnectionLost)
        XCTAssertEqual(model.forceBarDevice, .disconnected)
    }

    func testProgressorStatusMapsToTheBarDevice() {
        XCTAssertEqual(TindeqBluetooth.Status.idle.forceBarDevice, .disconnected)
        XCTAssertEqual(TindeqBluetooth.Status.interrupted("x").forceBarDevice, .interrupted)
        XCTAssertEqual(TindeqBluetooth.Status.unavailable.forceBarDevice, .bluetoothOff)
        XCTAssertEqual(TindeqBluetooth.Status.scanning.forceBarDevice, .connecting)
        XCTAssertEqual(TindeqBluetooth.Status.connecting.forceBarDevice, .connecting)
        XCTAssertEqual(TindeqBluetooth.Status.connected.forceBarDevice, .connected)
        XCTAssertEqual(TindeqBluetooth.Status.measuring.forceBarDevice, .measuring)
    }

    // MARK: - In-memory auth seam (mirrors GuidedForceSideBehaviorTests)

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
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("[]".utf8))
            client.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
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

    private func makeAuthService() -> AuthService {
        let suite = "ForceAutoReconnectAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AuthService(
            client: makeSupabaseClient(storage: InMemoryAuthStorage()),
            diagnostics: AuthDiagnosticsStore(fileURL: nil),
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            sessionGuard: AuthSessionGuardStore(defaults: defaults, keyPrefix: suite + ".guard")
        )
    }

    private func makeRepository() -> SendmeterRepository {
        let suite = "ForceAutoReconnectAppTests.repo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = {
            throw AuthError.sessionMissing
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
}

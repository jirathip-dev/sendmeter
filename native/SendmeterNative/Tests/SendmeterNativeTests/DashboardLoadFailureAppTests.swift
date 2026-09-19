import Foundation
import SendmeterCore
import SwiftUI
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import Supabase

/// #964: first launch after updating showed the generic "Something went
/// wrong" banner over an empty Dashboard. The device trigger itself stays
/// OPEN (it needs a device console capture of a launch-after-update with the
/// previous build's cache/queue state), so this suite pins the provable half
/// at the app boundary, driving a REAL `AppModel` against a stubbed
/// PostgREST transport:
///
/// * a failed account-data load is classified — a `DecodingError` is no
///   longer `.unknown` — and the banner carries the fixed, user-safe copy,
/// * the failure is retained on the model AFTER the dismissible banner is
///   gone (and when it was never shown), and the Dashboard's failure rule
///   renders from that retained state, so dismissing the banner cannot leave
///   a silently blank screen,
/// * a retry that succeeds clears the failure and publishes authoritative
///   data again,
/// * with last-good data on screen the same failure stays off the Dashboard
///   body (the #842 boundary) and only the banner speaks,
/// * the failure component paints its message and retry button — measured by
///   rendering the production component against a blank-card control.
final class DashboardLoadFailureAppTests: XCTestCase {
    /// A fresh account per test: the cache and queue are account-scoped files
    /// in the app container, so a shared user id would leak rows between tests.
    private let userID = UUID()

    // MARK: - AC: classified copy + a failure state that survives dismissal

    @MainActor
    func testFailedLoadClassifiesAndTheDashboardKeepsItsFailurePastDismissal() async throws {
        let server = FakeDashboardPostgREST()
        let model = try await makeSignedInModel(server: server)
        server.setMode(.malformed)

        await model.refreshAll()
        try await waitForLoadedFailure(model)

        // The banner copy is the CLASSIFIED one — not the generic fallback
        // the owner saw on the device.
        XCTAssertEqual(
            model.errorMessage,
            UserFacingError.message(for: .dataUnreadable),
            "a decode failure must surface the truthful class copy"
        )
        XCTAssertNotEqual(
            model.errorMessage,
            UserFacingError.message(for: .unknown)
        )
        XCTAssertEqual(model.dashboardLoadFailureClass, .dataUnreadable)
        XCTAssertTrue(model.showsDashboardLoadFailure)
        XCTAssertFalse(model.hasLoadedSessions, "fixture: the load never published data")

        // Dismissing the banner (the only affordance the owner had) must not
        // leave the Dashboard with an empty screen and no explanation.
        model.errorMessage = nil
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.dashboardLoadFailureClass, .dataUnreadable)
        XCTAssertTrue(
            model.showsDashboardLoadFailure,
            "the Dashboard's failure state must outlive the banner"
        )
    }

    // MARK: - AC: the retry re-runs the failed step and clears the state

    @MainActor
    func testSuccessfulRetryClearsTheDashboardFailureState() async throws {
        let server = FakeDashboardPostgREST()
        let model = try await makeSignedInModel(server: server)
        server.setMode(.malformed)

        await model.refreshAll()
        try await waitForLoadedFailure(model)
        XCTAssertTrue(model.showsDashboardLoadFailure)

        server.setMode(.empty)
        await model.refreshAll()

        XCTAssertNil(model.dashboardLoadFailureClass)
        XCTAssertFalse(model.showsDashboardLoadFailure)
        XCTAssertTrue(model.hasLoadedSessions, "the refresh published authoritative data")
    }

    // MARK: - AC: last-good data keeps the Dashboard body, banner only

    @MainActor
    func testFailureWithLastGoodDataStaysOffTheDashboardBody() async throws {
        let server = FakeDashboardPostgREST()
        let model = try await makeSignedInModel(server: server)

        await model.refreshAll()
        XCTAssertTrue(model.hasLoadedSessions, "fixture: the first load publishes")

        server.setMode(.malformed)
        await model.refreshAll()
        try await waitForLoadedFailure(model)

        XCTAssertEqual(model.dashboardLoadFailureClass, .dataUnreadable)
        XCTAssertEqual(
            model.errorMessage,
            UserFacingError.message(for: .dataUnreadable)
        )
        XCTAssertFalse(
            model.showsDashboardLoadFailure,
            "the last-good Dashboard stays on screen; only the banner speaks"
        )
    }

    // MARK: - AC: the component paints real content, not a blank card

    @MainActor
    func testFailureCardPaintsMessageAndRetryInsteadOfABlankCard() throws {
        let card = renderCard(
            DashboardLoadFailureCard(failureClass: .dataUnreadable, retry: {})
        )
        let blank = renderCard(
            SurfaceCard {
                Color.clear.frame(height: 220)
            }
        )

        // Validate the metric against a known-blank control before trusting
        // the assertion below (a metric that reports ink for a blank card
        // would fake this proof).
        XCTAssertLessThan(
            blank.inkFraction,
            0.005,
            "the ink metric must read a blank card as blank (measured \(blank.inkFraction))"
        )
        XCTAssertGreaterThan(
            card.inkFraction,
            0.015,
            "the failure card must paint its copy and retry (measured \(card.inkFraction))"
        )
        XCTAssertGreaterThan(
            card.inkRows,
            20,
            "the card must paint many rows of content (measured \(card.inkRows))"
        )
        // The message sits above the retry: ink in both the upper and the
        // lower band is what a blank card cannot produce.
        XCTAssertGreaterThan(card.inkRowsInTopHalf, 10, "message band")
        XCTAssertGreaterThan(card.inkRowsInBottomHalf, 5, "retry band")

        // Accessibility sizes wrap the same copy into more lines; dark mode
        // must not clip what light mode paints.
        let ax = renderCard(
            DashboardLoadFailureCard(failureClass: .dataUnreadable, retry: {}),
            dynamicType: .accessibility5
        )
        let axDark = renderCard(
            DashboardLoadFailureCard(failureClass: .dataUnreadable, retry: {}),
            dynamicType: .accessibility5,
            colorScheme: .dark
        )
        XCTAssertGreaterThan(
            ax.height,
            card.height,
            "accessibility text sizes must grow the card, not clip it"
        )
        XCTAssertEqual(
            ax.height,
            axDark.height,
            accuracy: 1,
            "dark mode must not clip what light mode paints"
        )
    }

    // MARK: - AC wiring: the Dashboard leads with the failure and retries it

    func testDashboardLeadsWithTheFailureStateAndRetriesTheFailedRefresh() throws {
        let view = try Self.source("Sources/Features/Dashboard/DashboardView.swift")
        let failureLead = try XCTUnwrap(view.range(of: "if model.showsDashboardLoadFailure"))
        let firstCard = try XCTUnwrap(view.range(of: "TodayDecisionCard(showRecovery:"))
        XCTAssertLessThan(
            failureLead.lowerBound,
            firstCard.lowerBound,
            "the failure state must lead the Dashboard content"
        )
        XCTAssertTrue(
            view.contains("DashboardLoadFailureCard(failureClass: failureClass)"),
            "the Dashboard must render the failure card from the model's classification"
        )
        XCTAssertTrue(
            view.contains("Task { await model.refreshAll() }"),
            "the retry must re-run the refresh that failed"
        )
        XCTAssertTrue(
            view.contains("UserFacingError.message(for: failureClass)"),
            "the component must render fixed copy, never a raw error"
        )
    }

    // MARK: - Model harness (mirrors the other app-target suites' seams)

    @MainActor
    private func waitForLoadedFailure(_ model: AppModel) async throws {
        for _ in 0..<400 {
            if model.dashboardLoadFailureClass != nil, !model.isLoadingData {
                // Allow the bootstrap refresh that shares this account's
                // funnel to settle so the assertions read one final state.
                try? await Task.sleep(nanoseconds: 50_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the load never recorded a failure (last: \(String(describing: model.dashboardLoadFailureClass)))")
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
    private func makeRepository(
        session: Auth.Session,
        server: FakeDashboardPostgREST
    ) -> SendmeterRepository {
        let suite = "DashboardLoadFailureAppTests.repo.\(UUID().uuidString)"
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
        server: FakeDashboardPostgREST,
        userID: UUID? = nil
    ) async throws -> AppModel {
        let accountID = userID ?? self.userID
        let suite = "DashboardLoadFailureAppTests.signed-in.\(UUID().uuidString)"
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

    // MARK: - Rendering (real component, production width)

    private struct RenderedCard {
        let width: CGFloat
        let height: CGFloat
        let inkRows: Int
        let inkFraction: Double
        let inkRowsInTopHalf: Int
        let inkRowsInBottomHalf: Int
    }

    private static let phoneWidth: CGFloat = 375
    /// `DashboardView` pads the card column 16 pt on each side.
    private static let cardWidth: CGFloat = phoneWidth - 32

    @MainActor
    private func renderCard<V: View>(
        _ content: V,
        dynamicType: DynamicTypeSize = .large,
        colorScheme: ColorScheme = .light
    ) -> RenderedCard {
        let renderer = ImageRenderer(
            content: content
                .frame(width: Self.cardWidth)
                .dynamicTypeSize(dynamicType)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage else {
            XCTFail("the card did not render")
            return RenderedCard(
                width: 0,
                height: 0,
                inkRows: 0,
                inkFraction: 0,
                inkRowsInTopHalf: 0,
                inkRowsInBottomHalf: 0
            )
        }
        return Self.measure(image)
    }

    /// Pixel metric: "ink" is a pixel dark enough to be glyph/button content
    /// rather than card material. A row counts once if it carries any ink.
    private static func measure(_ image: UIImage) -> RenderedCard {
        guard let cgImage = image.cgImage else {
            return RenderedCard(
                width: 0,
                height: 0,
                inkRows: 0,
                inkFraction: 0,
                inkRowsInTopHalf: 0,
                inkRowsInBottomHalf: 0
            )
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return RenderedCard(
                width: 0,
                height: 0,
                inkRows: 0,
                inkFraction: 0,
                inkRowsInTopHalf: 0,
                inkRowsInBottomHalf: 0
            )
        }
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        var inkRows = 0
        var inkRowsInTopHalf = 0
        var inkRowsInBottomHalf = 0
        var inkPixels = 0
        for row in 0..<height {
            var rowHasInk = false
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                let alpha = Double(pixels[offset + 3]) / 255
                guard alpha > 0.5 else { continue }
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
                if luminance < 128 {
                    inkPixels += 1
                    rowHasInk = true
                }
            }
            if rowHasInk {
                inkRows += 1
                if row < height / 2 {
                    inkRowsInTopHalf += 1
                } else {
                    inkRowsInBottomHalf += 1
                }
            }
        }
        let totalPixels = Double(width * height)
        return RenderedCard(
            width: image.size.width,
            height: image.size.height,
            inkRows: inkRows,
            inkFraction: totalPixels > 0 ? Double(inkPixels) / totalPixels : 0,
            inkRowsInTopHalf: inkRowsInTopHalf,
            inkRowsInBottomHalf: inkRowsInBottomHalf
        )
    }

    // MARK: - Source helper (duplicated per repo convention)

    private static func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}

// MARK: - Stubbed transport

/// A PostgREST stub that can either answer every table with an authoritative
/// empty result or with a payload whose shape this build cannot decode — the
/// "unexpected data on the launch path" failure the classification gap
/// collapsed into `.unknown`.
private final class FakeDashboardPostgREST: @unchecked Sendable {
    enum Mode {
        /// Well-formed, authoritative empty deltas: a fresh account with no
        /// rows.
        case empty
        /// A 200 whose body does not decode into the requested row type.
        case malformed
    }

    private let lock = NSLock()
    private var mode: Mode = .empty

    func setMode(_ mode: Mode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDashboardProtocol.self]
        FakeDashboardProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest) -> (status: Int, body: Data)? {
        lock.lock()
        let mode = self.mode
        lock.unlock()
        switch mode {
        case .empty:
            return (200, Data("[]".utf8))
        case .malformed:
            // PostgREST answers with a JSON object; every paged delta decodes
            // an array, so this throws a DecodingError inside the repository.
            return (200, Data(#"{"error":"unexpected payload shape"}"#.utf8))
        }
    }
}

private final class FakeDashboardProtocol: URLProtocol {
    nonisolated(unsafe) static var server: FakeDashboardPostgREST?

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
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

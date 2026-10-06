import SwiftUI
import UIKit
import XCTest

import SendmeterCore
import SendmeterWeather
import Supabase

@testable import Sendmeter

/// #927 follow-up (build-57 device report): the Dashboard's large title drew
/// ON TOP of the shared error banner, so the message was not legible.
///
/// These tests mount the REAL tab views (`MainTabView`) inside the REAL banner
/// host `RootView` uses (`ErrorBannerHost`), raise the banner the production
/// way (`model.errorMessage`), and read the laid-out UIKit navigation bar of
/// every tab back from the window. The banner occupies the window's top safe
/// area plus its 8 pt inset and its own rendered height; a navigation bar (and
/// so its large title) that starts above the banner's bottom edge is drawn
/// over the banner. Measured at the default and the largest Dynamic Type size,
/// on whatever phone the suite runs on — layout, not source text.
@MainActor
final class ErrorBannerLargeTitleLayoutTests: XCTestCase {
    /// Every tab, with the large title its navigation stack renders.
    private static let tabs: [(tab: AppTab, title: String)] = [
        (.dashboard, "Dashboard"),
        (.force, "Force"),
        (.workout, "Workout"),
        (.history, "History"),
        (.settings, "Settings"),
    ]

    /// The copy on the owner's build-57 screenshot.
    private static let reportedMessage = UserFacingError.message(for: .dataUnreadable)
    /// The longest failure copy the app can surface.
    private static let longestMessage = UserFacingError.message(for: .authClockSkew)

    func testEveryLargeTitleLaysOutBelowTheBannerAtTheDefaultTextSize() throws {
        try assertEveryLargeTitleClearsTheBanner(
            contentSize: .large,
            dynamicType: .large
        )
    }

    func testEveryLargeTitleLaysOutBelowTheBannerAtTheLargestTextSize() throws {
        try assertEveryLargeTitleClearsTheBanner(
            contentSize: .accessibilityExtraExtraExtraLarge,
            dynamicType: .accessibility5
        )
    }

    /// At the largest text size the whole banner — message and dismiss
    /// control — must still sit inside the visible screen, or part of the
    /// message is unreadable no matter what is under it.
    func testTheLongestCopyStaysOnScreenAtTheLargestTextSize() throws {
        let host = try BannerTabHost(contentSize: .accessibilityExtraExtraExtraLarge)
        defer { host.tearDown() }
        let safeArea = host.window.safeAreaInsets
        let visibleBottom = host.window.bounds.height - safeArea.bottom
        for message in [Self.reportedMessage, Self.longestMessage] {
            let banner = try Self.bannerHeight(
                message,
                width: host.bannerWidth,
                dynamicType: .accessibility5
            )
            let bannerBottom = safeArea.top + 8 + banner
            XCTAssertLessThanOrEqual(
                bannerBottom,
                visibleBottom,
                "the banner (\(banner) pt) must end on screen (bottom \(bannerBottom) pt, visible to \(visibleBottom) pt)"
            )
        }
    }

    // MARK: - Measurement

    private func assertEveryLargeTitleClearsTheBanner(
        contentSize: UIContentSizeCategory,
        dynamicType: DynamicTypeSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = try BannerTabHost(contentSize: contentSize)
        defer { host.tearDown() }
        host.model.errorMessage = Self.reportedMessage
        host.settle()

        let bannerHeight = try Self.bannerHeight(
            Self.reportedMessage,
            width: host.bannerWidth,
            dynamicType: dynamicType
        )
        let bannerBottom = host.window.safeAreaInsets.top + 8 + bannerHeight

        for (tab, title) in Self.tabs {
            host.model.selectedTab = tab
            host.settle()
            let bar = try XCTUnwrap(
                host.visibleNavigationBar(titled: title),
                "no visible navigation bar titled \(title)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                bar.prefersLargeTitles,
                "\(title) must render a large title for this check to mean anything",
                file: file,
                line: line
            )
            let barFrame = bar.convert(bar.bounds, to: host.window)
            XCTAssertGreaterThanOrEqual(
                barFrame.minY,
                bannerBottom - 0.5,
                "\(title)'s navigation bar starts at \(barFrame.minY) pt, inside the banner (bottom \(bannerBottom) pt)",
                file: file,
                line: line
            )
            if let titleLabel = host.largestLabel(titled: title, in: bar) {
                let titleFrame = titleLabel.convert(titleLabel.bounds, to: host.window)
                XCTAssertGreaterThanOrEqual(
                    titleFrame.minY,
                    bannerBottom - 0.5,
                    "\(title)'s large title starts at \(titleFrame.minY) pt, over the banner (bottom \(bannerBottom) pt)",
                    file: file,
                    line: line
                )
            }
        }

        // Dismissing the banner hands the space back to the screen.
        host.model.errorMessage = nil
        host.model.selectedTab = .dashboard
        host.settle()
        let bar = try XCTUnwrap(host.visibleNavigationBar(titled: "Dashboard"))
        XCTAssertEqual(
            bar.convert(bar.bounds, to: host.window).minY,
            host.window.safeAreaInsets.top,
            accuracy: 0.5,
            "with no banner the navigation bar returns to the top safe area",
            file: file,
            line: line
        )
    }

    /// The production banner's real laid-out height at the host's width.
    private static func bannerHeight(
        _ message: String,
        width: CGFloat,
        dynamicType: DynamicTypeSize
    ) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: ErrorBanner(message: message, dismiss: {})
                .dynamicTypeSize(dynamicType)
                .frame(width: width)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage, "banner did not render").size.height
    }

    // MARK: - Hosting

    /// `MainTabView` inside the production banner host, in a real window on
    /// the app's scene, with the content size forced through the window's
    /// traits so the navigation bars and SwiftUI read the same text size.
    @MainActor
    private final class BannerTabHost {
        let window: UIWindow
        let model: AppModel
        private let controller: UIHostingController<AnyView>
        private let databaseURL: URL

        /// RootView insets the banner 16 pt on each side.
        var bannerWidth: CGFloat { window.bounds.width - 32 }

        init(contentSize: UIContentSizeCategory) throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first,
                "the app-target suite needs the host app's window scene"
            )
            databaseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("banner-layout-\(UUID().uuidString).sqlite")
            model = makeBannerLayoutModel(databaseURL: databaseURL)
            controller = UIHostingController(
                rootView: AnyView(
                    ErrorBannerHost { MainTabView() }
                        .environment(model)
                        .environmentObject(model.forceModel)
                        .environmentObject(AppThemeController())
                )
            )
            window = UIWindow(windowScene: scene)
            // The same channel as the Settings text-size slider: SwiftUI's
            // Dynamic Type and the UIKit navigation bars both read it.
            window.traitOverrides.preferredContentSizeCategory = contentSize
            window.rootViewController = controller
            window.makeKeyAndVisible()
            settle()
        }

        /// Two passes: the banner's measured height lands one layout pass
        /// after the banner itself.
        func settle() {
            for _ in 0..<2 {
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                window.layoutIfNeeded()
            }
        }

        func visibleNavigationBar(titled title: String) -> UINavigationBar? {
            Self.descendants(of: window)
                .compactMap { $0 as? UINavigationBar }
                .first { bar in
                    bar.window != nil
                        && !bar.isHidden
                        && bar.alpha > 0.01
                        && bar.topItem?.title == title
                }
        }

        /// The large title is the biggest label carrying the title text.
        func largestLabel(titled title: String, in bar: UINavigationBar) -> UILabel? {
            Self.descendants(of: bar)
                .compactMap { $0 as? UILabel }
                .filter { $0.text == title && !$0.isHidden && $0.alpha > 0.01 }
                .max { $0.font.pointSize < $1.font.pointSize }
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: databaseURL)
        }

        private static func descendants(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap { descendants(of: $0) }
        }
    }
}

// MARK: - Hermetic model

/// A signed-out `AppModel` that reaches no live service: every request is
/// answered locally with an empty body, and the cache is a per-test file.
@MainActor
private func makeBannerLayoutModel(databaseURL: URL) -> AppModel {
    let suite = "ErrorBannerLargeTitleLayoutTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let client = SupabaseClient(
        supabaseURL: URL(string: "https://example.test")!,
        supabaseKey: "test-key",
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                storage: BannerLayoutAuthStorage(),
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
            sessionProvider: { throw URLError(.userAuthenticationRequired) },
            serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
            session: bannerLayoutURLSession()
        )
    )
    return AppModel(
        auth: auth,
        repository: repository,
        realtime: RealtimeService(client: client),
        weather: WeatherService(defaults: defaults, session: bannerLayoutURLSession()),
        cacheStorageSeams: CacheStorageSeams(openStore: { _ in
            try LocalCacheStore(databaseURL: databaseURL)
        })
    )
}

private func bannerLayoutURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BannerLayoutEmptyProtocol.self]
    return URLSession(configuration: configuration)
}

private final class BannerLayoutEmptyProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BannerLayoutAuthStorage: AuthLocalStorage {
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

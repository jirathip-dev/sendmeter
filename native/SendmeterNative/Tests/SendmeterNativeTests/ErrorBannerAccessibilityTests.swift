import SwiftUI
import XCTest
@testable import Sendmeter

/// #927: the shared error banner's accessibility contract, exercised against
/// the REAL `ErrorBanner` in the app-target lane.
///
/// Layout is measured by RENDERING the production component at the production
/// width (smallest supported phone: 375 pt, minus RootView's 16 pt insets) with
/// `ImageRenderer`, so the numbers come from real layout at both normal and
/// accessibility text sizes in light and dark — not from source text. The
/// announcement contract is measured by counting the posts the banner's host
/// makes while the message changes and while the view re-renders.
///
/// Not proven here, and called out in the lane report: a synthetic TAP on the
/// dismiss control. This lane has no touch injection (XCUITest lives in
/// `Tests/SendmeterNativeUITests`, outside this lane's file fence), and
/// SwiftUI's accessibility tree is only materialized for an active assistive
/// client — a unit-test host publishes no elements (measured: an empty walk
/// over the hosted window). The dismiss control's identifier/label wiring and
/// bounded hit region are therefore pinned to the component that the geometry
/// tests measure, and the tap stays OPEN.
@MainActor
final class ErrorBannerAccessibilityTests: XCTestCase {
    /// Real `FriendlyError` copy: a failed save (short) and the longest
    /// failure message the app can surface (the device-clock nudge).
    private static let shortMessage = "Couldn't save this. Try again."
    private static let longMessage = """
    Your iPhone's date and time may be wrong. Turn on Set Automatically in \
    Settings → General → Date & Time, then try again.
    """
    /// The smallest supported phone is the 375 pt iPhone SE (3rd generation) —
    /// also iOS 17's narrowest supported width.
    private static let phoneWidth: CGFloat = 375
    /// RootView insets the banner 16 pt on each side (`.padding(.horizontal)`).
    private static let bannerInset: CGFloat = 16
    private static var bannerWidth: CGFloat { phoneWidth - 2 * bannerInset }

    // MARK: - AC1: the dismiss control is a real 44 pt target

    func testDismissRowReservesTheFullTargetHeight() throws {
        let short = try render(shortMessage: Self.shortMessage, dynamicType: .large)

        // The banner is `.padding(12)` around one HStack row, so a row that
        // reserves the dismiss target is at least 12 + 44 + 12 pt tall. A
        // caption-sized glyph (the pre-fix control) renders ~46 pt, so this
        // fails on the old geometry.
        XCTAssertGreaterThanOrEqual(
            short.height,
            24 + ErrorBannerAccessibility.dismissTarget,
            "the banner must reserve a 44 pt row for the dismiss target (rendered \(short.height) pt)"
        )
        XCTAssertEqual(
            short.width,
            Self.bannerWidth,
            accuracy: 0.5,
            "the banner must fill the phone width, not overflow it"
        )
    }

    // MARK: - AC2: long copy wraps without clipping (small phone, both text sizes)

    func testLongMessageWrapsWithoutClippingAtBothTextSizes() throws {
        let shortLarge = try render(shortMessage: Self.shortMessage, dynamicType: .large)
        let longLarge = try render(shortMessage: Self.longMessage, dynamicType: .large)
        let shortAX = try render(
            shortMessage: Self.shortMessage,
            dynamicType: .accessibility5
        )
        let longAX = try render(shortMessage: Self.longMessage, dynamicType: .accessibility5)
        let longAXDark = try render(
            shortMessage: Self.longMessage,
            dynamicType: .accessibility5,
            colorScheme: .dark
        )

        // The long copy must add several lines to the same banner: a clipping
        // or single-line implementation keeps the height unchanged.
        XCTAssertGreaterThan(
            longLarge.height,
            shortLarge.height + 2 * Self.subheadlineLineHeight(.large),
            "long copy must wrap into multiple lines at normal text sizes"
        )
        XCTAssertGreaterThan(
            longAX.height,
            shortAX.height + 6 * Self.subheadlineLineHeight(.accessibility5),
            "long copy must wrap into many lines at accessibility text sizes"
        )
        XCTAssertLessThanOrEqual(
            (longAXDark.height - longAX.height).magnitude,
            1,
            "dark mode must not clip or truncate what light mode wraps"
        )
        XCTAssertEqual(
            longAXDark.width,
            Self.bannerWidth,
            accuracy: 0.5,
            "the wrapped banner must stay inside the phone width in dark mode"
        )
    }

    // MARK: - AC3: announced once; rerenders do not spam

    func testNewFailureAnnouncesExactlyOnceAndRerendersStaySilent() throws {
        var posted: [String] = []
        let box = BannerBox(message: nil)
        let host = WindowHost(BannerHarness(box: box, post: { posted.append($0) }))
        defer { host.tearDown() }

        XCTAssertEqual(posted, [], "an empty banner announces nothing")

        box.message = Self.longMessage
        host.settle()
        XCTAssertEqual(posted, [Self.longMessage], "a new failure announces once")

        // Rerenders: the banner is re-laid out for unrelated state changes (the
        // same shape a theme switch or animation frame produces).
        for tick in 1...5 {
            box.rerenderTick = tick
            host.settle(0.1)
        }
        XCTAssertEqual(
            posted,
            [Self.longMessage],
            "rerenders must not re-announce the same message"
        )

        box.message = Self.longMessage
        host.settle()
        XCTAssertEqual(posted, [Self.longMessage], "the same value is not a new failure")

        box.message = nil
        host.settle()
        XCTAssertEqual(posted, [Self.longMessage], "clearing the banner is silent")

        box.message = Self.shortMessage
        host.settle()
        XCTAssertEqual(
            posted,
            [Self.longMessage, Self.shortMessage],
            "a different failure announces again"
        )

        // The same failure re-occurring after a dismissal is a NEW failure for
        // the user, so it announces — once.
        box.message = nil
        host.settle()
        box.message = Self.shortMessage
        host.settle()
        XCTAssertEqual(
            posted,
            [Self.longMessage, Self.shortMessage, Self.shortMessage]
        )
    }

    func testAnnouncementPolicyMatrix() {
        XCTAssertFalse(ErrorBannerAccessibility.shouldAnnounce(previous: nil, next: nil))
        XCTAssertFalse(ErrorBannerAccessibility.shouldAnnounce(previous: "a", next: nil))
        XCTAssertFalse(ErrorBannerAccessibility.shouldAnnounce(previous: nil, next: ""))
        XCTAssertFalse(ErrorBannerAccessibility.shouldAnnounce(previous: "a", next: "a"))
        XCTAssertTrue(ErrorBannerAccessibility.shouldAnnounce(previous: nil, next: "a"))
        XCTAssertTrue(ErrorBannerAccessibility.shouldAnnounce(previous: "a", next: "b"))
    }

    /// The measured geometry above is the banner's; these pins keep the
    /// production wiring (call site, dismiss target, label, identifiers, and
    /// the bounded overlay shape) attached to the component that was measured.
    func testProductionWiringPins() {
        let app = Self.code(Self.source("Sources/App/SendmeterNativeApp.swift"))
        XCTAssertTrue(
            app.contains(".errorBannerAnnouncement(message: model.errorMessage)"),
            "RootView must announce through the message-valued modifier"
        )
        XCTAssertTrue(
            app.contains("if let message = model.errorMessage {"),
            "the banner must keep rendering the model's message"
        )
        XCTAssertTrue(
            app.contains("model.errorMessage = nil"),
            "dismiss must clear only the banner message"
        )

        let design = Self.code(Self.source("Sources/App/DesignSystem.swift"))
        let banner = Self.exactBlock(
            design,
            startingWith: "public struct ErrorBanner: View"
        )
        XCTAssertTrue(
            banner.contains(".accessibilityLabel(ErrorBannerAccessibility.dismissLabel)")
        )
        XCTAssertTrue(
            banner.contains(".accessibilityIdentifier(ErrorBannerAccessibility.dismissIdentifier)")
        )
        XCTAssertTrue(
            banner.contains("width: ErrorBannerAccessibility.dismissTarget")
                && banner.contains("height: ErrorBannerAccessibility.dismissTarget"),
            "the dismiss label must take the measured 44 pt target"
        )
        XCTAssertTrue(
            banner.contains("contentShape(.rect)"),
            "the 44 pt frame must be the tappable region"
        )
        XCTAssertTrue(banner.contains("Haptics.shared.playGesture(.light)"))
        XCTAssertFalse(
            banner.contains("accessibilityFocused")
                || banner.contains("accessibilityFocusState"),
            "the banner must never take VoiceOver focus (announcements do not move focus)"
        )
        XCTAssertTrue(
            banner.contains(
                ".contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))"
            ),
            "the banner overlay keeps its bounded rounded shape"
        )
        XCTAssertFalse(
            banner.contains(".contentShape(Rectangle())"),
            "the banner must not widen its overlay hit region to a full rectangle"
        )
        XCTAssertTrue(
            design.contains(
                "public static let dismissTarget: CGFloat = 44"
            ),
            "the target constant the geometry test measures against stays 44 pt"
        )

        let modifier = Self.exactBlock(
            design,
            startingWith: "struct ErrorBannerAnnouncementModifier: ViewModifier"
        )
        XCTAssertTrue(
            modifier.contains("var post: (String) -> Void = ErrorBannerAccessibility.post"),
            "the production default post must be the real announcement"
        )
    }

    // MARK: - Rendering

    /// Renders the production banner at the production width and returns its
    /// real laid-out size.
    private func render(
        shortMessage: String,
        dynamicType: DynamicTypeSize,
        colorScheme: ColorScheme = .light
    ) throws -> CGSize {
        let content = ErrorBanner(message: shortMessage, dismiss: {})
            .dynamicTypeSize(dynamicType)
            .environment(\.colorScheme, colorScheme)
            .frame(width: Self.bannerWidth)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "banner did not render")
        return image.size
    }

    private static func subheadlineLineHeight(
        _ dynamicType: DynamicTypeSize
    ) -> CGFloat {
        let contentSize: UIContentSizeCategory
        switch dynamicType {
        case .large: contentSize = .large
        case .accessibility5: contentSize = .accessibilityExtraExtraExtraLarge
        default: contentSize = .large
        }
        return UIFont.preferredFont(
            forTextStyle: .subheadline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize)
        ).lineHeight
    }

    // MARK: - Hosting (announcement counting)

    @MainActor
    private final class WindowHost {
        let window: UIWindow
        private let container = UIViewController()
        private let controller: UIHostingController<AnyView>

        init<V: View>(_ view: V) {
            controller = UIHostingController(rootView: AnyView(view))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
            window.windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            window.rootViewController = container
            container.addChild(controller)
            controller.view.frame = container.view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.view.addSubview(controller.view)
            controller.didMove(toParent: container)
            window.isHidden = false
            settle()
        }

        func settle(_ interval: TimeInterval = 0.3) {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
            window.layoutIfNeeded()
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @MainActor
    private final class BannerBox: ObservableObject {
        @Published var message: String?
        @Published var rerenderTick = 0

        init(message: String?) {
            self.message = message
        }
    }

    /// The production shape: the banner over a host view, with the
    /// announcement modifier attached where the message value is observed.
    private struct BannerHarness: View {
        @ObservedObject var box: BannerBox
        let post: (String) -> Void

        var body: some View {
            ZStack(alignment: .top) {
                Color.clear
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    if let message = box.message {
                        ErrorBanner(message: message) { box.message = nil }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .errorBannerAnnouncement(message: box.message, post: post)
        }
    }

    // MARK: - Source helpers (duplicated per repo convention)

    private static func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private static func code(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private static func exactBlock(_ source: String, startingWith marker: String) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant block: \(marker)")
            return ""
        }

        var depth = 0
        var cursor = openBrace.lowerBound
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[startRange.lowerBound...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }

        XCTFail("Unclosed source invariant block: \(marker)")
        return ""
    }
}

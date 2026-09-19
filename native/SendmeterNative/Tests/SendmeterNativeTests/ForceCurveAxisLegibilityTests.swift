import SendmeterCore
import SwiftUI
import UIKit
import XCTest
@testable import Sendmeter

/// #928 AC2 evidence: the REAL Force cards rendered at the smallest supported
/// phone width (375 pt — iPhone SE (3rd generation), the narrowest iOS 17
/// phone) at the default and an accessibility text size, light and dark.
///
/// The renders are written into the app's Documents directory
/// (`impl928-evidence/`) so the lane can commit them under `docs/evidence/`;
/// the assertions below measure the rendered layout, and the resolved
/// `caption2` point sizes are printed so the lane report can state the
/// measured Dynamic Type response.
///
/// Not proven here, and called out in the lane report: a physical-device
/// reading (AC6) and any touch interaction with the tooltip — this lane has no
/// touch injection (`Tests/SendmeterNativeUITests` is outside the file fence).
@MainActor
final class ForceCurveAxisLegibilityTests: XCTestCase {
    /// iPhone SE (3rd generation): 375×667 pt. ForceView insets its card stack
    /// by 16 pt on each side.
    private static let phoneWidth: CGFloat = 375
    private static let screenPadding: CGFloat = 16

    func testRenderedCardsFitTheSmallestPhoneAtEveryTextSize() throws {
        let large = try render(dynamicType: .large, colorScheme: .light)
        let accessibility = try render(dynamicType: .accessibility5, colorScheme: .dark)

        XCTAssertEqual(
            large.size.width,
            Self.phoneWidth,
            accuracy: 0.5,
            "the rendered stack must fill exactly the smallest phone width"
        )
        XCTAssertEqual(
            accessibility.size.width,
            Self.phoneWidth,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(
            accessibility.size.height,
            large.size.height,
            "an accessibility text size must make the cards grow instead of clipping"
        )
    }

    func testRenderedCardsAtTheAccessibilitySizeStayWideEnoughToDraw() throws {
        let accessibility = try render(dynamicType: .accessibility5, colorScheme: .light)

        // The curve plot's Canvas refuses to draw when the shared rule's
        // insets leave no plot rect; the card must therefore stay comfortably
        // wider than the card's own padding at the largest text size.
        XCTAssertGreaterThan(
            accessibility.size.width - 2 * Self.screenPadding,
            200,
            "the card content must keep room for the plot at accessibility sizes"
        )
    }

    /// The four AC2 captures: default and accessibility5, light and dark.
    func testWritesTheFourEvidenceCaptures() throws {
        let captures: [(DynamicTypeSize, ColorScheme, String)] = [
            (.large, .light, "force-chart-axis-928-normal-light"),
            (.large, .dark, "force-chart-axis-928-normal-dark"),
            (.accessibility5, .light, "force-chart-axis-928-ax5-light"),
            (.accessibility5, .dark, "force-chart-axis-928-ax5-dark")
        ]
        for (dynamicType, colorScheme, name) in captures {
            let image = try render(dynamicType: dynamicType, colorScheme: colorScheme)
            let directory = try Self.evidenceDirectory()
            let url = directory.appendingPathComponent("\(name).png")
            guard let data = image.pngData() else {
                XCTFail("Could not encode \(name) as PNG")
                continue
            }
            try data.write(to: url)
            XCTAssertGreaterThan(data.count, 10_000, "\(name) must carry a real render")
            print("impl928 evidence \(name) \(url.path) \(image.size.width)x\(image.size.height)pt")
        }

        print(
            "impl928 caption2 default "
                + "\(UIFontMetrics(forTextStyle: .caption2).scaledValue(for: ChartAxisLabelRule.basePointSize))"
                + " accessibility5 "
                + "\(UIFontMetrics(forTextStyle: .caption2).scaledValue(for: ChartAxisLabelRule.basePointSize, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)))"
        )
    }

    // MARK: - Render harness

    private func render(dynamicType: DynamicTypeSize, colorScheme: ColorScheme) throws -> UIImage {
        let content = Self.cards(dynamicType: dynamicType, colorScheme: colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        // A definite, generous height: with an unspecified height the renderer
        // measures the ideal height from single-line children, and a Text that
        // needs three lines then draws two plus an ellipsis (measured on the
        // iOS 26.5 simulator). The cards themselves never stretch — the image
        // keeps each card's natural height.
        renderer.proposedSize = ProposedViewSize(width: Self.phoneWidth, height: Self.renderHeight)
        guard let image = renderer.uiImage else {
            throw RenderError.noImage
        }
        return image
    }

    /// Tall enough for the accessibility5 stack (~2 500 pt) without being a
    /// candidate layout height for any card.
    private static let renderHeight: CGFloat = 8_000

    private enum RenderError: Error {
        case noImage
    }

    /// The two Force analysis cards exactly as `ForceView` stacks them (a
    /// 16 pt-padded stack over the grouped background), at the phone width.
    private static func cards(dynamicType: DynamicTypeSize, colorScheme: ColorScheme) -> some View {
        VStack(spacing: 16) {
            NativeForceCurveCard(
                tag: "Half crimp",
                model: model,
                hasLoadedRecordings: true,
                targetBand: targetBand,
                emptyActionTitle: "Record a pull",
                emptyAction: {}
            )
            ForceProgressCard(
                recordings: recordings,
                selectedTag: "Half crimp",
                selectedSide: .left,
                forceCurve: model,
                hasLoadedRecordings: true,
                targetBand: targetBand,
                connectionPending: false
            )
        }
        .padding(Self.screenPadding)
        .frame(width: Self.phoneWidth)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.dynamicTypeSize, dynamicType)
        .environment(\.colorScheme, colorScheme)
    }

    private static func evidenceDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("impl928-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Fixtures (the same curve the Core golden tests pin)

    private static var model: ForceCurveModel {
        let points: [ForceCurvePoint] = [
            ForceCurvePoint(windowSeconds: 1, kilograms: 44.2),
            ForceCurvePoint(windowSeconds: 3, kilograms: 38.5),
            ForceCurvePoint(windowSeconds: 7, kilograms: 33.1),
            ForceCurvePoint(windowSeconds: 15, kilograms: 29.8),
            ForceCurvePoint(windowSeconds: 30, kilograms: 27.4),
            ForceCurvePoint(windowSeconds: 60, kilograms: 25.9),
            ForceCurvePoint(windowSeconds: 120, kilograms: 24.8)
        ]
        let band: [ForceCurveConfidencePoint] = [
            ForceCurveConfidencePoint(
                windowSeconds: 1, kilograms: 44.2, lowKilograms: 40.1, highKilograms: 48
            ),
            ForceCurveConfidencePoint(
                windowSeconds: 3, kilograms: 38.5, lowKilograms: 34.9, highKilograms: 42.4
            ),
            ForceCurveConfidencePoint(
                windowSeconds: 7, kilograms: 33.1, lowKilograms: 29.8, highKilograms: 36.6
            ),
            ForceCurveConfidencePoint(
                windowSeconds: 15, kilograms: 29.8, lowKilograms: 26.6, highKilograms: 33.1
            ),
            ForceCurveConfidencePoint(
                windowSeconds: 30, kilograms: 27.4, lowKilograms: 24.3, highKilograms: 30.6
            ),
            ForceCurveConfidencePoint(
                windowSeconds: 60, kilograms: 25.9, lowKilograms: 22.9, highKilograms: 29
            ),
            ForceCurveConfidencePoint(
                windowSeconds: 120, kilograms: 24.8, lowKilograms: 21.9, highKilograms: 27.8
            )
        ]
        return ForceCurveModel(
            points: points,
            maximumForceKilograms: 46.3,
            criticalForceKilograms: 24.6,
            impulseAboveCriticalForceKilogramSeconds: 1234.5,
            capabilityFit: nil,
            confidenceBand: band
        )
    }

    private static let targetBand = ForceTargetBand(
        kilograms: 30,
        lowKilograms: 27,
        highKilograms: 33
    )

    private static var recordings: [TindeqRecording] {
        (0..<6).map { index in
            let metrics = ReverseActionMetrics(
                meanKilograms: 28.4,
                coefficientOfVariationPercent: 4.2,
                inTargetPercent: 93,
                timeUnderTensionMilliseconds: 40_000,
                driftPercent: -3.1,
                cadenceAdherencePercent: 97.5
            )
            let recordedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            return TindeqRecording(
                id: UUID(),
                recordedAt: recordedAt,
                durationMilliseconds: 10_000,
                peakKilograms: 34 + Double(index),
                averageKilograms: 26 + Double(index),
                sampleCount: 400,
                note: "",
                tag: "Half crimp",
                side: .left,
                groupID: nil,
                zone: .strength,
                source: .dynamometer,
                protocolMode: .hold,
                setMetrics: metrics
            )
        }
    }
}

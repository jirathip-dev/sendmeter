import SendmeterCore
import SwiftUI
import UIKit
import XCTest
@testable import Sendmeter

/// #929 AC2/AC5 evidence: the REAL weekly Training Load bars rendered offscreen
/// at the smallest supported phone width (375 pt — iPhone SE (3rd generation),
/// the narrowest iOS 17 phone) at the default and the largest accessibility
/// text size, light and dark, for a populated and a sparse four-week dataset —
/// plus the selected-value tooltip state the chart shows on tap/scrub.
///
/// The renders are written into the app's Documents directory
/// (`impl929-evidence/`) so the lane can commit them under
/// `docs/evidence/issue-929/`; the assertions below measure the shared rule's
/// decisions, the chart's own height contract and the reserved tooltip slot,
/// and the resolved `caption2` point sizes are printed so the lane report can
/// state the measured Dynamic Type response.
///
/// Not proven here, and called out in the lane report: physical-device
/// readability (#881) and a real touch driving the tooltip — this lane has no
/// touch injection, so the selected state comes from `WeeklyBarsView`'s
/// `initialSelection` seam.
@MainActor
final class TrainingLoadAxisLegibilityTests: XCTestCase {
    /// iPhone SE (3rd generation): 375 × 667 pt. The sheet insets its card
    /// stack by 16 pt and `SurfaceCard` pads its content by 16 pt again, so
    /// the weekly bars are laid out in 311 pt — the width the Core rule tests
    /// pin for the same slice.
    private static let phoneWidth: CGFloat = 375
    private static let screenPadding: CGFloat = 16
    private static let cardInnerWidth: CGFloat = phoneWidth - 4 * screenPadding

    /// The largest accessibility text size, and the `caption2` size it
    /// resolves to (measured below and printed, the same value the #928 lane
    /// measured on this simulator).
    private static let accessibilitySize = DynamicTypeSize.accessibility5
    private static let accessibilityPointSize: CGFloat = 40.5
    private static let accessibilityTraits = UITraitCollection(
        preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
    )

    // MARK: - The shared rule's decisions at the smallest phone width

    func testEveryWeeklyLabelSurvivesAtTheDefaultTextSize() {
        for weeks in [Self.populatedWeeks, Self.sparseWeeks] {
            let values = Self.valuePlan(for: weeks, pointSize: ChartAxisLabelRule.basePointSize)
            XCTAssertEqual(
                values.labelledIndices,
                Array(weeks.indices),
                "the default text size keeps every AU total drawn above its bar"
            )
            let captions = Self.weekPlan(for: weeks, pointSize: ChartAxisLabelRule.basePointSize)
            XCTAssertEqual(captions.labelledIndices, Array(weeks.indices), "and every week caption")
            XCTAssertEqual(captions.columnWidth, 71.75, accuracy: 0.0001)
        }
    }

    func testAccessibilitySizesThinTheWeeklyLabelsInsteadOfClippingThem() {
        XCTAssertEqual(
            UIFontMetrics(forTextStyle: .caption2).scaledValue(
                for: ChartAxisLabelRule.basePointSize,
                compatibleWith: Self.accessibilityTraits
            ),
            Self.accessibilityPointSize,
            "the pinned accessibility caption2 size must match this simulator"
        )

        let values = Self.valuePlan(for: Self.populatedWeeks, pointSize: Self.accessibilityPointSize)
        XCTAssertTrue(
            values.labelledIndices.isEmpty,
            "no 3-character AU total fits its 72 pt column at 40.5 pt — the row is "
                + "omitted and the exact values move to the readout under the chart"
        )
        XCTAssertLessThan(
            values.labelledIndices.count,
            Self.populatedWeeks.count,
            "the view shows its exact-values readout whenever a value label is omitted"
        )

        let sparseValues = Self.valuePlan(for: Self.sparseWeeks, pointSize: Self.accessibilityPointSize)
        XCTAssertEqual(
            sparseValues.labelledIndices,
            [0, 1],
            "the density adaptation follows the DATA too: the sparse set's "
                + "1-character '0' totals still fit their column at 40.5 pt"
        )

        let captions = Self.weekPlan(for: Self.populatedWeeks, pointSize: Self.accessibilityPointSize)
        XCTAssertEqual(
            captions.labelledIndices,
            [0, 1, 2],
            "the 2-character week captions survive at 40.5 pt; 'Now' (3 characters) "
                + "does not fit and is omitted rather than overhanging its column"
        )
    }

    func testEveryDrawnLabelFitsItsColumnAndClearsItsNeighbourAtEveryTextSize() {
        for pointSize in stride(from: ChartAxisLabelRule.basePointSize, through: Self.accessibilityPointSize, by: 1) {
            for weeks in [Self.populatedWeeks, Self.sparseWeeks] {
                for (labels, plan) in [
                    (Self.valueLabels(for: weeks), Self.valuePlan(for: weeks, pointSize: pointSize)),
                    (Self.weekLabels(for: weeks), Self.weekPlan(for: weeks, pointSize: pointSize))
                ] {
                    func width(_ index: Int) -> CGFloat {
                        ChartAxisLabelRule.estimatedLabelWidth(labels[index], pointSize: pointSize)
                    }
                    for index in plan.labelledIndices {
                        XCTAssertLessThanOrEqual(
                            width(index) / 2,
                            plan.columnWidth / 2,
                            "a drawn label must fit inside its own column at \(pointSize) pt"
                        )
                        XCTAssertGreaterThanOrEqual(plan.centers[index] - width(index) / 2, 0)
                        XCTAssertLessThanOrEqual(
                            plan.centers[index] + width(index) / 2,
                            Self.cardInnerWidth
                        )
                    }
                    for (previous, next) in zip(plan.labelledIndices, plan.labelledIndices.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(
                            plan.centers[next] - plan.centers[previous]
                                - (width(previous) + width(next)) / 2,
                            ChartAxisLabelRule.minimumGap - 0.0001,
                            "labels at \(pointSize) pt must not collide"
                        )
                    }
                }
            }
        }
    }

    // MARK: - The chart's height and the tooltip slot (AC2)

    func testTheChartHeightMakesRoomForTheGrownLabelBands() throws {
        // Explicit trait collections: the assertions must not depend on the
        // simulator's ambient content-size setting.
        let defaultBand = UIFontMetrics(forTextStyle: .caption2).scaledValue(
            for: WeeklyBarsView.labelBandBaseHeight,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        XCTAssertEqual(
            WeeklyBarsView.chartHeight(bandHeight: defaultBand),
            WeeklyBarsView.minimumChartHeight,
            accuracy: 0.0001,
            "the default text size must not change the shipped 108 pt chart"
        )

        // A real column at the accessibility size: the same shared font, the
        // same bar height and the same label spacing the view uses.
        let column = VStack(spacing: WeeklyBarsView.columnSpacing) {
            Text("1,232").font(ChartAxisLabelRule.font)
            Color.clear.frame(height: WeeklyBarsView.maximumBarHeight)
            Text("Now").font(ChartAxisLabelRule.font)
        }
        .environment(\.dynamicTypeSize, Self.accessibilitySize)
        let naturalHeight = try Self.measure(column, width: Self.cardInnerWidth).height
        XCTAssertGreaterThan(
            naturalHeight,
            WeeklyBarsView.minimumChartHeight,
            "at the largest accessibility size a column no longer fits the pre-#929 height"
        )

        let accessibilityBand = UIFontMetrics(forTextStyle: .caption2).scaledValue(
            for: WeeklyBarsView.labelBandBaseHeight,
            compatibleWith: Self.accessibilityTraits
        )
        XCTAssertGreaterThan(
            accessibilityBand,
            defaultBand,
            "the label band must follow the resolved text size"
        )
        XCTAssertGreaterThanOrEqual(
            WeeklyBarsView.chartHeight(bandHeight: accessibilityBand),
            naturalHeight,
            "the chart must make room for the grown label bands instead of clipping them"
        )
        print(
            "impl929 column heights natural \(naturalHeight) chart "
                + "\(WeeklyBarsView.chartHeight(bandHeight: accessibilityBand))"
        )
    }

    func testTheTooltipWrapsInsideTheCardAndTheSlotIsReserved() throws {
        let tooltip = TrainingLoadTooltip {
            VStack(alignment: .leading, spacing: 2) {
                Text("Now")
                    .font(.subheadline.weight(.semibold))
                Text("1,232.5 AU")
                    .font(.caption2.monospacedDigit())
                Text("▲ 105% vs prior wk")
                    .font(.caption2.monospacedDigit())
            }
            .frame(maxWidth: Self.cardInnerWidth, alignment: .leading)
        }
        .environment(\.dynamicTypeSize, Self.accessibilitySize)

        let size = try Self.measure(tooltip, width: Self.cardInnerWidth)
        XCTAssertLessThanOrEqual(
            size.width,
            Self.cardInnerWidth + 0.5,
            "the tooltip must wrap inside the card instead of overhanging it"
        )
        XCTAssertGreaterThan(
            size.height,
            WeeklyBarsView.labelBandBaseHeight,
            "the three-line tooltip is taller than one label band at this size"
        )
        let reserve = UIFontMetrics(forTextStyle: .caption2).scaledValue(
            for: WeeklyBarsView.tooltipReserveBaseHeight,
            compatibleWith: Self.accessibilityTraits
        )
        XCTAssertGreaterThanOrEqual(
            reserve,
            size.height,
            "the reserved tooltip slot must fit the three-line tooltip at this size "
                + "(it was a fixed 60 pt before #929)"
        )

        // The reserved slot must fit that tooltip: the chart below it may not
        // move when a selection appears.
        let unselected = try Self.render(
            Self.section(weeks: Self.populatedWeeks, selection: nil, dynamicType: .accessibility5, colorScheme: .light)
        )
        let selected = try Self.render(
            Self.section(weeks: Self.populatedWeeks, selection: 3, dynamicType: .accessibility5, colorScheme: .light)
        )
        XCTAssertEqual(
            selected.size.height,
            unselected.size.height,
            accuracy: 0.5,
            "showing the selected-value tooltip must not move the chart"
        )
    }

    // MARK: - Rendered evidence

    func testWritesTheWeeklySectionCaptures() throws {
        let captures: [(String, [WeeklyLoad], DynamicTypeSize, ColorScheme, Int?)] = [
            ("training-load-axis-929-populated-normal-light", Self.populatedWeeks, .large, .light, nil),
            ("training-load-axis-929-populated-normal-dark", Self.populatedWeeks, .large, .dark, nil),
            ("training-load-axis-929-populated-ax5-light", Self.populatedWeeks, .accessibility5, .light, nil),
            ("training-load-axis-929-populated-ax5-dark", Self.populatedWeeks, .accessibility5, .dark, nil),
            ("training-load-axis-929-sparse-normal-light", Self.sparseWeeks, .large, .light, nil),
            ("training-load-axis-929-sparse-normal-dark", Self.sparseWeeks, .large, .dark, nil),
            ("training-load-axis-929-sparse-ax5-light", Self.sparseWeeks, .accessibility5, .light, nil),
            ("training-load-axis-929-sparse-ax5-dark", Self.sparseWeeks, .accessibility5, .dark, nil),
            ("training-load-axis-929-populated-normal-dark-selected", Self.populatedWeeks, .large, .dark, 3),
            ("training-load-axis-929-populated-ax5-light-selected", Self.populatedWeeks, .accessibility5, .light, 3)
        ]

        let directory = try Self.evidenceDirectory()
        for (name, weeks, dynamicType, colorScheme, selection) in captures {
            let image = try Self.render(
                Self.section(weeks: weeks, selection: selection, dynamicType: dynamicType, colorScheme: colorScheme)
            )
            XCTAssertEqual(
                image.size.width,
                Self.phoneWidth,
                accuracy: 0.5,
                "\(name) must render at the smallest phone width"
            )
            guard let data = image.pngData() else {
                XCTFail("Could not encode \(name) as PNG")
                continue
            }
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url)
            XCTAssertGreaterThan(data.count, 10_000, "\(name) must carry a real render")
            print("impl929 evidence \(name) \(url.path) \(image.size.width)x\(image.size.height)pt")
        }

        // The accessibility-size section render is NOT written: ImageRenderer
        // sizes its canvas before `WeeklyBarsView`'s width state settles, so
        // the drawn readout overflows the reported canvas at that size. The
        // accessibility-size appraisal comes from the simulator captures
        // (`xcrun simctl`, the real app) and from the assertions above; the
        // numbers are printed here for the lane report.
        let normal = try Self.render(
            Self.section(weeks: Self.populatedWeeks, selection: nil, dynamicType: .large, colorScheme: .light)
        )
        let accessibility = try Self.render(
            Self.section(weeks: Self.populatedWeeks, selection: nil, dynamicType: .accessibility5, colorScheme: .light)
        )
        XCTAssertGreaterThan(
            accessibility.size.height,
            normal.size.height,
            "an accessibility text size must make the weekly section grow instead of clipping"
        )

        let measuredChart = try Self.measure(
            WeeklyBarsView(weeks: Self.populatedWeeks)
                .environment(\.dynamicTypeSize, .accessibility5),
            width: Self.cardInnerWidth
        )
        print(
            "impl929 sizes ax5 section \(accessibility.size) normal \(normal.size) chart \(measuredChart)"
        )

        print(
            "impl929 caption2 default "
                + "\(UIFontMetrics(forTextStyle: .caption2).scaledValue(for: ChartAxisLabelRule.basePointSize, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)))"
                + " accessibility5 \(Self.accessibilityPointSize)"
                + " band default "
                + "\(UIFontMetrics(forTextStyle: .caption2).scaledValue(for: WeeklyBarsView.labelBandBaseHeight, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)))"
                + " band accessibility5 "
                + "\(UIFontMetrics(forTextStyle: .caption2).scaledValue(for: WeeklyBarsView.labelBandBaseHeight, compatibleWith: Self.accessibilityTraits))"
        )
    }

    // MARK: - Render harness

    /// The weekly section exactly as `TrainingLoadSheet.weeklyLoadSection`
    /// stacks it: a `SurfaceCard` with its title + delta chip over the sheet's
    /// grouped background, at the phone width — including the accessibility
    /// branch that moves the chip to its own line (#929).
    private static func section(
        weeks: [WeeklyLoad],
        selection: Int?,
        dynamicType: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        weeklyLoadTitle
                        deltaChip
                    }
                } else {
                    HStack {
                        weeklyLoadTitle
                        Spacer()
                        deltaChip
                    }
                }
                WeeklyBarsView(weeks: weeks, initialSelection: selection)
            }
        }
        .padding(Self.screenPadding)
        .frame(width: Self.phoneWidth)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.dynamicTypeSize, dynamicType)
        .environment(\.colorScheme, colorScheme)
    }

    private static var weeklyLoadTitle: some View {
        SectionLabel("Weekly load", systemImage: "chart.bar.fill")
    }

    private static var deltaChip: some View {
        Text("▲ 17% vs prior wk")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.blue)
    }

    private static func render(_ content: some View) throws -> UIImage {
        // A definite, generous canvas with the content anchored to its top,
        // then cropped to what was actually drawn: ImageRenderer measures the
        // canvas from the layout pass that runs before `WeeklyBarsView`'s width
        // state settles, so at accessibility sizes the drawn readout overflows
        // the height it reports.
        let canvasHeight: CGFloat = 4_000
        let renderer = ImageRenderer(
            content: content
                .frame(width: Self.phoneWidth, height: canvasHeight, alignment: .top)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: Self.phoneWidth, height: canvasHeight)
        guard let image = renderer.uiImage else {
            throw RenderError.noImage
        }
        // The canvas outside the content is transparent; flatten it onto white
        // so a blank row reads as white rather than as an unset pixel.
        let opaque = UIGraphicsImageRenderer(size: image.size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        return try croppedToContent(opaque)
    }

    /// Crops the blank canvas below the drawn content.
    private static func croppedToContent(_ image: UIImage) throws -> UIImage {
        guard let cg = image.cgImage else { throw RenderError.noImage }
        guard let background = rowColor(of: cg, row: 0) else { throw RenderError.noImage }
        func isBlank(_ color: (Int, Int, Int)) -> Bool {
            func delta(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int)) -> Int {
                abs(lhs.0 - rhs.0) + abs(lhs.1 - rhs.1) + abs(lhs.2 - rhs.2)
            }
            return delta(color, background) <= 12 || delta(color, (255, 255, 255)) <= 12
        }
        var lastContentRow = 0
        for row in stride(from: cg.height - 1, through: 0, by: -1) {
            guard let color = rowColor(of: cg, row: row) else { continue }
            if !isBlank(color) {
                lastContentRow = row
                break
            }
        }
        let cropHeight = min(max(lastContentRow + 1, 1), cg.height)
        guard let cropped = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: cropHeight)) else {
            throw RenderError.noImage
        }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// The average colour of one pixel row, read back from a 1×1 downscale.
    private static func rowColor(of cg: CGImage, row: Int) -> (Int, Int, Int)? {
        guard let strip = cg.cropping(to: CGRect(x: 0, y: row, width: cg.width, height: 1)) else {
            return nil
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// Measures one element's natural size at `width` (used for the column and
    /// the tooltip probes).
    private static func measure(_ content: some View, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(content: content.frame(width: width))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: 4_000)
        guard let image = renderer.uiImage else {
            throw RenderError.noImage
        }
        return image.size
    }

    private enum RenderError: Error {
        case noImage
    }

    private static func evidenceDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("impl929-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Fixtures

    /// Four weeks of load, the shape the sheet's weekly chart plots.
    private static let populatedWeeks = [
        WeeklyLoad(label: "3w", total: 630),
        WeeklyLoad(label: "2w", total: 1_050),
        WeeklyLoad(label: "1w", total: 600),
        WeeklyLoad(label: "Now", total: 1_232)
    ]

    /// A sparse window: two trained weeks, two empty ones.
    private static let sparseWeeks = [
        WeeklyLoad(label: "3w", total: 0),
        WeeklyLoad(label: "2w", total: 0),
        WeeklyLoad(label: "1w", total: 300),
        WeeklyLoad(label: "Now", total: 360)
    ]

    private static func valueLabels(for weeks: [WeeklyLoad]) -> [String] {
        weeks.map { TrainingLoad.formatAU($0.total) }
    }

    private static func weekLabels(for weeks: [WeeklyLoad]) -> [String] {
        weeks.map(\.label)
    }

    private static func valuePlan(for weeks: [WeeklyLoad], pointSize: CGFloat) -> ChartAxisLabelRule.ColumnLabelPlan {
        ChartAxisLabelRule.columnLabelPlan(
            labels: valueLabels(for: weeks),
            width: cardInnerWidth,
            spacing: CGFloat(TrainingLoadInteraction.weeklyBarSpacing),
            pointSize: pointSize
        )
    }

    private static func weekPlan(for weeks: [WeeklyLoad], pointSize: CGFloat) -> ChartAxisLabelRule.ColumnLabelPlan {
        ChartAxisLabelRule.columnLabelPlan(
            labels: weekLabels(for: weeks),
            width: cardInnerWidth,
            spacing: CGFloat(TrainingLoadInteraction.weeklyBarSpacing),
            pointSize: pointSize
        )
    }
}

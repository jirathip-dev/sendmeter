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

    /// The largest accessibility text size the sheet is checked at.
    private static let accessibilitySize = DynamicTypeSize.accessibility5

    /// The `caption2` size at `.accessibility5` **for this simulator**, resolved
    /// from the same `UIFontMetrics` source the view's `@ScaledMetric` reads, so
    /// every expectation below is environment-independent. The resolved value is
    /// display-scale dependent: 40.5 pt on a 2× device, 40.66… pt on the 3×
    /// device hosted CI runs on (the original literal 40.5 failed there).
    private static let accessibilityPointSize: CGFloat = UIFontMetrics(forTextStyle: .caption2)
        .scaledValue(for: ChartAxisLabelRule.basePointSize, compatibleWith: accessibilityTraits)

    /// The size the #929 arithmetic was written against. Asserted *near* the
    /// resolved value, not equal to it: the closest decision boundary at
    /// `.accessibility5` is "Now" against its 71.75 pt column (6 + 3 × 0.62 ×
    /// size), which carries 9.65 pt of margin, so a ±0.5 pt display-scale drift
    /// cannot flip a decision — a larger drift means the arithmetic and its
    /// printed evidence need a re-check, not a rescale.
    private static let accessibilityPointSizeAnchor: CGFloat = 40.5
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
            Self.accessibilityPointSize,
            Self.accessibilityPointSizeAnchor,
            accuracy: 0.5,
            "the resolved accessibility caption2 size must stay near the 40.5 pt the #929 "
                + "arithmetic was written against; got \(Self.accessibilityPointSize) pt "
                + "(the resolved value is display-scale dependent)"
        )

        let values = Self.valuePlan(for: Self.populatedWeeks, pointSize: Self.accessibilityPointSize)
        XCTAssertTrue(
            values.labelledIndices.isEmpty,
            "no 3-character AU total fits its 72 pt column at \(Self.accessibilityPointSize) pt — the row is "
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
                + "1-character '0' totals still fit their column at \(Self.accessibilityPointSize) pt"
        )

        let captions = Self.weekPlan(for: Self.populatedWeeks, pointSize: Self.accessibilityPointSize)
        XCTAssertEqual(
            captions.labelledIndices,
            [0, 1, 2],
            "the 2-character week captions survive at \(Self.accessibilityPointSize) pt; 'Now' (3 characters) "
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

    /// The tooltip exactly as `WeeklyBarsView.tooltipCard` composes it: the
    /// shared chrome around the label / total / delta stack, bounded by the
    /// card's inner width.
    private static func tooltip(dynamicType: DynamicTypeSize) -> some View {
        TrainingLoadTooltip {
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
        .environment(\.dynamicTypeSize, dynamicType)
    }

    func testTheTooltipWrapsInsideTheCardAndTheSlotIsReserved() throws {
        // #929 fix round: the reserve has to hold the *wrapped* tooltip at
        // every Dynamic Type size. With the card finally sized to its wrapped
        // content, the largest size wraps the delta to a second line (measured
        // 258.5 pt) and the shipped 60 pt base under-reserved it (221.5 pt), so
        // the base grew to 72 pt — and this loop is what keeps the two numbers
        // honest at every size, not just at the one the lane happened to look
        // at.
        var tightest = (size: DynamicTypeSize.large, deficit: -CGFloat.greatestFiniteMagnitude)
        for dynamicType in Self.dynamicTypeSizes {
            let tooltip = Self.tooltip(dynamicType: dynamicType)
            let size = try Self.measure(tooltip, width: Self.cardInnerWidth)
            XCTAssertLessThanOrEqual(
                size.width,
                Self.cardInnerWidth + 0.5,
                "at \(dynamicType) the tooltip must wrap inside the card instead of overhanging it"
            )
            XCTAssertGreaterThan(
                size.height,
                WeeklyBarsView.labelBandBaseHeight,
                "at \(dynamicType) the tooltip is taller than one label band"
            )
            let reserve = Self.tooltipReserve(for: Self.traits(for: dynamicType))
            XCTAssertGreaterThanOrEqual(
                reserve,
                size.height,
                "at \(dynamicType) the reserved tooltip slot must fit the wrapped tooltip "
                    + "(measured \(size.height) pt, reserve \(reserve) pt)"
            )
            let deficit = size.height - reserve
            if deficit > tightest.deficit {
                tightest = (dynamicType, deficit)
            }
        }
        print("impl929 fix tooltip reserve tightest at \(tightest.size): deficit \(tightest.deficit) pt")

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

    // MARK: - #929 fix round (review-929-r1 blockers 1 and 2)

    /// **Blocker 1.** The tooltip's own card (pure white in the light scheme)
    /// must contain the whole wrapped content.
    ///
    /// The #929 test measured the *slot reserve* against the content and never
    /// the *card background* against the text it wraps, so a card sized to the
    /// unwrapped ideal (three lines) could clip a wrapped fourth line with
    /// every test green. Layer: **rendered measurement** — a real
    /// `ImageRenderer` render classified row by row (pure-white rows = the
    /// card, the border token `#D8D8DC` = the card's edge, dark or coloured
    /// rows = text).
    func testTheTooltipCardBackgroundContainsTheWrappedText() throws {
        // The chrome on its own, at both ends of the Dynamic Type range.
        for dynamicType in [DynamicTypeSize.large, .accessibility5] {
            let name = dynamicType.isAccessibilitySize ? "ax5" : "default"
            let image = try Self.render(Self.tooltip(dynamicType: dynamicType), flatten: Self.backdrop)
            let card = try Self.tooltipCardMetrics(in: image, traits: Self.traits(for: dynamicType))
            try Self.writeFixRoundCapture(image, named: "fix-tooltip-chrome-\(name)")
            print("impl929 fix tooltip chrome \(name) — \(card)")
            XCTAssertGreaterThan(card.cardRows, 8, "\(name): the tooltip card must be drawn")
            XCTAssertGreaterThan(card.textRows, 8, "\(name): the tooltip's text must be drawn")
            XCTAssertNotNil(card.lastBorderRow, "\(name): the tooltip card's border must be drawn")
            XCTAssertLessThanOrEqual(
                card.lastTextRow ?? 0,
                card.lastBorderRow ?? 0,
                "\(name): the tooltip card's background must contain its wrapped text — the text "
                    + "ends at row \(card.lastTextRow.map(String.init) ?? "?") but the card's "
                    + "border is at row \(card.lastBorderRow.map(String.init) ?? "?") (\(card))"
            )
        }
        // …and inside the real weekly card, at the size where the delta wraps
        // to a second line.
        let section = try Self.render(
            Self.section(
                weeks: Self.populatedWeeks,
                selection: 3,
                dynamicType: .accessibility5,
                colorScheme: .light
            ),
            flatten: Self.backdrop
        )
        let sectionCard = try Self.tooltipCardMetrics(
            in: section,
            traits: Self.traits(for: .accessibility5)
        )
        try Self.writeFixRoundCapture(section, named: "fix-tooltip-card-ax5-section")
        print("impl929 fix tooltip in section ax5 — \(sectionCard)")
        XCTAssertLessThanOrEqual(
            sectionCard.lastTextRow ?? 0,
            sectionCard.lastBorderRow ?? 0,
            "ax5: the selected-value tooltip's card must contain its text inside the weekly "
                + "card too (\(sectionCard))"
        )
    }

    /// **Blocker 2.** The exact-values readout exists for the sizes where the
    /// shared rule omits a value label, so it must never be drawn while every
    /// bar still carries its own label — the state the delivered build
    /// rendered, because the readout resolved from a width (41) the chart's
    /// own in-reader plan never saw (311).
    ///
    /// Layer: **rendered measurement in a hosted layout** — `ImageRenderer`
    /// leaves the width state at zero, so this leg renders through
    /// `UIHostingController` where the layout callbacks settle the way they do
    /// in the app.
    func testTheValuesReadoutNeverDuplicatesTheValueLabels() throws {
        for (dynamicType, name) in [(DynamicTypeSize.large, "default"), (.accessibility5, "ax5")] {
            let image = try Self.hostedImage(
                Self.section(
                    weeks: Self.populatedWeeks,
                    selection: nil,
                    dynamicType: dynamicType,
                    colorScheme: .light,
                    pinWidth: false
                ),
                dynamicType: dynamicType,
                startWidth: Self.placeholderWidth
            )
            let bands = try Self.chartBandMetrics(in: image, traits: Self.traits(for: dynamicType), scale: image.scale)
            try Self.writeFixRoundCapture(image, named: "fix-readout-\(name)-hosted")
            print("impl929 fix readout \(name) — \(bands)")
            XCTAssertFalse(
                bands.labelsDrawn && bands.readoutDrawn,
                "\(name): the readout must not duplicate the drawn value labels "
                    + "(labels \(bands.labelsDrawn), readout \(bands.readoutDrawn): \(bands))"
            )
            XCTAssertTrue(
                bands.labelsDrawn || bands.readoutDrawn,
                "\(name): the weekly values must stay readable — the per-bar labels or the "
                    + "readout must be drawn (\(bands))"
            )
        }
    }

    // MARK: - Pixel probes for the fix-round tests

    /// The backdrop the probes flatten a transparent canvas onto: light enough
    /// not to read as text, deliberately not white (the card's own token).
    private static let backdrop = UIColor(white: 0.92, alpha: 1)

    /// The width the delivered build laid the weekly section out at before it
    /// settled on the card's real width: the readout resolved its plan from
    /// this number (41 pt) while the chart's own reader used 311 pt.
    private static let placeholderWidth: CGFloat = 41

    /// Where the tooltip card's background starts, where its bottom border is
    /// and where its text ends, in image pixels. Everything inside the
    /// reserved slot belongs to the tooltip, so no chart markup can be
    /// mistaken for it.
    struct TooltipCardMetrics: CustomStringConvertible {
        let firstCardRow: Int
        let slotBottomRow: Int
        let lastBorderRow: Int?
        let lastTextRow: Int?
        let cardRows: Int
        let textRows: Int

        var contained: Bool {
            guard let lastBorderRow, let lastTextRow else { return false }
            return lastTextRow <= lastBorderRow
        }

        var description: String {
            "card rows from \(firstCardRow) (\(cardRows) white rows), slot ends \(slotBottomRow), "
                + "last border row \(lastBorderRow.map(String.init) ?? "none"), "
                + "last text row \(lastTextRow.map(String.init) ?? "none") (\(textRows) text rows), "
                + "contained \(contained)"
        }
    }

    /// Where the chart's bars are, whether a value label is drawn above them
    /// and whether the readout is drawn below the chart.
    struct ChartBandMetrics: CustomStringConvertible {
        let firstBarRow: Int
        let lastBarRow: Int
        let labelsDrawn: Bool
        let readoutDrawn: Bool

        var description: String {
            "bars \(firstBarRow)-\(lastBarRow), value labels \(labelsDrawn), readout \(readoutDrawn)"
        }
    }

    struct RowScan {
        /// Rows that are mostly the tooltip's pure-white background.
        let cardCounts: [Int]
        /// Rows with the tooltip border's colour (`#D8D8DC` light scheme).
        let borderCounts: [Int]
        /// Rows with dark or strongly coloured glyph pixels.
        let textCounts: [Int]
        /// Rows with coloured (non-grey) pixels: the bar fills, but also any
        /// coloured glyph. The bar band is the *wide* run of these rows.
        let coloredCounts: [Int]
    }

    private static func tooltipCardMetrics(
        in image: UIImage,
        traits: UITraitCollection,
        slack: CGFloat = 40
    ) throws -> TooltipCardMetrics {
        let scan = try rowScan(of: image)
        guard let firstCard = scan.cardCounts.firstIndex(where: { $0 >= 8 }) else {
            throw RenderError.noImage
        }
        // The tooltip is top-aligned in its reserved slot, so the slot's band
        // (plus a little slack for a card that overflows it) holds the whole
        // tooltip and nothing else of the weekly card.
        let slotBottom = min(
            firstCard + Int((tooltipReserve(for: traits) * image.scale).rounded()) + Int(slack),
            scan.cardCounts.count - 1
        )
        var lastBorder: Int?
        var lastText: Int?
        var textRows = 0
        for row in firstCard ... slotBottom {
            if scan.borderCounts[row] >= 20 {
                lastBorder = row
            }
            if scan.textCounts[row] >= 4 {
                lastText = row
                textRows += 1
            }
        }
        return TooltipCardMetrics(
            firstCardRow: firstCard,
            slotBottomRow: slotBottom,
            lastBorderRow: lastBorder,
            lastTextRow: lastText,
            cardRows: scan.cardCounts[firstCard ... slotBottom].filter { $0 >= 8 }.count,
            textRows: textRows
        )
    }

    /// The tooltip slot reserve at `traits`, the same scaled metric the view
    /// lays the slot out with.
    private static func tooltipReserve(for traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .caption2).scaledValue(
            for: WeeklyBarsView.tooltipReserveBaseHeight,
            compatibleWith: traits
        )
    }

    private static func chartBandMetrics(
        in image: UIImage,
        traits: UITraitCollection,
        scale: CGFloat
    ) throws -> ChartBandMetrics {
        let scan = try rowScan(of: image)
        let width = image.cgImage?.width ?? 1
        // Anchor the chart on its own bars: rows whose coloured pixels cover at
        // least 30% of the rendered width. The column fills do (77% at four
        // bars, both scales); text — the accessibility delta chip included —
        // tops out near 18%.
        let solidRows = scan.coloredCounts.enumerated()
            .filter { Double($0.element) >= 0.30 * Double(width) }
            .map(\.offset)
        // The bars are one contiguous band; the longest run is the chart.
        var bands: [[Int]] = []
        for row in solidRows {
            if var last = bands.last, row - (last.last ?? row) <= 4 {
                last.append(row)
                bands[bands.count - 1] = last
            } else {
                bands.append([row])
            }
        }
        guard let barBand = bands.max(by: { $0.count < $1.count }),
              let firstBar = barBand.first,
              let lastBar = barBand.last else {
            throw RenderError.chartNotFound
        }
        // A bar band is bar-shaped: the tallest bar is `maximumBarHeight`. Much
        // taller than that means the anchor is wrong, and every assertion built
        // on it would be meaningless — fail loudly here instead (this is what
        // the delivered detector did not do when it anchored on the delta
        // chip's glyphs and reported `labels true` from the header).
        let detectedHeight = CGFloat(lastBar - firstBar + 1) / scale
        let tallestBar = WeeklyBarsView.maximumBarHeight * 1.5
        guard detectedHeight <= tallestBar else {
            throw RenderError.barBandMisdetected(
                rows: "\(firstBar)-\(lastBar)",
                points: detectedHeight,
                limit: tallestBar
            )
        }
        let band = bandHeight(for: traits) * scale
        // A value label is drawn in its reserved band above the bar; the
        // readout, when it is drawn at all, starts below the chart's own frame
        // — one week-caption band plus the chart's spacing — and its first
        // line begins at the card's leading edge.
        let labelWindow = max(firstBar - Int(band.rounded()) - 8, 0)
        let labelsDrawn = labelWindow < firstBar
            && scan.textCounts[labelWindow ..< firstBar].contains { $0 >= 4 }
        let readoutStart = min(lastBar + Int(band.rounded()) + 8, scan.textCounts.count)
        let readoutDrawn = readoutStart < scan.textCounts.count
            && scan.textCounts[readoutStart...].contains { $0 >= 4 }
        return ChartBandMetrics(
            firstBarRow: firstBar,
            lastBarRow: lastBar,
            labelsDrawn: labelsDrawn,
            readoutDrawn: readoutDrawn
        )
    }

    /// Per-row pixel counts: pure-white rows (the tooltip background token),
    /// glyph rows (dark or strongly coloured) and fill rows (the bars).
    private static func rowScan(of image: UIImage) throws -> RowScan {
        guard let cg = image.cgImage else { throw RenderError.noImage }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.noImage
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var cardCounts = [Int](repeating: 0, count: height)
        var borderCounts = [Int](repeating: 0, count: height)
        var textCounts = [Int](repeating: 0, count: height)
        var coloredCounts = [Int](repeating: 0, count: height)
        for row in 0 ..< height {
            let rowOffset = row * width * 4
            var card = 0
            var border = 0
            var text = 0
            var colored = 0
            for column in 0 ..< width {
                let index = rowOffset + column * 4
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                if red >= 252, green >= 252, blue >= 252 {
                    card += 1
                    continue
                }
                // The tooltip border token is #D8D8DC in the light scheme.
                if abs(red - 216) <= 6, abs(green - 216) <= 6, abs(blue - 220) <= 6 {
                    border += 1
                }
                let luminance = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
                if luminance < 150 {
                    text += 1
                }
                // 15 leaves the grey card/backdrop out while catching the
                // bars' lightest gradient rows.
                let spread = max(red, green, blue) - min(red, green, blue)
                if spread > 15 {
                    colored += 1
                }
            }
            cardCounts[row] = card
            borderCounts[row] = border
            textCounts[row] = text
            coloredCounts[row] = colored
        }
        return RowScan(
            cardCounts: cardCounts,
            borderCounts: borderCounts,
            textCounts: textCounts,
            coloredCounts: coloredCounts
        )
    }

    /// Renders `content` in a real host window: `ImageRenderer` never runs the
    /// width state to its settled value, a hosted layout does. `startWidth`
    /// reproduces the app's own geometry history — the sheet is laid out at a
    /// placeholder width first (the delivered build published 41 pt) and only
    /// then settles on the card's real width.
    private static func hostedImage(
        _ content: some View,
        dynamicType: DynamicTypeSize,
        startWidth: CGFloat? = nil
    ) throws -> UIImage {
        let host = UIHostingController(rootView: content)
        let width = startWidth ?? phoneWidth
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_400))
        window.traitOverrides.preferredContentSizeCategory = Self.contentSizeCategory(for: dynamicType)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        if let startWidth, startWidth != phoneWidth {
            window.frame = CGRect(x: 0, y: 0, width: phoneWidth, height: 1_400)
            host.view.frame = window.bounds
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let bounds = CGRect(x: 0, y: 0, width: phoneWidth, height: host.view.bounds.height)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
            backdrop.setFill()
            context.fill(bounds)
            host.view.layer.render(in: context.cgContext)
        }
        return try croppedToContent(image)
    }

    private static func traits(for dynamicType: DynamicTypeSize) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: contentSizeCategory(for: dynamicType))
    }

    /// The exact category `@ScaledMetric` resolves `dynamicType` to, so the
    /// test's reserve arithmetic reads the same number the view lays out with.
    private static func contentSizeCategory(for dynamicType: DynamicTypeSize) -> UIContentSizeCategory {
        switch dynamicType {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }

    /// Every Dynamic Type size the reserve has to hold the tooltip at.
    private static let dynamicTypeSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    private static func bandHeight(for traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .caption2).scaledValue(
            for: WeeklyBarsView.labelBandBaseHeight,
            compatibleWith: traits
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
        colorScheme: ColorScheme,
        pinWidth: Bool = true
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
        .frame(width: pinWidth ? Self.phoneWidth : nil)
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

    private static func render(_ content: some View, flatten: UIColor = .white) throws -> UIImage {
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
        // The canvas outside the content is transparent; flatten it so a blank
        // row reads as one known colour rather than as an unset pixel. The
        // tooltip probes pass `backdrop`, which is deliberately not white:
        // white is the tooltip card's own background token.
        let opaque = UIGraphicsImageRenderer(size: image.size).image { context in
            flatten.setFill()
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

    private enum RenderError: Error, CustomStringConvertible {
        case noImage
        case chartNotFound
        case barBandMisdetected(rows: String, points: CGFloat, limit: CGFloat)

        var description: String {
            switch self {
            case .noImage:
                return "the render produced no image"
            case .chartNotFound:
                return "no bar band was found in the render — the detector cannot anchor the "
                    + "chart, so the assertion would be meaningless"
            case let .barBandMisdetected(rows, points, limit):
                return "the detected bar band (rows \(rows), \(points) pt) is not bar-shaped "
                    + "(the tallest bar is \(WeeklyBarsView.maximumBarHeight) pt, limit \(limit) pt): "
                    + "the detector anchored on something that is not the chart"
            }
        }
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

    /// Writes one fix-round render into the evidence directory so the lane
    /// report can carry the pixels the assertions ran against.
    private static func writeFixRoundCapture(_ image: UIImage, named name: String) throws {
        guard let data = image.pngData() else {
            throw RenderError.noImage
        }
        let url = try evidenceDirectory().appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("impl929 fix capture \(name) \(url.path) \(image.size.width)x\(image.size.height)pt")
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

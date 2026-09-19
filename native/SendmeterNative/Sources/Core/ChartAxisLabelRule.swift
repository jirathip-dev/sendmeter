import Foundation

/// The one shared Dynamic Type-aware axis-label rule for the Force charts
/// (#928).
///
/// The Force duration curve drew its axis text at a fixed 8 pt and the Force
/// progress tiles at a fixed 9 pt, so neither followed Dynamic Type and both
/// crowded at the smallest phone width. This rule is the single place that
/// decides the label size, the tick density and the plot insets:
///
/// 1. **Label size.** `basePointSize` is `caption2` at the default Dynamic
///    Type size. Regular SwiftUI text uses the matching text style,
///    `ChartAxisLabelRule.font` (`.caption2`, declared next to
///    `ChartToken.axis` in `ChartTheme.swift`). The curve's Canvas cannot read
///    a text style back as a number, so it seeds
///    `@ScaledMetric(relativeTo: .caption2)` with `basePointSize` and draws
///    with the resolved value — one number for both the drawn glyphs and the
///    arithmetic below.
/// 2. **Tick density — the documented collision adaptation.** Every width
///    estimate is proportional to the resolved point size, so a larger text
///    size thins the labelled ticks automatically: `visibleTickIndices` keeps
///    the first candidate and then drops any later tick whose estimated label
///    would sit closer than `minimumGap` points to the previously kept label.
///    The alternative — shrinking the text until it fits — is exactly what
///    this issue removes.
/// 3. **Plot insets.** `insets` reserves the leading/trailing/top/bottom room
///    the outermost labels need at the resolved size, so a grown label stays
///    inside the card instead of clipping at the canvas edge.
///
/// Everything here is pure arithmetic: no glyph measurement, no SwiftUI, and
/// no text layout in a Canvas draw pass (labels are estimated, never laid
/// out).
public enum ChartAxisLabelRule {
    /// Label size in points at the default Dynamic Type size — `caption2`,
    /// the smallest system text style. Views seed
    /// `@ScaledMetric(relativeTo: .caption2)` with this so the drawn size and
    /// the collision math read the same number.
    public static let basePointSize: CGFloat = 11

    /// Minimum clear space between two neighbouring axis labels, in points.
    public static let minimumGap: CGFloat = 6

    /// Width of one character as a fraction of the point size. SF's digit
    /// advance is ~0.6 em; 0.62 keeps a hair of margin for the `s` suffix.
    public static let advanceRatio: CGFloat = 0.62

    /// One-line label height as a multiple of the point size (SF line height).
    public static let lineHeightRatio: CGFloat = 1.25

    /// Estimated drawn width of `label` at `pointSize`, in points.
    public static func estimatedLabelWidth(_ label: String, pointSize: CGFloat) -> CGFloat {
        CGFloat(label.count) * pointSize * advanceRatio
    }

    /// Estimated drawn height of a one-line label at `pointSize`, in points.
    public static func estimatedLabelHeight(pointSize: CGFloat) -> CGFloat {
        pointSize * lineHeightRatio
    }

    /// The tick indices to label, in order.
    ///
    /// The first candidate is always labelled; every later candidate is
    /// labelled only when its estimated label clears the previously kept
    /// label by `minimumGap`. `labels` and `positions` are the candidate tick
    /// texts and their centres, in the same order and the same coordinate
    /// space (points).
    public static func visibleTickIndices(
        labels: [String],
        positions: [CGFloat],
        pointSize: CGFloat,
        minimumGap: CGFloat = ChartAxisLabelRule.minimumGap
    ) -> [Int] {
        guard labels.count == positions.count, !labels.isEmpty else { return [] }
        var kept: [Int] = []
        for index in labels.indices {
            guard let previous = kept.last else {
                kept.append(index)
                continue
            }
            let previousRight = positions[previous]
                + estimatedLabelWidth(labels[previous], pointSize: pointSize) / 2
            let nextLeft = positions[index]
                - estimatedLabelWidth(labels[index], pointSize: pointSize) / 2
            if nextLeft - previousRight >= minimumGap {
                kept.append(index)
            }
        }
        return kept
    }

    /// Plot insets that keep the outermost labels inside the canvas.
    public struct Insets: Equatable, Sendable {
        public let leading: CGFloat
        public let trailing: CGFloat
        public let top: CGFloat
        public let bottom: CGFloat

        public init(leading: CGFloat, trailing: CGFloat, top: CGFloat, bottom: CGFloat) {
            self.leading = leading
            self.trailing = trailing
            self.top = top
            self.bottom = bottom
        }
    }

    // MARK: - Flexible equal-width columns (the Training Load weekly bars, #929)

    /// The label layout for a chart drawn as `count` equal, flexible columns
    /// that fill `width` with `spacing` between neighbours — the shape the
    /// Training Load weekly bars use, as opposed to the Force plot's canvas
    /// with explicit `insets`.
    public struct ColumnLabelPlan: Equatable, Sendable {
        /// X centre of each column, in the same point space as `width`.
        public let centers: [CGFloat]
        /// Width of one column (the full width minus the inter-column gaps).
        public let columnWidth: CGFloat
        /// Indices whose label is drawn, in order.
        public let labelledIndices: [Int]

        public init(centers: [CGFloat], columnWidth: CGFloat, labelledIndices: [Int]) {
            self.centers = centers
            self.columnWidth = columnWidth
            self.labelledIndices = labelledIndices
        }
    }

    /// X centres of `count` equal columns filling `width`, with `spacing`
    /// between neighbours.
    ///
    /// This is the same slot arithmetic `TrainingLoadInteraction.weeklyBarIndex`
    /// hit-tests a finger against, so a label centred on a slot always belongs
    /// to the column that same point selects.
    public static func columnCenters(width: CGFloat, count: Int, spacing: CGFloat) -> [CGFloat] {
        guard count > 0, width.isFinite, width > 0 else { return [] }
        let safeSpacing = spacing.isFinite ? max(spacing, 0) : 0
        let pitch = (width + safeSpacing) / CGFloat(count)
        return (0..<count).map { (CGFloat($0) + 0.5) * pitch - safeSpacing / 2 }
    }

    /// The column tick indices a flexible equal-width column chart can label.
    ///
    /// `labels` are the candidate texts in column order and `width` is the
    /// chart's full width. Unlike a canvas plot, this shape has no `insets` to
    /// grow into, so a label is a candidate only when its own estimate plus
    /// `minimumGap` fits inside **its own column** — a wider label would
    /// overhang the neighbouring column or leave the card. The surviving
    /// candidates then go through `visibleTickIndices`, the shared collision
    /// adaptation, so a grown label thins the row instead of overlapping its
    /// neighbour.
    public static func columnLabelPlan(
        labels: [String],
        width: CGFloat,
        spacing: CGFloat,
        pointSize: CGFloat,
        minimumGap: CGFloat = ChartAxisLabelRule.minimumGap
    ) -> ColumnLabelPlan {
        let count = labels.count
        let centers = columnCenters(width: width, count: count, spacing: spacing)
        guard centers.count == count, !labels.isEmpty else {
            return ColumnLabelPlan(centers: [], columnWidth: 0, labelledIndices: [])
        }
        let safeSpacing = spacing.isFinite ? max(spacing, 0) : 0
        let columnWidth = max((width + safeSpacing) / CGFloat(count) - safeSpacing, 0)
        let fitting = labels.indices.filter {
            estimatedLabelWidth(labels[$0], pointSize: pointSize) + minimumGap <= columnWidth
        }
        let kept = visibleTickIndices(
            labels: fitting.map { labels[$0] },
            positions: fitting.map { centers[$0] },
            pointSize: pointSize,
            minimumGap: minimumGap
        )
        return ColumnLabelPlan(
            centers: centers,
            columnWidth: columnWidth,
            labelledIndices: kept.map { fitting[$0] }
        )
    }

    /// Insets for a plot whose leading column centres the y labels on
    /// `leading / 2`, whose trailing edge centres the last x label on the
    /// plot's right edge, and whose x labels sit centred in the bottom band.
    ///
    /// The minima are the plot's previous fixed insets, so a default-size
    /// label never shrinks the plot; only a label that would otherwise clip
    /// grows its edge.
    public static func insets(
        yLabels: [String],
        xLabels: [String],
        pointSize: CGFloat,
        minimumLeading: CGFloat = 32,
        minimumTrailing: CGFloat = 8,
        minimumTop: CGFloat = 8,
        minimumBottom: CGFloat = 20,
        padding: CGFloat = 4
    ) -> Insets {
        let widestY = yLabels
            .map { estimatedLabelWidth($0, pointSize: pointSize) }
            .max() ?? 0
        let widestX = xLabels
            .map { estimatedLabelWidth($0, pointSize: pointSize) }
            .max() ?? 0
        let height = estimatedLabelHeight(pointSize: pointSize)
        return Insets(
            // The y label is centred on half the inset, so the inset has to
            // span the whole label plus the gap to the plot.
            leading: max(minimumLeading, widestY + padding),
            // The last x label is centred on the plot's right edge.
            trailing: max(minimumTrailing, widestX / 2 + padding / 2),
            // The top y label is centred on the plot's top edge.
            top: max(minimumTop, height / 2 + padding / 2),
            // The x labels are centred in the bottom band.
            bottom: max(minimumBottom, height + padding / 2)
        )
    }
}

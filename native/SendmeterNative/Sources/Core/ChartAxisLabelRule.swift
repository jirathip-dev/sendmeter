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

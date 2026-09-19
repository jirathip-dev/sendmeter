import CoreGraphics

/// Pure tooltip placement for the force-duration curve (#755, moved to Core in
/// #928).
///
/// The tooltip's own size is *measured*, never guessed: its host publishes the
/// rendered `tooltipSize` from a `GeometryReader`, and these functions clamp
/// the measured box inside the plot rect. Extracting the clamp keeps the #755
/// invariants testable — a clamped centre always keeps the measured tooltip
/// inside the plot with the shipped clearance, and a plot too small for the
/// tooltip falls back to the plot's centre rather than jumping outside.
public enum ForceCurveTooltipPlacement {
    /// Horizontal centre for a tooltip anchored at `anchor`, clamped so the
    /// measured tooltip stays inside `plotFrame` with `inset` clearance.
    /// A zero measurement (before the first layout pass) uses the shipped
    /// 90 pt fallback.
    public static func x(
        anchor: CGFloat,
        plotFrame: CGRect,
        tooltipWidth: CGFloat,
        inset: CGFloat = 8
    ) -> CGFloat {
        let width = tooltipWidth > 0 ? tooltipWidth : 90
        let minCenter = plotFrame.minX + width / 2 + inset
        let maxCenter = plotFrame.maxX - width / 2 - inset
        if minCenter > maxCenter { return plotFrame.midX }
        return min(max(anchor, minCenter), maxCenter)
    }

    /// Vertical centre for the tooltip: pinned to the top of the plot rect
    /// (the shipped #755 placement) as long as the measured tooltip fits;
    /// a zero measurement uses the shipped 60 pt fallback.
    public static func y(
        plotFrame: CGRect,
        tooltipHeight: CGFloat,
        inset: CGFloat = 4
    ) -> CGFloat {
        let height = tooltipHeight > 0 ? tooltipHeight : 60
        let minCenter = plotFrame.minY + height / 2 + inset
        let maxCenter = plotFrame.maxY - height / 2 - inset
        if minCenter > maxCenter { return plotFrame.midY }
        return minCenter
    }
}

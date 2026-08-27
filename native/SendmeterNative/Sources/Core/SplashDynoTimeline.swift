import Foundation

/// A single keyframe pose of the splash kangaroo, in the same units as the web
/// `@keyframes splash-dyno` (src/index.css): translation as a fraction of the
/// stage's own size (CSS `%` / 100), rotation in degrees, scale as separate
/// x/y factors. Transform-only, so a view applying a pose stays
/// compositor-friendly.
public struct SplashDynoPose: Equatable {
    public var txFraction: Double
    public var tyFraction: Double
    public var rotationDegrees: Double
    public var scaleX: Double
    public var scaleY: Double

    /// The un-animated pose — `translate3d(0, 0, 0) rotate(0) scale(1)`.
    /// Also the reduce-motion fallback, matching the web
    /// `@media (prefers-reduced-motion: reduce) { animation: none }` rule
    /// (the element renders at its base transform).
    public static let rest = SplashDynoPose(
        txFraction: 0, tyFraction: 0,
        rotationDegrees: 0, scaleX: 1, scaleY: 1
    )

    public init(
        txFraction: Double,
        tyFraction: Double,
        rotationDegrees: Double,
        scaleX: Double,
        scaleY: Double
    ) {
        self.txFraction = txFraction
        self.tyFraction = tyFraction
        self.rotationDegrees = rotationDegrees
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}

/// Phase math for the splash kangaroo dyno, ported from the web animation
/// `splash-dyno 4.2s cubic-bezier(0.35, 0, 0.2, 1) infinite`
/// (src/index.css). Pure Foundation so the stops and timing are pinned by
/// `swift test`; the CSS animation applies one easing curve BETWEEN each pair
/// of keyframes, so `pose(at:)` does the same: locate the segment, ease the
/// segment fraction with the shared cubic bezier, then lerp each channel.
public enum SplashDynoTimeline {
    /// One full cycle, seconds. `animation: splash-dyno 4.2s ... infinite`.
    public static let cycleDuration: Double = 4.2

    /// Keyframe stops, percent of the cycle → pose. Values MUST match
    /// src/index.css `@keyframes splash-dyno` (see SplashView, which carries
    /// the cross-side KEEP-IN-SYNC comment).
    static let stops: [(percent: Double, pose: SplashDynoPose)] = [
        (0, SplashDynoPose.rest),
        (4, SplashDynoPose.rest),
        (5, SplashDynoPose(txFraction: -0.01, tyFraction: 0.02, rotationDegrees: -1, scaleX: 1.035, scaleY: 0.965)),
        (11, SplashDynoPose(txFraction: 0.05, tyFraction: -0.08, rotationDegrees: 4, scaleX: 0.98, scaleY: 1.02)),
        (15, SplashDynoPose(txFraction: 0.06, tyFraction: -0.10, rotationDegrees: 6, scaleX: 1, scaleY: 1)),
        (18, SplashDynoPose(txFraction: 0.04, tyFraction: 0.03, rotationDegrees: 44, scaleX: 1, scaleY: 1)),
        (20, SplashDynoPose(txFraction: 0, tyFraction: 0.24, rotationDegrees: 88, scaleX: 1.04, scaleY: 0.96)),
        (22, SplashDynoPose(txFraction: 0, tyFraction: 0.20, rotationDegrees: 94, scaleX: 0.99, scaleY: 1.01)),
        (23.5, SplashDynoPose(txFraction: 0, tyFraction: 0.23, rotationDegrees: 90, scaleX: 1, scaleY: 1)),
        (64, SplashDynoPose(txFraction: 0, tyFraction: 0.23, rotationDegrees: 90, scaleX: 1, scaleY: 1)),
        (76, SplashDynoPose(txFraction: -0.03, tyFraction: 0.14, rotationDegrees: 45, scaleX: 1, scaleY: 1)),
        (86, SplashDynoPose.rest),
        (100, SplashDynoPose.rest),
    ]

    /// The pose at `elapsed` seconds into the cycle. Any value is accepted —
    /// it is wrapped into `[0, cycleDuration)` first, so a caller can either
    /// feed a wrapped clock (loop) or use the wrap for free (same result).
    public static func pose(at elapsed: Double) -> SplashDynoPose {
        let wrapped = (
            (elapsed.truncatingRemainder(dividingBy: cycleDuration)) + cycleDuration
        ).truncatingRemainder(dividingBy: cycleDuration)
        let percent = wrapped / cycleDuration * 100
        let (lower, upper) = segment(containing: percent)
        let span = upper.percent - lower.percent
        let raw = span <= 0 ? 0 : (percent - lower.percent) / span
        let eased = easeSegmentProgress(min(max(raw, 0), 1))
        return SplashDynoPose(
            txFraction: lerp(lower.pose.txFraction, upper.pose.txFraction, eased),
            tyFraction: lerp(lower.pose.tyFraction, upper.pose.tyFraction, eased),
            rotationDegrees: lerp(lower.pose.rotationDegrees, upper.pose.rotationDegrees, eased),
            scaleX: lerp(lower.pose.scaleX, upper.pose.scaleX, eased),
            scaleY: lerp(lower.pose.scaleY, upper.pose.scaleY, eased)
        )
    }

    /// The CSS animation-timing-function. `cubic-bezier(0.35, 0, 0.2, 1)`:
    /// fast start, long settle — slow-in/out within each segment. Maps the
    /// segment's linear time fraction to the eased value fraction.
    public static func easeSegmentProgress(_ x: Double) -> Double {
        let x1 = 0.35, x2 = 0.2, y1 = 0.0, y2 = 1.0
        // Solve bezierX(t) == x for t (Newton, then bisection fallback) and
        // return bezierY(t). Bisection alone would do; Newton gets the
        // 1e-7 precision target in a couple of steps for the common case.
        var t = x
        for _ in 0..<8 {
            let dx = bezierDerivativeX(t, x1: x1, x2: x2)
            guard dx > 1e-9 else { break }
            let next = t - (bezierX(t, x1: x1, x2: x2) - x) / dx
            t = min(max(next, 0), 1)
        }
        if abs(bezierX(t, x1: x1, x2: x2) - x) > 1e-7 {
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if bezierX(mid, x1: x1, x2: x2) < x { lo = mid } else { hi = mid }
            }
            t = (lo + hi) / 2
        }
        return bezierY(t, y1: y1, y2: y2)
    }

    // MARK: - Cubic bezier for cubic-bezier(0.35, 0, 0.2, 1)

    private static func bezierX(_ t: Double, x1: Double, x2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
    }

    private static func bezierDerivativeX(_ t: Double, x1: Double, x2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
    }

    private static func bezierY(_ t: Double, y1: Double, y2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
    }

    // MARK: - Helpers

    private static func segment(containing percent: Double) -> (lower: (percent: Double, pose: SplashDynoPose), upper: (percent: Double, pose: SplashDynoPose)) {
        guard percent > stops[0].percent else { return (stops[0], stops[0]) }
        for index in 1..<stops.count where percent <= stops[index].percent {
            return (stops[index - 1], stops[index])
        }
        let last = stops[stops.count - 1]
        return (last, last)
    }

    private static func lerp(_ from: Double, _ to: Double, _ fraction: Double) -> Double {
        from + (to - from) * fraction
    }
}

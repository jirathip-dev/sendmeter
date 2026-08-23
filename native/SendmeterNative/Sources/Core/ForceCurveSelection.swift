import Foundation

/// Pure geometry for choosing a measured point while scrubbing the log-x
/// force-duration curve (#755). The curve's x-axis spans 1–120s, so screen x
/// positions are linear over log(seconds), not seconds. Keeping these two
/// mappings in Core lets Canvas rendering and the scrub overlay share one
/// inverse transform instead of drifting apart.
public enum ForceCurveSelection {
    /// Map a duration to its 0...1 fraction of the log-x plot, clamped to the
    /// measured first/last window so gesture hit-testing and tooltip
    /// positioning use the same coordinate space as the drawn curve.
    public static func xFraction(
        forSeconds seconds: Double,
        firstSeconds: Double,
        lastSeconds: Double
    ) -> Double? {
        guard seconds.isFinite,
              firstSeconds.isFinite,
              lastSeconds.isFinite,
              firstSeconds > 0,
              lastSeconds > 0
        else { return nil }
        let low = min(firstSeconds, lastSeconds)
        let high = max(firstSeconds, lastSeconds)
        let lowLog = log10(low)
        let highLog = log10(high)
        let span = highLog - lowLog
        guard span > .ulpOfOne else { return 0 }
        let clamped = min(max(seconds, low), high)
        return (log10(clamped) - lowLog) / span
    }

    /// Inverse of `xFraction` — the duration under a finger at a plot fraction.
    public static func seconds(
        atXFraction fraction: Double,
        firstSeconds: Double,
        lastSeconds: Double
    ) -> Double? {
        guard fraction.isFinite,
              firstSeconds.isFinite,
              lastSeconds.isFinite,
              firstSeconds > 0,
              lastSeconds > 0
        else { return nil }
        let low = min(firstSeconds, lastSeconds)
        let high = max(firstSeconds, lastSeconds)
        let lowLog = log10(low)
        let highLog = log10(high)
        let span = highLog - lowLog
        guard span > .ulpOfOne else { return low }
        let clampedFraction = min(max(fraction, 0), 1)
        return pow(10, lowLog + clampedFraction * span)
    }

    /// Nearest measured point to a scrubbed duration, measured in log space so
    /// the 1–10s end of the curve is not visually over-represented.
    public static func nearestPointIndex(
        points: [ForceCurvePoint],
        toSeconds seconds: Double
    ) -> Int? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let targetLog = log10(seconds)
        return points.indices
            .filter { points[$0].windowSeconds.isFinite && points[$0].windowSeconds > 0 }
            .min { lhs, rhs in
                let lhsDistance = abs(log10(points[lhs].windowSeconds) - targetLog)
                let rhsDistance = abs(log10(points[rhs].windowSeconds) - targetLog)
                return lhsDistance < rhsDistance
            }
    }
}

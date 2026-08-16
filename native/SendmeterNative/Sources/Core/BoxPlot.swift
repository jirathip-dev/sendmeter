import Foundation

/// Five-number summary for a box plot (web `src/lib/boxplot.ts`).
public struct FiveNumberSummary: Equatable, Sendable {
    public let min: Double
    public let q1: Double
    public let median: Double
    public let q3: Double
    public let max: Double

    public init(min: Double, q1: Double, median: Double, q3: Double, max: Double) {
        self.min = min
        self.q1 = q1
        self.median = median
        self.q3 = q3
        self.max = max
    }
}

/// Matplotlib-style box-plot stats: quartiles plus 1.5·IQR-fenced whiskers
/// and the outliers beyond them (web `BoxStats`).
public struct BoxStats: Equatable, Sendable {
    public let q1: Double
    public let median: Double
    public let q3: Double
    /// Whisker ends — the furthest data point still INSIDE the 1.5·IQR fence
    /// on each side (not simply min/max).
    public let whiskerLow: Double
    public let whiskerHigh: Double
    public let outliers: [Double]

    public init(q1: Double, median: Double, q3: Double, whiskerLow: Double, whiskerHigh: Double, outliers: [Double]) {
        self.q1 = q1
        self.median = median
        self.q3 = q3
        self.whiskerLow = whiskerLow
        self.whiskerHigh = whiskerHigh
        self.outliers = outliers
    }
}

/// Pure box-plot math for the per-rep force-distribution charts (#630).
/// Byte-for-byte port of the web's `fiveNumberSummary` / `boxStats`
/// (`src/lib/boxplot.ts`), so native and web charts agree on identical data.
public enum BoxPlot {
    /// Linear-interpolation quantile, the R-7 / "standard" method (Excel /
    /// numpy default): index by `(n-1)*p` and interpolate between the two
    /// neighboring sorted values.
    static func quantile(sorted: [Double], p: Double) -> Double {
        let n = sorted.count
        if n == 1 { return sorted[0] }
        let idx = Double(n - 1) * p
        let lo = Int(idx.rounded(.down))
        let hi = Int(idx.rounded(.up))
        if lo == hi { return sorted[lo] }
        let fraction = idx - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * fraction
    }

    /// Min/Q1/median/Q3/max. Nil for empty input so callers skip rendering
    /// instead of dividing by zero.
    public static func fiveNumberSummary(_ values: [Double]) -> FiveNumberSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return FiveNumberSummary(
            min: sorted[0],
            q1: quantile(sorted: sorted, p: 0.25),
            median: quantile(sorted: sorted, p: 0.5),
            q3: quantile(sorted: sorted, p: 0.75),
            max: sorted[sorted.count - 1]
        )
    }

    /// Classic box-plot stats. Nil for empty input.
    public static func boxStats(_ values: [Double]) -> BoxStats? {
        guard let summary = fiveNumberSummary(values) else { return nil }
        let iqr = summary.q3 - summary.q1
        let fenceLow = summary.q1 - 1.5 * iqr
        let fenceHigh = summary.q3 + 1.5 * iqr

        var whiskerLow = Double.infinity
        var whiskerHigh = -Double.infinity
        var outliers: [Double] = []
        for value in values {
            if value < fenceLow || value > fenceHigh {
                outliers.append(value)
            } else {
                if value < whiskerLow { whiskerLow = value }
                if value > whiskerHigh { whiskerHigh = value }
            }
        }
        // Every value happened to be an outlier (degenerate/near-zero-IQR
        // data) — fall back to min/max rather than leaving the ±∞ sentinels.
        if !whiskerLow.isFinite {
            whiskerLow = summary.min
            whiskerHigh = summary.max
        }

        return BoxStats(
            q1: summary.q1,
            median: summary.median,
            q3: summary.q3,
            whiskerLow: whiskerLow,
            whiskerHigh: whiskerHigh,
            outliers: outliers
        )
    }
}

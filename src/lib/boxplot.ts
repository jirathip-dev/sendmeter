export interface FiveNumberSummary {
  min: number;
  q1: number;
  median: number;
  q3: number;
  max: number;
}

/// Linear-interpolation quantile, the R-7 / "standard" method (same one
/// Excel/numpy's default use): index by `(n-1)*p` and interpolate between
/// the two neighboring sorted values.
function quantile(sorted: number[], p: number): number {
  const n = sorted.length;
  if (n === 1) return sorted[0]!;
  const idx = (n - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo]!;
  const frac = idx - lo;
  return sorted[lo]! + (sorted[hi]! - sorted[lo]!) * frac;
}

/// Min/Q1/median/Q3/max for a box plot. Null for empty input so callers can
/// skip rendering rather than dividing by zero / reading `undefined`.
export function fiveNumberSummary(values: number[]): FiveNumberSummary | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return {
    min: sorted[0]!,
    q1: quantile(sorted, 0.25),
    median: quantile(sorted, 0.5),
    q3: quantile(sorted, 0.75),
    max: sorted[sorted.length - 1]!,
  };
}

export interface BoxStats {
  q1: number;
  median: number;
  q3: number;
  /// Whisker ends — the furthest data point still INSIDE the 1.5·IQR fence
  /// on each side (not simply min/max — a value beyond the fence is an
  /// outlier instead, per the classic Tukey box plot).
  whiskerLo: number;
  whiskerHi: number;
  outliers: number[];
}

/// Classic matplotlib-style box-plot stats: quartiles (via
/// `fiveNumberSummary`) plus 1.5·IQR-fenced whiskers and the outliers beyond
/// them. Null for empty input.
export function boxStats(values: number[]): BoxStats | null {
  const summary = fiveNumberSummary(values);
  if (!summary) return null;
  const { q1, median, q3 } = summary;
  const iqr = q3 - q1;
  const fenceLo = q1 - 1.5 * iqr;
  const fenceHi = q3 + 1.5 * iqr;

  let whiskerLo = Infinity;
  let whiskerHi = -Infinity;
  const outliers: number[] = [];
  for (const v of values) {
    if (v < fenceLo || v > fenceHi) {
      outliers.push(v);
    } else {
      if (v < whiskerLo) whiskerLo = v;
      if (v > whiskerHi) whiskerHi = v;
    }
  }
  // Every value happened to be an outlier (degenerate/near-zero-IQR data) —
  // fall back to min/max rather than leaving the +/-Infinity sentinels.
  if (!Number.isFinite(whiskerLo)) {
    whiskerLo = summary.min;
    whiskerHi = summary.max;
  }

  return { q1, median, q3, whiskerLo, whiskerHi, outliers };
}

import { boxStats, type BoxStats } from "./boxplot";

/// Minimal shape the Force tab's trend data needs to satisfy — deliberately
/// not `TrendPoint` from `ForceTrendChart.tsx` (that also carries an `id`,
/// only needed for the scatter's React keys) so this stays a pure,
/// component-agnostic helper.
export interface TrendSample {
  recordedAt: string; // ISO timestamp
  val: number; // peakKg or %BW, per the chart's current mode
}

export interface DailyBoxStats {
  date: string; // YYYY-MM-DD
  /// ms of the day's best rep — used both for the box's x-position (the
  /// chart is time-scaled, not index-based) and the PR-day callout.
  t: number;
  best: number;
  count: number;
  /// Never null in practice: every entry starts life with at least one
  /// pushed value, and `boxStats` only returns null for an empty array.
  stats: BoxStats;
}

/// Per-day aggregation for the Peak Force Trend chart (issue #145): unlike
/// the chart's older per-day reduction (best value + rep count only), this
/// retains every rep's value for the day so `boxStats()` can drive a Tukey
/// box (quartiles/whiskers/outliers) instead of a single highlighted dot.
/// `sorted` must already be date-ascending (the chart sorts once up front).
export function dailyBoxStats(sorted: TrendSample[]): DailyBoxStats[] {
  const byDate = new Map<string, { t: number; best: number; values: number[] }>();
  for (const r of sorted) {
    const date = r.recordedAt.slice(0, 10);
    const cur = byDate.get(date);
    if (!cur) {
      byDate.set(date, { t: Date.parse(r.recordedAt), best: r.val, values: [r.val] });
    } else {
      cur.values.push(r.val);
      if (r.val > cur.best) {
        cur.best = r.val;
        cur.t = Date.parse(r.recordedAt);
      }
    }
  }
  return [...byDate.entries()]
    .map(([date, d]) => ({
      date,
      t: d.t,
      best: d.best,
      count: d.values.length,
      stats: boxStats(d.values)!,
    }))
    .sort((a, b) => a.date.localeCompare(b.date));
}

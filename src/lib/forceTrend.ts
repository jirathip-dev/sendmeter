import { boxStats, type BoxStats } from "./boxplot";
import { isEffortRecording, type ZonedHold } from "./zoneHistory";
import type { TindeqSide } from "../types";

/// Minimal shape the Force tab's trend data needs to satisfy — deliberately
/// not `TrendPoint` from `ForceTrendChart.tsx` (that also carries an `id`,
/// only needed for the scatter's React keys) so this stays a pure,
/// component-agnostic helper.
export interface TrendSample {
  recordedAt: string; // ISO timestamp
  val: number; // peakKg or %BW, per the chart's current mode
}

/// The recordings `ForceTrendChart` plots: scoped to the selected tag/side,
/// and — Prehab (#325) — excluded from effort. A Prehab hold is a submax,
/// sub-CF hold BY DESIGN, so its peak would otherwise fabricate a fake "PR
/// dropped" day the moment it becomes the day's best rep — exactly what the
/// daily-bests aggregation the chart builds on top of this already protects
/// against for a submax endurance day. Exported (pure, no hooks) so that
/// guarantee is pinned without rendering `ForceTrendChart` itself, which
/// reads `localStorage` at the top of its body and isn't renderable outside
/// a browser-like test environment.
export function trendChartRecordings<T extends ZonedHold & { tag: string; side: TindeqSide }>(
  recordings: T[],
  selectedTag: string | null,
  selectedSide: TindeqSide | null,
): T[] {
  return recordings.filter(
    (r) =>
      (selectedTag === null || r.tag === selectedTag) &&
      (selectedSide === null || r.side === selectedSide) &&
      isEffortRecording(r),
  );
}

/// Per-point nearest-neighbor pixel gaps for an x-position array that's
/// already ascending (as `ForceTrendChart`'s day x-positions are, since
/// `dailyBoxStats` sorts by date and same-day timestamps can't interleave
/// across days). A lone point (no neighbor) gets `Infinity` — callers clamp
/// that themselves.
export function neighborGapsPx(xs: number[]): number[] {
  return xs.map((x, i) => {
    const gaps: number[] = [];
    if (i > 0) gaps.push(x - xs[i - 1]!);
    if (i < xs.length - 1) gaps.push(xs[i + 1]! - x);
    return gaps.length ? Math.min(...gaps) : Infinity;
  });
}

/// Each day's hover/tap hit-rect width, from ITS OWN nearest-neighbor gap —
/// NOT the dataset-wide minimum gap. (Issue #145 revision: deriving one
/// shared `hitW` from the global minimum gap meant a single close pair of
/// days anywhere in the dataset collapsed EVERY day's hit target to
/// near-zero, breaking hover/tap scrubbing chart-wide.) Floored to `minW` so
/// a day with a genuinely tight neighbor still gets a tappable target — the
/// same tradeoff the visible box width already makes elsewhere (a slightly
/// overlapping hit-rect beats an unusable one) — and capped so it doesn't
/// swallow a neighbor's hits.
export function hitWidthsPx(xs: number[], boxW: number, minW: number): number[] {
  return neighborGapsPx(xs).map((gap) =>
    Math.max(minW, Math.min(Math.max(boxW, 12), Number.isFinite(gap) ? gap : boxW)),
  );
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

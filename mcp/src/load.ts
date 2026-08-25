/// Training-load math mirrored from the web app's src/lib/metrics.ts (same
/// recurrence, same constants — the equivalence is pinned by
/// test/load.test.ts, which runs both implementations over shared inputs).
/// Only stored data feeds these: sessions.load (duration × RPE, computed and
/// stored by the DB), and the ratio itself is derived, never written back.

export interface LoadSession {
  date: string; // YYYY-MM-DD
  load: number;
}

export const ACUTE_SPAN_DAYS = 7;
export const CHRONIC_SPAN_DAYS = 28;
export const EWMA_LOOKBACK_DAYS = 90;

/// Exponentially-weighted moving average over a daily series, null-aware:
/// leading nulls stay null, interior nulls carry the previous EMA forward.
/// Same recurrence as the web's ewma().
export function ewma(
  values: (number | null)[],
  span: number,
): (number | null)[] {
  const lambda = 2 / (span + 1);
  const out: (number | null)[] = new Array<number | null>(values.length);
  let ema: number | null = null;
  for (let i = 0; i < values.length; i++) {
    const v = values[i] ?? null;
    if (v !== null) ema = ema === null ? v : v * lambda + ema * (1 - lambda);
    out[i] = ema;
  }
  return out;
}

export interface EwmaLoadState {
  acute: number;
  chronic: number;
}

/// The acute/chronic EWMA terms behind the ratio, as of the given reference
/// date (defaults to today). Mirrors metrics.ts ewmaLoadState(): a 90-day
/// daily load series mean-seeded before the EWMA recurrence.
export function ewmaLoadState(
  sessions: LoadSession[],
  referenceDate: string,
): EwmaLoadState | null {
  const loadByDate = new Map<string, number>();
  for (const s of sessions) {
    loadByDate.set(s.date, (loadByDate.get(s.date) ?? 0) + s.load);
  }
  const dailyLoads: number[] = [];
  for (let i = EWMA_LOOKBACK_DAYS - 1; i >= 0; i--) {
    const d = daysAgoFrom(referenceDate, i);
    dailyLoads.push(loadByDate.get(d) ?? 0);
  }
  if (dailyLoads.every((v) => v === 0)) return null;

  const seed = dailyLoads.reduce((s, v) => s + v, 0) / dailyLoads.length;
  const series = [seed, ...dailyLoads];
  return {
    acute: ewma(series, ACUTE_SPAN_DAYS)[series.length - 1]!,
    chronic: ewma(series, CHRONIC_SPAN_DAYS)[series.length - 1]!,
  };
}

export interface AcwrResult {
  acute: number;
  chronic: number;
  acwr: number | null;
}

/// Rolling acute (7d) / chronic-avg (28d ÷ 4) sums for display, plus the
/// EWMA ratio — identical shape to metrics.ts computeAcwr().
export function computeAcwr(
  sessions: LoadSession[],
  referenceDate: string,
): AcwrResult {
  const acute = sumLoadBetween(sessions, daysAgoFrom(referenceDate, 6), referenceDate);
  const chronic =
    sumLoadBetween(sessions, daysAgoFrom(referenceDate, 27), referenceDate) / 4;
  const state = ewmaLoadState(sessions, referenceDate);
  return {
    acute,
    chronic,
    acwr: state === null || state.chronic === 0 ? null : state.acute / state.chronic,
  };
}

/// Same zone thresholds as the web's getACWRStatus(), minus the CSS colors —
/// this is data, not presentation.
export function acwrStatusLabel(acwr: number | null): string {
  if (acwr === null) return "No data";
  if (acwr < 0.7) return "Under-training";
  if (acwr <= 0.8) return "Low";
  if (acwr <= 1.3) return "Optimal";
  if (acwr <= 1.5) return "Caution";
  return "Danger";
}

export interface WeeklyLoad {
  /// 0 = the week ending today, 1 = the week before, ...
  weekIndex: number;
  start: string;
  end: string;
  total: number;
}

/// Week buckets ending on `referenceDate`, mirroring metrics.ts
/// computeWeeklyLoads()'s [start = daysAgo(wb*7+6), end = daysAgo(wb*7)]
/// windows AND its ordering — oldest week first, exactly like the web's
/// `[3, 2, 1, 0].map(...)` for 4 weeks (extended to `weeks`).
export function computeWeeklyLoads(
  sessions: LoadSession[],
  referenceDate: string,
  weeks: number,
): WeeklyLoad[] {
  const out: WeeklyLoad[] = [];
  for (let wb = weeks - 1; wb >= 0; wb--) {
    const start = daysAgoFrom(referenceDate, wb * 7 + 6);
    const end = daysAgoFrom(referenceDate, wb * 7);
    out.push({
      weekIndex: wb,
      start,
      end,
      total: sumLoadBetween(sessions, start, end),
    });
  }
  return out;
}

function sumLoadBetween(
  sessions: LoadSession[],
  from: string,
  to: string,
): number {
  return sessions
    .filter((s) => s.date >= from && s.date <= to)
    .reduce((sum, s) => sum + s.load, 0);
}

function daysAgoFrom(referenceDate: string, n: number): string {
  const [y, m, d] = referenceDate.split("-").map(Number);
  const ref = new Date(y!, m! - 1, d!, 0, 0, 0, 0);
  ref.setDate(ref.getDate() - n);
  return dateStrLocal(ref);
}

function dateStrLocal(d: Date): string {
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}

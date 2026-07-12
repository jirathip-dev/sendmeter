import type {
  AcwrData,
  AcwrStatus,
  Session,
  TindeqRecordingMeta,
  WeeklyLoad,
} from "../types";
import { daysAgo, today } from "./dates";

export function getACWRStatus(acwr: number | null): AcwrStatus {
  if (acwr === null) return { label: "No data", color: "#6E6E73" };
  if (acwr < 0.7) return { label: "Under-training", color: "#5B5FC7" };
  if (acwr <= 0.8) return { label: "Low", color: "#7B83EB" };
  if (acwr <= 1.3) return { label: "Optimal", color: "#34C759" };
  if (acwr <= 1.5) return { label: "Caution", color: "#FFB800" };
  return { label: "Danger", color: "#FF453A" };
}

const EWMA_LOOKBACK_DAYS = 90;
const EWMA_LAMBDA_ACUTE = 2 / (7 + 1); // 7-day time constant
const EWMA_LAMBDA_CHRONIC = 2 / (28 + 1); // 28-day time constant

/// Exponentially-weighted acute:chronic ratio (Williams et al. 2016), which
/// the literature now favors over the plain rolling-average ratio: it
/// weights recent days more heavily and avoids "mathematical coupling"
/// (the acute window being a literal subset of the chronic window), giving
/// a more sensitive, more responsive signal. Both EWMAs are seeded with the
/// window's mean load (not a raw first-day value) to shrink the start-up
/// bias inherent to any EWMA — by 90 daily steps the seed's influence on
/// the chronic term has decayed to under 1%.
function ewmaAcwr(sessions: Session[]): number | null {
  const loadByDate = new Map<string, number>();
  for (const s of sessions) {
    loadByDate.set(s.date, (loadByDate.get(s.date) ?? 0) + s.load);
  }
  const dailyLoads: number[] = [];
  for (let i = EWMA_LOOKBACK_DAYS - 1; i >= 0; i--) {
    dailyLoads.push(loadByDate.get(daysAgo(i)) ?? 0);
  }
  if (dailyLoads.every((v) => v === 0)) return null;

  const seed = dailyLoads.reduce((s, v) => s + v, 0) / dailyLoads.length;
  let emaAcute = seed;
  let emaChronic = seed;
  for (const load of dailyLoads) {
    emaAcute = load * EWMA_LAMBDA_ACUTE + emaAcute * (1 - EWMA_LAMBDA_ACUTE);
    emaChronic = load * EWMA_LAMBDA_CHRONIC + emaChronic * (1 - EWMA_LAMBDA_CHRONIC);
  }
  return emaChronic > 0 ? emaAcute / emaChronic : null;
}

export function computeAcwr(sessions: Session[]): AcwrData {
  // acute/chronic stay simple rolling sums — they're shown as-is on the
  // Load card ("Acute 7d", "Chronic avg") where a plain total is the
  // intuitive read. Only the acwr ratio itself (and its risk zone) uses
  // the more sensitive EWMA method.
  const acute = sessions
    .filter((s) => s.date >= daysAgo(6) && s.date <= today())
    .reduce((sum, s) => sum + s.load, 0);
  const chronic =
    sessions
      .filter((s) => s.date >= daysAgo(27) && s.date <= today())
      .reduce((sum, s) => sum + s.load, 0) / 4;
  return { acute, chronic, acwr: ewmaAcwr(sessions) };
}

export interface TindeqStats {
  bestPeak: number;
  lastPeak: number;
  avg30d: number | null;
  delta: number | null; // lastPeak - avg30d
}

export function computeTindeqStats(
  recordings: TindeqRecordingMeta[],
): TindeqStats | null {
  if (recordings.length < 2) return null;
  const sorted = [...recordings].sort((a, b) =>
    a.recordedAt.localeCompare(b.recordedAt),
  );
  const last = sorted[sorted.length - 1]!;
  const bestPeak = Math.max(...sorted.map((r) => r.peakKg));
  const cutoff = Date.now() - 30 * 86400000;
  const window = sorted.filter(
    (r) => Date.parse(r.recordedAt) >= cutoff && r.id !== last.id,
  );
  const avg30d = window.length
    ? window.reduce((s, r) => s + r.peakKg, 0) / window.length
    : null;
  return {
    bestPeak,
    lastPeak: last.peakKg,
    avg30d,
    delta: avg30d === null ? null : last.peakKg - avg30d,
  };
}

export function computeWeeklyLoads(sessions: Session[]): WeeklyLoad[] {
  return [3, 2, 1, 0].map((wb) => {
    const start = daysAgo(wb * 7 + 6);
    const end = daysAgo(wb * 7);
    const total = sessions
      .filter((s) => s.date >= start && s.date <= end)
      .reduce((sum, s) => sum + s.load, 0);
    return { label: wb === 0 ? "Now" : `${wb}w`, total };
  });
}

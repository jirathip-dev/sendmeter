/// Pure merge/staleness logic behind `useLiveForce` (#309), pulled out so
/// the spark-buffer re-anchoring + overlap dedup + rolling-window trim are
/// unit-testable without React or a live WatchConnectivity listener.

import type { LiveForceMessage } from "sendlog-auth-bridge";

/// How long the beat may go quiet before the mirror hides. The watch beats
/// ~2 Hz while measuring and on every status change; 8s of silence means the
/// gauge screen closed, the watch app died, or the phone went unreachable.
export const STALE_MS = 8_000;

/// How far back the phone's own sparkline buffer reaches (SL-95). Each beat
/// only carries a capped trailing/backfill window (see
/// TindeqManager.ForceBeatWindow, issue #148) — the phone accumulates those
/// slices into this longer rolling history itself.
export const SPARK_WINDOW_MS = 45_000;

export interface LiveForceSample {
  atMs: number; // wall-clock epoch ms, re-anchored from the beat's relative t
  kg: number;
}

export interface LiveForce {
  status: "connected" | "measuring";
  kg: number;
  peakKg: number;
  elapsedMs: number;
  sessionCount: number;
  tag: string;
  side: string;
  updatedAt: number; // ms epoch
  /// Rolling ~45s buffer of recent force samples for the mirror sparkline,
  /// oldest first. Gaps (e.g. the rest between reps) simply aren't present —
  /// render as separate line runs rather than interpolating across them.
  spark: LiveForceSample[];
}

/// Merges one watch beat into the accumulated live-force state. Returns
/// `null` on an "idle" beat (mirror hides). Otherwise re-anchors the beat's
/// relative `[t, kg]` spark window to wall-clock time, dedups it against the
/// previous buffer (beats resend an overlapping trailing window — later beat
/// wins for a given rounded ms), and trims to the rolling `SPARK_WINDOW_MS`
/// window.
export function mergeForceBeat(
  prev: LiveForce | null,
  msg: LiveForceMessage,
): LiveForce | null {
  if (msg.status === "idle") return null;
  const status = msg.status; // narrowed off "idle"
  const updatedAtMs = msg.updated_at * 1000;
  const elapsedMs = msg.elapsed_ms ?? 0;
  // Wall-clock time of this beat's t=0 — lets each [t, kg] point be
  // re-anchored to absolute time even though `t` resets to 0 on every new
  // hold (TindeqManager.start() clears its sample buffer).
  const originMs = updatedAtMs - elapsedMs;
  const incoming: LiveForceSample[] = (msg.spark ?? []).map(([t, kg]) => ({
    atMs: originMs + t,
    kg,
  }));

  const byTime = new Map<number, number>();
  for (const p of prev?.spark ?? []) byTime.set(Math.round(p.atMs), p.kg);
  for (const p of incoming) byTime.set(Math.round(p.atMs), p.kg);
  // Dedup (beats resend an overlapping trailing window) + trim to the
  // rolling buffer window.
  const cutoff = updatedAtMs - SPARK_WINDOW_MS;
  const spark = Array.from(byTime.entries())
    .filter(([atMs]) => atMs >= cutoff)
    .sort((a, b) => a[0] - b[0])
    .map(([atMs, kg]) => ({ atMs, kg }));

  return {
    status,
    kg: msg.kg ?? 0,
    peakKg: msg.peak_kg ?? 0,
    elapsedMs,
    sessionCount: msg.session_count ?? 0,
    tag: msg.tag ?? "",
    side: msg.side ?? "",
    updatedAt: updatedAtMs,
    spark,
  };
}

/// Whether the given beat is still within the staleness window.
export function isFresh(beat: LiveForce, nowMs: number): boolean {
  return nowMs - beat.updatedAt <= STALE_MS;
}

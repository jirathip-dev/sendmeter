/// Pure merge/accumulation/staleness logic behind `useLiveWorkout` (#309),
/// pulled out so the WC-vs-realtime freshness race and the HR-series
/// accumulation are unit-testable without React or a live Supabase channel.

import type { LiveWorkoutMessage } from "sendlog-auth-bridge";
import type { LiveWorkout } from "../types";

/// How long a heartbeat may go quiet before the workout is presumed dead
/// (watch upserts every ~5s; 30s of silence = app killed / walked away).
export const STALE_MS = 30_000;

/// Placeholder workout id for a WC beat that arrives before the initial
/// `fetchLiveWorkout()` resolves — there's no `workout_id` on the WC path.
export const WC_PLACEHOLDER_ID = "wc-live";

/// WatchConnectivity beat → LiveWorkout (epoch seconds → ISO strings). The
/// WC path has no workout_id; keep the previous row's id so correlation
/// survives (beats always follow the initial Supabase row in practice).
export function messageToLive(
  msg: LiveWorkoutMessage,
  prev: LiveWorkout | null,
): LiveWorkout {
  const iso = (sec: number | undefined) =>
    sec !== undefined ? new Date(sec * 1000).toISOString() : null;
  return {
    workoutId: prev?.workoutId ?? WC_PLACEHOLDER_ID,
    status: msg.status,
    startedAt: iso(msg.started_at) ?? prev?.startedAt ?? new Date().toISOString(),
    hr: msg.hr ?? null,
    attemptCount: msg.attempt_count ?? 0,
    activeKcal: msg.active_kcal ?? null,
    elevationGainM: msg.elevation_gain_m ?? null,
    climbing: msg.climbing ?? false,
    climbingSince: iso(msg.climbing_since),
    restStartedAt: iso(msg.rest_started_at),
    restTargetS: msg.rest_target_s ?? null,
    updatedAt: iso(msg.updated_at) ?? new Date().toISOString(),
  };
}

export function rowToLive(row: Record<string, unknown>): LiveWorkout {
  return {
    workoutId: row.workout_id as string,
    status: row.status as LiveWorkout["status"],
    startedAt: row.started_at as string,
    hr: row.hr as number | null,
    attemptCount: row.attempt_count as number,
    activeKcal: row.active_kcal as number | null,
    elevationGainM: row.elevation_gain_m as number | null,
    climbing: row.climbing as boolean,
    climbingSince: (row.climbing_since as string | null) ?? null,
    restStartedAt: (row.rest_started_at as string | null) ?? null,
    restTargetS: (row.rest_target_s as number | null) ?? null,
    updatedAt: row.updated_at as string,
  };
}

/// One point of the client-accumulated live HR series (SL-90) — every
/// heartbeat's HR reading, collected while the mirror is open so the
/// fullscreen can chart the workout's HR in real time.
export interface LiveHrPoint {
  t: number; // ms epoch of the beat
  hr: number;
}

export interface HrLog {
  id: string;
  pts: LiveHrPoint[];
}

/// WC-vs-realtime freshness race: keep whichever source is newest. Equal
/// timestamps let the incoming beat win (mirrors the original `>` guard,
/// which only rejected a strictly-older incoming beat).
export function preferFresher(
  prev: LiveWorkout | null,
  incoming: LiveWorkout,
): LiveWorkout {
  if (prev && new Date(prev.updatedAt).getTime() > new Date(incoming.updatedAt).getTime()) {
    return prev; // a fresher supabase row already landed
  }
  return incoming;
}

/// Appends `next`'s HR reading to the series, keyed by workout id. A
/// placeholder→real id transition (a WC beat arrived before the initial
/// fetch resolved) carries the series forward instead of resetting it, since
/// `live_workouts` is one row per user — the placeholder and the fetched row
/// are the same workout. Any other id change (a genuinely new workout)
/// starts a fresh series. Duplicate/out-of-order beats (t <= last point) are
/// dropped.
export function appendHrPoint(prev: HrLog, next: LiveWorkout): HrLog {
  if (next.status !== "live" || next.hr === null) return prev;
  const pt: LiveHrPoint = { t: new Date(next.updatedAt).getTime(), hr: next.hr };
  if (prev.id !== next.workoutId) {
    const carried = prev.id === WC_PLACEHOLDER_ID ? prev.pts : [];
    const last = carried[carried.length - 1];
    if (last && pt.t <= last.t) return { id: next.workoutId, pts: carried };
    return { id: next.workoutId, pts: [...carried, pt] };
  }
  const last = prev.pts[prev.pts.length - 1];
  if (last && pt.t <= last.t) return prev; // duplicate/out-of-order beat
  return { id: prev.id, pts: [...prev.pts, pt] };
}

/// The hook's final visible state: hides an ended/missing/stale row and only
/// surfaces the HR series when it belongs to the currently-visible row.
export function visibleLiveWorkout(
  row: LiveWorkout | null,
  hrLog: HrLog,
  nowMs: number,
): [LiveWorkout | null, LiveHrPoint[]] {
  if (!row || row.status !== "live") return [null, []];
  if (nowMs - new Date(row.updatedAt).getTime() > STALE_MS) return [null, []];
  return [row, hrLog.id === row.workoutId ? hrLog.pts : []];
}

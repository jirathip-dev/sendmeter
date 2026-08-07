/// Session duration in minutes must land inside the DB's own bound (#487,
/// F3): `sessions.duration_min` has `check (duration_min between 1 and 600)`
/// (see supabase/migrations/20260711000000_initial_schema.sql). Several call
/// sites compute a duration from a wall-clock span and clamp it inline
/// (insertTindeqSession, insertPhoneWorkout); `recalcTindeqSessionDuration`
/// was the one spot that clamped only the floor, not the ceiling — a session
/// whose recordings span more than 600 minutes (e.g. a stray rep logged
/// weeks apart under the same group_id) hit the DB constraint on write
/// *after* the recordings had already been re-grouped, leaving the user with
/// regrouped recordings and no session. Centralizing here so every duration
/// computation shares one clamp, tested once.
export function clampDurationMin(min: number): number {
  return Math.max(1, Math.min(600, Math.round(min)));
}

export interface DurationSpanRecording {
  recordedAt: string;
  durationMs: number;
}

/// Duration (minutes, already clamped to the DB's 1..600 bound) of the span
/// from the first recording's start to the last recording's end — the
/// "total time" a Tindeq/gauge session actually took, independent of the
/// wall-clock moment it happened to be logged or recomputed. Returns null for
/// an empty list (nothing to compute — callers should leave the session's
/// existing duration alone rather than write a bogus one).
export function computeGroupDurationMin(
  recs: readonly DurationSpanRecording[],
): number | null {
  if (recs.length === 0) return null;
  const starts = recs.map((r) => Date.parse(r.recordedAt));
  const ends = recs.map((r) => Date.parse(r.recordedAt) + r.durationMs);
  const spanMs = Math.max(...ends) - Math.min(...starts);
  return clampDurationMin(spanMs / 60000);
}

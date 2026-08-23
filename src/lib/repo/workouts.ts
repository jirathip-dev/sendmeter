import { supabase } from "../supabase";
import type {
  LiveWorkout,
  PhaseId,
  RoutinePreset,
  RoutineStep,
  Session,
  WorkoutAttempt,
  WorkoutDetail,
  WorkoutHrSample,
  WorkoutListItem,
} from "../../types";
import { today } from "../dates";
import { workoutDurationMin } from "../pendingWorkouts";
import { unwrap } from "./shared";
import { unwrapOneMutation } from "../mutationInvariant";
import { toSession, type SessionRow } from "./sessions";
import { rowToLive } from "../liveWorkoutMirror";

// ---- Routine presets (Workout tab guided routine timer) ----

const ROUTINE_COLS = "id, name, steps";

type RoutineRow = { id: string; name: string; steps: RoutineStep[] };

export async function fetchRoutinePresets(): Promise<RoutinePreset[]> {
  const data = unwrap(
    await supabase
      .from("routine_presets")
      .select(ROUTINE_COLS)
      .is("deleted_at", null)
      .order("created_at", { ascending: false }),
  );
  return data as RoutineRow[];
}

export async function insertRoutinePreset(
  p: Omit<RoutinePreset, "id">,
): Promise<RoutinePreset> {
  const data = unwrap<RoutineRow>(
    await supabase
      .from("routine_presets")
      .insert({ name: p.name, steps: p.steps })
      .select(ROUTINE_COLS)
      .single(),
  );
  return data;
}

export async function updateRoutinePreset(
  id: string,
  p: Omit<RoutinePreset, "id">,
): Promise<RoutinePreset> {
  const data = unwrap<RoutineRow>(
    await supabase
      .from("routine_presets")
      .update({ name: p.name, steps: p.steps })
      .eq("id", id)
      .select(ROUTINE_COLS)
      .single(),
  );
  return data;
}

export async function deleteRoutinePreset(id: string): Promise<void> {
  unwrap(
    await supabase
      .from("routine_presets")
      .update({ deleted_at: new Date().toISOString() })
      .eq("id", id),
  );
}

const WORKOUT_DETAIL_COLS =
  "id, started_at, ended_at, source, avg_hr, max_hr, active_kcal, elevation_gain_m, attempts_detected, attempts_confirmed, rpe_predicted, rpe_confirmed, climb_attempts(started_at, duration_s, elevation_gain_m, avg_hr, peak_hr, effort_score, source)";

type WorkoutDetailRow = {
  id: string;
  started_at: string;
  ended_at: string;
  source: string;
  avg_hr: number | null;
  max_hr: number | null;
  active_kcal: number | null;
  elevation_gain_m: number;
  attempts_detected: number;
  attempts_confirmed: number;
  rpe_predicted: number | null;
  rpe_confirmed: number | null;
  climb_attempts: {
    started_at: string;
    duration_s: number;
    elevation_gain_m: number;
    avg_hr: number | null;
    peak_hr: number | null;
    effort_score: number | null;
    source: string;
  }[];
};

function toWorkoutDetail(data: WorkoutDetailRow): WorkoutDetail {
  return {
    id: data.id,
    startedAt: data.started_at,
    endedAt: data.ended_at,
    source: data.source as WorkoutDetail["source"],
    avgHr: data.avg_hr,
    maxHr: data.max_hr,
    activeKcal: data.active_kcal,
    elevationGainM: data.elevation_gain_m,
    attemptsDetected: data.attempts_detected,
    attemptsConfirmed: data.attempts_confirmed,
    rpePredicted: data.rpe_predicted === null ? null : Number(data.rpe_predicted),
    rpeConfirmed: data.rpe_confirmed,
    attempts: data.climb_attempts.map((a) => ({
      startedAt: a.started_at,
      durationS: a.duration_s,
      elevationGainM: a.elevation_gain_m,
      avgHr: a.avg_hr,
      peakHr: a.peak_hr,
      effortScore: a.effort_score,
      source: a.source as WorkoutAttempt["source"],
    })),
  };
}

export async function fetchWorkoutForSession(
  sessionId: string,
): Promise<WorkoutDetail | null> {
  const { data, error } = await supabase
    .from("climb_workouts")
    .select(WORKOUT_DETAIL_COLS)
    .eq("session_id", sessionId)
    .order("started_at", { referencedTable: "climb_attempts", ascending: true })
    .maybeSingle();
  if (error) throw error;
  return data ? toWorkoutDetail(data) : null;
}

export async function fetchWorkoutById(
  id: string,
): Promise<WorkoutDetail | null> {
  const { data, error } = await supabase
    .from("climb_workouts")
    .select(WORKOUT_DETAIL_COLS)
    .eq("id", id)
    .order("started_at", { referencedTable: "climb_attempts", ascending: true })
    .maybeSingle();
  if (error) throw error;
  return data ? toWorkoutDetail(data) : null;
}

/// Recent workouts WITH their attempts — feeds the summary stats card
/// (SL-85): avg climb/rest per workout, HR recovery trends.
export async function fetchRecentWorkoutDetails(
  limit = 10,
): Promise<WorkoutDetail[]> {
  const data = unwrap(
    await supabase
      .from("climb_workouts")
      .select(WORKOUT_DETAIL_COLS)
      .order("started_at", { ascending: false })
      .order("started_at", { referencedTable: "climb_attempts", ascending: true })
      .limit(limit),
  );
  return (data as WorkoutDetailRow[]).map(toWorkoutDetail);
}

/// Recent workouts for the Workout tab (metadata only; detail lazy-loads).
export async function fetchWorkouts(limit = 30): Promise<WorkoutListItem[]> {
  const data = unwrap(
    await supabase
      .from("climb_workouts")
      .select(
        "id, session_id, started_at, ended_at, avg_hr, attempts_confirmed, attempts_detected, rpe_confirmed, source",
      )
      .order("started_at", { ascending: false })
      .limit(limit),
  );
  return data.map((r) => ({
    id: r.id,
    sessionId: r.session_id,
    startedAt: r.started_at,
    endedAt: r.ended_at,
    avgHr: r.avg_hr,
    attemptsConfirmed: r.attempts_confirmed,
    attemptsDetected: r.attempts_detected,
    rpeConfirmed: r.rpe_confirmed,
    source: r.source as WorkoutListItem["source"],
  }));
}

/// The current live-workout heartbeat row, if any (the useLiveWorkout hook
/// applies the status/staleness rules).
export async function fetchLiveWorkout(): Promise<LiveWorkout | null> {
  const { data, error } = await supabase
    .from("live_workouts")
    .select("*")
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return rowToLive(data as unknown as Record<string, unknown>);
}

/// Save a phone-logged workout (SL-41): a sessions row (feeds ACWR/History,
/// workout_source='phone'), the climb_workouts row (source='phone', no HR /
/// raw trace), and one manual climb_attempts row per logged boulder.
///
/// #615: the three rows are created by ONE transactional RPC
/// (`create_phone_workout`) instead of three sequential inserts — partial
/// rows are impossible, and the caller's stable ids make a retry an
/// idempotent replay (the RPC returns the already-committed canonical
/// session for a known id). The ids are minted when the workout ends and
/// persisted with the confirming state, so a retry after a process restart
/// replays the same ids.
export async function insertPhoneWorkout(input: {
  sessionId: string;
  workoutId: string;
  startedAt: string;
  endedAt: string;
  attempts: { startedAt: string; durationS: number }[];
  type: string;
  typeLabel: string;
  rpe: number;
  phase: PhaseId;
}): Promise<Session> {
  const durationMin = workoutDurationMin(input.startedAt, input.endedAt);
  const n = input.attempts.length;
  const data = unwrapOneMutation<SessionRow>(
    await supabase
      .rpc("create_phone_workout", {
        p_session_id: input.sessionId,
        p_workout_id: input.workoutId,
        p_date: today(),
        p_type: input.type,
        p_type_label: input.typeLabel,
        p_duration_min: durationMin,
        p_rpe: input.rpe,
        p_note: `${n} boulder${n === 1 ? "" : "s"}`,
        p_phase: input.phase,
        p_started_at: input.startedAt,
        p_ended_at: input.endedAt,
        p_attempts: input.attempts.map((a) => ({
          started_at: a.startedAt,
          duration_s: a.durationS,
        })),
      })
      .single(),
  );
  // The RPC returns the canonical session row (same shape as SESSION_COLS).
  return toSession(data);
}

/// The workout's 1Hz HR trace, from climb_workouts.raw
/// ([[t_s, alt_m, motion_rms, hr], ...] — only t + hr survive the mapping).
/// Returns null when the workout kept no raw trace (older builds, phone
/// workouts) — the HR chart just doesn't render then.
export async function fetchWorkoutRaw(
  workoutId: string,
): Promise<WorkoutHrSample[] | null> {
  const data = unwrap<{ raw: [number, number, number, number | null][] | null }>(
    await supabase
      .from("climb_workouts")
      .select("raw")
      .eq("id", workoutId)
      .single(),
  );
  if (!data.raw || data.raw.length === 0) return null;
  return data.raw.map((s) => ({ t: s[0], hr: s[3] ?? null }));
}

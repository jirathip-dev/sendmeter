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
import { unwrap } from "./shared";
import { unwrapOneMutation } from "../mutationInvariant";

// ---- Routine presets (Workout tab guided routine timer) ----

const ROUTINE_COLS = "id, name, steps";

type RoutineRow = { id: string; name: string; steps: RoutineStep[] };

export async function fetchRoutinePresets(): Promise<RoutinePreset[]> {
  const data = unwrap(
    await supabase
      .from("routine_presets")
      .select(ROUTINE_COLS)
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
  unwrap(await supabase.from("routine_presets").delete().eq("id", id));
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
    .select(
      "workout_id, status, started_at, hr, attempt_count, active_kcal, elevation_gain_m, climbing, climbing_since, rest_started_at, rest_target_s, updated_at",
    )
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    workoutId: data.workout_id,
    status: data.status as LiveWorkout["status"],
    startedAt: data.started_at,
    hr: data.hr,
    attemptCount: data.attempt_count,
    activeKcal: data.active_kcal,
    elevationGainM: data.elevation_gain_m,
    climbing: data.climbing,
    climbingSince: data.climbing_since,
    restStartedAt: data.rest_started_at,
    restTargetS: data.rest_target_s,
    updatedAt: data.updated_at,
  };
}

/// Save a phone-logged workout (SL-41): a sessions row (feeds ACWR/History,
/// workout_source='phone'), the climb_workouts row (source='phone', no HR /
/// raw trace), and one manual climb_attempts row per logged boulder.
/// Sequential inserts — on a mid-flight failure the session may exist
/// without its workout; acceptable for v1 (retrying save is idempotent-ish
/// via the user just re-saving, and rows are user-deletable).
export async function insertPhoneWorkout(input: {
  startedAt: string;
  endedAt: string;
  attempts: { startedAt: string; durationS: number }[];
  type: string;
  typeLabel: string;
  rpe: number;
  phase: PhaseId;
}): Promise<Session> {
  const durationMin = Math.max(
    1,
    Math.min(
      600,
      Math.round(
        (new Date(input.endedAt).getTime() -
          new Date(input.startedAt).getTime()) /
          60000,
      ),
    ),
  );
  const n = input.attempts.length;
  const session = unwrapOneMutation<{ id: string }>(
    await supabase
      .from("sessions")
      .insert({
        date: today(),
        type: input.type,
        type_label: input.typeLabel,
        duration_min: durationMin,
        rpe: input.rpe,
        note: `${n} boulder${n === 1 ? "" : "s"}`,
        phase: input.phase,
        workout_source: "phone",
        // Unconfirmed until the user edits it away from the auto-save
        // default (issue #114) — see EditSessionSheet's rpe_confirmed: true.
        rpe_confirmed: false,
      })
      .select("id")
      .maybeSingle(),
  );
  const workout = unwrapOneMutation<{ id: string }>(
    await supabase
      .from("climb_workouts")
      .insert({
        started_at: input.startedAt,
        ended_at: input.endedAt,
        attempts_detected: 0,
        attempts_confirmed: n,
        rpe_confirmed: input.rpe,
        session_id: session.id,
        source: "phone",
      })
      .select("id")
      .maybeSingle(),
  );
  if (n > 0) {
    unwrap(
      await supabase.from("climb_attempts").insert(
        input.attempts.map((a) => ({
          workout_id: workout.id,
          started_at: a.startedAt,
          duration_s: a.durationS,
          elevation_gain_m: 0,
          source: "manual",
        })),
      ),
    );
  }
  // Return the saved session so callers can offer an immediate "Edit" (the
  // auto-save-on-stop flow toasts with an edit action).
  return {
    id: session.id,
    date: today(),
    type: input.type,
    typeLabel: input.typeLabel,
    duration: durationMin,
    rpe: input.rpe,
    rpeConfirmed: false,
    load: durationMin * input.rpe,
    note: `${n} boulder${n === 1 ? "" : "s"}`,
    phase: input.phase,
    groupId: null,
    workoutSource: "phone",
  };
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

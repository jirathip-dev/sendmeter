import { supabase } from "./supabase";
import type {
  HealthMetric,
  LogFormState,
  NewTindeqRecording,
  PhaseId,
  PhasePeriod,
  RpePair,
  Session,
  TindeqRecordingMeta,
  TindeqSample,
  TindeqSide,
  WorkoutDetail,
} from "../types";
import { SESSION_TYPES } from "../constants";
import { today } from "./dates";

type SessionRow = {
  id: string;
  date: string;
  type: string;
  type_label: string;
  duration_min: number;
  rpe: number;
  load: number | null; // generated column, only null in Postgres edge cases
  note: string;
  phase: string;
  group_id: string | null;
};

const SESSION_COLS =
  "id, date, type, type_label, duration_min, rpe, load, note, phase, group_id";

function toSession(r: SessionRow): Session {
  return {
    id: r.id,
    date: r.date,
    type: r.type,
    typeLabel: r.type_label,
    duration: r.duration_min,
    rpe: r.rpe,
    load: r.load ?? r.duration_min * r.rpe,
    note: r.note,
    phase: r.phase as PhaseId,
    groupId: r.group_id,
  };
}

export async function fetchSessions(): Promise<Session[]> {
  const { data, error } = await supabase
    .from("sessions")
    .select(SESSION_COLS)
    .order("date", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data.map(toSession);
}

export async function insertSession(form: LogFormState): Promise<Session> {
  const typeInfo = SESSION_TYPES.find((t) => t.id === form.type);
  const { data, error } = await supabase
    .from("sessions")
    .insert({
      date: form.date,
      type: form.type,
      type_label: typeInfo?.label || form.type,
      duration_min: form.duration,
      rpe: form.rpe,
      note: form.note,
      phase: form.phase,
    })
    .select(SESSION_COLS)
    .single();
  if (error) throw error;
  return toSession(data);
}

/// Log a completed Tindeq gauge session into the training log so it feeds
/// ACWR and shows in History, linked back to its recordings via group_id.
export async function insertTindeqSession(input: {
  durationMin: number;
  rpe: number;
  phase: PhaseId;
  note: string;
  groupId: string;
}): Promise<Session> {
  const { data, error } = await supabase
    .from("sessions")
    .insert({
      date: today(),
      type: "tindeq",
      type_label: "Tindeq",
      duration_min: Math.max(1, Math.min(600, input.durationMin)),
      rpe: input.rpe,
      note: input.note,
      phase: input.phase,
      group_id: input.groupId,
    })
    .select(SESSION_COLS)
    .single();
  if (error) throw error;
  return toSession(data);
}

export async function deleteSession(id: string): Promise<void> {
  const { error } = await supabase.from("sessions").delete().eq("id", id);
  if (error) throw error;
}

export interface UserSettings {
  currentPhase: PhaseId;
  phaseStartDate: string;
}

export async function fetchSettings(): Promise<UserSettings> {
  const { data, error } = await supabase
    .from("user_settings")
    .select("current_phase, phase_start_date")
    .maybeSingle();
  if (error) throw error;
  if (data) {
    return {
      currentPhase: data.current_phase as PhaseId,
      phaseStartDate: data.phase_start_date,
    };
  }
  const defaults = { current_phase: "capacity", phase_start_date: today() };
  const { error: upsertError } = await supabase
    .from("user_settings")
    .upsert(defaults);
  if (upsertError) throw upsertError;
  return { currentPhase: "capacity", phaseStartDate: defaults.phase_start_date };
}

export async function updateSettings(s: UserSettings): Promise<void> {
  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError) throw userError;
  const { error } = await supabase.from("user_settings").upsert({
    user_id: userData.user.id,
    current_phase: s.currentPhase,
    phase_start_date: s.phaseStartDate,
    updated_at: new Date().toISOString(),
  });
  if (error) throw error;
}

function toPhasePeriod(r: {
  id: string;
  phase: string;
  started_on: string;
  ended_on: string | null;
}): PhasePeriod {
  return {
    id: r.id,
    phase: r.phase as PhaseId,
    startedOn: r.started_on,
    endedOn: r.ended_on,
  };
}

export async function fetchPhasePeriods(): Promise<PhasePeriod[]> {
  const { data, error } = await supabase
    .from("phase_periods")
    .select("id, phase, started_on, ended_on")
    .order("started_on", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data.map(toPhasePeriod);
}

/// Switch the current phase, preserving history. Exactly one open period
/// (ended_on null) exists per user — enforced by a partial unique index.
/// Same-day switches never leave 1-day sliver rows: switching back to the
/// phase you just left reopens it (full undo, day count restored).
export async function switchPhase(
  newPhase: PhaseId,
): Promise<{ periods: PhasePeriod[]; settings: UserSettings }> {
  const t = today();
  const periods = await fetchPhasePeriods();
  const open = periods.find((p) => p.endedOn === null);

  async function syncSettings(startedOn: string): Promise<void> {
    await updateSettings({ currentPhase: newPhase, phaseStartDate: startedOn });
  }

  if (!open) {
    const { error } = await supabase
      .from("phase_periods")
      .insert({ phase: newPhase, started_on: t });
    if (error) throw error;
    await syncSettings(t);
  } else if (open.phase === newPhase) {
    // no-op
  } else if (open.startedOn === t) {
    // Same-day sliver: undo back to the previous phase, or relabel in place.
    const prev = periods
      .filter((p) => p.endedOn !== null)
      .sort((a, b) => b.endedOn!.localeCompare(a.endedOn!))[0];
    if (prev && prev.phase === newPhase && prev.endedOn === t) {
      // Undo: delete the sliver first so the one-open index never sees two.
      const { error: delError } = await supabase
        .from("phase_periods")
        .delete()
        .eq("id", open.id);
      if (delError) throw delError;
      const { error: reopenError } = await supabase
        .from("phase_periods")
        .update({ ended_on: null })
        .eq("id", prev.id);
      if (reopenError) throw reopenError;
      await syncSettings(prev.startedOn);
    } else {
      const { error } = await supabase
        .from("phase_periods")
        .update({ phase: newPhase })
        .eq("id", open.id);
      if (error) throw error;
      await syncSettings(open.startedOn);
    }
  } else {
    const { error: closeError } = await supabase
      .from("phase_periods")
      .update({ ended_on: t })
      .eq("id", open.id);
    if (closeError) throw closeError;
    const { error: insertError } = await supabase
      .from("phase_periods")
      .insert({ phase: newPhase, started_on: t });
    if (insertError) throw insertError;
    await syncSettings(t);
  }

  const refreshed = await fetchPhasePeriods();
  const nowOpen = refreshed.find((p) => p.endedOn === null);
  return {
    periods: refreshed,
    settings: {
      currentPhase: (nowOpen?.phase ?? newPhase) as PhaseId,
      phaseStartDate: nowOpen?.startedOn ?? t,
    },
  };
}

export async function fetchRecordings(): Promise<TindeqRecordingMeta[]> {
  // samples deliberately excluded — the list view only needs metadata
  const { data, error } = await supabase
    .from("tindeq_recordings")
    .select(
      "id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id",
    )
    .order("recorded_at", { ascending: false });
  if (error) throw error;
  return data.map((r) => ({
    id: r.id,
    recordedAt: r.recorded_at,
    durationMs: r.duration_ms,
    peakKg: r.peak_kg,
    avgKg: r.avg_kg,
    sampleCount: r.sample_count,
    note: r.note,
    tag: r.tag,
    side: r.side as TindeqSide,
    groupId: r.group_id,
  }));
}

export async function fetchRecordingsByGroup(
  groupId: string,
): Promise<TindeqRecordingMeta[]> {
  const { data, error } = await supabase
    .from("tindeq_recordings")
    .select(
      "id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id",
    )
    .eq("group_id", groupId)
    .order("recorded_at", { ascending: true });
  if (error) throw error;
  return data.map((r) => ({
    id: r.id,
    recordedAt: r.recorded_at,
    durationMs: r.duration_ms,
    peakKg: r.peak_kg,
    avgKg: r.avg_kg,
    sampleCount: r.sample_count,
    note: r.note,
    tag: r.tag,
    side: r.side as TindeqSide,
    groupId: r.group_id,
  }));
}

export async function fetchRecordingSamples(
  id: string,
): Promise<TindeqSample[]> {
  const { data, error } = await supabase
    .from("tindeq_recordings")
    .select("samples")
    .eq("id", id)
    .single();
  if (error) throw error;
  return (data.samples as [number, number][]).map(([t, kg]) => ({ t, kg }));
}

export async function insertRecording(
  rec: NewTindeqRecording,
): Promise<TindeqRecordingMeta> {
  const { data, error } = await supabase
    .from("tindeq_recordings")
    .insert({
      duration_ms: rec.durationMs,
      peak_kg: rec.peakKg,
      avg_kg: rec.avgKg,
      sample_count: rec.samples.length,
      note: rec.note,
      tag: rec.tag,
      side: rec.side,
      group_id: rec.groupId,
      samples: rec.samples.map((s) => [s.t, s.kg]),
    })
    .select(
      "id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id",
    )
    .single();
  if (error) throw error;
  return {
    id: data.id,
    recordedAt: data.recorded_at,
    durationMs: data.duration_ms,
    peakKg: data.peak_kg,
    avgKg: data.avg_kg,
    sampleCount: data.sample_count,
    note: data.note,
    tag: data.tag,
    side: data.side as TindeqSide,
    groupId: data.group_id,
  };
}

/// Deletes the auth user; every table cascades from auth.users, so all data
/// goes with it. Required by App Store guideline 5.1.1(v).
export async function deleteAccount(): Promise<void> {
  const { error } = await supabase.rpc("delete_account");
  if (error) throw error;
  await supabase.auth.signOut();
}

export async function fetchHealthMetrics(days = 14): Promise<HealthMetric[]> {
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - days);
  const cutoffStr = `${cutoff.getFullYear()}-${String(cutoff.getMonth() + 1).padStart(2, "0")}-${String(cutoff.getDate()).padStart(2, "0")}`;
  const { data, error } = await supabase
    .from("health_metrics")
    .select(
      "date, readiness, zone, hrv_sdnn_ms, resting_hr, sleep_hours, body_mass_kg",
    )
    .gte("date", cutoffStr)
    .order("date", { ascending: true });
  if (error) throw error;
  return data.map((r) => ({
    date: r.date,
    readiness: r.readiness,
    zone: r.zone,
    hrvSdnnMs: r.hrv_sdnn_ms,
    restingHr: r.resting_hr,
    sleepHours: r.sleep_hours,
    bodyMassKg: r.body_mass_kg,
  }));
}

export async function fetchRpePairs(): Promise<RpePair[]> {
  const { data, error } = await supabase
    .from("climb_workouts")
    .select("rpe_predicted, rpe_confirmed, started_at")
    .not("rpe_predicted", "is", null)
    .not("rpe_confirmed", "is", null)
    .order("started_at", { ascending: true });
  if (error) throw error;
  return data.map((r) => ({
    predicted: Number(r.rpe_predicted),
    confirmed: r.rpe_confirmed as number,
    startedAt: r.started_at,
  }));
}

export async function fetchWorkoutForSession(
  sessionId: string,
): Promise<WorkoutDetail | null> {
  const { data, error } = await supabase
    .from("climb_workouts")
    .select(
      "id, avg_hr, max_hr, active_kcal, elevation_gain_m, attempts_detected, attempts_confirmed, rpe_predicted, rpe_confirmed, climb_attempts(started_at, duration_s, elevation_gain_m, avg_hr, peak_hr, effort_score)",
    )
    .eq("session_id", sessionId)
    .order("started_at", { referencedTable: "climb_attempts", ascending: true })
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    id: data.id,
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
    })),
  };
}

export async function deleteRecording(id: string): Promise<void> {
  const { error } = await supabase
    .from("tindeq_recordings")
    .delete()
    .eq("id", id);
  if (error) throw error;
}

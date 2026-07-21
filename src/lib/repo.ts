import { supabase } from "./supabase";
import type {
  DeletedSession,
  DeletedTindeqRecording,
  HealthMetric,
  LiveWorkout,
  LogFormState,
  NewTindeqRecording,
  PhaseId,
  PhasePeriod,
  Session,
  SessionPatch,
  TindeqPreset,
  TindeqRecordingMeta,
  RoutinePreset,
  RoutineStep,
  TindeqSample,
  TindeqSide,
  WorkoutAttempt,
  WorkoutDetail,
  WorkoutHrSample,
  WorkoutListItem,
} from "../types";
import { SESSION_TYPES } from "../constants";
import { today } from "./dates";

/// Throws on a Postgrest error, otherwise returns `data`. Safe for any
/// query except `.maybeSingle()`, where `data: null` with no error is a
/// legitimate "no row" result rather than something this cast should paper
/// over — those call sites keep their own explicit error check.
function unwrap<T>(result: {
  data: T | null;
  error: { message: string } | null;
}): T {
  if (result.error) throw result.error;
  return result.data as T;
}

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
  workout_source: string | null;
};

const SESSION_COLS =
  "id, date, type, type_label, duration_min, rpe, load, note, phase, group_id, workout_source";

function toSession(r: SessionRow): Session {
  return {
    id: r.id,
    date: r.date,
    type: r.type,
    typeLabel: r.type_label,
    duration: r.duration_min,
    rpe: r.rpe,
    load: r.load ?? Math.round(r.duration_min * r.rpe),
    note: r.note,
    phase: r.phase as PhaseId,
    groupId: r.group_id,
    // Fallback for rows written by watch builds that predate workout_source:
    // they still mark themselves with type='auto'.
    workoutSource:
      (r.workout_source as Session["workoutSource"]) ??
      (r.type === "auto" ? "watch" : null),
  };
}

export async function fetchSessions(): Promise<Session[]> {
  const data = unwrap(
    await supabase
      .from("sessions")
      .select(SESSION_COLS)
      .is("deleted_at", null)
      .order("date", { ascending: false })
      .order("created_at", { ascending: false }),
  );
  return data.map(toSession);
}

export async function fetchDeletedSessions(): Promise<DeletedSession[]> {
  const data = unwrap(
    await supabase
      .from("sessions")
      .select(`${SESSION_COLS}, deleted_at`)
      .not("deleted_at", "is", null)
      .order("deleted_at", { ascending: false }),
  );
  return data.map((r) => ({ ...toSession(r), deletedAt: r.deleted_at! }));
}

export async function insertSession(form: LogFormState): Promise<Session> {
  const typeInfo = SESSION_TYPES.find((t) => t.id === form.type);
  const data = unwrap<SessionRow>(
    await supabase
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
      .single(),
  );
  return toSession(data);
}

/// Edit a session's user-facing fields (SL-43). Deliberately narrow: date,
/// phase, group_id, and workout_source are not editable — the last is the
/// immutable auto-tracked provenance badge.
export async function updateSession(
  id: string,
  patch: SessionPatch,
): Promise<Session> {
  const data = unwrap<SessionRow>(
    await supabase
      .from("sessions")
      .update({
        type: patch.type,
        type_label: patch.typeLabel,
        duration_min: patch.duration,
        rpe: patch.rpe,
        note: patch.note,
      })
      .eq("id", id)
      .select(SESSION_COLS)
      .single(),
  );
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
  /// Defaults to today — History's create-from-recordings passes the
  /// recordings' own date.
  date?: string;
}): Promise<Session> {
  const data = unwrap<SessionRow>(
    await supabase
      .from("sessions")
      .insert({
        date: input.date ?? today(),
        type: "tindeq",
        type_label: "Tindeq",
        duration_min: Math.max(1, Math.min(600, input.durationMin)),
        rpe: input.rpe,
        note: input.note,
        phase: input.phase,
        group_id: input.groupId,
      })
      .select(SESSION_COLS)
      .single(),
  );
  return toSession(data);
}

/// Factory for the soft-delete/restore/purge triplet shared by `sessions`
/// and `tindeq_recordings` — both tables follow the same `deleted_at`
/// convention (see the soft_delete migration).
function makeSoftDeleteOps(table: "sessions" | "tindeq_recordings") {
  return {
    /// Soft delete: sets deleted_at so the row can be recovered from Trash.
    async remove(id: string): Promise<void> {
      unwrap(
        await supabase
          .from(table)
          .update({ deleted_at: new Date().toISOString() })
          .eq("id", id),
      );
    },
    async restore(id: string): Promise<void> {
      unwrap(
        await supabase.from(table).update({ deleted_at: null }).eq("id", id),
      );
    },
    /// Permanent delete — used only from the Trash view's "Delete forever".
    async purge(id: string): Promise<void> {
      unwrap(await supabase.from(table).delete().eq("id", id));
    },
  };
}

const sessionSoftDelete = makeSoftDeleteOps("sessions");
export const deleteSession = sessionSoftDelete.remove;
export const restoreSession = sessionSoftDelete.restore;
export const purgeSession = sessionSoftDelete.purge;

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
  unwrap(await supabase.from("user_settings").upsert(defaults));
  return { currentPhase: "capacity", phaseStartDate: defaults.phase_start_date };
}

export async function updateSettings(s: UserSettings): Promise<void> {
  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError) throw userError;
  unwrap(
    await supabase.from("user_settings").upsert({
      user_id: userData.user.id,
      current_phase: s.currentPhase,
      phase_start_date: s.phaseStartDate,
      updated_at: new Date().toISOString(),
    }),
  );
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
  const data = unwrap(
    await supabase
      .from("phase_periods")
      .select("id, phase, started_on, ended_on")
      .order("started_on", { ascending: false })
      .order("created_at", { ascending: false }),
  );
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
    unwrap(
      await supabase
        .from("phase_periods")
        .insert({ phase: newPhase, started_on: t }),
    );
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
      unwrap(
        await supabase.from("phase_periods").delete().eq("id", open.id),
      );
      unwrap(
        await supabase
          .from("phase_periods")
          .update({ ended_on: null })
          .eq("id", prev.id),
      );
      await syncSettings(prev.startedOn);
    } else {
      unwrap(
        await supabase
          .from("phase_periods")
          .update({ phase: newPhase })
          .eq("id", open.id),
      );
      await syncSettings(open.startedOn);
    }
  } else {
    unwrap(
      await supabase
        .from("phase_periods")
        .update({ ended_on: t })
        .eq("id", open.id),
    );
    unwrap(
      await supabase
        .from("phase_periods")
        .insert({ phase: newPhase, started_on: t }),
    );
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

const RECORDING_COLS =
  "id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id, protocol_run_id, set_no";

type RecordingRow = {
  id: string;
  recorded_at: string;
  duration_ms: number;
  peak_kg: number;
  avg_kg: number;
  sample_count: number;
  note: string;
  tag: string;
  side: string;
  group_id: string | null;
  protocol_run_id: string | null;
  set_no: number | null;
};

function toRecording(r: RecordingRow): TindeqRecordingMeta {
  return {
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
    protocolRunId: r.protocol_run_id,
    setNo: r.set_no,
  };
}

export async function fetchRecordings(): Promise<TindeqRecordingMeta[]> {
  // samples deliberately excluded — the list view only needs metadata
  const data = unwrap(
    await supabase
      .from("tindeq_recordings")
      .select(RECORDING_COLS)
      .is("deleted_at", null)
      .order("recorded_at", { ascending: false }),
  );
  return data.map(toRecording);
}

export async function fetchDeletedRecordings(): Promise<
  DeletedTindeqRecording[]
> {
  const data = unwrap(
    await supabase
      .from("tindeq_recordings")
      .select(`${RECORDING_COLS}, deleted_at`)
      .not("deleted_at", "is", null)
      .order("deleted_at", { ascending: false }),
  );
  return data.map((r) => ({ ...toRecording(r), deletedAt: r.deleted_at! }));
}

export async function fetchRecordingsByGroup(
  groupId: string,
): Promise<TindeqRecordingMeta[]> {
  const data = unwrap(
    await supabase
      .from("tindeq_recordings")
      .select(RECORDING_COLS)
      .eq("group_id", groupId)
      .is("deleted_at", null)
      // Newest-first, matching the outer History timeline (SL-58) — a session's
      // reps read top-to-bottom the same way loose recordings do.
      .order("recorded_at", { ascending: false }),
  );
  return data.map(toRecording);
}

export async function fetchRecordingSamples(
  id: string,
): Promise<TindeqSample[]> {
  const data = unwrap<{ samples: [number, number][] }>(
    await supabase.from("tindeq_recordings").select("samples").eq("id", id).single(),
  );
  return data.samples.map(([t, kg]) => ({ t, kg }));
}

export async function insertRecording(
  rec: NewTindeqRecording,
): Promise<TindeqRecordingMeta> {
  const data = unwrap<RecordingRow>(
    await supabase
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
        protocol_run_id: rec.protocolRunId,
        set_no: rec.setNo,
        samples: rec.samples.map((s) => [s.t, s.kg]),
      })
      .select(RECORDING_COLS)
      .single(),
  );
  return toRecording(data);
}

// MARK: Tindeq presets (hang protocols for the guided gauge timer)

const PRESET_COLS =
  "id, name, hold_s, reps, sets, rest_reps_s, rest_sets_s, target_kg, target_pct, pct_basis, pct_step, target_curve, alternate_sides";

type PresetRow = {
  id: string;
  name: string;
  hold_s: number;
  reps: number;
  sets: number;
  rest_reps_s: number;
  rest_sets_s: number;
  target_kg: number | null;
  target_pct: number | null;
  pct_basis: string;
  pct_step: number;
  target_curve: boolean;
  alternate_sides: boolean;
};

function toPreset(r: PresetRow): TindeqPreset {
  return {
    id: r.id,
    name: r.name,
    holdS: r.hold_s,
    reps: r.reps,
    sets: r.sets,
    restRepsS: r.rest_reps_s,
    restSetsS: r.rest_sets_s,
    targetKg: r.target_kg,
    targetPct: r.target_pct,
    pctBasis: r.pct_basis === "cf" ? "cf" : "pr",
    pctStep: r.pct_step,
    targetCurve: r.target_curve,
    alternateSides: r.alternate_sides,
  };
}

function presetToRow(p: Omit<TindeqPreset, "id">) {
  return {
    name: p.name,
    hold_s: p.holdS,
    reps: p.reps,
    sets: p.sets,
    rest_reps_s: p.restRepsS,
    rest_sets_s: p.restSetsS,
    target_kg: p.targetKg,
    target_pct: p.targetPct,
    pct_basis: p.pctBasis,
    pct_step: p.pctStep,
    target_curve: p.targetCurve,
    alternate_sides: p.alternateSides,
  };
}

export async function fetchPresets(): Promise<TindeqPreset[]> {
  const data = unwrap(
    await supabase
      .from("tindeq_presets")
      .select(PRESET_COLS)
      .order("created_at", { ascending: false }),
  );
  return data.map(toPreset);
}

export async function insertPreset(
  p: Omit<TindeqPreset, "id">,
): Promise<TindeqPreset> {
  const data = unwrap<PresetRow>(
    await supabase
      .from("tindeq_presets")
      .insert(presetToRow(p))
      .select(PRESET_COLS)
      .single(),
  );
  return toPreset(data);
}

export async function updatePreset(
  id: string,
  p: Omit<TindeqPreset, "id">,
): Promise<TindeqPreset> {
  const data = unwrap<PresetRow>(
    await supabase
      .from("tindeq_presets")
      .update(presetToRow(p))
      .eq("id", id)
      .select(PRESET_COLS)
      .single(),
  );
  return toPreset(data);
}

export async function deletePreset(id: string): Promise<void> {
  unwrap(await supabase.from("tindeq_presets").delete().eq("id", id));
}

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

/// Assign an ungrouped recording to an existing gauge-session group (SL-44).
/// Grouping-only: the linked session's note/duration/RPE are left as logged.
export async function updateRecordingGroup(
  id: string,
  groupId: string,
): Promise<TindeqRecordingMeta> {
  const data = unwrap<RecordingRow>(
    await supabase
      .from("tindeq_recordings")
      .update({ group_id: groupId })
      .eq("id", id)
      .select(RECORDING_COLS)
      .single(),
  );
  return toRecording(data);
}

/// Recompute a Tindeq session's duration from its recordings' actual time span
/// (first rep's start → last rep's end) and persist it. Keeps the session's
/// "total time" — and the load/ACWR it drives — honest as recordings are
/// assigned in or removed, instead of frozen at the wall-clock value from when
/// it was logged. No-op if the group has no live recordings. Returns the
/// minutes written (or null when nothing to compute).
export async function recalcTindeqSessionDuration(
  groupId: string,
): Promise<number | null> {
  const recs = await fetchRecordingsByGroup(groupId);
  if (recs.length === 0) return null;
  const starts = recs.map((r) => Date.parse(r.recordedAt));
  const ends = recs.map((r) => Date.parse(r.recordedAt) + r.durationMs);
  const spanMs = Math.max(...ends) - Math.min(...starts);
  const durationMin = Math.max(1, Math.round(spanMs / 60000));
  unwrap(
    await supabase
      .from("sessions")
      .update({ duration_min: durationMin })
      .eq("group_id", groupId)
      .is("deleted_at", null)
      .select("id"),
  );
  return durationMin;
}

/// Edit a recording's label fields after the fact (SL-58: users forget to set
/// tag/side before a rep). Only tag/side/note — never the samples.
export async function updateRecordingMeta(
  id: string,
  patch: { tag: string; side: TindeqSide; note: string },
): Promise<TindeqRecordingMeta> {
  const data = unwrap<RecordingRow>(
    await supabase
      .from("tindeq_recordings")
      .update({ tag: patch.tag, side: patch.side, note: patch.note })
      .eq("id", id)
      .select(RECORDING_COLS)
      .single(),
  );
  return toRecording(data);
}

/// Bulk tag/side/note edit for every recording in a set or run (SL-79).
export async function updateRecordingsMeta(
  ids: string[],
  patch: { tag: string; side: TindeqSide; note: string },
): Promise<TindeqRecordingMeta[]> {
  if (ids.length === 0) return [];
  const data = unwrap<RecordingRow[]>(
    await supabase
      .from("tindeq_recordings")
      .update({ tag: patch.tag, side: patch.side, note: patch.note })
      .in("id", ids)
      .select(RECORDING_COLS),
  );
  return data.map(toRecording);
}

// MARK: Tag management (SL-92) — rename across the whole dataset + hide.
// Tags stay denormalized as tindeq_recordings.tag; tindeq_tags only holds the
// hidden flag (see the migration comment). A tag needs a row here only when
// hidden — visible tags come from distinct recording tags.

/// Names of the user's hidden tags, filtered out of the Force-tab pickers,
/// trend and curve (the recordings themselves are untouched).
export async function fetchHiddenTags(): Promise<string[]> {
  const data = unwrap<{ name: string }[]>(
    await supabase.from("tindeq_tags").select("name").eq("hidden", true),
  );
  return data.map((r) => r.name);
}

/// Rename a tag EVERYWHERE — repoints every recording carrying `oldName` to
/// `newName` and clears any stale registry row, atomically (DB function). If
/// `newName` already exists the two tags merge.
export async function renameTag(
  oldName: string,
  newName: string,
): Promise<void> {
  const name = newName.trim();
  if (!name) throw new Error("Tag name can't be empty");
  unwrap(
    await supabase.rpc("rename_tindeq_tag", {
      old_name: oldName,
      new_name: name,
    }),
  );
}

/// Hide or unhide a tag. Upserts the registry row (user_id defaults to
/// auth.uid()); the recordings are never touched.
export async function setTagHidden(
  name: string,
  hidden: boolean,
): Promise<void> {
  const { error } = await supabase
    .from("tindeq_tags")
    .upsert({ name, hidden }, { onConflict: "user_id,name" });
  if (error) throw error;
}

/// Deletes the auth user; every table cascades from auth.users, so all data
/// goes with it. Required by App Store guideline 5.1.1(v).
export async function deleteAccount(): Promise<void> {
  unwrap(await supabase.rpc("delete_account"));
  await supabase.auth.signOut();
}

export async function fetchHealthMetrics(days = 14): Promise<HealthMetric[]> {
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - days);
  const cutoffStr = `${cutoff.getFullYear()}-${String(cutoff.getMonth() + 1).padStart(2, "0")}-${String(cutoff.getDate()).padStart(2, "0")}`;
  const data = unwrap(
    await supabase
      .from("health_metrics")
      .select(
        "date, readiness, zone, hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours, sleep_rem_hours, body_mass_kg, resp_rate_bpm",
      )
      .gte("date", cutoffStr)
      .order("date", { ascending: true }),
  );
  return data.map((r) => ({
    date: r.date,
    readiness: r.readiness,
    zone: r.zone,
    hrvSdnnMs: r.hrv_sdnn_ms,
    restingHr: r.resting_hr,
    sleepHours: r.sleep_hours,
    sleepDeepHours: r.sleep_deep_hours,
    sleepRemHours: r.sleep_rem_hours,
    bodyMassKg: r.body_mass_kg,
    respRateBpm: r.resp_rate_bpm,
  }));
}

/// Full body-weight history (SL-88) — every dated weigh-in, oldest first.
/// The strength-to-weight trend forward-fills these across rep dates, so it
/// needs the whole history, not the dashboard's 14-day window.
export async function fetchWeightHistory(): Promise<
  { date: string; kg: number }[]
> {
  const data = unwrap(
    await supabase
      .from("health_metrics")
      .select("date, body_mass_kg")
      .not("body_mass_kg", "is", null)
      .order("date", { ascending: true }),
  );
  return data.map((r) => ({ date: r.date, kg: r.body_mass_kg as number }));
}

/// Hard-deletes the signed-in user's health_metrics rows (RLS scopes to
/// auth.uid()). Used by "Clear health data & resync" to recover from data
/// polluted by e.g. the watch being worn by someone else. Defaults to all
/// rows; pass `from`/`to` (YYYY-MM-DD) to limit to a date range. A lower
/// date bound is always sent so PostgREST never sees an unfiltered delete.
export async function deleteHealthMetrics(opts?: {
  from?: string;
  to?: string;
}): Promise<void> {
  // Guard: an unauthenticated DELETE isn't an error — RLS just matches zero
  // rows and reports success, so the UI would claim "cleared" while nothing
  // happened (seen when a revoked session fell back to anon). Fail loudly
  // instead so the user knows to sign in again.
  const { data, error: userError } = await supabase.auth.getUser();
  if (userError || !data.user) {
    throw new Error("Session expired — sign in again, then retry the clear.");
  }
  let q = supabase
    .from("health_metrics")
    .delete()
    .gte("date", opts?.from ?? "2000-01-01");
  if (opts?.to) q = q.lte("date", opts.to);
  const { error } = await q;
  if (error) throw error;
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
  const session = unwrap<{ id: string }>(
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
      })
      .select("id")
      .single(),
  );
  const workout = unwrap<{ id: string }>(
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
      .single(),
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

const recordingSoftDelete = makeSoftDeleteOps("tindeq_recordings");
export const deleteRecording = recordingSoftDelete.remove;
export const restoreRecording = recordingSoftDelete.restore;
export const purgeRecording = recordingSoftDelete.purge;

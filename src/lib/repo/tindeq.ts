import { supabase } from "../supabase";
import type {
  DeletedTindeqRecording,
  NewTindeqRecording,
  TindeqPreset,
  TindeqRecordingMeta,
  TindeqSample,
  TindeqSide,
} from "../../types";
import type { RecordedZone } from "../force-curve";
import { localDayRange } from "../dates";
import {
  legacyPresetRow,
  retryWithoutPresetHoldsColumn,
} from "../presetSchemaCompat";
import { unwrap, makeSoftDeleteOps } from "./shared";

const RECORDING_COLS =
  "id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id, protocol_run_id, set_no, zone";

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
  zone: string | null;
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
    // Constrained to the four quality ids plus "prehab" by a DB check
    // (#259, widened #325); null on every row saved before it, and on
    // freehand/watch holds.
    zone: r.zone as RecordedZone | null,
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

/// Same-LOCAL-day Tindeq recordings that haven't been grouped into any
/// session yet (SL-21) — feeds the "link to this session?" nudge shown after
/// logging a session. Narrower than History's "ungrouped" notion (which also
/// treats a stale/orphaned group_id — its session got deleted — as loose):
/// here `group_id is null` is the case that actually matters, a gauge run the
/// user never turned into a session at all.
export async function fetchUnlinkedRecordingsForDate(
  date: string,
): Promise<TindeqRecordingMeta[]> {
  const { start, end } = localDayRange(date);
  const data = unwrap(
    await supabase
      .from("tindeq_recordings")
      .select(RECORDING_COLS)
      .is("group_id", null)
      .is("deleted_at", null)
      .gte("recorded_at", start)
      .lt("recorded_at", end)
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

/// Raw kg samples for a specific set of recordings, keyed by recording id —
/// one query per request rather than one per rep (issue #100's per-rep box
/// plots). Only the kg half of each `[tMs, kg]` pair is kept; the box plot
/// only needs the force distribution, not time.
///
/// Scoped to explicit ids (not a whole `group_id`) rather than always
/// pulling every recording in the session: `SessionRow` calls this with all
/// of a session's recording ids on open (one-shot, keeps the box plot
/// glanceable — issue #100), but on a realtime-triggered refresh only with
/// the ids NOT already cached, so an unrelated write elsewhere in the
/// account doesn't re-download samples already on hand (SL-102 — this used
/// to be `fetchSamplesByGroup(groupId)`, unconditionally refetched on every
/// realtime bump while the detail was open).
export async function fetchSamplesForRecordings(
  ids: string[],
): Promise<Map<string, number[]>> {
  if (ids.length === 0) return new Map();
  // Typed as the raw jsonb shape (not the narrower tuple-array type used
  // elsewhere) — TS's structural check for an ARRAY of objects containing a
  // `Json`-typed property doesn't unify against a narrower array type the
  // way a single (non-array) row does, so the single-recording queries above
  // can assert straight to the tuple type but this multi-row one can't.
  const data = unwrap<{ id: string; samples: [number, number][] | null }[]>(
    await supabase
      .from("tindeq_recordings")
      .select("id, samples")
      .in("id", ids)
      .is("deleted_at", null)
      .overrideTypes<{ id: string; samples: [number, number][] | null }[], { merge: false }>(),
  );
  return new Map(data.map((r) => [r.id, (r.samples ?? []).map(([, kg]) => kg)]));
}

export async function insertRecording(
  rec: NewTindeqRecording,
): Promise<TindeqRecordingMeta> {
  const data = unwrap<RecordingRow>(
    await supabase
      .from("tindeq_recordings")
      .insert({
        // Only set when the caller minted one for retry-idempotency (#106) —
        // omitted, the column's own gen_random_uuid() default applies.
        ...(rec.id ? { id: rec.id } : {}),
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
        // `?? null` rather than a pass-through: entries queued before #259
        // (localStorage survives the update) carry no `zone` at all, and an
        // explicit null is what "we don't know" means for this column.
        zone: rec.zone ?? null,
        samples: rec.samples.map((s) => [s.t, s.kg]),
      })
      .select(RECORDING_COLS)
      .single(),
  );
  return toRecording(data);
}

// MARK: Tindeq presets (hang protocols for the guided gauge timer)

const PRESET_COLS =
  "id, name, hold_s, holds_s, reps, sets, rest_reps_s, rest_sets_s, target_kg, target_pct, pct_basis, pct_step, target_curve, alternate_sides";
const LEGACY_PRESET_COLS =
  "id, name, hold_s, reps, sets, rest_reps_s, rest_sets_s, target_kg, target_pct, pct_basis, pct_step, target_curve, alternate_sides";

type LegacyPresetRow = {
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

type PresetRow = LegacyPresetRow & {
  // Absent only when the server predates `preset_holds_per_set`; normalize
  // those rows to the same null used by ordinary presets on the new schema.
  holds_s?: number[] | null;
};

function toPreset(r: PresetRow): TindeqPreset {
  return {
    id: r.id,
    name: r.name,
    holdS: r.hold_s,
    holdsS: r.holds_s ?? null,
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
    holds_s: p.holdsS,
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
  const data = unwrap<PresetRow[]>(
    await retryWithoutPresetHoldsColumn<PresetRow[]>(
      () =>
        supabase
          .from("tindeq_presets")
          .select(PRESET_COLS)
          .order("created_at", { ascending: false }),
      () =>
        supabase
          .from("tindeq_presets")
          .select(LEGACY_PRESET_COLS)
          .order("created_at", { ascending: false }),
    ),
  );
  return data.map(toPreset);
}

export async function insertPreset(
  p: Omit<TindeqPreset, "id">,
): Promise<TindeqPreset> {
  const data = unwrap<PresetRow>(
    await retryWithoutPresetHoldsColumn<PresetRow>(
      () =>
        supabase
          .from("tindeq_presets")
          .insert(presetToRow(p))
          .select(PRESET_COLS)
          .single(),
      () =>
        supabase
          .from("tindeq_presets")
          .insert(legacyPresetRow(presetToRow(p)))
          .select(LEGACY_PRESET_COLS)
          .single(),
    ),
  );
  return toPreset(data);
}

export async function updatePreset(
  id: string,
  p: Omit<TindeqPreset, "id">,
): Promise<TindeqPreset> {
  const data = unwrap<PresetRow>(
    await retryWithoutPresetHoldsColumn<PresetRow>(
      () =>
        supabase
          .from("tindeq_presets")
          .update(presetToRow(p))
          .eq("id", id)
          .select(PRESET_COLS)
          .single(),
      () =>
        supabase
          .from("tindeq_presets")
          .update(legacyPresetRow(presetToRow(p)))
          .eq("id", id)
          .select(LEGACY_PRESET_COLS)
          .single(),
    ),
  );
  return toPreset(data);
}

export async function deletePreset(id: string): Promise<void> {
  unwrap(await supabase.from("tindeq_presets").delete().eq("id", id));
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

/// Link previously-ungrouped Tindeq recordings to a session via the same
/// group_id convention History's multi-select flow uses (SL-21): mint a
/// fresh group_id for the session if it doesn't have one yet (a session
/// logged through the plain Log Session form never gets one), stamp it onto
/// the recordings in one batch (mirrors updateRecordingsMeta's `.in()`
/// pattern). Duration is recomputed from the recording span ONLY for tindeq
/// sessions, where duration is defined as the gauge wall-clock span — for a
/// manually-logged session the user just typed a duration into the form, and
/// attaching a few gauge reps must not clobber it (e.g. a 90-min climbing
/// session would become the reps' 12-min span).
export async function linkRecordingsToSession(
  session: { id: string; groupId: string | null; type: string },
  recordingIds: string[],
): Promise<void> {
  if (recordingIds.length === 0) return;
  const groupId = session.groupId ?? crypto.randomUUID();
  if (!session.groupId) {
    unwrap(
      await supabase
        .from("sessions")
        .update({ group_id: groupId })
        .eq("id", session.id)
        .select("id"),
    );
  }
  unwrap(
    await supabase
      .from("tindeq_recordings")
      .update({ group_id: groupId })
      .in("id", recordingIds)
      .select("id"),
  );
  if (session.type === "tindeq") await recalcTindeqSessionDuration(groupId);
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
// Tags stay denormalized as tindeq_recordings.tag; tindeq_tags only holds
// per-tag metadata: the hidden flag and, since #280, the fitted force-curve
// params (see the migration comments). A tag needs a row here only once it's
// hidden or has a curve — visible tags come from distinct recording tags.

/// Names of the user's hidden tags, filtered out of the Force-tab pickers,
/// trend and curve (the recordings themselves are untouched).
export async function fetchHiddenTags(): Promise<string[]> {
  const data = unwrap<{ name: string }[]>(
    await supabase.from("tindeq_tags").select("name").eq("hidden", true),
  );
  return data.map((r) => r.name);
}

/// A tag's persisted critical-force fit (#280). Null params = never fitted.
export interface TagCurve {
  name: string;
  cf: number | null;
  wPrime: number | null;
}

/// Every tag that has a stored curve — the phone's read side of #280, used to
/// predict a gauge session's RPE from W' depletion across whatever mix of
/// exercises the session contained. (The watch reads the same columns as part
/// of its tag fetch, so it costs no extra round trip there.)
export async function fetchTagCurves(): Promise<TagCurve[]> {
  const data = unwrap<{ name: string; cf_kg: number | null; w_prime_kgs: number | null }[]>(
    await supabase
      .from("tindeq_tags")
      .select("name, cf_kg, w_prime_kgs")
      .not("cf_kg", "is", null),
  );
  return data.map((r) => ({ name: r.name, cf: r.cf_kg, wPrime: r.w_prime_kgs }));
}

/// Persist a tag's fitted curve (#280) so the watch — which can't refit it,
/// having no raw sample streams — can still predict session RPE from two
/// numbers. Upserts the registry row, creating it when the tag has never been
/// hidden.
///
/// The payload deliberately carries ONLY the curve columns: PostgREST's upsert
/// sets exactly the keys it's given, so `hidden` is left untouched on an
/// existing row (and takes its `false` default on a fresh one). Adding
/// `hidden` here would silently unhide a hidden tag on every recompute.
export async function saveTagCurve(input: {
  name: string;
  cf: number;
  wPrime: number;
  recordingCount: number;
}): Promise<void> {
  const { error } = await supabase.from("tindeq_tags").upsert(
    {
      name: input.name,
      cf_kg: input.cf,
      w_prime_kgs: input.wPrime,
      curve_fitted_at: new Date().toISOString(),
      curve_recording_count: input.recordingCount,
    },
    { onConflict: "user_id,name" },
  );
  if (error) throw error;
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

const recordingSoftDelete = makeSoftDeleteOps("tindeq_recordings");
export const deleteRecording = recordingSoftDelete.remove;
export const restoreRecording = recordingSoftDelete.restore;
export const purgeRecording = recordingSoftDelete.purge;

import { supabase } from "../supabase";
import type {
  DeletedSession,
  LogFormState,
  PhaseId,
  Session,
  SessionPatch,
} from "../../types";
import { SESSION_TYPES } from "../../constants";
import { today } from "../dates";
import { makeSoftDeleteOps, unwrap } from "./shared";
import { unwrapOneMutation } from "../mutationInvariant";

export type SessionRow = {
  id: string;
  date: string;
  type: string;
  type_label: string;
  duration_min: number;
  rpe: number;
  // Optional: absent on any cached/legacy row shape from before this column
  // existed — toSession below defaults a missing value to true.
  rpe_confirmed?: boolean;
  load: number;
  note: string;
  phase: string;
  group_id: string | null;
  workout_source: string | null;
};

export const SESSION_COLS =
  "id, date, type, type_label, duration_min, rpe, rpe_confirmed, load, note, phase, group_id, workout_source";

export function toSession(r: SessionRow): Session {
  return {
    id: r.id,
    date: r.date,
    type: r.type,
    typeLabel: r.type_label,
    duration: r.duration_min,
    rpe: r.rpe,
    // Coerce missing/undefined (rows predating the column, e.g. a stale
    // cached shape) to confirmed — only an explicit `false` mutes the bar.
    rpeConfirmed: r.rpe_confirmed !== false,
    load: r.load,
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
      .order("created_at", { ascending: false })
      .overrideTypes<SessionRow[], { merge: false }>(),
  );
  return data.map(toSession);
}

export async function fetchDeletedSessions(): Promise<DeletedSession[]> {
  const data = unwrap(
    await supabase
      .from("sessions")
      .select(`${SESSION_COLS}, deleted_at`)
      .not("deleted_at", "is", null)
      .order("deleted_at", { ascending: false })
      .overrideTypes<(SessionRow & { deleted_at: string })[], { merge: false }>(),
  );
  return data.map((r) => ({ ...toSession(r), deletedAt: r.deleted_at! }));
}

export async function insertSession(form: LogFormState): Promise<Session> {
  const typeInfo = SESSION_TYPES.find((t) => t.id === form.type);
  const data = unwrapOneMutation(
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
      .maybeSingle()
      .overrideTypes<SessionRow, { merge: false }>(),
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
  const data = unwrapOneMutation(
    await supabase
      .from("sessions")
      .update({
        type: patch.type,
        type_label: patch.typeLabel,
        duration_min: patch.duration,
        rpe: patch.rpe,
        note: patch.note,
        // Reaching this function means a human reviewed the edit sheet —
        // always mark confirmed, whatever the RPE ends up as.
        rpe_confirmed: true,
      })
      .eq("id", id)
      .select(SESSION_COLS)
      .maybeSingle()
      .overrideTypes<SessionRow, { merge: false }>(),
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
  /// False for an RPE nobody reviewed (issue #114) — which is what a #280
  /// W'-depletion prediction is, and equally what its fallback default is.
  /// Omitted keeps the column's `true` default, for paths where the number
  /// came from a human.
  rpeConfirmed?: boolean;
  /// Sensor sessions keep the historical Tindeq label; sensorless Force
  /// sessions opt into the product-facing Force label.
  typeLabel?: string;
}): Promise<Session> {
  const data = unwrapOneMutation(
    await supabase
      .from("sessions")
      .insert({
        date: input.date ?? today(),
        type: "tindeq",
        type_label: input.typeLabel ?? "Tindeq",
        duration_min: Math.max(1, Math.min(600, input.durationMin)),
        rpe: input.rpe,
        rpe_confirmed: input.rpeConfirmed ?? true,
        note: input.note,
        phase: input.phase,
        group_id: input.groupId,
      })
      .select(SESSION_COLS)
      .maybeSingle()
      .overrideTypes<SessionRow, { merge: false }>(),
  );
  return toSession(data);
}

const sessionSoftDelete = makeSoftDeleteOps("sessions");
export const deleteSession = sessionSoftDelete.remove;
export const restoreSession = sessionSoftDelete.restore;
export const purgeSession = sessionSoftDelete.purge;

import { supabase } from "./supabase";
import type {
  LogFormState,
  NewTindeqRecording,
  PhaseId,
  Session,
  TindeqRecordingMeta,
  TindeqSample,
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
  load: number;
  note: string;
  phase: string;
};

function toSession(r: SessionRow): Session {
  return {
    id: r.id,
    date: r.date,
    type: r.type,
    typeLabel: r.type_label,
    duration: r.duration_min,
    rpe: r.rpe,
    load: r.load,
    note: r.note,
    phase: r.phase as PhaseId,
  };
}

export async function fetchSessions(): Promise<Session[]> {
  const { data, error } = await supabase
    .from("sessions")
    .select("id, date, type, type_label, duration_min, rpe, load, note, phase")
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
    .select("id, date, type, type_label, duration_min, rpe, load, note, phase")
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

export async function fetchRecordings(): Promise<TindeqRecordingMeta[]> {
  // samples deliberately excluded — the list view only needs metadata
  const { data, error } = await supabase
    .from("tindeq_recordings")
    .select("id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note")
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
      samples: rec.samples.map((s) => [s.t, s.kg]),
    })
    .select("id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note")
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
  };
}

export async function deleteRecording(id: string): Promise<void> {
  const { error } = await supabase
    .from("tindeq_recordings")
    .delete()
    .eq("id", id);
  if (error) throw error;
}

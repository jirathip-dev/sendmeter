import { supabase } from "./supabase";
import { today } from "./dates";

const LEGACY_KEY = "climbing_tracker_v1";
const IMPORTED_KEY = "climbing_tracker_v1_imported";

interface LegacySession {
  date: string;
  type: string;
  typeLabel: string;
  duration: number;
  rpe: number;
  note: string;
  phase: string;
}

export interface LegacyData {
  sessions: LegacySession[];
  currentPhase: string;
  phaseStartDate: string;
}

export function readLegacyData(): LegacyData | null {
  try {
    const raw = localStorage.getItem(LEGACY_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as LegacyData;
    if (!Array.isArray(parsed.sessions) || parsed.sessions.length === 0) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

export async function importLegacyData(d: LegacyData): Promise<number> {
  const rows = d.sessions.map((s) => ({
    date: s.date,
    type: s.type,
    type_label: s.typeLabel || s.type,
    duration_min: Math.min(600, Math.max(1, Math.round(s.duration))),
    rpe: Math.min(10, Math.max(1, Math.round(s.rpe))),
    note: s.note || "",
    phase: s.phase || "capacity",
  }));
  const { error } = await supabase.from("sessions").insert(rows);
  if (error) throw error;

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError) throw userError;
  const { error: settingsError } = await supabase.from("user_settings").upsert({
    user_id: userData.user.id,
    current_phase: d.currentPhase || "capacity",
    phase_start_date: d.phaseStartDate || today(),
    updated_at: new Date().toISOString(),
  });
  if (settingsError) throw settingsError;
  return rows.length;
}

export function markLegacyImported(): void {
  try {
    const raw = localStorage.getItem(LEGACY_KEY);
    if (raw) localStorage.setItem(IMPORTED_KEY, raw);
    localStorage.removeItem(LEGACY_KEY);
  } catch {
    // storage unavailable; ignore
  }
}

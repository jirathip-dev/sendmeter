import { supabase } from "../supabase";
import type { PhaseId } from "../../types";
import { today } from "../dates";
import { unwrap } from "./shared";

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

/// Deletes the auth user; every table cascades from auth.users, so all data
/// goes with it. Required by App Store guideline 5.1.1(v).
export async function deleteAccount(): Promise<void> {
  unwrap(await supabase.rpc("delete_account"));
  await supabase.auth.signOut();
}

import { supabase } from "../supabase";
import type { PhaseId } from "../../types";
import { today } from "../dates";
import { unwrap } from "./shared";
import { signOutUser } from "../signOut";

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
  // #492: capture the signed-in user's id BEFORE the delete RPC runs (and
  // before signing out). This is what the discard below is scoped to —
  // `supabase.auth.getUser()` after the RPC would be validating a JWT for a
  // user row that no longer exists, and `null` here is what caused this
  // account's deletion to wipe every OTHER account's queued recordings on
  // the same device too (`clearRecordingQueue(null)` is an unscoped-wipe
  // sentinel, not "this user"). `getSession()` is a local read — no extra
  // round trip, same source `useAuth.ts`'s sign-out wrapper uses.
  const {
    data: { session },
  } = await supabase.auth.getSession();
  const userId = session?.user.id ?? null;
  unwrap(await supabase.rpc("delete_account"));
  // Through the shared sign-out (#273), which marks the SIGNED_OUT as expected
  // rather than an incident (#202) — that used to be a second hand-rolled copy
  // of the pair. `discard` rather than `drain`: the rows this queue would
  // upload into no longer exist, so there is nothing to attempt and nothing to
  // ask the user to keep. `userId` (not `null`) scopes the discard to just
  // this account, the same "mine" rule `discardQueueOnUserSignOut` already
  // applies on a normal sign-out — see its doc comment and `clearRecordingQueue`'s.
  await signOutUser({ userId, queue: "discard" });
}

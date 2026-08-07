import { supabase } from "../supabase";
import type { PhaseId } from "../../types";
import { today } from "../dates";
import { unwrap } from "./shared";
import { signOutUser } from "../signOut";
import { captureDataLoss } from "../monitoring";

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
///
/// #492 F1 (review): the first version of this fix captured `userId` here
/// and trusted it enough to pass through as `clearRecordingQueue`'s unscoped
/// wipe sentinel whenever it came back `null`. That is unsound on its own
/// terms: this read and the `delete_account` RPC's own bearer-token read are
/// TWO INDEPENDENT `getSession()` calls (`SupabaseClient._getAccessToken`
/// makes its own inside `rpc()`), and a token rotation landing between them
/// — e.g. another tab's auto-refresh ticker, mid multi-tab commit guard —
/// can make this one legitimately resolve `{ session: null }` while the
/// RPC's own read picks up the freshly-rotated, still-valid session. The
/// RPC then succeeds while `userId` here is `null`, reproducing #492
/// exactly. The fix is not "read more carefully" (the race is real and not
/// fully avoidable from this side) — it is that a `null` id can no longer
/// mean "discard everyone's queue" ANYWHERE downstream: `signOutUser`
/// discards nothing and reports when `userId` is falsy (see its doc
/// comment), and `clearRecordingQueue` no longer accepts `null` at the type
/// level at all. So `userId` is passed through as-is, including `null` —
/// it can only ever narrow what gets discarded, never widen it.
export async function deleteAccount(): Promise<void> {
  // Captured BEFORE the delete RPC runs (and before signing out) — after the
  // RPC, `supabase.auth.getUser()` would be validating a JWT for a user row
  // that no longer exists. `getSession()` is a local read — no extra round
  // trip, same source `useAuth.ts`'s sign-out wrapper uses.
  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.getSession();
  if (sessionError) {
    // #492 F1 (review): this error used to be silently discarded. It is
    // exactly the shape that can leave `userId` unresolved below — worth
    // knowing about on its own, even though nothing downstream can turn it
    // into an unscoped wipe any more.
    //
    // R2-F2 (round-2 review, nit): `captureDataLoss` is nominally the #264
    // LOSS channel and nothing is lost here — reused deliberately because
    // it is the only free-form Sentry hook this module can reach without
    // widening `monitoring.ts`'s closed `HANDLED_OPERATIONS` map, which is
    // out of this branch's declared scope (see the identical note on
    // `signOut.ts`'s sibling report). Expected to be rare; revisit with a
    // dedicated non-loss channel outside this branch's scope.
    captureDataLoss("account.delete-session-read-failed", {});
  }
  const userId = session?.user.id ?? null;
  unwrap(await supabase.rpc("delete_account"));
  // Through the shared sign-out (#273), which marks the SIGNED_OUT as expected
  // rather than an incident (#202) — that used to be a second hand-rolled copy
  // of the pair. `discard` rather than `drain`: the rows this queue would
  // upload into no longer exist, so there is nothing to attempt and nothing to
  // ask the user to keep.
  await signOutUser({ userId, queue: "discard" });
}

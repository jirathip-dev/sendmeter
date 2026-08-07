import { supabase } from "./supabase";
import { isUserSignOutPending, markUserSignOut } from "./authDiagnostics";
import { captureDataLoss } from "./monitoring";
import {
  clearRecordingQueue,
  drainPendingRecordingsQueue,
  pendingRecordingsCount,
} from "./recordingQueue";
import { insertRecording } from "./repo/tindeq";
import type { NewTindeqRecording } from "../types";

// #273: THE sign-out path. Both call sites that end a session on purpose go
// through `signOutUser` — the account sheet's Sign Out and `deleteAccount`'s
// implicit one. They used to hold a copy each of `markUserSignOut()` +
// `supabase.auth.signOut()`, which is how the two would have drifted the
// moment either grew a step, and this one grows a destructive step.
//
// What it does, and why in this order, is written down next to the queue it
// acts on: the "#273" section of the policy block in `recordingQueue.ts`. The
// short version — drain while the token is still alive, clear only what
// uploaded, ask about any remainder, and never discard anything on a sign-out
// the user did not ask for.

/// What to do about entries that could not be uploaded. `cancel` abandons the
/// sign-out entirely and leaves the session up — the honest answer to "you
/// have 3 unsynced recordings" is sometimes "wait, let me find wifi first".
export type QueueRemainderChoice = "keep" | "discard" | "cancel";

/// Asked ONCE, only when the drain leaves something behind, and given the
/// count so the user is deciding about a number rather than a possibility.
export type RemainderPrompt = (
  count: number,
) => QueueRemainderChoice | Promise<QueueRemainderChoice>;

/// Which of the two visible phases the sign-out is in, so a caller can say
/// "Uploading…" rather than showing "Signing out…" for the length of a bad
/// network's timeout.
export type SignOutPhase = "draining" | "signing-out";

/// How long the pre-sign-out drain gets. It has to complete before
/// `supabase.auth.signOut()` (afterwards there is no token and every insert
/// 401s), so a hung request would otherwise hang sign-out — an action the user
/// must always be able to complete. Generous enough that a working-but-slow
/// connection finishes a handful of inserts, short enough to stay a pause
/// rather than a hang. Hitting it is not an error, it is the "could not
/// upload" answer, and the prompt takes it from there.
export const DRAIN_TIMEOUT_MS = 8000;

export interface SignOutDeps {
  drain?: (
    userId: string,
    insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
  ) => Promise<number>;
  insert?: (input: NewTindeqRecording & { id: string }) => Promise<unknown>;
  count?: () => Promise<number>;
  clear?: () => Promise<number>;
  mark?: () => void;
  userSignOutPending?: () => boolean;
  signOut?: () => Promise<{ error: Error | null }>;
  report?: (what: string, detail: Record<string, number | boolean>) => void;
  timeoutMs?: number;
}

export interface SignOutOptions {
  /// The signed-in user. Only entries stamped with it are ever attempted (a
  /// recording queued under another account is left alone, and counts as
  /// remainder). `null` skips the drain — there is nothing to attribute an
  /// upload to.
  userId: string | null;
  /// `drain` is a normal Sign Out. `discard` is for account deletion: the rows
  /// are already gone server-side, so there is nothing left to upload INTO and
  /// asking the user to keep recordings for an account that no longer exists
  /// would be nonsense.
  queue?: "drain" | "discard";
  onRemainder?: RemainderPrompt;
  onPhase?: (phase: SignOutPhase) => void;
}

export interface SignOutOutcome {
  /// False only when the user backed out at the remainder prompt. The session
  /// is still up and nothing was touched.
  signedOut: boolean;
  /// From `supabase.auth.signOut()`. The local session is cleared either way.
  error: Error | null;
  /// Recordings that reached Supabase during the pre-sign-out drain.
  uploaded: number;
  /// Recordings still queued after the drain — what the prompt was about.
  remaining: number;
  /// Recordings deleted from this device. Non-zero only on an explicit choice.
  discarded: number;
  /// Whether the drain hit its deadline instead of finishing.
  timedOut: boolean;
}

/// What `useAuth` hands down to the UI: everything but the user id, which the
/// hook already knows. Named so the prop type doesn't get re-spelled (and
/// re-widened) at each layer it passes through.
export type SignOut = (
  opts?: Omit<SignOutOptions, "userId">,
) => Promise<SignOutOutcome>;

/// Resolve to `fallback` if `work` hasn't settled within `ms`. The work is not
/// cancelled — there is no way to cancel an in-flight insert — it just stops
/// being waited on. That is safe here: an insert that lands after the deadline
/// removes its own entry from the queue, and one that lands after
/// `signOut()` fails and leaves the entry exactly where it was.
async function withDeadline<T>(
  work: Promise<T>,
  ms: number,
  fallback: T,
): Promise<{ value: T; timedOut: boolean }> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<{ value: T; timedOut: true }>((resolve) => {
    timer = setTimeout(() => resolve({ value: fallback, timedOut: true }), ms);
  });
  try {
    return await Promise.race([
      work.then((value) => ({ value, timedOut: false as const })),
      deadline,
    ]);
  } finally {
    clearTimeout(timer);
  }
}

/// The ONE place queued recordings are deleted from this device, and the
/// reason `clearRecordingQueue` has no other caller: it refuses unless the
/// user's own sign-out marker is currently set. A revoked or expired session
/// (#265) cannot set that marker — it signs the app out with no user action at
/// all — so it falls straight through here having discarded nothing.
///
/// `userId` is threaded straight to `clearRecordingQueue` — #484 F3: it must
/// be the SAME id the remainder count (`pendingRecordingsCount`) was scoped
/// to, or "Delete N and sign out" understates what a scoped count names but
/// an unscoped delete actually destroys.
///
/// Required, non-null `string` ON PURPOSE (#492 F1, review): the first
/// version of this fix still accepted `userId: string | null` here and
/// `deleteAccount()` passed `null` through whenever it couldn't resolve an
/// id — which is a real, demonstrated race (two independent `getSession()`
/// reads, one for this id and one for the delete RPC's own bearer token, can
/// disagree across a token rotation in another tab) — reproducing #492's
/// whole-device wipe exactly. `clearRecordingQueue` itself now refuses a
/// `null` id at the type level, so this function does too: `signOutUser`
/// only calls it when `opts.userId` is truthy, and treats a falsy one as
/// "discard nothing, report it" instead (see its doc comment). There is no
/// path from here to an unscoped wipe any more.
///
/// Exported so the refusal is directly testable; not for general use.
export async function discardQueueOnUserSignOut(
  userId: string,
  deps: Pick<SignOutDeps, "clear" | "userSignOutPending" | "report"> = {},
): Promise<number> {
  const pending = deps.userSignOutPending ?? isUserSignOutPending;
  if (!pending()) return 0;
  return (deps.clear ?? (() => clearRecordingQueue(userId)))();
}

/// End the session. See the module comment; this is the only implementation.
export async function signOutUser(
  opts: SignOutOptions,
  deps: SignOutDeps = {},
): Promise<SignOutOutcome> {
  const drain = deps.drain ?? drainPendingRecordingsQueue;
  const insert = deps.insert ?? insertRecording;
  // #484 F5: scoped to the signing-out account — with no known user id (the
  // drain above is skipped for the same reason) there is no "mine" to count,
  // so the remainder prompt reports 0 rather than another account's stranded
  // entries.
  const count =
    deps.count ??
    (() => (opts.userId ? pendingRecordingsCount(opts.userId) : Promise.resolve(0)));
  const mark = deps.mark ?? markUserSignOut;
  const signOut = deps.signOut ?? (() => supabase.auth.signOut());
  const report = deps.report ?? captureDataLoss;
  const policy = opts.queue ?? "drain";

  let uploaded = 0;
  let remaining = 0;
  let timedOut = false;
  let choice: QueueRemainderChoice = policy === "discard" ? "discard" : "keep";

  if (policy === "drain") {
    opts.onPhase?.("draining");
    if (opts.userId) {
      // Deliberately before the sign-out: the insert needs a live token.
      const drained = await withDeadline(
        // The drain is written not to reject (every store call is caught, and
        // a failing insert is a `remaining` entry), but a sign-out must not be
        // takeable down by a surprise from it.
        drain(opts.userId, insert).catch(() => 0),
        deps.timeoutMs ?? DRAIN_TIMEOUT_MS,
        0,
      );
      uploaded = drained.value;
      timedOut = drained.timedOut;
    }
    remaining = await count().catch(() => 0);
    if (remaining > 0 && opts.onRemainder) choice = await opts.onRemainder(remaining);
    if (choice === "cancel") {
      return { signedOut: false, error: null, uploaded, remaining, discarded: 0, timedOut };
    }
  }

  opts.onPhase?.("signing-out");
  // Set immediately before the sign-out, as it always has been: it is
  // time-boxed, and it is also what lets the discard below know this teardown
  // is the user's doing.
  mark();

  let discarded = 0;
  if (choice === "discard") {
    if (opts.userId) {
      // Before `signOut()`, not after: the user asked for this and it must
      // happen even if the network call fails. It is a local delete, so
      // there is no token to race.
      discarded = await discardQueueOnUserSignOut(opts.userId, deps);
      if (policy === "drain" && discarded < remaining) {
        // The user asked for these to be gone and some of them are not. Silent
        // is the one thing this must not be.
        report("tindeq-queue: discard-on-signout-incomplete", {
          requested: remaining,
          discarded,
        });
      }
    } else {
      // #492 F1 (review): no attributable user id. The pre-fix bug was
      // exactly this case silently falling back to "wipe every account's
      // queue on this device" — an id-resolution failure widening the blast
      // radius is worse than doing nothing, so this path discards NOTHING
      // and says so out loud instead of guessing.
      //
      // R2-F2 (round-2 review, nit): `report` (default `captureDataLoss`)
      // is nominally the #264 LOSS channel, and nothing is lost here — the
      // discard-skip is the whole point. Reused deliberately rather than
      // introducing a differently-labeled channel: `report` is the one
      // free-form diagnostic hook already threaded through this function
      // (the sibling `discard-on-signout-incomplete` report above uses the
      // same one), and a proper "handled, not lost" channel would mean
      // widening `monitoring.ts`'s closed `HANDLED_OPERATIONS` map, which
      // is out of this branch's declared scope. This event should be rare
      // (the #492 F1 race it flags is not an everyday occurrence), so
      // channel dilution risk is low; still, revisit with a dedicated
      // non-loss channel outside this branch's scope rather than treating
      // this reuse as the final shape. The user-visible residual this skip
      // leaves behind (R2-F3) is documented in `recordingQueue.ts`'s #273
      // policy block, not here — this comment is only about which Sentry
      // channel the report itself rides on.
      report("tindeq-queue: discard-skipped-no-attributable-user", {});
    }
  }

  const { error } = await signOut();
  return { signedOut: true, error, uploaded, remaining, discarded, timedOut };
}

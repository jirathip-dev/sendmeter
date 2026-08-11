/// The cross-account privacy boundary for watch→phone live-mirror packets
/// (#530). Single source of truth for both `liveWorkoutMirror.ts` and
/// `liveForceMirror.ts` (round-1 review F4 — this predicate used to be
/// duplicated verbatim in each, which let one copy drift from a later fix to
/// the other) and for both `useLiveWorkout` / `useLiveForce`.

const LAST_ACCOUNT_KEY = "sendmeter:live-mirror-last-account";
/// Separate from `LAST_ACCOUNT_KEY` on purpose (round-2 review R2-F1): this
/// key names the account a switch was observed INTO, and is written by
/// exactly one caller (`recordAuthenticatedAccountForLiveMirror`, the single
/// auth-boundary owner) and cleared by exactly one other
/// (`recordStampedPacketAccepted`, once the watch proves it has caught up).
/// Any number of mirror hooks may READ it (`hasAccountChangedSincePersisted`)
/// without disarming it for one another — reading must never double as
/// writing, which was round-1's bug.
const TRANSITIONED_INTO_KEY = "sendmeter:live-mirror-transitioned-into";

export interface LiveMirrorOwnershipStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/// Native ids (a Swift `UUID.uuidString`) come back UPPERCASE; supabase-js
/// ids are lowercase — same normalization as `normalizeRunId` in the mirror
/// modules and `normalizeUserId` in `healthSync.ts` (#535). Empty/whitespace
/// normalizes to `null`, same as an absent value — used below to distinguish
/// "no stamp at all" from "a stamp present but too malformed to trust".
function normalizeUserId(value: string | null | undefined): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.toLowerCase() : null;
}

/// Whether a WatchConnectivity live-mirror packet may reach the currently
/// authenticated account's reducer.
///
/// - A packet whose `account_user_id` key is present but does not match the
///   current account is always rejected — the watch may still be relaying a
///   run that started under a previous account for a while after the phone
///   itself has switched, and run id/sequence ordering alone cannot tell
///   that apart from a legitimate late beat.
/// - A packet whose key is present but unparseable (empty, whitespace, or a
///   non-string) is rejected unconditionally too (#530 round-1 review F6):
///   it CLAIMS an owner it cannot substantiate, which is a stronger claim
///   than carrying no owner at all and must not be routed into the lenient
///   legacy branch below.
/// - Only a packet whose key is genuinely ABSENT (`undefined` — a pre-#530
///   watch build) reaches the legacy branch: accepted while this mirror has
///   never lived through an account transition, rejected once it has.
export function acceptsPacketOwner(
  accountUserId: string | null | undefined,
  currentUserId: string,
  hasHadAccountTransition: boolean,
): boolean {
  if (accountUserId === undefined) {
    return !hasHadAccountTransition;
  }
  const owner = normalizeUserId(accountUserId);
  if (owner === null) return false;
  return owner === normalizeUserId(currentUserId);
}

function browserLocalStorage(): LiveMirrorOwnershipStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

/// Records the account this device has just authenticated — called exactly
/// ONCE per session the app observes with a real user id, by the single
/// owner at the auth boundary (`useAuth.ts`'s `onSession`, which is the one
/// funnel for both the ordinary sign-in/sign-out path and the narrower
/// in-place A→B swap on a `visibilitychange` re-check). This is the ONLY
/// function that writes `TRANSITIONED_INTO_KEY` on a genuine switch
/// (round-2 review R2-F1).
///
/// Round-1's version conflated this write with the per-mirror-hook READ
/// (`hasAccountChangedSincePersisted`'s old read-modify-write shape): the
/// FIRST mirror hook to mount after a switch consumed the signal and
/// overwrote it, so a SECOND mirror mounting moments later (a different tab
/// — `useLiveWorkout` lives in both `WorkoutView` and `HistoryView`,
/// `useLiveForce` in `ForceView`, and tabs mount conditionally) saw no
/// transition at all. Separating the writer from the readers means any
/// number of mirrors can consult the same durable signal without disarming
/// it for one another.
///
/// `localStorage`-backed, not `authEventStore.ts`'s Preferences-on-native
/// dual store: this is a defensive signal, not forensic evidence, and an
/// ordinary sign-out/sign-in never wipes the WebView's own storage — that's
/// the narrower case that module exists for.
export function recordAuthenticatedAccountForLiveMirror(
  userId: string,
  storage: LiveMirrorOwnershipStorage | null = browserLocalStorage(),
): void {
  const normalized = normalizeUserId(userId);
  if (!storage || normalized === null) return;
  let stored: string | null;
  try {
    stored = storage.getItem(LAST_ACCOUNT_KEY);
  } catch {
    return; // storage unreadable — nothing durable to compare against
  }
  try {
    if (stored !== null && stored !== normalized) {
      // Latches "a switch was observed INTO this account" — see
      // `recordStampedPacketAccepted` for how this later clears.
      storage.setItem(TRANSITIONED_INTO_KEY, normalized);
    }
    storage.setItem(LAST_ACCOUNT_KEY, normalized);
  } catch {
    /* best-effort — a failed write just means the signal can't be recorded */
  }
}

/// Pure READ of the durable transition marker `recordAuthenticatedAccountForLiveMirror`
/// writes — never mutates storage (round-2 review R2-F1/R2-F4), so any
/// number of mirror hooks can call this at mount without disarming it for
/// one another.
///
/// Fails CLOSED (round-2 review R2-F5): unavailable or unreadable storage
/// returns `true` — "treat as if a transition may have happened, don't
/// trust an unstamped packet" — rather than `false`. A privacy boundary
/// should not silently disable itself just because its own signal can't be
/// read; the AC's conservative-mixed-version requirement applies exactly as
/// hard here as when the signal reads normally.
export function hasAccountChangedSincePersisted(
  currentUserId: string,
  storage: LiveMirrorOwnershipStorage | null = browserLocalStorage(),
): boolean {
  const normalized = normalizeUserId(currentUserId);
  if (!storage || normalized === null) return true;
  try {
    return storage.getItem(TRANSITIONED_INTO_KEY) === normalized;
  } catch {
    return true;
  }
}

/// Clears the durable transition marker for `userId` once the watch has
/// PROVEN it has caught up — a genuinely STAMPED packet (not the
/// legacy-absent branch) correctly attributed to this account is positive
/// evidence the watch is on a #530-aware build and has relayed the current
/// account, closing the risk window `recordAuthenticatedAccountForLiveMirror`
/// opened. Called by both mirror hooks whenever `acceptsPacketOwner` accepts
/// a packet whose `account_user_id` was actually present (round-2 review
/// R2-F1's "stronger still" suggestion — clear on watch evidence, not on a
/// phone-side mount).
///
/// Not `removeItem`: keeps the storage interface narrow, matching
/// `authEventStore.ts`'s `getItem`/`setItem`-only shape. Any stored value
/// other than the normalized `userId` itself reads as "not transitioned" in
/// `hasAccountChangedSincePersisted`'s equality check, so an empty string
/// works as well as deleting the key.
export function recordStampedPacketAccepted(
  userId: string,
  storage: LiveMirrorOwnershipStorage | null = browserLocalStorage(),
): void {
  const normalized = normalizeUserId(userId);
  if (!storage || normalized === null) return;
  try {
    storage.setItem(TRANSITIONED_INTO_KEY, "");
  } catch {
    /* best-effort */
  }
}

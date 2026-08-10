/// The cross-account privacy boundary for watch→phone live-mirror packets
/// (#530). Single source of truth for both `liveWorkoutMirror.ts` and
/// `liveForceMirror.ts` (round-1 review F4 — this predicate used to be
/// duplicated verbatim in each, which let one copy drift from a later fix to
/// the other) and for both `useLiveWorkout` / `useLiveForce`.

const LAST_ACCOUNT_KEY = "sendmeter:live-mirror-last-account";

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

/// Durable (survives an unmount/remount) record of whether THIS device has
/// ever authenticated a DIFFERENT account than the one it's authenticated as
/// now — round-1 review F1's fix.
///
/// A `useRef`-only transition flag is inert on the only account-switch path
/// the UI actually has: this app has no in-place account swap (`App.tsx`
/// renders `<LoginScreen />` whenever there is no session), so a user-driven
/// A→B switch is sign-out → UNMOUNT of the whole authed tree → sign-in →
/// fresh mount, and a `useRef` initialized fresh on that new mount can never
/// see A ever existed. `localStorage` survives that remount (it's the same
/// WebView, not a reload), so persisting the last-seen account here — and
/// comparing against it once at the NEXT mount — is what actually closes the
/// window described in the issue: a still-unstamped legacy watch beat for A
/// must not render as B's the moment B's tab (re)mounts.
///
/// This is a defensive signal, not forensic evidence, so it deliberately
/// does NOT need `authEventStore.ts`'s Preferences-on-native dual store —
/// that module exists to survive the WebView's OWN storage being wiped,
/// which an ordinary sign-out/sign-in never triggers.
///
/// Re-derives from "stored last-seen account differs from current" on every
/// call rather than latching one permanent flag for the life of the install:
/// once the transition risk window has passed (this same account relaunches
/// later with no further switch), a still-unstamped legacy watch is trusted
/// again — exactly as it would be for a device that has never switched at
/// all. Every call also records `currentUserId` as the new "last seen"
/// value, so the NEXT mount (a real switch, or just a relaunch) can compare
/// against it.
export function hasAccountChangedSincePersisted(
  currentUserId: string,
  storage: LiveMirrorOwnershipStorage | null = browserLocalStorage(),
): boolean {
  const normalizedCurrent = normalizeUserId(currentUserId);
  if (!storage || normalizedCurrent === null) return false;
  let stored: string | null;
  try {
    stored = storage.getItem(LAST_ACCOUNT_KEY);
  } catch {
    return false; // storage unreadable — nothing durable to compare against
  }
  const changed = stored !== null && stored !== normalizedCurrent;
  try {
    storage.setItem(LAST_ACCOUNT_KEY, normalizedCurrent);
  } catch {
    /* best-effort — a failed write just means the NEXT mount can't compare */
  }
  return changed;
}

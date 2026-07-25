import {
  isAuthRetryableFetchError,
  type AuthError,
  type Session,
} from "@supabase/supabase-js";

/// Issue #194: a null `getSession()` result on foreground currently drops the
/// user straight to the login screen with no record of *why* — storage never
/// had a session, a network hiccup mid-refresh, or auth-js silently clearing
/// a revoked one (it removes an invalid stored session without emitting
/// SIGNED_OUT — see useAuth.ts). Those three need different fixes, so
/// classify and record which one happened rather than staying silent.
export type NullSessionReason =
  | "network-error"
  | "revoked"
  | "storage-missing"
  | "storage-unavailable";

/// Tri-state deliberately, not a boolean. "storage threw" and "storage held
/// nothing" are opposite diagnoses — the first says we cannot tell whether a
/// session existed, the second says one never did — and collapsing them makes
/// a private-browsing/quota failure read as "never logged in", inverting the
/// signal this module exists to produce.
export type StoredSessionProbe = "present" | "absent" | "unavailable";

export interface NullSessionEvent {
  reason: NullSessionReason;
  /// Consecutive occurrences of this same reason, so a burst of foreground
  /// events (e.g. repeated tab switches while offline) reads as one ongoing
  /// incident rather than N distinct ones.
  count: number;
}

/// Issue #202: `NullSessionEvent` plus the timestamps a persisted, on-device
/// record needs to be readable — when the incident started and when it last
/// recurred.
export interface AuthDiagnosticEvent extends NullSessionEvent {
  firstAt: string; // ISO
  lastAt: string; // ISO
}

const AUTH_EVENTS_KEY = "sendmeter:auth-events";

/// Ring cap — small, since each entry is a few bytes and a burst of the same
/// reason collapses into one entry via the count.
export const MAX_AUTH_EVENTS = 20;

const NULL_SESSION_REASONS: readonly NullSessionReason[] = [
  "network-error",
  "revoked",
  "storage-missing",
  "storage-unavailable",
];

/// Hydrated lazily from storage on first access so dedupe (matching against
/// the newest entry) survives a relaunch. `null` means "not hydrated yet",
/// distinct from an empty (hydrated, no events) ring.
let events: AuthDiagnosticEvent[] | null = null;

/// Mirrors supabase-js's own default-storage-key derivation
/// (`sb-<project ref>-auth-token`) so this reads the key THIS client
/// actually wrote to. Matching any `sb-*-auth-token` key would pick up a
/// different project's entry (e.g. hosted vs. local stack) and invert the
/// diagnosis.
export function deriveAuthStorageKey(url: string): string {
  const ref = new URL(url).hostname.split(".")[0];
  return `sb-${ref}-auth-token`;
}

export function classifyNullSession(
  stored: StoredSessionProbe,
  error: AuthError | null,
): NullSessionReason {
  if (stored === "unavailable") return "storage-unavailable";
  if (stored === "absent") return "storage-missing";
  return isAuthRetryableFetchError(error) ? "network-error" : "revoked";
}

interface AuthStorage {
  getItem(key: string): string | null;
}

interface AuthEventStorage extends AuthStorage {
  setItem(key: string, value: string): void;
}

function defaultStorage(): AuthEventStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

function isAuthDiagnosticEvent(v: unknown): v is AuthDiagnosticEvent {
  if (!v || typeof v !== "object") return false;
  const e = v as Record<string, unknown>;
  return (
    typeof e.reason === "string" &&
    (NULL_SESSION_REASONS as readonly string[]).includes(e.reason) &&
    typeof e.count === "number" &&
    typeof e.firstAt === "string" &&
    typeof e.lastAt === "string"
  );
}

/// Read the persisted ring. Tolerant of missing/corrupt storage — a bad blob
/// or unavailable storage is treated as an empty ring rather than throwing,
/// mirroring `recordingQueue.ts`'s `loadQueue`.
export function loadAuthEvents(
  storage: AuthStorage | null = defaultStorage(),
): AuthDiagnosticEvent[] {
  if (!storage) return [];
  try {
    const raw = storage.getItem(AUTH_EVENTS_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isAuthDiagnosticEvent).slice(-MAX_AUTH_EVENTS);
  } catch {
    return [];
  }
}

/// Persist the ring. Returns whether the write actually landed — never
/// throws, since a full/disabled store must not break the auth path this is
/// called from.
function saveAuthEvents(
  next: AuthDiagnosticEvent[],
  storage: AuthEventStorage | null,
): boolean {
  if (!storage) return false;
  try {
    storage.setItem(AUTH_EVENTS_KEY, JSON.stringify(next));
    return true;
  } catch {
    return false;
  }
}

/// Pure: append one occurrence of `reason`. Collapses into the newest entry
/// (bumping `count` + `lastAt`) when it matches the same reason, else pushes
/// a new entry and evicts the oldest beyond `MAX_AUTH_EVENTS`. Returns a NEW
/// array — doesn't mutate `prev`.
export function appendAuthEvent(
  prev: AuthDiagnosticEvent[],
  reason: NullSessionReason,
  nowIso: string,
): AuthDiagnosticEvent[] {
  const last = prev[prev.length - 1];
  if (last && last.reason === reason) {
    return [
      ...prev.slice(0, -1),
      { ...last, count: last.count + 1, lastAt: nowIso },
    ];
  }
  const next = [...prev, { reason, count: 1, firstAt: nowIso, lastAt: nowIso }];
  return next.length > MAX_AUTH_EVENTS ? next.slice(-MAX_AUTH_EVENTS) : next;
}

/// Records a null-session classification: updates the in-memory ring
/// (hydrating from storage on first call, so dedupe survives a relaunch),
/// persists it, and warns to the console. Never throws — a failed or
/// unavailable storage write (the storage-unavailable reason making its own
/// persistence fail is the expected irony here) is swallowed, and the
/// console path plus the in-memory ring keep working regardless.
export function recordAuthNullSession(
  reason: NullSessionReason,
  storage: AuthEventStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): NullSessionEvent {
  if (events === null) events = loadAuthEvents(storage);
  events = appendAuthEvent(events, reason, now());
  saveAuthEvents(events, storage);
  // appendAuthEvent always pushes or replaces an entry, so the ring is
  // never empty here.
  const latest = events[events.length - 1]!;
  // Not "on foreground": this also runs at mount, where a null session on a
  // logged-out cold start is entirely normal. Keep the message neutral so an
  // ordinary launch doesn't read as an incident in the console.
  console.warn(`[auth] null session: ${reason} (x${latest.count})`);
  return { reason: latest.reason, count: latest.count };
}

/// The most recently classified null-session event — the "attributable, not
/// silent" distinction issue #194 asks for, surfaced for inspection.
export function getLastNullSessionEvent(): NullSessionEvent | null {
  if (events === null) events = loadAuthEvents();
  const latest = events[events.length - 1];
  return latest ? { reason: latest.reason, count: latest.count } : null;
}

/// The persisted ring, newest-first, for on-device display (issue #202) —
/// e.g. a read-only list in the account sheet, so a daily-logout cause is
/// readable on the phone without a debugger attached.
export function getAuthDiagnosticEvents(): AuthDiagnosticEvent[] {
  if (events === null) events = loadAuthEvents();
  return [...events].reverse();
}

/// Resets the in-memory ring, and the persisted ring when a storage is
/// given — pass `null` (as the tests do) to reset memory only. Exported
/// for tests; not currently wired to any UI action.
export function clearAuthDiagnostics(
  storage: AuthEventStorage | null = defaultStorage(),
): void {
  events = [];
  saveAuthEvents(events, storage);
}

/// Absent storage, and storage that throws on read, both mean "we cannot tell"
/// — never "there was no session". `getItem` can throw even once obtained
/// (quota/security errors in some WebKit configurations), so guard the read
/// too, not just the handle.
export function probeStoredSession(
  storage: AuthStorage | null,
  url: string,
): StoredSessionProbe {
  if (!storage) return "unavailable";
  try {
    return storage.getItem(deriveAuthStorageKey(url)) ? "present" : "absent";
  } catch {
    return "unavailable";
  }
}

/// Same shape as supabase-js's `getSession()` result — narrowed so tests can
/// fake it without constructing a full SupabaseClient.
interface SessionClient {
  auth: {
    getSession(): Promise<
      | { data: { session: Session }; error: null }
      | { data: { session: null }; error: AuthError }
      | { data: { session: null }; error: null }
    >;
  };
}

/// Wraps `client.auth.getSession()` with the classification above. The
/// storage key MUST be read BEFORE calling getSession() — auth-js deletes an
/// invalid stored session as a side effect of that call, so reading after
/// would misclassify every revocation as storage-missing.
export async function getSessionWithDiagnostics(
  client: SessionClient,
  url: string,
  storage: AuthStorage | null = defaultStorage(),
): Promise<{ session: Session | null; reason: NullSessionReason | null }> {
  const stored = probeStoredSession(storage, url);
  const { data, error } = await client.auth.getSession();
  if (data.session) return { session: data.session, reason: null };
  const reason = classifyNullSession(stored, error);
  recordAuthNullSession(reason);
  return { session: null, reason };
}

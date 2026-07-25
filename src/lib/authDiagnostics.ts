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

let lastEvent: NullSessionEvent | null = null;

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

export function recordAuthNullSession(reason: NullSessionReason): NullSessionEvent {
  lastEvent =
    lastEvent && lastEvent.reason === reason
      ? { reason, count: lastEvent.count + 1 }
      : { reason, count: 1 };
  // Not "on foreground": this also runs at mount, where a null session on a
  // logged-out cold start is entirely normal. Keep the message neutral so an
  // ordinary launch doesn't read as an incident in the console.
  console.warn(`[auth] null session: ${reason} (x${lastEvent.count})`);
  return lastEvent;
}

/// The most recently classified null-session event — the "attributable, not
/// silent" distinction issue #194 asks for, surfaced for inspection.
export function getLastNullSessionEvent(): NullSessionEvent | null {
  return lastEvent;
}

interface AuthStorage {
  getItem(key: string): string | null;
}

function defaultStorage(): AuthStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
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

import {
  isAuthRetryableFetchError,
  type AuthError,
  type Session,
} from "@supabase/supabase-js";
import {
  createDurableAuthStore,
  createLocalStorageStore,
  type AuthEventStoreKind,
  type DurableAuthStore,
} from "./authEventStore";

/// Issue #194: a null `getSession()` result on foreground currently drops the
/// user straight to the login screen with no record of *why* — storage never
/// had a session, a network hiccup mid-refresh, or auth-js silently clearing
/// a revoked one (it removes an invalid stored session without emitting
/// SIGNED_OUT — see useAuth.ts). Those three need different fixes, so
/// classify and record which one happened rather than staying silent.
///
/// Issue #202 adds two causes that aren't `getSession()` results at all: a
/// sign-out the *user* asked for (so a deliberate logout doesn't read as an
/// incident), and the WebView's own storage being wiped underneath us.
export type NullSessionReason =
  | "network-error"
  | "revoked"
  | "storage-missing"
  | "storage-unavailable"
  | "user-signed-out"
  | "storage-wiped";

/// Tri-state deliberately, not a boolean. "storage threw" and "storage held
/// nothing" are opposite diagnoses — the first says we cannot tell whether a
/// session existed, the second says one never did — and collapsing them makes
/// a private-browsing/quota failure read as "never logged in", inverting the
/// signal this module exists to produce.
export type StoredSessionProbe = "present" | "absent" | "unavailable";

/// Which observer saw the null session. The #202 diagnosis was that only
/// `get-session` was ever instrumented, so the likeliest logout path — the
/// auto-refresh tick failing and auth-js tearing the session down itself —
/// left no trace at all. Carrying the origin makes "we asked and got null"
/// distinguishable from "auth-js signed us out".
export type AuthEventSource = "get-session" | "auth-state-change" | "init";

export interface NullSessionEvent {
  reason: NullSessionReason;
  /// Consecutive occurrences of this same reason, so a burst of foreground
  /// events (e.g. repeated tab switches while offline) reads as one ongoing
  /// incident rather than N distinct ones.
  count: number;
}

/// Everything besides the cause that makes a record readable weeks later:
/// where it came from, which build produced it, which store it landed in, and
/// when we last held a session we know was good.
export interface AuthEventMeta {
  source?: AuthEventSource;
  /// The auth-js event name (`SIGNED_OUT`, `TOKEN_REFRESHED`, …) when the
  /// record came from `onAuthStateChange`.
  authEvent?: string;
  build?: string;
  /// Last-known-good session heartbeat, captured at the moment the incident
  /// STARTED — so an event reads "valid at 23:40, gone at 06:50, cause X"
  /// rather than a bare cause.
  lastGoodAt?: string;
  lastGoodExpiresAt?: string;
  store?: AuthEventStoreKind;
}

/// Issue #202: `NullSessionEvent` plus the timestamps a persisted, on-device
/// record needs to be readable — when the incident started and when it last
/// recurred — plus the attribution metadata above.
export interface AuthDiagnosticEvent extends NullSessionEvent, AuthEventMeta {
  firstAt: string; // ISO
  lastAt: string; // ISO
}

const AUTH_EVENTS_KEY = "sendmeter:auth-events";
const HEARTBEAT_KEY = "sendmeter:auth-heartbeat";
/// Written into BOTH the durable store and `localStorage`. Coming back from
/// the durable store while the `localStorage` copy is gone is the one
/// observation that separates "iOS threw the WebView's data away" from "the
/// session was revoked server-side".
const CANARY_KEY = "sendmeter:webview-canary";
/// Owned by `authEventFlush.ts`, listed here so the whole diagnostics working
/// set comes off the durable store in one hydration pass at launch.
export const FLUSH_MARKER_KEY = "sendmeter:auth-events-flushed";

export const AUTH_DIAGNOSTIC_KEYS = [
  AUTH_EVENTS_KEY,
  HEARTBEAT_KEY,
  CANARY_KEY,
  FLUSH_MARKER_KEY,
] as const;

/// Ring cap — small, since each entry is a few bytes and a burst of the same
/// reason collapses into one entry via the count.
export const MAX_AUTH_EVENTS = 20;

const NULL_SESSION_REASONS: readonly NullSessionReason[] = [
  "network-error",
  "revoked",
  "storage-missing",
  "storage-unavailable",
  "user-signed-out",
  "storage-wiped",
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

/// Classifies a null session that arrived via `onAuthStateChange` rather than
/// from a `getSession()` call. Returns null for events we deliberately don't
/// record.
///
/// `INITIAL_SESSION` is skipped because `getSessionWithDiagnostics` covers the
/// same moment with a better classification (it probes storage BEFORE auth-js
/// can clear it); recording both would double every cold start.
///
/// A `SIGNED_OUT` we didn't ask for is `revoked`, not `storage-missing`:
/// auth-js only tears the session down (`_callRefreshToken` →
/// `_removeSession`) on a NON-retryable refresh failure whose access token has
/// already expired — i.e. the refresh token itself was rejected. Probing
/// storage at that point finds the key already deleted and would misreport it
/// as "never had a session".
export function classifyAuthStateChange(
  event: string,
  userInitiated: boolean,
): NullSessionReason | null {
  if (event === "INITIAL_SESSION") return null;
  if (event === "SIGNED_OUT")
    return userInitiated ? "user-signed-out" : "revoked";
  // TOKEN_REFRESHED/USER_UPDATED/… with a null session shouldn't happen; if
  // one does, record it rather than dropping the only trace of it. The
  // auth-js event name rides along in the metadata.
  return "revoked";
}

export interface AuthStorage {
  getItem(key: string): string | null;
}

export interface AuthEventStorage extends AuthStorage {
  setItem(key: string, value: string): void;
}

/// The WebView's own `localStorage` — where supabase-js keeps the session.
/// Deliberately distinct from the ring store below: on native the ring moves
/// out of the WebView, but the session probe must keep reading the store
/// supabase-js actually writes to.
function webStorage(): AuthEventStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

/// The durable ring store. `localStorage`-backed until `initAuthDiagnostics()`
/// swaps in Preferences on native — memoized so events recorded before init
/// still accumulate in one place.
let ringStore: DurableAuthStore | null = null;

function defaultStorage(): DurableAuthStore {
  ringStore ??= createLocalStorageStore();
  return ringStore;
}

/// The durable ring store, for the modules that persist alongside the ring
/// (`authEventFlush.ts` keeps its "already sent" marker there, so a flush
/// isn't re-sent on every launch).
export function getAuthEventStore(): DurableAuthStore {
  return defaultStorage();
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

/// Two occurrences belong to the same incident only when cause, origin AND
/// build match. Collapsing across builds would hide "the build with the fix
/// still did it", which is the question the record exists to answer.
function sameIncident(
  entry: AuthDiagnosticEvent,
  reason: NullSessionReason,
  meta: AuthEventMeta,
): boolean {
  return (
    entry.reason === reason &&
    entry.source === meta.source &&
    entry.authEvent === meta.authEvent &&
    entry.build === meta.build
  );
}

/// Pure: append one occurrence of `reason`. Collapses into the newest entry
/// (bumping `count` + `lastAt`) when it matches the same incident, else pushes
/// a new entry and evicts the oldest beyond `MAX_AUTH_EVENTS`. Returns a NEW
/// array — doesn't mutate `prev`.
///
/// A collapse keeps the FIRST occurrence's metadata: the heartbeat captured
/// when the incident started ("valid at 23:40") is the informative one, and
/// overwriting it with the fifth foreground retry's heartbeat would erase
/// exactly the interval we're trying to read.
export function appendAuthEvent(
  prev: AuthDiagnosticEvent[],
  reason: NullSessionReason,
  nowIso: string,
  meta: AuthEventMeta = {},
): AuthDiagnosticEvent[] {
  const last = prev[prev.length - 1];
  if (last && sameIncident(last, reason, meta)) {
    return [
      ...prev.slice(0, -1),
      { ...last, count: last.count + 1, lastAt: nowIso },
    ];
  }
  const next = [
    ...prev,
    { reason, count: 1, firstAt: nowIso, lastAt: nowIso, ...meta },
  ];
  return next.length > MAX_AUTH_EVENTS ? next.slice(-MAX_AUTH_EVENTS) : next;
}

/// Identity of an incident across rings: same cause, same start, same origin
/// and build. `firstAt` never changes once an entry exists (collapses only
/// move `lastAt`/`count`), which is what makes it usable as a key — the same
/// key is also the `auth_events` upsert conflict target.
function incidentKey(e: AuthDiagnosticEvent): string {
  return [e.reason, e.firstAt, e.source ?? "", e.authEvent ?? "", e.build ?? ""].join(
    "|",
  );
}

/// Union two rings by incident identity, keeping the further-along version of
/// each (highest count, latest `lastAt`). Used at boot to reconcile the
/// durable ring with the legacy `localStorage` one and with anything recorded
/// before the durable store finished hydrating.
///
/// Deliberately a UNION, not an addition: the same ring gets reconciled again
/// on every launch (the legacy copy isn't erased — it's evidence), and summing
/// counts would inflate a one-off incident into a nightly epidemic.
export function mergeAuthEvents(
  a: readonly AuthDiagnosticEvent[],
  b: readonly AuthDiagnosticEvent[],
): AuthDiagnosticEvent[] {
  const byKey = new Map<string, AuthDiagnosticEvent>();
  for (const entry of [...a, ...b]) {
    const key = incidentKey(entry);
    const seen = byKey.get(key);
    if (!seen || seen.count < entry.count || seen.lastAt < entry.lastAt) {
      byKey.set(key, {
        ...entry,
        count: Math.max(seen?.count ?? 0, entry.count),
        lastAt: seen && seen.lastAt > entry.lastAt ? seen.lastAt : entry.lastAt,
      });
    }
  }
  const merged = [...byKey.values()].sort((x, y) =>
    x.firstAt.localeCompare(y.firstAt),
  );
  return merged.length > MAX_AUTH_EVENTS
    ? merged.slice(-MAX_AUTH_EVENTS)
    : merged;
}

/// Records a null-session classification: updates the in-memory ring
/// (hydrating from storage on first call, so dedupe survives a relaunch),
/// persists it, and warns to the console. Never throws — a failed or
/// unavailable storage write (the storage-unavailable reason making its own
/// persistence fail is the expected irony here) is swallowed, and the
/// console path plus the in-memory ring keep working regardless.
///
/// Synchronous by contract even though the native store is async: the durable
/// write is queued behind a write-behind cache (see `authEventStore.ts`), so
/// the auth path never awaits Preferences and a rejected write cannot surface
/// here.
export function recordAuthNullSession(
  reason: NullSessionReason,
  storage: AuthEventStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
  meta: AuthEventMeta = {},
): NullSessionEvent {
  if (events === null) events = loadAuthEvents(storage);
  events = appendAuthEvent(events, reason, now(), meta);
  saveAuthEvents(events, storage);
  // appendAuthEvent always pushes or replaces an entry, so the ring is
  // never empty here.
  const latest = events[events.length - 1]!;
  // Not "on foreground": this also runs at mount, where a null session on a
  // logged-out cold start is entirely normal. Keep the message neutral so an
  // ordinary launch doesn't read as an incident in the console.
  const via = meta.authEvent ? ` via ${meta.authEvent}` : "";
  console.warn(`[auth] null session: ${reason}${via} (x${latest.count})`);
  return { reason: latest.reason, count: latest.count };
}

/// Metadata every real (non-test) record carries: origin, the current build,
/// the store the ring lives in, and the last-known-good heartbeat.
function currentMeta(
  source: AuthEventSource,
  authEvent: string | undefined,
  storage: DurableAuthStore | null,
  build: string | null,
): AuthEventMeta {
  const beat = storage ? loadSessionHeartbeat(storage) : null;
  return {
    source,
    ...(authEvent ? { authEvent } : {}),
    ...(build ? { build } : {}),
    ...(beat
      ? {
          lastGoodAt: beat.at,
          ...(beat.expiresAt ? { lastGoodExpiresAt: beat.expiresAt } : {}),
        }
      : {}),
    ...(storage ? { store: storage.kind } : {}),
  };
}

/// Runs `write` once the durable store and the build tag are installed —
/// immediately when init has already finished (or was never started, e.g. in
/// tests and on a caller that manages its own storage).
///
/// Until `initAuthDiagnostics` resolves, `defaultStorage()` is still the
/// WebView's localStorage and `status.build` is null. Writing then would
/// misattribute the launch-time event — `store: "local-storage"` on a native
/// build, no build tag — which is exactly the attribution this instrumentation
/// exists to add. Worse, `build` is part of the incident identity
/// (`sameIncident`/`incidentKey`), so one ongoing incident recorded either
/// side of init would split into two ring entries and two `auth_events` rows.
///
/// Deferring is safe precisely because nothing awaits this: the caller has
/// already returned, and the event's timestamp is captured at CALL time, not
/// at write time, so the record still says when it happened.
function whenReady(write: () => void): void {
  if (!initPromise || initReady) {
    write();
    return;
  }
  // Runs on both settle paths: a failed init must not swallow the evidence,
  // it just means the record lands on the fallback store.
  void initPromise.then(write, write);
}

/// Issue #202's headline fix: record the null sessions auth-js hands *us*,
/// not only the ones we went and asked for. Returns the classification, or
/// null for an event we deliberately don't record (see
/// `classifyAuthStateChange`). Not the resulting ring entry: with no explicit
/// storage the write may land after `initAuthDiagnostics` resolves, so the
/// occurrence count isn't known yet at call time.
export function recordAuthStateChange(
  event: string,
  opts: {
    storage?: DurableAuthStore | null;
    now?: () => string;
    build?: string | null;
    userInitiated?: boolean;
  } = {},
): NullSessionReason | null {
  const userInitiated = opts.userInitiated ?? consumeUserSignOut();
  const reason = classifyAuthStateChange(event, userInitiated);
  if (!reason) return null;
  // Captured now, written later: the record must carry the moment auth-js
  // signed us out, not the moment the durable store finished hydrating.
  const at = (opts.now ?? (() => new Date().toISOString()))();
  const write = () => {
    const storage =
      opts.storage === undefined ? defaultStorage() : opts.storage;
    recordAuthNullSession(
      reason,
      storage,
      () => at,
      currentMeta(
        "auth-state-change",
        event,
        storage,
        opts.build === undefined ? status.build : opts.build,
      ),
    );
  };
  // An explicit storage means the caller owns placement — write straight
  // through, and keep the whole path synchronous for it.
  if (opts.storage === undefined) whenReady(write);
  else write();
  return reason;
}

/// A sign-out the user asked for must not read as an incident. Set right
/// before `supabase.auth.signOut()` and consumed by the SIGNED_OUT that
/// follows. Time-boxed, so a sign-out that never completes can't silently
/// absolve a genuine revocation hours later.
const USER_SIGNOUT_TTL_MS = 15_000;
let userSignOutAt = 0;
let clock: () => number = () => Date.now();

export function markUserSignOut(): void {
  userSignOutAt = clock();
}

function consumeUserSignOut(): boolean {
  if (!userSignOutAt) return false;
  const fresh = clock() - userSignOutAt < USER_SIGNOUT_TTL_MS;
  userSignOutAt = 0;
  return fresh;
}

/// Test seam for the sign-out TTL above.
export function setDiagnosticsClock(fn: () => number): void {
  clock = fn;
}

// ---------------------------------------------------------------------------
// Last-known-good session heartbeat
// ---------------------------------------------------------------------------

/// When we last held a session we know was live, and when that session's
/// access token was due to expire. Refreshed on foreground while signed in,
/// so the gap between `at` and the next recorded event bounds the window the
/// logout happened in.
export interface SessionHeartbeat {
  at: string; // ISO
  expiresAt: string | null; // ISO, from session.expires_at
}

export function heartbeatFromSession(
  session: { expires_at?: number | null },
  nowIso: string,
): SessionHeartbeat {
  return {
    at: nowIso,
    // supabase-js stores expiry as unix SECONDS.
    expiresAt: session.expires_at
      ? new Date(session.expires_at * 1000).toISOString()
      : null,
  };
}

/// With no explicit storage the write waits for the durable store, same as
/// the record path: the FIRST heartbeat of every launch would otherwise land
/// in the WebView's localStorage — the store the canary exists to prove is
/// unreliable — and be gone in exactly the scenario the heartbeat is meant to
/// date. The beat itself is stamped and returned synchronously.
export function recordSessionHeartbeat(
  session: { expires_at?: number | null } | null,
  storage?: AuthEventStorage | null,
  now: () => string = () => new Date().toISOString(),
): SessionHeartbeat | null {
  if (!session) return null;
  const beat = heartbeatFromSession(session, now());
  const write = (target: AuthEventStorage | null) => {
    if (!target) return;
    try {
      target.setItem(HEARTBEAT_KEY, JSON.stringify(beat));
    } catch {
      // Same contract as the ring: never throw into the auth path.
    }
  };
  if (storage === undefined) whenReady(() => write(defaultStorage()));
  else write(storage);
  return beat;
}

export function loadSessionHeartbeat(
  storage: AuthStorage | null = defaultStorage(),
): SessionHeartbeat | null {
  if (!storage) return null;
  try {
    const raw = storage.getItem(HEARTBEAT_KEY);
    if (!raw) return null;
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return null;
    const b = parsed as Record<string, unknown>;
    if (typeof b.at !== "string") return null;
    return {
      at: b.at,
      expiresAt: typeof b.expiresAt === "string" ? b.expiresAt : null,
    };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Reads for the UI
// ---------------------------------------------------------------------------

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

export interface AuthDiagnosticsStatus {
  /// Which backend the ring is on right now — shown in the account sheet so
  /// "nothing recorded" can be read against "…and it only ever lived in the
  /// WebView's localStorage".
  store: AuthEventStoreKind;
  /// True when the durable store held our canary but the WebView's copy was
  /// gone at launch: iOS wiped the website data, taking the session with it.
  webviewWiped: boolean;
  build: string | null;
}

let status: AuthDiagnosticsStatus = {
  store: "local-storage",
  webviewWiped: false,
  build: null,
};

export function getAuthDiagnosticsStatus(): AuthDiagnosticsStatus {
  return status;
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

/// Pure: what the canary says about the WebView's storage. Only a durable
/// store that OUTLIVES the WebView (Preferences) can tell us anything — on
/// web both copies are the same store, so a missing web copy there means
/// "first run", not "wiped".
/// A WebView store that THROWS on read is not evidence of a wipe — that's
/// storage-unavailable, the opposite diagnosis (we can't tell), so
/// `webReadable` gates the claim.
export function detectWebviewWipe(
  storeKind: AuthEventStoreKind,
  durableCanary: string | null,
  webCanary: string | null,
  webReadable = true,
): boolean {
  return (
    storeKind === "preferences" && webReadable && !!durableCanary && !webCanary
  );
}

let initPromise: Promise<AuthDiagnosticsStatus> | null = null;
/// Set when the durable store + build tag are installed. `whenReady` writes
/// straight through from then on, so the steady state stays synchronous.
let initReady = false;

/// Installs the durable ring store, migrates whatever the old
/// `localStorage`-only ring holds, and checks the storage-wipe canary.
/// Order-independent: events recorded before this resolves are merged into
/// the hydrated ring rather than lost, so callers can fire it without
/// awaiting on the auth path.
export function initAuthDiagnostics(
  opts: {
    /// May be a promise: the real store is resolved asynchronously (a native
    /// Preferences hydration), and tests need that pending window to exercise
    /// the deferral in `whenReady`.
    store?: DurableAuthStore | Promise<DurableAuthStore>;
    web?: AuthEventStorage | null;
    build?: string | null;
    now?: () => string;
  } = {},
): Promise<AuthDiagnosticsStatus> {
  initPromise ??= runInit(opts);
  return initPromise;
}

async function runInit(opts: {
  store?: DurableAuthStore | Promise<DurableAuthStore>;
  web?: AuthEventStorage | null;
  build?: string | null;
  now?: () => string;
}): Promise<AuthDiagnosticsStatus> {
  const now = opts.now ?? (() => new Date().toISOString());
  // Always awaited, even for an injected store: on native this is a real
  // native round-trip, and a caller (or a test) must never see an init that
  // happens to be synchronous and so never exercises the deferral above.
  const store = await (opts.store ?? createDurableAuthStore(AUTH_DIAGNOSTIC_KEYS));
  const web = opts.web === undefined ? webStorage() : opts.web;

  // Anything this lifetime recorded before the durable store was ready.
  const preInit = events ?? [];
  // The legacy ring: on native, evidence written by already-shipped builds
  // sits in localStorage and would otherwise be dropped by the move. Left in
  // place rather than erased — a wiped WebView is a finding, and rewriting
  // that store here would destroy the very thing the canary reads.
  const legacy = store.kind === "preferences" ? loadAuthEvents(web) : [];

  const merged = mergeAuthEvents(
    mergeAuthEvents(loadAuthEvents(store), legacy),
    preInit,
  );

  ringStore = store;
  events = merged;
  status = { store: store.kind, webviewWiped: false, build: opts.build ?? null };

  const durableCanary = store.getItem(CANARY_KEY);
  let webCanary: string | null = null;
  let webReadable = true;
  try {
    webCanary = web?.getItem(CANARY_KEY) ?? null;
  } catch {
    webReadable = false;
  }
  const wiped = detectWebviewWipe(
    store.kind,
    durableCanary,
    webCanary,
    webReadable,
  );
  status = { ...status, webviewWiped: wiped };

  const stamp = durableCanary ?? now();
  store.setItem(CANARY_KEY, stamp);
  try {
    web?.setItem(CANARY_KEY, stamp);
  } catch {
    // A WebView that can't hold the canary can't hold the session either —
    // that surfaces as storage-unavailable on the next classification.
  }

  // Installed: from here on `whenReady` writes straight through, and every
  // deferred record picks up this store and build tag.
  initReady = true;

  if (wiped) {
    // Recorded, not merely flagged: this is the finding the ring exists to
    // deliver, and it has to survive to the next sign-in flush. Through
    // `currentMeta` like every other record — the heartbeat is already
    // hydrated in `store`, and the event whose whole job is bounding "when
    // did the session die" is the last one that should lack it.
    recordAuthNullSession(
      "storage-wiped",
      store,
      now,
      currentMeta("init", undefined, store, status.build),
    );
  } else {
    saveAuthEvents(events, store);
  }

  return status;
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

/// Test seam: forget the installed store, the init memoization and the
/// status, so a case can boot the module again from scratch.
export function resetAuthDiagnosticsForTest(): void {
  events = null;
  ringStore = null;
  initPromise = null;
  initReady = false;
  userSignOutAt = 0;
  status = { store: "local-storage", webviewWiped: false, build: null };
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
///
/// The `storage` argument is the WEBVIEW's localStorage (where supabase-js
/// keeps the session), NOT the ring store — on native those are deliberately
/// different places.
export async function getSessionWithDiagnostics(
  client: SessionClient,
  url: string,
  storage: AuthStorage | null = webStorage(),
): Promise<{ session: Session | null; reason: NullSessionReason | null }> {
  const stored = probeStoredSession(storage, url);
  const { data, error } = await client.auth.getSession();
  if (data.session) return { session: data.session, reason: null };
  const reason = classifyNullSession(stored, error);
  const at = new Date().toISOString();
  // Same deferral as `recordAuthStateChange`: the cold-start null session
  // (storage-missing resolves with no network, so it usually beats init)
  // must not be filed against the pre-init store with no build tag.
  whenReady(() => {
    const ring = defaultStorage();
    recordAuthNullSession(
      reason,
      ring,
      () => at,
      currentMeta("get-session", undefined, ring, status.build),
    );
  });
  return { session: null, reason };
}

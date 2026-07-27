import type { NewTindeqRecording } from "../types";
import { defaultMainQueueStore } from "./recordingDB";
import type { MainQueueStore } from "./recordingDB";

// #106: a tindeq_recordings insert that failed because the auth session had
// died (e.g. refresh-token-family revocation — see CLAUDE.md) or the network
// dropped used to just throw, get caught, and vanish: the slice/sample data
// lived only in a local `try` variable, so the rep was gone the instant the
// catch returned (and gone for good the moment App.tsx's `if (!session)
// return <LoginScreen />` unmounted the tab on logout). This module persists
// a failed insert's payload instead, so it survives both the failed request
// AND a logout-triggered unmount, and can be retried once a session comes
// back.
//
// #269: TWO STORES, not one. `loadQueue`/`saveQueue`/`enqueueRecording`/
// `persistRecording` below are the SALVAGE LANE — synchronous, localStorage-
// backed, callable from a React cleanup (see useTindeq.ts's unmount salvage).
// The MAIN queue is `persistRecordingToMainQueue` further down — async,
// IndexedDB-backed, with orders of magnitude more headroom, so the
// oldest-entry eviction this lane still does is no longer reachable in
// ordinary use (see the policy block above `persistRecordingToMainQueue`).
// Every other call site (ForceView, the drain) uses the main queue; this
// lane exists ONLY because the unmount-salvage cleanup is genuinely
// synchronous and cannot `await` an IndexedDB write. `drainSalvageLane`
// moves whatever lands here into the main queue on the next mount/foreground
// — it doubles as the one-time migration off the old localStorage-only
// queue, since a `put` under the same id is idempotent.

const STORAGE_KEY = "sendmeter:pending-recordings";

// Byte budget, not item count: a rep's samples array dominates an entry's
// size — a 5-min free hold serializes to ~544 KB, and useTindeq.ts's
// MAX_RECORDING_MS safety cap (30 min) tops out around 3.3 MB. Capping by
// COUNT let a handful of long holds blow straight through what some WebKit
// builds allow for a single localStorage value; capping by approximate
// serialized bytes instead degrades gracefully (drop the oldest entries
// first) rather than silently failing to persist at all. ~1.5 MB leaves
// headroom under everything else already living under the `sendmeter:`
// prefix. This budget is SALVAGE-LANE ONLY — the main queue (IndexedDB) has
// no equivalent cap; see the policy block above `persistRecordingToMainQueue`.
export const MAX_QUEUE_BYTES = 1_500_000;

/// A recording queued for retry. `input.id` is a client-generated uuid,
/// supplied to insertRecording as the row's primary key — a retry of an
/// insert that actually landed server-side (but whose response the client
/// never saw, e.g. the session died mid-request) then collides on the
/// unique constraint (Postgres 23505) instead of creating a duplicate row.
/// `id` mirrors `input.id` for convenient local dedup/lookup.
export interface PendingRecording {
  id: string;
  queuedAt: string; // ISO — display + FIFO eviction order
  /// The session that captured it, when known. A drain only ever attempts
  /// entries matching the CURRENT user, so a stale queue can never attribute
  /// a rep to whoever happens to sign in next (solo-user app today, but
  /// cheap to get right).
  userId: string | null;
  input: NewTindeqRecording & { id: string };
}

interface QueueStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

function defaultStorage(): QueueStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

function isPendingRecording(v: unknown): v is PendingRecording {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  if (
    typeof r.id !== "string" ||
    typeof r.queuedAt !== "string" ||
    !(r.userId === null || typeof r.userId === "string") ||
    !r.input ||
    typeof r.input !== "object"
  ) {
    return false;
  }
  const input = r.input as Record<string, unknown>;
  return typeof input.id === "string" && Array.isArray(input.samples);
}

/// Read the persisted queue. Tolerant of missing/corrupt storage — a bad
/// blob is treated as an empty queue rather than throwing.
export function loadQueue(
  storage: QueueStorage | null = defaultStorage(),
): PendingRecording[] {
  if (!storage) return [];
  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isPendingRecording) : [];
  } catch {
    return [];
  }
}

/// Persist the queue. Returns whether the write actually landed — a full or
/// disabled store (private browsing, a native shell quirk, a single entry
/// over quota on its own) throws on setItem, and callers need to know that
/// happened rather than assume "queued" succeeded.
export function saveQueue(
  queue: PendingRecording[],
  storage: QueueStorage | null = defaultStorage(),
): boolean {
  if (!storage) return false;
  try {
    storage.setItem(STORAGE_KEY, JSON.stringify(queue));
    return true;
  } catch {
    return false;
  }
}

function approxByteSize(queue: PendingRecording[]): number {
  return JSON.stringify(queue).length;
}

/// Pure: append one recording, evicting the OLDEST entries first until the
/// queue's approximate serialized size is back under MAX_QUEUE_BYTES (or
/// only the just-added entry is left — it's never dropped here even if it
/// alone is over budget; saveQueue's return value is what tells the caller
/// whether that still fit in practice). Returns a NEW array — doesn't
/// mutate `queue`.
export function enqueueRecording(
  queue: PendingRecording[],
  input: NewTindeqRecording & { id: string },
  userId: string | null,
  now: () => string = () => new Date().toISOString(),
): PendingRecording[] {
  let next = [...queue, { id: input.id, queuedAt: now(), userId, input }];
  while (next.length > 1 && approxByteSize(next) > MAX_QUEUE_BYTES) {
    next = next.slice(1);
  }
  return next;
}

export interface PersistResult {
  /// Whether the recording now has a durable home. `false` means the samples
  /// exist ONLY in the caller's memory.
  persisted: boolean;
  /// How many PREVIOUSLY-queued recordings were dropped to make room — by
  /// enqueueRecording's own byte budget, and then one at a time by the retry
  /// loop below. Each one is itself a lost rep, so callers report it.
  evicted: number;
}

// #264 / #269 — WHAT HAPPENS WHEN THE PERSIST WRITE ITSELF FAILS, ON THE
// SALVAGE LANE.
//
// This function is the SALVAGE LANE's persist path — synchronous,
// localStorage-backed, and callable from useTindeq.ts's unmount cleanup
// (which cannot `await` anything). Everywhere else uses the async main queue,
// `persistRecordingToMainQueue` below, whose IndexedDB store is what actually
// absorbs a realistic offline session; see the policy block above it for why
// eviction there is a backstop, not the everyday path. This lane still needs
// its own failure policy because it's the one place `persistRecordingToMainQueue`
// itself falls back to when IndexedDB is unavailable/exhausted — so the
// buck has to stop somewhere, and here it does.
//
// saveQueue returns false when localStorage.setItem throws: the origin quota
// is exhausted (MAX_QUEUE_BYTES bounds what THIS queue adds, but not what the
// rest of the `sendmeter:` keys already occupy, and WebKit's per-origin limit
// is smaller than some builds admit) or storage is disabled outright. Before
// #264 both call sites treated that as a dead end — the salvage-on-unmount
// path console.warn'd into a console no deployed device surfaces, and
// ForceView toasted a failure with no way to act on it.
//
// The policy, in order:
//
//   1. THE NEW RECORDING WINS. It is the rep the user just pulled and the only
//      one they are still thinking about; a queued entry is by definition one
//      that has already failed to sync at least once. So a refused write is
//      retried after dropping the OLDEST queued entry, repeatedly, down to the
//      new entry alone. This is the same oldest-first degradation
//      enqueueRecording already applies at the byte budget, just driven by the
//      store's actual answer instead of an estimate.
//   2. IF THE LONE ENTRY STILL WON'T WRITE, THE LOSS IS REAL AND MUST BE SAID
//      OUT LOUD. There is no further store to fall back to FROM HERE, so the
//      contract is to report rather than to pretend: `persisted: false` is
//      returned, and `reportPersistFailure` in `./lostRecordings` emits a
//      Sentry event plus a durable one-shot user notice. Callers must NOT
//      show copy implying the recording will sync later.
//   3. IN-MEMORY SAMPLES ARE STILL WORTH SOMETHING. `persisted: false` does
//      not mean "gone yet" — it means "gone when this scope ends". A caller
//      that is still mounted (ForceView) holds the payload and offers Retry;
//      a caller that is unmounting (useTindeq's salvage cleanup) cannot, and
//      only reports.
//
// Deliberately NOT done: no compression, no partial (down-sampled) save.
// Each trades away the exactness of the curve. IndexedDB is no longer
// rejected (#269 supersedes the earlier "adds a second async store to the one
// path that must stay synchronous" reasoning) — it's the main queue now; this
// lane is what's left of that original synchronous-only design, scoped down
// to the one call site that's genuinely synchronous.

/// Read the SALVAGE LANE queue, append `input`, and write it back — making
/// room by dropping the oldest entries if the store refuses the write. See
/// the policy block above for why the new recording is the one that
/// survives. Not the main queue — see the file-level comment.
export function persistRecording(
  input: NewTindeqRecording & { id: string },
  userId: string | null,
  storage: QueueStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): PersistResult {
  const before = loadQueue(storage);
  let next = enqueueRecording(before, input, userId, now);
  // What enqueueRecording's byte budget already dropped (it added exactly one).
  let evicted = before.length + 1 - next.length;
  // Bounded: `next` shrinks by one every iteration and stops at length 1.
  for (;;) {
    if (saveQueue(next, storage)) return { persisted: true, evicted };
    if (next.length <= 1) return { persisted: false, evicted };
    next = next.slice(1);
    evicted += 1;
  }
}

// #269 — THE MAIN QUEUE (IndexedDB), and why eviction there is a BACKSTOP,
// not the everyday degradation the salvage lane above still documents for
// itself.
//
// Working assumption for why a realistic session can't reach it: even a long
// outage — say a full ~3-hour gym session with every save failing — lands
// on the order of 60 reps in the queue, and the single biggest any one entry
// can be is bounded by useTindeq.ts's MAX_RECORDING_MS safety cap (30 min,
// ≈3.3 MB per the comment on MAX_QUEUE_BYTES above). That puts the whole
// queue in the low tens of MB at the extreme. IndexedDB's origin quota is
// proportional to free disk space (typically hundreds of MB to low GB even on
// a constrained device), not the ~5 MB WKWebView localStorage budget the old
// single-store queue had to share with every other `sendmeter:` key — the
// actual root cause of #269. So the eviction backstop below exists for a
// device that's already nearly out of disk for unrelated reasons, not for
// ordinary use.
//
// The policy:
//
//   1. Try to `put` the entry. On success, done — `evicted: 0` unless a prior
//      iteration of this same call already dropped something.
//   2. On failure (quota exceeded — the one realistic IndexedDB write error),
//      drop the single oldest entry (`deleteOldest`, oldest-first, same
//      policy as the salvage lane) and retry the SAME put. Repeat until it
//      lands or there is nothing left to drop.
//   3. If the main queue is STILL refusing (empty and still failing, or
//      `deleteOldest` itself errors), fall back to the salvage lane's
//      `persistRecording` — same contract as when IndexedDB is unavailable
//      below, just reached the long way. Its own eviction count is ADDED to
//      whatever this function already sacrificed, so `evicted` reports the
//      true total across both lanes rather than resetting at the handoff.
//
// IndexedDB unavailable/blocked (private mode, storage disabled entirely, an
// `open` that times out) is the simpler case: `store` resolves `null` and
// this degrades straight to `persistRecording`, i.e. exactly today's (pre-
// #269) behavior — no eviction-then-fallback dance, because there was never
// a main queue to try.
export async function persistRecordingToMainQueue(
  input: NewTindeqRecording & { id: string },
  userId: string | null,
  store?: MainQueueStore | null,
  storage: QueueStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): Promise<PersistResult> {
  const resolved = store !== undefined ? store : await defaultMainQueueStore();
  if (!resolved) {
    // No main queue this session — degrade to exactly the pre-#269 behavior.
    return persistRecording(input, userId, storage, now);
  }
  const entry: PendingRecording = { id: input.id, queuedAt: now(), userId, input };
  let evicted = 0;
  for (;;) {
    try {
      await resolved.put(entry);
      return { persisted: true, evicted };
    } catch {
      const dropped = await resolved.deleteOldest().catch(() => false);
      if (!dropped) break;
      evicted += 1;
    }
  }
  // Eviction backstop exhausted — fall through to the salvage lane rather
  // than losing the recording outright.
  const fallback = persistRecording(input, userId, storage, now);
  return { ...fallback, evicted: fallback.evicted + evicted };
}

/// Move every entry sitting in the SALVAGE LANE (localStorage) into the MAIN
/// queue (IndexedDB) — removing each from localStorage only AFTER its main-
/// queue `put` resolves, so an interruption (tab closed mid-drain, a `put`
/// that throws) leaves the tail safely in localStorage rather than losing it.
/// `put` is idempotent (`keyPath: "id"`), so re-running after a partial drain
/// never duplicates. This function IS the one-time legacy migration off the
/// old localStorage-only queue — there's no separate migration code or
/// version flag; "drain the salvage lane on every mount/foreground" already
/// covers it, and an empty lane makes this a cheap no-op forever after.
export async function drainSalvageLane(
  store: MainQueueStore,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const queue = loadQueue(storage);
  if (queue.length === 0) return 0;
  let moved = 0;
  for (const entry of queue) {
    try {
      await store.put(entry);
    } catch {
      // Leave this entry AND everything after it (still in original order)
      // for the next drain — a partial main-queue failure here is the same
      // "try again later" shape as a broken drainQueue insert below.
      break;
    }
    // Re-read + write back per entry, not a single end-of-loop write — a late
    // failure below must never re-add an entry a PRIOR iteration already
    // moved, and a concurrent enqueue (ForceView.queueFailedRecording racing
    // this drain) must not be clobbered either. Same race-safety shape as
    // drainPendingRecordingsQueue's per-id delete further down.
    const current = loadQueue(storage);
    saveQueue(
      current.filter((p) => p.id !== entry.id),
      storage,
    );
    moved += 1;
  }
  return moved;
}

/// Total recordings sitting in EITHER lane — the main IndexedDB queue plus
/// whatever the salvage lane hasn't been drained into it yet. Powers the
/// pending-depth readout (`lib/pendingDepth.ts`'s `phoneQueueLine`); this is
/// the read side, kept here alongside the stores it reads.
export async function pendingRecordingCount(
  store?: MainQueueStore | null,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const resolved = store !== undefined ? store : await defaultMainQueueStore();
  const salvageCount = loadQueue(storage).length;
  if (!resolved) return salvageCount;
  const mainCount = await resolved.count().catch(() => 0);
  return mainCount + salvageCount;
}

export interface DrainResult {
  succeeded: PendingRecording[];
  /// Still-pending entries, in their original relative order.
  remaining: PendingRecording[];
}

function isDuplicateKeyError(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const err = e as { code?: unknown; message?: unknown };
  if (err.code === "23505") return true; // Postgres unique_violation
  return (
    typeof err.message === "string" && /duplicate key value/i.test(err.message)
  );
}

/// Try inserting each queued recording IN ORDER for `userId`, via the
/// injected `insert` (so this stays supabase-free and unit-testable). Stops
/// attempting further entries after the first non-duplicate failure — if the
/// session is still broken the rest would fail the same way, and retrying
/// out of order would just reshuffle History for no benefit; they're left
/// queued for the next drain. A 23505 (unique-constraint) failure is treated
/// as SUCCESS — it means an earlier attempt (this one's own client-generated
/// id was already used by a prior insert that landed but whose response the
/// client never saw) actually committed, and this is just a redundant
/// retry. Entries queued under a DIFFERENT user id are never attempted (and
/// never dropped) by this pass.
export async function drainQueue(
  queue: PendingRecording[],
  userId: string,
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
): Promise<DrainResult> {
  const succeeded: PendingRecording[] = [];
  const remaining: PendingRecording[] = [];
  let broken = false;
  for (const item of queue) {
    if (item.userId !== null && item.userId !== userId) {
      remaining.push(item);
      continue;
    }
    if (broken) {
      remaining.push(item);
      continue;
    }
    try {
      await insert(item.input);
      succeeded.push(item);
    } catch (e) {
      if (isDuplicateKeyError(e)) {
        succeeded.push(item);
        continue;
      }
      remaining.push(item);
      broken = true;
    }
  }
  return { succeeded, remaining };
}

// In-flight guard: two near-simultaneous mounts in the SAME tab (e.g. a
// fast-firing auth event followed by React re-rendering AuthedApp) must not
// both drain and double-insert. This is a single module-level flag, not a
// cross-tab lock — fine for this solo-user app (#106); a genuine second tab
// racing the same queue is an accepted, rare edge case. Set synchronously
// (before any `await`) so the second of two synchronous calls sees it.
let draining = false;

/// Pre-#269 behavior, kept as the fallback for a session with no IndexedDB at
/// all (private mode, storage disabled) — in that case the salvage lane IS
/// the only queue that ever existed (every write already fell back to it via
/// `persistRecordingToMainQueue`), so drain it directly the same way this
/// function always has.
async function drainLocalStorageQueue(
  userId: string,
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
  storage: QueueStorage | null,
): Promise<number> {
  const queue = loadQueue(storage);
  if (queue.length === 0) return 0;
  const { succeeded } = await drainQueue(queue, userId, insert);
  if (succeeded.length === 0) return 0;
  // The drain's inserts are awaited one at a time, so a NEW failure can be
  // queued (a synchronous read-modify-write of storage — see
  // ForceView.queueFailedRecording) while we're mid-drain. Re-read storage
  // now and drop only what THIS pass actually resolved, by id, instead of
  // writing back the pre-drain `remaining` snapshot — that would silently
  // clobber the entry that raced in.
  const current = loadQueue(storage);
  const succeededIds = new Set(succeeded.map((p) => p.id));
  saveQueue(
    current.filter((p) => !succeededIds.has(p.id)),
    storage,
  );
  return succeeded.length;
}

/// Drain everything queued for `userId`: first move the salvage lane into the
/// main queue (`drainSalvageLane` — a no-op once nothing is left there), then
/// attempt every main-queue entry via `insert`, then delete only what
/// actually succeeded (per-id, not a bulk overwrite — a concurrent enqueue
/// mid-drain must survive, same reasoning as `drainLocalStorageQueue` above).
/// Falls back to draining the salvage lane directly when no main queue is
/// available this session. Returns how many were recovered.
export async function drainPendingRecordingsQueue(
  userId: string,
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
  storage: QueueStorage | null = defaultStorage(),
  store?: MainQueueStore | null,
): Promise<number> {
  if (draining) return 0;
  draining = true;
  try {
    const resolved = store !== undefined ? store : await defaultMainQueueStore();
    if (!resolved) {
      return await drainLocalStorageQueue(userId, insert, storage);
    }
    await drainSalvageLane(resolved, storage);
    const queue = await resolved.getAll();
    if (queue.length === 0) return 0;
    const { succeeded } = await drainQueue(queue, userId, insert);
    if (succeeded.length === 0) return 0;
    await resolved.delete(succeeded.map((p) => p.id));
    return succeeded.length;
  } finally {
    draining = false;
  }
}

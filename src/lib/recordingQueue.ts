import type { NewTindeqRecording } from "../types";

// #106: a tindeq_recordings insert that failed because the auth session had
// died (e.g. refresh-token-family revocation — see CLAUDE.md) or the network
// dropped used to just throw, get caught, and vanish: the slice/sample data
// lived only in a local `try` variable, so the rep was gone the instant the
// catch returned (and gone for good the moment App.tsx's `if (!session)
// return <LoginScreen />` unmounted the tab on logout). This module persists
// a failed insert's payload to localStorage instead, so it survives both the
// failed request AND a logout-triggered unmount, and can be retried once a
// session comes back.

const STORAGE_KEY = "sendmeter:pending-recordings";

// Byte budget, not item count: a rep's samples array dominates an entry's
// size — a 5-min free hold serializes to ~544 KB, and useTindeq.ts's
// MAX_RECORDING_MS safety cap (30 min) tops out around 3.3 MB. Capping by
// COUNT let a handful of long holds blow straight through what some WebKit
// builds allow for a single localStorage value; capping by approximate
// serialized bytes instead degrades gracefully (drop the oldest entries
// first) rather than silently failing to persist at all. ~1.5 MB leaves
// headroom under everything else already living under the `sendmeter:`
// prefix.
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

// #264 — WHAT HAPPENS WHEN THE PERSIST WRITE ITSELF FAILS.
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
//      OUT LOUD. There is no third store to fall back to, so the contract is
//      to report rather than to pretend: `persisted: false` is returned, and
//      `reportPersistFailure` in `./lostRecordings` emits a Sentry event plus
//      a durable one-shot user notice. Callers must NOT show copy implying the
//      recording will sync later.
//   3. IN-MEMORY SAMPLES ARE STILL WORTH SOMETHING. `persisted: false` does
//      not mean "gone yet" — it means "gone when this scope ends". A caller
//      that is still mounted (ForceView) holds the payload and offers Retry;
//      a caller that is unmounting (useTindeq's salvage cleanup) cannot, and
//      only reports.
//
// Deliberately NOT done: no compression, no IndexedDB fallback, no partial
// (down-sampled) save. Each trades away the exactness of the curve or adds a
// second async store to the one path that must stay synchronous.

/// Read the queue, append `input`, and write it back — making room by
/// dropping the oldest entries if the store refuses the write. See the policy
/// block above for why the new recording is the one that survives.
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
// racing the same queue is an accepted, rare edge case.
let draining = false;

/// Load the queue, attempt everything for `userId`, persist whatever's
/// still pending, and report how many were recovered.
export async function drainPendingRecordingsQueue(
  userId: string,
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  if (draining) return 0;
  const queue = loadQueue(storage);
  if (queue.length === 0) return 0;
  draining = true;
  try {
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
  } finally {
    draining = false;
  }
}

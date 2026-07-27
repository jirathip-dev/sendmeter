import type { NewTindeqRecording } from "../types";
import {
  approxByteSize,
  byQueuedAt,
  isPendingRecording,
  type PendingRecording,
} from "./pendingRecording";
import { notifyPendingUploadsChanged } from "./pendingUploads";
import {
  isQuotaError,
  openRecordingDb,
  type RecordingDb,
  type RecordingDbLoader,
} from "./recordingDb";

// #106: a tindeq_recordings insert that failed because the auth session had
// died (e.g. refresh-token-family revocation — see CLAUDE.md) or the network
// dropped used to just throw, get caught, and vanish: the slice/sample data
// lived only in a local `try` variable, so the rep was gone the instant the
// catch returned (and gone for good the moment App.tsx's `if (!session)
// return <LoginScreen />` unmounted the tab on logout). This module persists
// a failed insert's payload instead, so it survives both the failed request
// AND a logout-triggered unmount, and can be retried once a session comes back.
//
// #269: "persists" means TWO stores now — IndexedDB for the queue proper and
// localStorage as a synchronous emergency lane. The policy block above
// `persistRecording` is where that split is written down; read it before
// changing either path.

export type { PendingRecording };

const STORAGE_KEY = "sendmeter:pending-recordings";

// Byte budget for the SYNC LANE only (#269 — before that, for the whole
// queue). A rep's samples array dominates an entry's size: a 5-min free hold
// serializes to ~544 KB, and useTindeq.ts's MAX_RECORDING_MS safety cap
// (30 min) tops out around 3.3 MB. Capping by COUNT let a handful of long holds
// blow straight through what some WebKit builds allow for a single localStorage
// value; capping by approximate serialized bytes instead degrades gracefully
// (drop the oldest entries first) rather than silently failing to persist at
// all. ~1.5 MB leaves headroom under everything else already living under the
// `sendmeter:` prefix — and the lane is only ever meant to hold ONE entry
// between a salvage and the next foreground, so the budget is now a backstop
// against a lane that failed to drain, not a working limit.
export const MAX_QUEUE_BYTES = 1_500_000;

// Byte budget for the MAIN (IndexedDB) queue. The working assumption about
// session size, stated so the next reader can check it rather than trust it:
// the heaviest realistic offline session is a guided protocol run end to end —
// call it 60 holds of 30 s. At the ~1.8 KB/s that samples serialize to, that's
// ~54 KB a rep, ~3.2 MB for the session. 64 MB is ~20 such sessions stacked up,
// or ~19 back-to-back recordings at the 30-min MAX_RECORDING_MS cap. Eviction
// is therefore not something a real session reaches — it is the backstop for a
// queue that has silently failed to drain for weeks, which is a different bug
// and one we would rather cap than let grow without bound.
export const MAX_IDB_QUEUE_BYTES = 64_000_000;

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

/// Read the sync lane. Tolerant of missing/corrupt storage — a bad blob is
/// treated as an empty queue rather than throwing.
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

/// Persist the sync lane. Returns whether the write actually landed — a full or
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

/// Pure: append one recording to the SYNC LANE, evicting the OLDEST entries
/// first until the lane's approximate serialized size is back under
/// MAX_QUEUE_BYTES (or only the just-added entry is left — it's never dropped
/// here even if it alone is over budget; the store's own answer is what tells
/// the caller whether that fit in practice). Returns a NEW array — doesn't
/// mutate `queue`. The IndexedDB path applies the same shape against
/// MAX_IDB_QUEUE_BYTES inline, since it writes one entry rather than rewriting
/// the whole queue.
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
  /// How many PREVIOUSLY-queued recordings were dropped to make room — by the
  /// byte budget, and then one at a time by the retry loop when the store
  /// refuses a write outright. Each one is itself a lost rep, so callers
  /// report it. Expected to be 0 forever on the IndexedDB path; see
  /// MAX_IDB_QUEUE_BYTES for why, and treat a non-zero value as a finding.
  evicted: number;
}

// #264 / #269 — WHERE A RECORDING GOES WHEN IT CAN'T BE SENT, AND WHAT HAPPENS
// WHEN THAT WRITE ITSELF FAILS.
//
// TWO STORES, ON PURPOSE. Do not collapse them into one.
//
//   * IndexedDB (`recordingDb.ts`) is THE QUEUE. Every path that can await uses
//     it: ForceView's failed-insert handler, the drain, the manual retry. It is
//     here for headroom — see MAX_IDB_QUEUE_BYTES.
//   * localStorage (this file's STORAGE_KEY) is a SYNCHRONOUS EMERGENCY LANE,
//     written by exactly one caller: useTindeq's salvage-on-unmount cleanup.
//     A React cleanup function cannot await — the sample buffer is gone the
//     moment it returns — so an async write there does not "finish later", it
//     loses the recording. That is the whole reason this store still exists,
//     and it is not a style preference. The lane holds at most the one rep
//     being rescued, and `absorbSyncLane` moves it into IndexedDB on the next
//     foreground/drain, so nothing lives there for long.
//   * IndexedDB unavailable (private mode, storage disabled, a blocked open)
//     degrades to the lane rather than throwing. A smaller queue beats no queue.
//
// WHEN A WRITE IS REFUSED. Both stores can refuse — the origin quota is
// exhausted, or storage is disabled outright. Before #264 both call sites
// treated that as a dead end: the salvage path console.warn'd into a console no
// deployed device surfaces, and ForceView toasted a failure with no way to act
// on it. The policy, in order:
//
//   1. THE NEW RECORDING WINS. It is the rep the user just pulled and the only
//      one they are still thinking about; a queued entry is by definition one
//      that has already failed to sync at least once. So a refused write is
//      retried after dropping the OLDEST queued entry, repeatedly, down to the
//      new entry alone. This is the same oldest-first degradation the byte
//      budget applies, just driven by the store's actual answer instead of an
//      estimate. #269 did NOT delete this — it made it unreachable in practice
//      by giving the main queue real headroom, and kept it as the backstop.
//      Every eviction is still reported to monitoring, and now genuinely means
//      something is wrong rather than "Tuesday".
//   2. IF THE LONE ENTRY STILL WON'T WRITE — to IndexedDB, and then not to the
//      lane either — THE LOSS IS REAL AND MUST BE SAID OUT LOUD. There is no
//      third store, so the contract is to report rather than to pretend:
//      `persisted: false` is returned, and `reportPersistFailure` in
//      `./lostRecordings` emits a Sentry event plus a durable one-shot user
//      notice. Callers must NOT show copy implying the recording will sync.
//   3. IN-MEMORY SAMPLES ARE STILL WORTH SOMETHING. `persisted: false` does
//      not mean "gone yet" — it means "gone when this scope ends". A caller
//      that is still mounted (ForceView) holds the payload and offers Retry;
//      a caller that is unmounting (useTindeq's salvage cleanup) cannot, and
//      only reports.
//
// Deliberately NOT done: no compression, no down-sampled partial save. Both
// trade away the exactness of the curve, which is the product.
//
// #273 — WHEN A QUEUED RECORDING IS ALLOWED TO LEAVE THE DEVICE'S STORAGE.
//
// Nothing used to clear either store, ever. Signing out is the action a user
// takes when they want their data off a device, and it left every unsynced rep
// sitting there indefinitely. The rule now:
//
//   * A USER-INITIATED sign-out DRAINS FIRST, then clears only what actually
//     uploaded. On a normal online sign-out that empties both stores with no
//     prompt and no loss, which is the overwhelmingly common case. The drain
//     has to finish BEFORE `supabase.auth.signOut()` — afterwards there is no
//     token and every insert 401s — but it is deadlined (see
//     `DRAIN_TIMEOUT_MS` in `signOut.ts`), because a slow network must not
//     hang sign-out. A drain that times out is simply "could not upload".
//   * ANY REMAINDER IS THE USER'S CALL, asked once, with the count. Only
//     entries that genuinely cannot upload (offline, or the server refusing)
//     reach this, so the prompt is rare and always has something to decide.
//     An UNCONDITIONAL confirm was rejected: it would fire mostly on an empty
//     queue and train the user to dismiss the one that matters.
//   * A FORCED OR REVOKED SIGN-OUT NEVER DISCARDS ANYTHING. #265 was a real
//     production session revocation with no user action behind it; under a
//     flat clear-on-sign-out rule that auth bug would have destroyed every
//     unsynced rep on the device. An auth failure escalating into data loss is
//     strictly worse than the problem being fixed here. The two paths are told
//     apart by `markUserSignOut()`'s marker (`authDiagnostics.ts`), which a
//     revocation has no way to set — and `clearRecordingQueue` is only ever
//     reached through `discardQueueOnUserSignOut`, which checks it.
//   * CLEARING COVERS BOTH STORES. An entry absorbed into IndexedDB and one
//     still sitting in the sync lane are equally the user's data.
//
// ACCEPTED RESIDUAL, deliberately: a user who signs out with entries that
// cannot upload and chooses to KEEP them leaves those entries on the device
// until the same account signs back in and drains them. Nothing ages them out.
// That is the right trade for a personal training app on a personal phone —
// the alternative is destroying training data to satisfy a privacy property
// the user just declined — and the wrong one for a shared device. If this app
// ever runs on shared hardware, revisit it here first.

/// SYNCHRONOUS emergency lane — see the policy block above. Read the lane,
/// append `input`, write it back, making room by dropping the oldest entries if
/// the store refuses. The ONLY caller that should use this is a path that
/// genuinely cannot await (useTindeq's unmount cleanup); everything else wants
/// `persistRecordingDurable`.
export function persistRecording(
  input: NewTindeqRecording & { id: string },
  userId: string | null,
  storage: QueueStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): PersistResult {
  const before = loadQueue(storage);
  let next = enqueueRecording(before, input, userId, now);
  // What the byte budget already dropped (enqueueRecording added exactly one).
  let evicted = before.length + 1 - next.length;
  // Bounded: `next` shrinks by one every iteration and stops at length 1.
  for (;;) {
    if (saveQueue(next, storage)) {
      notifyPendingUploadsChanged();
      return { persisted: true, evicted };
    }
    if (next.length <= 1) return { persisted: false, evicted };
    next = next.slice(1);
    evicted += 1;
  }
}

/// THE MAIN PATH — see the policy block above. Queue `input` in IndexedDB,
/// falling back to the synchronous lane if IndexedDB is unavailable or refuses
/// the write outright. Async, which every caller but the unmount cleanup can be.
export async function persistRecordingDurable(
  input: NewTindeqRecording & { id: string },
  userId: string | null,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): Promise<PersistResult> {
  const db = await loadDb().catch(() => null);
  // No IndexedDB at all → the lane is the queue. Strictly worse (that is the
  // whole point of #269) but still durable.
  if (!db) return persistRecording(input, userId, storage, now);

  const existing = await db.getAll().catch(() => null);
  if (existing === null) return persistRecording(input, userId, storage, now);

  const entry: PendingRecording = { id: input.id, queuedAt: now(), userId, input };
  // Budget eviction first, so the retry loop below only ever deals with the
  // store refusing something the budget already thinks should fit.
  let keep = [...existing, entry];
  while (keep.length > 1 && approxByteSize(keep) > MAX_IDB_QUEUE_BYTES) {
    keep = keep.slice(1);
  }
  let evicted = existing.length + 1 - keep.length;
  const overBudget = existing.slice(0, evicted).map((e) => e.id);
  if (overBudget.length > 0) await db.delete(overBudget).catch(() => {});

  // Survivors other than the new entry, oldest first — what the retry loop is
  // allowed to drop.
  let droppable = keep.filter((e) => e.id !== entry.id);
  for (;;) {
    try {
      await db.put([entry]);
      notifyPendingUploadsChanged();
      return { persisted: true, evicted };
    } catch (e) {
      // Only a quota refusal is worth evicting for; anything else (a
      // structurally unwritable record, a dead connection) would refuse the
      // lone entry just as hard, and dropping queued reps to learn that would
      // be pure loss.
      const oldest = isQuotaError(e) ? droppable[0] : undefined;
      if (!oldest) break;
      droppable = droppable.slice(1);
      await db.delete([oldest.id]).catch(() => {});
      evicted += 1;
    }
  }

  // IndexedDB refused even the lone entry. The lane is a different store with a
  // different budget, so it is worth one honest attempt before declaring loss.
  const lane = persistRecording(input, userId, storage, now);
  return { persisted: lane.persisted, evicted: evicted + lane.evicted };
}

/// Move everything in the synchronous lane into the main queue and clear the
/// lane. This is BOTH the one-time migration of pre-#269
/// `sendmeter:pending-recordings` entries AND the ongoing drain of the salvage
/// lane — they are the same operation on the same entry shape, so there is no
/// separate migration flag to get out of step with reality.
///
/// SAFE TO INTERRUPT, which is the property that matters:
///   * `put` is ONE transaction, so the copy either lands whole or not at all;
///     a rejected copy leaves the lane untouched and is retried next launch.
///   * the lane is only cleared AFTER that transaction commits, so a process
///     killed in between leaves entries in both stores — and the next run
///     re-puts them under the same keyPath id, which OVERWRITES rather than
///     duplicating. (The drain is idempotent for the same reason one layer
///     further out: the id is the row's primary key, so a re-inserted recording
///     collides 23505 and is treated as already-saved.)
///   * the lane is cleared by RE-READING it and removing only the ids we
///     actually copied, so a salvage that raced in during the copy isn't
///     clobbered.
///
/// Returns how many entries moved.
export async function absorbSyncLane(
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const lane = loadQueue(storage);
  if (lane.length === 0) return 0;
  const db = await loadDb().catch(() => null);
  if (!db) return 0; // no main store to move into — the lane stays the queue
  try {
    await db.put(lane);
  } catch {
    return 0; // nothing committed; the lane still holds them
  }
  const movedIds = new Set(lane.map((p) => p.id));
  saveQueue(
    loadQueue(storage).filter((p) => !movedIds.has(p.id)),
    storage,
  );
  notifyPendingUploadsChanged();
  return lane.length;
}

/// How many recordings are waiting to upload, across BOTH stores. Ids, not
/// payloads — `keys()` is a getAllKeys, so this doesn't deserialize the
/// samples. De-duplicated because the interrupted-migration window (committed
/// to IndexedDB, not yet cleared from the lane) legitimately has an entry in
/// both, and showing it twice would make a stall look worse than it is.
export async function pendingRecordingsCount(
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const ids = new Set(loadQueue(storage).map((p) => p.id));
  const db = await loadDb().catch(() => null);
  if (db) {
    const keys = await db.keys().catch(() => [] as string[]);
    for (const k of keys) ids.add(k);
  }
  return ids.size;
}

/// Remove EVERY queued recording from BOTH stores — the "#273" section of the
/// policy block above is the decision this carries out, and is where to look
/// before calling it.
///
/// DO NOT CALL THIS DIRECTLY. `discardQueueOnUserSignOut` in `signOut.ts` is
/// the only caller, because it is the only place that first checks the
/// sign-out was one the user asked for; a revoked session must never reach
/// here. `signOutInvariants.test.ts` pins that as a structural property rather
/// than a convention, since the cost of the two paths drifting is the user's
/// training data.
///
/// Returns how many DISTINCT entries were actually removed — not how many were
/// there. A store that refuses the clear contributes nothing to the count, so
/// a caller can tell "deleted" from "asked to delete" (the sign-out path
/// reports the gap to monitoring). De-duplicated across the stores for the
/// same reason `pendingRecordingsCount` is: an interrupted absorb legitimately
/// leaves the same entry in both.
export async function clearRecordingQueue(
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const removed = new Set<string>();
  const db = await loadDb().catch(() => null);
  if (db) {
    // Read the ids first (only for the count) and clear in one transaction —
    // `delete(await keys())` would leave behind anything written in between.
    const keys = await db.keys().catch(() => [] as string[]);
    const cleared = await db.clear().then(
      () => true,
      () => false,
    );
    if (cleared) for (const k of keys) removed.add(k);
  }
  const lane = loadQueue(storage);
  if (lane.length > 0 && saveQueue([], storage)) {
    for (const p of lane) removed.add(p.id);
  }
  notifyPendingUploadsChanged();
  return removed.size;
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

/// Absorb the sync lane, attempt everything queued for `userId` across both
/// stores, remove whatever landed, and report how many were recovered.
///
/// Both stores are read even though `absorbSyncLane` normally empties the lane
/// first: if the absorb couldn't commit (IndexedDB refused, or isn't there at
/// all) the lane still holds real recordings, and leaving them unattempted
/// until IndexedDB recovers would strand them for no reason.
export async function drainPendingRecordingsQueue(
  userId: string,
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  if (draining) return 0;
  draining = true;
  try {
    await absorbSyncLane(loadDb, storage);
    const db: RecordingDb | null = await loadDb().catch(() => null);
    const main = db ? await db.getAll().catch(() => [] as PendingRecording[]) : [];
    const lane = loadQueue(storage);
    // An interrupted absorb leaves the same entry in both stores; attempt it once.
    const mainIds = new Set(main.map((p) => p.id));
    const queue = [...main, ...lane.filter((p) => !mainIds.has(p.id))].sort(byQueuedAt);
    if (queue.length === 0) return 0;

    const { succeeded } = await drainQueue(queue, userId, insert);
    if (succeeded.length === 0) return 0;
    const succeededIds = new Set(succeeded.map((p) => p.id));
    // Deleting by id is inherently race-safe on the main store — unlike the
    // lane's read-modify-write below, it can't clobber an entry that arrived
    // mid-drain (the drain awaits one insert at a time, so a salvage really can
    // land in between).
    if (db) await db.delete([...succeededIds]).catch(() => {});
    const currentLane = loadQueue(storage);
    if (currentLane.some((p) => succeededIds.has(p.id))) {
      saveQueue(
        currentLane.filter((p) => !succeededIds.has(p.id)),
        storage,
      );
    }
    notifyPendingUploadsChanged();
    return succeeded.length;
  } finally {
    draining = false;
  }
}

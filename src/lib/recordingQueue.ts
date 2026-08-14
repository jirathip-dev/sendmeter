import type { NewTindeqRecording } from "../types";
import {
  approxByteSize,
  byQueuedAt,
  isPendingRecording,
  type PendingRecording,
  type PendingRecordingRejection,
} from "./pendingRecording";
import { notifyPendingUploadsChanged } from "./pendingUploads";
import {
  isQuotaError,
  openRecordingDb,
  type RecordingDb,
  type RecordingDbLoader,
} from "./recordingDb";
import { classifyHandledFailure } from "./monitoring";
import { currentAppVersion } from "./appVersion";

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
//
// ACCEPTED RESIDUAL #2 (R2-F3, round-2 review of #492's fix): the
// account-deletion discard (`deleteAccount()`, `queue: "discard"`) can now
// be SKIPPED entirely — see `signOutUser`'s doc comment — when the deleting
// account's id can't be resolved (the #492 F1 `getSession()`/RPC race).
// #264's never-swallow half is satisfied (it's reported, not silently
// dropped) but its user-visible half is not: unlike a genuinely LOST
// recording (`lostRecordings.ts`'s one-shot notice), nothing was lost here,
// so there is no UI notice — only a Sentry report. The account is already
// deleted server-side by the time this could happen, so there is no "sign
// back in and drain" recovery path either. The honest residual: THAT
// ACCOUNT'S recordings stay on the device forever, invisible (a scoped
// count for a different, still-signed-in account will never surface an id
// that isn't theirs — same "mine" rule as everywhere else in this file) and
// permanently un-uploadable (the account they'd upload into no longer
// exists). Accepted rather than fixed, because the alternative — falling
// back to an unscoped wipe to guarantee cleanup — is #492 itself.

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

/// Every recording queued for `userId` (plus unattributed legacy entries,
/// `userId: null` — the same "attemptable by anyone" rule `drainQueue`
/// already applies), across BOTH stores. De-duplicated because the
/// interrupted-migration window (committed to IndexedDB, not yet cleared
/// from the lane) legitimately has an entry in both.
///
/// #484 F5: uses `RecordingDb.getAllForUser`, which goes through the `userId`
/// index for the common case rather than deserializing every OTHER account's
/// stranded queue just to filter it out locally — see that method's doc
/// comment. The single reader both `pendingRecordingsCount` and
/// `pendingRecordingsBreakdown` build on, so there is exactly one place that
/// combines the two stores.
async function pendingRecordingsForUser(
  userId: string,
  loadDb: RecordingDbLoader,
  storage: QueueStorage | null,
): Promise<PendingRecording[]> {
  const mine = (p: PendingRecording) => p.userId === null || p.userId === userId;
  const byId = new Map<string, PendingRecording>();
  for (const p of loadQueue(storage).filter(mine)) byId.set(p.id, p);
  const db = await loadDb().catch(() => null);
  if (db) {
    const rows = await db.getAllForUser(userId).catch(() => [] as PendingRecording[]);
    for (const p of rows) byId.set(p.id, p);
  }
  return [...byId.values()];
}

/// How many recordings are waiting to upload for `userId` — TOTAL, including
/// any that are `rejection.stuck` (#484): they are still on the device,
/// still unsynced, and a sign-out remainder prompt (`signOut.ts`) must count
/// them or its "N recordings not uploaded" understates what a "Delete" choice
/// there will actually remove. Callers that need the pending/stuck split for
/// display use `pendingRecordingsBreakdown` instead.
export async function pendingRecordingsCount(
  userId: string,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  return (await pendingRecordingsForUser(userId, loadDb, storage)).length;
}

/// The same total as `pendingRecordingsCount`, split into what's still being
/// actively retried (`pending`) versus what a drain has stopped attempting
/// automatically (`stuck` — see the policy block above `drainQueue`). For the
/// ambient UI: `pendingUploadsLine`/`uploadWarningPresentation` render these
/// as two distinct, honestly-labeled states rather than one number that goes
/// silent about data that will never sync on its own (#475 F1's "the #264
/// rule inverted" — a count with zero readers).
export async function pendingRecordingsBreakdown(
  userId: string,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<{ pending: number; stuck: number }> {
  const all = await pendingRecordingsForUser(userId, loadDb, storage);
  const stuck = all.filter((p) => p.rejection?.stuck === true).length;
  return { pending: all.length - stuck, stuck };
}

/// Remove queued recordings from BOTH stores, SCOPED to `userId` (plus
/// unattributed legacy entries) — the "#273" section of the policy block
/// above is the decision this carries out, and is where to look before
/// calling it.
///
/// `userId` is a required, non-null `string` ON PURPOSE (#492 F1, review of
/// the initial fix): the first version of this fix kept `userId: string |
/// null` with `null` meaning "clear EVERYTHING, unscoped", on the theory
/// that `deleteAccount()` needed it. The review found `deleteAccount()`
/// could still legitimately resolve a `null` id (two independent
/// `getSession()` reads — the id capture here and the RPC's own bearer-token
/// read — can race a token rotation in another tab and disagree), and that a
/// TYPE-LEVEL `null` on this function meant that race reproduced #492's
/// whole-device wipe byte-for-byte. Making `null` unrepresentable here (not
/// just unused) is what closes it: there is no longer a value a caller can
/// pass to this function that wipes another account's queue.
///
/// R2-F1 (round-2 review): an earlier version of THIS fix moved the unscoped
/// wipe behind a separately-named `clearRecordingQueueUnscoped` rather than
/// deleting it, reasoning that a deliberately-named primitive is harder to
/// reach by accident than a `null` argument. That reasoning didn't survive
/// review: the function had no `isUserSignOutPending` gate (so a revoked
/// session calling it would violate #265/#273 outright), the "exactly one
/// deletion place" structural pin in `signOutInvariants.test.ts` did not
/// match its name and so did not cover it, and mutation-testing proved it —
/// adding a production call site left every structural pin green. A whole-
/// device wipe capability with zero callers is not a safety net, it is an
/// unpinned second deletion site waiting for its first caller. The #273
/// policy block's answer is "only the signed-in account's own entries,
/// never everyone's" with no carve-out, so there is no capability to keep:
/// deleted outright rather than re-guarded.
///
/// Scopes to `userId` plus unattributed (`userId: null`) legacy entries, the
/// same "mine" rule `pendingRecordingsCount` uses — #484 F3: before that,
/// the delete was always unscoped while the sign-out prompt's count became
/// scoped, so "Delete N and sign out" could silently destroy another
/// account's stranded recordings along with the N it named.
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
  userId: string,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const mine = (p: PendingRecording) => p.userId === null || p.userId === userId;
  const removed = new Set<string>();
  const db = await loadDb().catch(() => null);
  if (db) {
    // Only `userId`'s (plus unattributed) ids, deleted by id —
    // `getAllForUser` already applies the same "mine" rule.
    const rows = await db.getAllForUser(userId).catch(() => [] as PendingRecording[]);
    const ids = rows.map((p) => p.id);
    if (ids.length > 0) {
      const ok = await db.delete(ids).then(
        () => true,
        () => false,
      );
      if (ok) for (const id of ids) removed.add(id);
    }
  }
  const lane = loadQueue(storage);
  const laneMine = lane.filter(mine);
  if (laneMine.length > 0) {
    if (saveQueue(lane.filter((p) => !mine(p)), storage)) {
      for (const p of laneMine) removed.add(p.id);
    }
  }
  notifyPendingUploadsChanged();
  return removed.size;
}

/// #613: remove ONE queued recording by id, from BOTH stores, scoped to
/// `userId` (plus unattributed legacy entries — the same "mine" rule as
/// `pendingRecordingsCount`).
///
/// Two callers, both about a single rep the user actually recorded, and
/// neither is the #273 sign-out path (that one stays exclusively
/// `clearRecordingQueue` via `discardQueueOnUserSignOut`):
///
///   * the durable-first save path writes the entry BEFORE the network insert
///     (`recordingSave.ts`), so a successful insert must dequeue it — an entry
///     left behind would be re-attempted (harmless 23505) but, worse, counted
///     in the ambient "waiting to upload" backlog forever;
///   * Undo of a just-saved rep (ForceView) dequeues the same entry, so the
///     rep the user discarded cannot drain back into the list later.
///
/// Best-effort: a store that refuses the delete contributes nothing to the
/// return, and a lane write that fails is left for the next drain. Idempotent:
/// removing an id that isn't queued anywhere returns false with no error.
export async function removeQueuedRecording(
  id: string,
  userId: string,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<boolean> {
  const mine = (p: PendingRecording) => p.userId === null || p.userId === userId;
  let removed = false;
  const db = await loadDb().catch(() => null);
  if (db) {
    // `delete` is by id, so confirm the entry is this user's BEFORE deleting —
    // a uuid collision is practically impossible, but the "mine" rule is the
    // whole point of #484 F3 and costs nothing here.
    const mineById = await db
      .getAllForUser(userId)
      .then((rows) => rows.some((p) => p.id === id))
      .catch(() => false);
    if (mineById) {
      removed = await db.delete([id]).then(
        () => true,
        () => false,
      );
    }
  }
  const lane = loadQueue(storage);
  const next = lane.filter((p) => !(p.id === id && mine(p)));
  if (next.length !== lane.length) {
    if (saveQueue(next, storage)) removed = true;
  }
  if (removed) notifyPendingUploadsChanged();
  return removed;
}

/// #484: the one way a `rejection.stuck` entry is attempted again outside of
/// the app-version-change window that produced it — the "explicit user
/// action" leg of the policy block above `drainQueue`. Clears `rejection`
/// entirely (not just `stuck`), so the next drain treats it as a fresh
/// attempt with a fresh latch: if it fails again under the CURRENT build,
/// that starts a new first-rejection window rather than instantly re-tripping
/// `stuck` against a `firstVersion` this retry never saw.
export async function retryStuckRecordings(
  userId: string,
  loadDb: RecordingDbLoader = openRecordingDb,
  storage: QueueStorage | null = defaultStorage(),
): Promise<number> {
  const stuckMine = (p: PendingRecording) =>
    p.rejection?.stuck === true && (p.userId === null || p.userId === userId);
  const clear = (p: PendingRecording): PendingRecording => ({
    id: p.id,
    queuedAt: p.queuedAt,
    userId: p.userId,
    input: p.input,
  });
  let cleared = 0;
  const db = await loadDb().catch(() => null);
  if (db) {
    const rows = await db.getAllForUser(userId).catch(() => [] as PendingRecording[]);
    const stuck = rows.filter(stuckMine);
    if (stuck.length > 0) {
      const ok = await db.put(stuck.map(clear)).then(
        () => true,
        () => false,
      );
      if (ok) cleared += stuck.length;
    }
  }
  const lane = loadQueue(storage);
  const stuckLane = lane.filter(stuckMine);
  if (stuckLane.length > 0) {
    const ids = new Set(stuckLane.map((p) => p.id));
    if (saveQueue(lane.map((p) => (ids.has(p.id) ? clear(p) : p)), storage)) {
      cleared += stuckLane.length;
    }
  }
  if (cleared > 0) notifyPendingUploadsChanged();
  return cleared;
}

export interface DrainResult {
  succeeded: PendingRecording[];
  /// Still being actively retried, in their original relative order — either
  /// untouched, or carrying an UPDATED `rejection` stamp from a fresh
  /// constraint rejection this pass that has not (yet) survived an
  /// app-version change.
  remaining: PendingRecording[];
  /// #484: entries whose `rejection.stuck` is true after this pass — either
  /// already stuck coming in (never attempted this pass, per the policy
  /// block below) or freshly latched by THIS pass's rejection. Retained by
  /// the caller, not deleted, and excluded from automatic retry until
  /// `retryStuckRecordings` clears them.
  stuck: PendingRecording[];
}

function isDuplicateKeyError(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const err = e as { code?: unknown; message?: unknown };
  if (err.code === "23505") return true; // Postgres unique_violation
  return (
    typeof err.message === "string" && /duplicate key value/i.test(err.message)
  );
}

/// Is this failure a content-based rejection — the payload itself violates a
/// database constraint (SQLSTATE 23xxx: a CHECK, NOT NULL or foreign-key
/// violation) — as opposed to the environment being temporarily broken?
///
/// `classifyHandledFailure` already draws this line for Sentry reporting
/// (`monitoring.ts`) and is reused here rather than duplicated: "auth",
/// "network", "permission" and "unknown" all mean "no verdict was reached
/// about THIS payload" and must default to retry, exactly like every other
/// transient failure — mirroring the watch-side precedent at #475 and its
/// correction at #475 F11 (a healthy workout must never be blocked by
/// nothing more than bad wifi or a stale token).
///
/// #484: unlike the watch, a constraint code here is NOT treated as an
/// immediate, final verdict either — see the policy block above `drainQueue`
/// for why (this repo's CHECK constraints are value allow-lists that
/// migrations widen, and a web deploy can go live slightly ahead of its own
/// migration). This only says "the payload, not the environment" so the
/// caller can decide whether it's SEEN this before.
function isConstraintFailure(e: unknown): boolean {
  return classifyHandledFailure(e) === "constraint";
}

/// Best-effort diagnosis detail from a constraint-rejection error — never
/// matched on to decide anything, only stored on `rejection` so a human can
/// tell what's stuck and why. Truncated: this rides in IndexedDB
/// indefinitely, not a one-shot event.
function failureDetail(e: unknown): { code: string; message: string } {
  if (e && typeof e === "object") {
    const err = e as { code?: unknown; message?: unknown; status?: unknown };
    const code =
      typeof err.code === "string"
        ? err.code
        : typeof err.status === "number"
          ? String(err.status)
          : "unknown";
    const message = typeof err.message === "string" ? err.message : String(e);
    return { code, message: message.slice(0, 300) };
  }
  return { code: "unknown", message: String(e).slice(0, 300) };
}

/// Fold one more constraint rejection into `prev` (absent on the first
/// sighting). `stuck` latches true the moment a rejection is seen under a
/// build DIFFERENT from `firstVersion` — i.e. this exact payload survived a
/// deploy that could plausibly have carried a schema fix and was rejected
/// again anyway. It never un-latches on its own; `retryStuckRecordings` is
/// the only way back (see its doc comment for why that also resets
/// `firstVersion` rather than just clearing `stuck`).
function nextRejection(
  prev: PendingRecordingRejection | undefined,
  e: unknown,
  appVersion: string,
  at: string,
): PendingRecordingRejection {
  const { code, message } = failureDetail(e);
  if (!prev) {
    return { code, message, firstVersion: appVersion, firstAt: at, lastVersion: appVersion, lastAt: at, stuck: false };
  }
  return {
    code,
    message,
    firstVersion: prev.firstVersion,
    firstAt: prev.firstAt,
    lastVersion: appVersion,
    lastAt: at,
    stuck: prev.stuck || prev.firstVersion !== appVersion,
  };
}

/// Try inserting each queued recording IN ORDER for `userId`, via the
/// injected `insert` (so this stays supabase-free and unit-testable).
///
/// #484 — THE QUARANTINE POLICY. A permanently-shaped rejection (a database
/// CHECK/NOT NULL/foreign-key violation — see `isConstraintFailure`) does NOT
/// delete the entry, on the first sighting or ever: this repo's own history
/// is why. Its CHECK constraints are value allow-lists that migrations
/// WIDEN — `tindeq_recordings_zone_check` twice already — and CLAUDE.md's
/// release flow fires the Vercel production deploy on the merge itself while
/// the migration workflow is still separately running, so a client can be
/// briefly ahead of its own schema. A recording rejected in that window would
/// have inserted cleanly minutes later; deleting it on the first 23xxx
/// destroys real training data over a race, not a bad payload. (Mirrors the
/// watch-side precedent too: #475 F12 demanded exactly this — retain and
/// re-attempt — after F11 forced the same "don't punish transient failures"
/// correction this file already applies to auth/network above.)
///
/// So: a constraint rejection keeps the entry in `remaining` (auto-retried
/// next drain, same as any other queued entry) UNLESS it has already been
/// rejected once before under a DIFFERENT app build (`nextRejection`'s
/// `stuck` latch) — that survives a full deploy cycle without being fixed,
/// which is the signal this repo actually has for "probably not a schema
/// race". Only then does it move to `stuck`: retained on device, excluded
/// from automatic attempts, visible to the user as its own state (never
/// silent — see `pendingRecordingsBreakdown`), and recoverable only via
/// `retryStuckRecordings`.
///
/// A constraint rejection does NOT set the "stop the pass" `blocked` flag —
/// unlike a transient failure, it says nothing about any OTHER entry's
/// payload, so draining continues past it (the issue's headline defect: one
/// bad entry must not block the healthy ones behind it). A 23505
/// (unique-constraint) failure is treated as SUCCESS — an earlier attempt
/// (this one's own client-generated id) already landed and this is a
/// redundant retry. Entries queued under a DIFFERENT user id, and entries
/// already `stuck`, are never attempted (or dropped) by this pass.
export async function drainQueue(
  queue: PendingRecording[],
  userId: string,
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
  now: () => string = () => new Date().toISOString(),
  appVersion: () => string = currentAppVersion,
): Promise<DrainResult> {
  const succeeded: PendingRecording[] = [];
  const remaining: PendingRecording[] = [];
  const stuck: PendingRecording[] = [];
  let blocked = false;
  for (const item of queue) {
    if (item.userId !== null && item.userId !== userId) {
      remaining.push(item);
      continue;
    }
    if (item.rejection?.stuck) {
      // Confirmed stuck by an earlier pass — never auto-retried.
      stuck.push(item);
      continue;
    }
    if (blocked) {
      remaining.push(item);
      continue;
    }
    try {
      // #487 (F2): stamp the capture time before the (possibly much later)
      // insert — `item.queuedAt` was set when this entry was first queued,
      // right after the live insert attempt failed, i.e. at the moment it
      // was actually recorded, not whenever this drain happens to run.
      // `item.input.recordedAt` wins if already set (e.g. a retried queue
      // entry that already carries one) so a drain never overwrites an
      // earlier, more precise stamp with a later `queuedAt`.
      await insert({ ...item.input, recordedAt: item.input.recordedAt ?? item.queuedAt });
      succeeded.push(item);
    } catch (e) {
      if (isDuplicateKeyError(e)) {
        succeeded.push(item);
        continue;
      }
      if (isConstraintFailure(e)) {
        const rejection = nextRejection(item.rejection, e, appVersion(), now());
        const updated: PendingRecording = { ...item, rejection };
        (rejection.stuck ? stuck : remaining).push(updated);
        continue; // per-payload, not systemic — keep draining past it
      }
      remaining.push(item);
      blocked = true;
    }
  }
  return { succeeded, remaining, stuck };
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
  now: () => string = () => new Date().toISOString(),
  appVersion: () => string = currentAppVersion,
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
    const laneOnly = lane.filter((p) => !mainIds.has(p.id));
    const queue = [...main, ...laneOnly].sort(byQueuedAt);
    if (queue.length === 0) return 0;

    const { succeeded, remaining, stuck } = await drainQueue(
      queue,
      userId,
      insert,
      now,
      appVersion,
    );
    // #484: `remaining`/`stuck` entries whose object reference differs from
    // what went IN carry an updated `rejection` stamp this pass produced —
    // by identity, since `drainQueue` only allocates a new object when it has
    // something new to say. Everything else (a different-user skip, an
    // already-stuck passthrough) comes back unchanged and needs no rewrite.
    const originalById = new Map(queue.map((p) => [p.id, p]));
    const changed = [...remaining, ...stuck].filter((p) => p !== originalById.get(p.id));

    if (succeeded.length === 0 && changed.length === 0) return 0;

    const removedIds = new Set(succeeded.map((p) => p.id));
    // Deleting by id is inherently race-safe on the main store — unlike the
    // lane's read-modify-write below, it can't clobber an entry that arrived
    // mid-drain (the drain awaits one insert at a time, so a salvage really can
    // land in between).
    if (db && removedIds.size > 0) await db.delete([...removedIds]).catch(() => {});
    // A changed entry (a fresh/updated rejection stamp this pass produced) is
    // RETAINED, never removed — persisted back into IndexedDB when it's there
    // (this also finishes migrating a lane-only entry that just picked up its
    // first stamp), else rewritten in place below, since the lane is the only
    // store when there's no IndexedDB at all.
    //
    // R2-F1: `stored` is CONFIRMED, not assumed — a lane-only entry is there
    // precisely BECAUSE `absorbSyncLane`'s own `db.put` already failed once,
    // so this retry's failure is correlated, not independent. Removing it
    // from the lane on the mere attempt (the pre-fix `.catch(() => {})`
    // shape) would erase the only copy that exists the moment the SAME
    // refusal recurs — this file's own `retryStuckRecordings` already gets
    // this right (`db.put(...).then(() => true, () => false)`); this is that
    // exact pattern.
    const stored =
      db && changed.length > 0
        ? await db.put(changed).then(
            () => true,
            () => false,
          )
        : false;

    const currentLane = loadQueue(storage);
    const changedById = new Map(changed.map((p) => [p.id, p]));
    // A changed entry leaves the lane only once IndexedDB is CONFIRMED to
    // hold it (`stored`). Whenever it is NOT confirmed — no IndexedDB at all,
    // OR IndexedDB refused this particular put (the lane-only, correlated-
    // failure case R2-F1 is about) — the freshest copy is instead rewritten
    // IN PLACE in the lane, so the rejection stamp a lane-only entry just
    // picked up isn't silently dropped on the floor while it waits for
    // IndexedDB to recover. A single `saveQueue` write is all-or-nothing, so
    // there's nothing further to confirm on that side.
    const goneFromLane = new Set(removedIds);
    if (stored) for (const id of changedById.keys()) goneFromLane.add(id);
    const nextLane = currentLane
      .filter((p) => !goneFromLane.has(p.id))
      .map((p) => (stored ? p : (changedById.get(p.id) ?? p)));
    if (
      nextLane.length !== currentLane.length ||
      nextLane.some((p, i) => p !== currentLane[i])
    ) {
      saveQueue(nextLane, storage);
    }

    notifyPendingUploadsChanged();
    return succeeded.length;
  } finally {
    draining = false;
  }
}

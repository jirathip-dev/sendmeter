import {
  byQueuedAt,
  isPendingRecording,
  type PendingRecording,
} from "./pendingRecording";

// #269: the MAIN offline recording queue. `recordingQueue.ts` used to keep the
// whole queue in localStorage, whose WKWebView per-origin budget (~5 MB, shared
// with every other `sendmeter:` key) is small enough that an ordinary long
// offline session could evict reps it had already queued — the exact scenario
// the queue exists to survive. IndexedDB's per-origin headroom is orders of
// magnitude larger, so the queue lives here now and localStorage keeps only the
// synchronous emergency lane (see the policy block in `recordingQueue.ts`).
//
// Everything here degrades to `null` rather than throwing. IndexedDB can be
// absent (a non-browser test runner), refused (private mode, storage disabled
// by policy) or simply never answer (a version-change block, or a WebKit
// private-mode open that hangs) — and the caller's answer to all three is the
// same: fall back to the localStorage lane. A queue that throws on open would
// turn "no IndexedDB" into "no queue at all", which is strictly worse than what
// we had before.

const DB_NAME = "sendmeter";
const DB_VERSION = 2;
const STORE = "pending-recordings";
/// #484 F5: lets `getAllForUser` fetch one account's own entries without
/// deserializing every OTHER account's stranded queue. Added in the v1→v2
/// upgrade below, on the EXISTING store — `onupgradeneeded` never re-creates
/// it, so this never touches stored data.
const USER_ID_INDEX = "userId";

/// An `open` that neither succeeds nor errors is a real failure mode (a
/// blocked version change; historically, private-mode WebKit). Without a
/// deadline the caller would await forever on a path whose whole job is to
/// not lose a recording, so a slow open is treated as an absent one.
const OPEN_TIMEOUT_MS = 3000;

/// The narrow surface `recordingQueue` needs. Deliberately not an IDBDatabase:
/// every method is total (no throwing accessors), ids are the only handles, and
/// it can be stubbed in a test without standing up a fake IndexedDB.
export interface RecordingDb {
  /// Every queued entry, OLDEST FIRST. Records that don't parse as a
  /// PendingRecording are dropped from the result rather than returned.
  getAll(): Promise<PendingRecording[]>;
  /// Just the ids — a `getAllKeys`, so counting the backlog for the UI doesn't
  /// deserialize megabytes of samples.
  keys(): Promise<string[]>;
  /// Write every entry in ONE transaction: it either all lands or none of it
  /// does. The migration depends on that — a half-copied queue that then gets
  /// cleared from localStorage would lose the uncopied half. Rejects with the
  /// underlying DOMException (`QuotaExceededError` among them).
  put(entries: PendingRecording[]): Promise<void>;
  /// Delete by id. Missing ids are not an error.
  delete(ids: string[]): Promise<void>;
  /// Empty the store in ONE transaction. Separate from `delete(await keys())`
  /// on purpose: the sign-out discard (#273) is the user asking for their
  /// recordings to be off this device, and a read-then-delete would leave
  /// behind anything written between the two. Rejects if the transaction
  /// aborts, so a caller can tell "removed" from "asked to remove".
  clear(): Promise<void>;
  /// #484 F5: every entry attributed to `userId`, PLUS unattributed legacy
  /// entries (`userId === null` — #189: still counted, matching `drainQueue`'s
  /// attempt rule). Uses the `userId` index for the attributed subset, so the
  /// common single-account case never deserializes another account's
  /// stranded queue; only falls through to a full `getAll()` when the store
  /// holds more keys than the index matched (i.e. there IS an unattributed or
  /// other-account residue to go looking for).
  getAllForUser(userId: string): Promise<PendingRecording[]>;
}

export type RecordingDbLoader = () => Promise<RecordingDb | null>;

function defaultFactory(): IDBFactory | null {
  try {
    // Not just a typeof check: reading `indexedDB` itself throws in some
    // storage-disabled configurations.
    return typeof indexedDB === "undefined" ? null : indexedDB;
  } catch {
    return null;
  }
}

function requestValue<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("IndexedDB request failed"));
  });
}

/// Run `issue` inside one readwrite transaction and resolve when the whole
/// transaction COMMITS — `oncomplete`, never a request's `onsuccess`. The
/// distinction is load-bearing rather than pedantic: a request can succeed
/// inside a transaction that later aborts, and `absorbSyncLane` clears the
/// localStorage lane on this promise resolving, so resolving on request success
/// would delete the lane's only copy of a write that never landed.
///
/// A failing request aborts the transaction — deliberately not suppressed with
/// preventDefault, since partial writes are what the atomicity guarantee above
/// exists to rule out. Three routes reach the rejection and all three are
/// covered: a synchronous throw from `issue` (a structured-clone failure), an
/// asynchronous request `onerror` (quota, caught by `firstError`), and an abort
/// raised at commit time with no request error at all (`tx.error`). The last
/// two are how Blink actually delivers `QuotaExceededError` — verified in
/// Chrome against a CDP-constrained origin quota, not assumed.
function writeTx(
  db: IDBDatabase,
  issue: (store: IDBObjectStore) => IDBRequest[],
): Promise<void> {
  return new Promise((resolve, reject) => {
    let firstError: unknown = null;
    let tx: IDBTransaction;
    try {
      tx = db.transaction(STORE, "readwrite");
    } catch (e) {
      reject(e);
      return;
    }
    tx.oncomplete = () => resolve();
    tx.onabort = () =>
      reject(firstError ?? tx.error ?? new Error("IndexedDB transaction aborted"));
    try {
      for (const req of issue(tx.objectStore(STORE))) {
        req.onerror = () => {
          if (firstError === null) firstError = req.error;
        };
      }
    } catch (e) {
      firstError = e;
      try {
        tx.abort();
      } catch {
        // already aborting — onabort still rejects with `firstError`
      }
    }
  });
}

function wrap(db: IDBDatabase): RecordingDb {
  return {
    async getAll() {
      const rows: unknown[] = await requestValue(
        db.transaction(STORE, "readonly").objectStore(STORE).getAll(),
      );
      return rows.filter(isPendingRecording).sort(byQueuedAt);
    },
    async keys() {
      const ids: IDBValidKey[] = await requestValue(
        db.transaction(STORE, "readonly").objectStore(STORE).getAllKeys(),
      );
      return ids.filter((k): k is string => typeof k === "string");
    },
    put(entries) {
      if (entries.length === 0) return Promise.resolve();
      return writeTx(db, (store) => entries.map((e) => store.put(e)));
    },
    delete(ids) {
      if (ids.length === 0) return Promise.resolve();
      return writeTx(db, (store) => ids.map((id) => store.delete(id)));
    },
    clear() {
      return writeTx(db, (store) => [store.clear()]);
    },
    async getAllForUser(userId) {
      // `getAll` accepts a plain key directly (shorthand for a range
      // matching only that key) — deliberately not `IDBKeyRange.only(...)`,
      // which is a separate global this module would otherwise depend on
      // (present in every real browser, but not in Node/vitest without an
      // explicit polyfill import).
      const indexed: unknown[] = await requestValue(
        db.transaction(STORE, "readonly").objectStore(STORE).index(USER_ID_INDEX).getAll(userId),
      );
      const attributed = indexed.filter(isPendingRecording);
      // Cheap (getAllKeys, no deserialize) existence check: if the store
      // holds no more keys than the index just matched, there is nothing
      // unattributed or belonging to another account to go find.
      const totalKeys: IDBValidKey[] = await requestValue(
        db.transaction(STORE, "readonly").objectStore(STORE).getAllKeys(),
      );
      if (totalKeys.length <= attributed.length) {
        return attributed.sort(byQueuedAt);
      }
      // A `userId: null` field is not a valid IndexedDB key, so the index
      // silently omits those records — this full scan is the only way to
      // find them, and it only runs when the cheap check above says there's
      // something beyond this user's own attributed rows.
      const allRows: unknown[] = await requestValue(
        db.transaction(STORE, "readonly").objectStore(STORE).getAll(),
      );
      const seen = new Set(attributed.map((p) => p.id));
      const legacy = allRows
        .filter(isPendingRecording)
        .filter((p) => p.userId === null && !seen.has(p.id));
      return [...attributed, ...legacy].sort(byQueuedAt);
    },
  };
}

let cached: Promise<RecordingDb | null> | null = null;

function openOnce(factory: IDBFactory | null): Promise<RecordingDb | null> {
  if (!factory) return Promise.resolve(null);
  return new Promise<IDBDatabase | null>((resolve) => {
    let settled = false;
    const settle = (v: IDBDatabase | null) => {
      if (settled) {
        // A success that arrives after the deadline: nobody is going to use
        // this handle, so don't leave a connection open holding a version lock.
        v?.close();
        return;
      }
      settled = true;
      resolve(v);
    };
    let req: IDBOpenDBRequest;
    try {
      req = factory.open(DB_NAME, DB_VERSION);
    } catch {
      resolve(null);
      return;
    }
    const timer = setTimeout(() => settle(null), OPEN_TIMEOUT_MS);
    req.onupgradeneeded = () => {
      const d = req.result;
      let store: IDBObjectStore;
      if (!d.objectStoreNames.contains(STORE)) {
        // keyPath `id`, no autoIncrement: re-putting an entry the migration
        // already copied overwrites it instead of adding a second copy.
        store = d.createObjectStore(STORE, { keyPath: "id" });
      } else {
        // v1 → v2 (#484 F5): the store already exists — grab it off the
        // versionchange transaction rather than re-creating it, which would
        // wipe every queued recording.
        store = req.transaction!.objectStore(STORE);
      }
      if (!store.indexNames.contains(USER_ID_INDEX)) {
        store.createIndex(USER_ID_INDEX, "userId");
      }
    };
    req.onsuccess = () => {
      clearTimeout(timer);
      settle(req.result);
    };
    req.onerror = () => {
      clearTimeout(timer);
      settle(null);
    };
    req.onblocked = () => {
      clearTimeout(timer);
      settle(null);
    };
  }).then((db) => {
    if (!db) return null;
    // Another tab upgrading, or the browser evicting the origin's storage,
    // leaves a handle that rejects everything. Drop the memo so the next call
    // re-opens rather than failing forever.
    db.onversionchange = () => {
      db.close();
      cached = null;
    };
    db.onclose = () => {
      cached = null;
    };
    return wrap(db);
  });
}

/// Open (once per session) the recording queue database. Resolves `null` — it
/// never rejects — when IndexedDB is unavailable, refused or blocked; the
/// caller's job is then to use the localStorage lane instead.
///
/// Pass an explicit `factory` to bypass the module-level memo (tests).
export function openRecordingDb(
  factory?: IDBFactory | null,
): Promise<RecordingDb | null> {
  if (factory !== undefined) return openOnce(factory);
  cached ??= openOnce(defaultFactory());
  return cached;
}

/// Forget the memoized connection. Only for tests — the app opens once.
export function resetRecordingDbCache(): void {
  cached = null;
}

/// Whether a rejected write was the store refusing for want of room, as
/// opposed to a structurally broken write. Only the quota case is what the
/// eviction backstop is FOR — a `DataCloneError` would never fit no matter how
/// much we drop, so evicting queued reps to discover that would be pure loss.
///
/// Keys on `name` because that is what the real object carries: a genuine
/// refusal from Blink arrives as a `DOMException` with
/// `name === "QuotaExceededError"` and an EMPTY message, delivered
/// asynchronously — observed directly in Chrome against an origin quota capped
/// via CDP, which is also where the whole reject-on-abort path was exercised.
/// Don't match on the message; there isn't one.
export function isQuotaError(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const name = (e as { name?: unknown }).name;
  return name === "QuotaExceededError" || name === "NS_ERROR_DOM_QUOTA_REACHED";
}

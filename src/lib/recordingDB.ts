import type { PendingRecording } from "./recordingQueue";

// #269: IndexedDB adapter for the tindeq recording MAIN queue. This is the
// only module that touches the real `indexedDB` global — everything else
// (recordingQueue.ts's policy logic, the pending-depth readout) talks to the
// `MainQueueStore` interface below, injected, so it stays unit-testable in
// node (this project's vitest runs in node — which has no `indexedDB`,
// conveniently exercising the "unavailable" fallback path for free without a
// `fake-indexeddb` dependency).

const DB_NAME = "sendmeter";
const DB_VERSION = 1;
const STORE_NAME = "pending-recordings";
const QUEUED_AT_INDEX = "queuedAt";

// How long to wait for indexedDB.open() before giving up and treating it as
// unavailable — private-mode Safari and some locked-down WebViews can leave
// the request neither resolving nor rejecting (storage disabled outright)
// rather than erroring cleanly, so a plain `await` here could hang forever.
const OPEN_TIMEOUT_MS = 2000;

export interface MainQueueStore {
  /// Every entry, oldest first (by `queuedAt`) — the order the salvage-lane
  /// drain writes them in and the order a queue drain attempts them in.
  getAll(): Promise<PendingRecording[]>;
  /// `keyPath: "id"` makes this idempotent — writing the same id twice
  /// overwrites in place rather than duplicating, which is what makes
  /// `drainSalvageLane` safe to resume after an interruption. Stored as a
  /// structured-clone object, no JSON (de)serialization.
  put(entry: PendingRecording): Promise<void>;
  /// Remove entries by id. Missing ids are silently ignored (IndexedDB's own
  /// `delete` semantics).
  delete(ids: string[]): Promise<void>;
  count(): Promise<number>;
  /// Drop the single oldest entry (by `queuedAt`). Returns whether anything
  /// was actually there to drop — the eviction backstop's stopping condition
  /// in `persistRecordingToMainQueue`.
  deleteOldest(): Promise<boolean>;
}

function promisifyRequest<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function promisifyTransaction(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error ?? new Error("transaction aborted"));
  });
}

class IndexedDBMainQueueStore implements MainQueueStore {
  constructor(private db: IDBDatabase) {}

  private objectStore(mode: IDBTransactionMode): IDBObjectStore {
    return this.db.transaction(STORE_NAME, mode).objectStore(STORE_NAME);
  }

  async getAll(): Promise<PendingRecording[]> {
    const index = this.objectStore("readonly").index(QUEUED_AT_INDEX);
    return promisifyRequest(index.getAll() as IDBRequest<PendingRecording[]>);
  }

  async put(entry: PendingRecording): Promise<void> {
    const tx = this.db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).put(entry);
    await promisifyTransaction(tx);
  }

  async delete(ids: string[]): Promise<void> {
    if (ids.length === 0) return;
    const tx = this.db.transaction(STORE_NAME, "readwrite");
    const store = tx.objectStore(STORE_NAME);
    for (const id of ids) store.delete(id);
    await promisifyTransaction(tx);
  }

  async count(): Promise<number> {
    return promisifyRequest(this.objectStore("readonly").count());
  }

  async deleteOldest(): Promise<boolean> {
    const tx = this.db.transaction(STORE_NAME, "readwrite");
    const index = tx.objectStore(STORE_NAME).index(QUEUED_AT_INDEX);
    const cursor = await promisifyRequest(index.openCursor());
    if (!cursor) {
      await promisifyTransaction(tx); // no-op transaction, but finish cleanly
      return false;
    }
    cursor.delete();
    await promisifyTransaction(tx);
    return true;
  }
}

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        const store = db.createObjectStore(STORE_NAME, { keyPath: "id" });
        store.createIndex(QUEUED_AT_INDEX, QUEUED_AT_INDEX);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("indexedDB open blocked"));
  });
}

/// Open the real IndexedDB-backed store, guarded so this NEVER throws:
/// `indexedDB` undefined (node/tests/a browser that removes it entirely), an
/// open that errors, or one that just never settles (some private-mode /
/// locked-down WebViews) all resolve to `null` instead. That gives every
/// caller exactly one fallback branch to handle: "no main queue available,
/// use the sync salvage lane."
async function openMainQueueStore(): Promise<MainQueueStore | null> {
  if (typeof indexedDB === "undefined") return null;
  try {
    const db = await Promise.race([
      openDatabase(),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("indexedDB open timed out")), OPEN_TIMEOUT_MS),
      ),
    ]);
    return new IndexedDBMainQueueStore(db);
  } catch {
    return null;
  }
}

// Memoized: opening a fresh connection on every call would be wasteful, and
// on some WebKit builds concurrent opens of the same DB are themselves a
// source of flakiness. Created lazily on first use and reused for the rest of
// the session — a store that resolves null once (unavailable) stays null
// rather than re-probing on every call.
let cached: Promise<MainQueueStore | null> | null = null;

/// The store production call sites default to when they aren't handed one
/// explicitly. Tests always inject a fake `MainQueueStore` (or `null`)
/// instead of calling this, so this function is never exercised there — node
/// has no `indexedDB`, and this project deliberately doesn't add
/// `fake-indexeddb` as a dependency to fake one.
export function defaultMainQueueStore(): Promise<MainQueueStore | null> {
  if (!cached) cached = openMainQueueStore();
  return cached;
}

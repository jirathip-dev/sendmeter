import { describe, it, expect, vi } from "vitest";
import {
  MAX_QUEUE_BYTES,
  absorbSyncLane,
  clearRecordingQueue,
  drainPendingRecordingsQueue,
  drainQueue,
  enqueueRecording,
  loadQueue,
  pendingRecordingsCount,
  persistRecording,
  persistRecordingDurable,
  saveQueue,
  type PendingRecording,
} from "./recordingQueue";
import { IDBFactory } from "fake-indexeddb";
import { byQueuedAt } from "./pendingRecording";
import { openRecordingDb } from "./recordingDb";
import type { RecordingDb, RecordingDbLoader } from "./recordingDb";
import type { NewTindeqRecording } from "../types";

function rec(id: string, tag = "FDP", samples = 2): NewTindeqRecording & { id: string } {
  return {
    id,
    durationMs: 7000,
    peakKg: 32.1,
    avgKg: 28.4,
    note: "",
    tag,
    side: "left",
    groupId: "group-1",
    protocolRunId: null,
    setNo: null,
    zone: null,
    samples: Array.from({ length: samples }, (_, i) => ({ t: i * 500, kg: 10 + i })),
  };
}

/// A samples array big enough to make byte-budget eviction observable
/// without a real Bluetooth-scale recording — ~4000 samples serializes to
/// roughly 80 KB, so 30 of these comfortably clears MAX_QUEUE_BYTES.
function bigRec(id: string): NewTindeqRecording & { id: string } {
  return rec(id, "FDP", 4000);
}

/// In-memory stand-in for localStorage — keeps these tests jsdom-free
/// (this project's vitest config runs in node), matching the "pure logic
/// only" convention for web tests.
function fakeStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
  };
}

/// Storage whose setItem always throws (quota exceeded / disabled).
function throwingStorage() {
  return {
    getItem: () => null,
    setItem: () => {
      throw new Error("QuotaExceededError");
    },
  };
}

/// Let pending microtasks (and any queued macrotask) run. The queue paths are
/// several awaits deep now — a test that interleaves with one has to actually
/// let it reach the await it wants to interleave at.
function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

/// A promise plus its resolver, created up front so a test can release it
/// whether or not the code under test has reached the await yet.
function deferred() {
  let resolve: () => void = () => {};
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve: () => resolve() };
}

/// #269: IndexedDB absent — private mode, storage disabled by policy, or a
/// blocked open. `openRecordingDb` resolves null for all three, so this loader
/// IS the private-mode case as the app sees it.
const noDb: RecordingDbLoader = () => Promise.resolve(null);

/// The real refusal object, not an approximation of one: a DOMException named
/// QuotaExceededError with an empty message is exactly what Blink was observed
/// to reject with under a capped origin quota. fake-indexeddb has no quota to
/// exceed, so the only way to exercise the eviction backstop from vitest is to
/// make the store say no — with the same shape a device would.
function quotaError(): DOMException {
  return new DOMException("", "QuotaExceededError");
}

/// In-memory RecordingDb. `failPut` is consulted on every put (1-based attempt
/// count) and its return value, if any, is thrown instead of writing.
function fakeDb(
  seed: PendingRecording[] = [],
  failPut?: (attempt: number) => unknown,
) {
  const map = new Map(seed.map((e) => [e.id, e] as const));
  let attempts = 0;
  const db: RecordingDb = {
    getAll: () => Promise.resolve([...map.values()].sort(byQueuedAt)),
    keys: () => Promise.resolve([...map.keys()]),
    put: (entries) => {
      attempts += 1;
      const err = failPut?.(attempts);
      if (err) return Promise.reject(err);
      for (const e of entries) map.set(e.id, e);
      return Promise.resolve();
    },
    delete: (ids) => {
      for (const id of ids) map.delete(id);
      return Promise.resolve();
    },
    clear: () => {
      map.clear();
      return Promise.resolve();
    },
  };
  return { db, map, loader: (): Promise<RecordingDb | null> => Promise.resolve(db) };
}

describe("enqueueRecording", () => {
  it("appends with the input's client-generated id + a timestamp", () => {
    const queue = enqueueRecording([], rec("id-1"), "user-1", () => "2026-07-23T00:00:00.000Z");
    expect(queue).toEqual<PendingRecording[]>([
      {
        id: "id-1",
        queuedAt: "2026-07-23T00:00:00.000Z",
        userId: "user-1",
        input: rec("id-1"),
      },
    ]);
  });

  it("does not mutate the input array", () => {
    const original: PendingRecording[] = [];
    enqueueRecording(original, rec("id-1"), "user-1");
    expect(original).toEqual([]);
  });

  it("evicts the OLDEST entries first once over the byte budget", () => {
    let queue: PendingRecording[] = [];
    for (let i = 0; i < 30; i++) {
      queue = enqueueRecording(queue, bigRec(`id-${i}`), "user-1");
    }
    const serialized = JSON.stringify(queue).length;
    expect(serialized).toBeLessThanOrEqual(MAX_QUEUE_BYTES);
    // Oldest entries evicted, newest survive in order.
    expect(queue.at(-1)!.id).toBe("id-29");
    expect(queue.some((p) => p.id === "id-0")).toBe(false);
  });

  it("never drops the just-added entry even if it alone is over budget", () => {
    // A single huge entry (bigger than the whole budget) must still come
    // back — there's nothing safer to do than keep it and let saveQueue's
    // return value report whether it actually fit in real storage.
    const huge = rec("huge", "FDP", 200_000); // way over MAX_QUEUE_BYTES alone
    const queue = enqueueRecording([{ id: "old", queuedAt: "t", userId: "user-1", input: rec("old") }], huge, "user-1");
    expect(queue.map((p) => p.id)).toEqual(["huge"]);
  });
});

describe("loadQueue / saveQueue", () => {
  it("round-trips through storage and reports success", () => {
    const storage = fakeStorage();
    const queue = enqueueRecording([], rec("id-1"), "user-1");
    expect(saveQueue(queue, storage)).toBe(true);
    expect(loadQueue(storage)).toEqual(queue);
  });

  it("reports false when the write doesn't land", () => {
    const queue = enqueueRecording([], rec("id-1"), "user-1");
    expect(saveQueue(queue, throwingStorage())).toBe(false);
  });

  it("treats missing storage as an empty queue", () => {
    expect(loadQueue(fakeStorage())).toEqual([]);
  });

  it("tolerates corrupt JSON without throwing", () => {
    const storage = fakeStorage();
    storage.setItem("sendmeter:pending-recordings", "{not json");
    expect(loadQueue(storage)).toEqual([]);
  });

  it("drops entries that don't match the PendingRecording shape", () => {
    const storage = fakeStorage();
    storage.setItem(
      "sendmeter:pending-recordings",
      JSON.stringify([{ id: "ok" }, "garbage", null]),
    );
    expect(loadQueue(storage)).toEqual([]);
  });

  it("treats a null storage handle as a no-op (private mode etc.)", () => {
    expect(saveQueue([], null)).toBe(false);
    expect(loadQueue(null)).toEqual([]);
  });
});

/// A store pre-seeded with `queue`, whose setItem refuses its first `refusals`
/// calls and then behaves — the shape of a quota-exhausted origin that has
/// room again once the value being written has shed its oldest entries.
function seededStorage(queue: PendingRecording[], refusals = 0) {
  const map = new Map<string, string>();
  map.set("sendmeter:pending-recordings", JSON.stringify(queue));
  let refused = 0;
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => {
      if (refused < refusals) {
        refused += 1;
        throw new Error("QuotaExceededError");
      }
      map.set(k, v);
    },
  };
}

/// Build a queue of the given recordings, oldest first.
function queueOf(...ids: string[]): PendingRecording[] {
  return ids.reduce<PendingRecording[]>(
    (q, id) => enqueueRecording(q, rec(id), "user-1", () => "2026-07-01T00:00:00.000Z"),
    [],
  );
}

describe("persistRecording (#264 — the saveQueue-returned-false branch)", () => {
  it("reports persisted with nothing evicted on the happy path", () => {
    const storage = fakeStorage();
    const result = persistRecording(rec("id-1"), "user-1", storage);
    expect(result).toEqual({ persisted: true, evicted: 0 });
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["id-1"]);
  });

  it("drops the OLDEST queued entries and retries until the write lands", () => {
    // Refuses twice: the write only fits once the two oldest are gone.
    const storage = seededStorage(queueOf("old-1", "old-2", "old-3"), 2);
    const result = persistRecording(rec("new-1"), "user-1", storage);
    expect(result).toEqual({ persisted: true, evicted: 2 });
    // The new rep survived; the two oldest were the price.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["old-3", "new-1"]);
  });

  it("reports the loss rather than pretending, when even the lone entry won't write", () => {
    const result = persistRecording(rec("id-1"), "user-1", throwingStorage());
    expect(result.persisted).toBe(false);
    // Nothing was in the queue to evict — the new rep alone was refused.
    expect(result.evicted).toBe(0);
  });

  it("counts every entry it dropped on the way down before giving up", () => {
    // Refuses forever — both older entries are sacrificed and it STILL fails.
    const storage = seededStorage(queueOf("old-1", "old-2"), Infinity);
    expect(persistRecording(rec("new-1"), "user-1", storage)).toEqual({
      persisted: false,
      evicted: 2,
    });
  });

  it("reports a null storage handle (disabled storage) as not persisted", () => {
    expect(persistRecording(rec("id-1"), "user-1", null)).toEqual({
      persisted: false,
      evicted: 0,
    });
  });

  it("also counts what the byte budget evicted before the store was asked", () => {
    const storage = fakeStorage();
    // 30 × ~80 KB clears MAX_QUEUE_BYTES, so adding one more must evict.
    let queue: PendingRecording[] = [];
    for (let i = 0; i < 30; i++) {
      queue = enqueueRecording(queue, bigRec(`big-${i}`), "user-1");
    }
    saveQueue(queue, storage);
    const before = loadQueue(storage).length;
    const result = persistRecording(bigRec("big-new"), "user-1", storage);
    expect(result.persisted).toBe(true);
    expect(result.evicted).toBeGreaterThan(0);
    expect(loadQueue(storage).length).toBe(before + 1 - result.evicted);
  });
});

describe("drainQueue", () => {
  it("inserts every entry for the matching user and reports them succeeded", async () => {
    const queue = [
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t", userId: "user-1", input: rec("b") },
    ];
    const insert = vi.fn().mockResolvedValue({});
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.succeeded.map((p) => p.id)).toEqual(["a", "b"]);
    expect(result.remaining).toEqual([]);
    expect(insert).toHaveBeenCalledTimes(2);
  });

  it("stops attempting further entries after the first hard failure, in order", async () => {
    const queue = [
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t", userId: "user-1", input: rec("b") },
      { id: "c", queuedAt: "t", userId: "user-1", input: rec("c") },
    ];
    const insert = vi
      .fn()
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error("still unauthenticated"));
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.succeeded.map((p) => p.id)).toEqual(["a"]);
    // b failed, c was never attempted — both come back queued, in order.
    expect(result.remaining.map((p) => p.id)).toEqual(["b", "c"]);
    expect(insert).toHaveBeenCalledTimes(2);
  });

  // #484 F3 — PROVED. Before this fix, `drainQueue` had no `quarantined`
  // bucket at all and ANY non-duplicate failure (including this one) set the
  // single `broken` flag that parks every later entry — "b" and "c" would
  // both come back in `remaining`, `insert` would be called exactly twice,
  // and the healthy "c" would never even be attempted. A permanently-rejected
  // "a" (a real database CHECK-constraint violation — this exact payload will
  // NEVER succeed) must not have that power.
  it("quarantines a permanently-rejected entry and keeps draining the healthy ones behind it (#484 F3)", async () => {
    const queue = [
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t", userId: "user-1", input: rec("b") },
      { id: "c", queuedAt: "t", userId: "user-1", input: rec("c") },
    ];
    const insert = vi
      .fn()
      .mockRejectedValueOnce({
        code: "23514",
        message: 'new row for relation "tindeq_recordings" violates check constraint "tindeq_recordings_duration_check"',
      })
      .mockResolvedValueOnce({})
      .mockResolvedValueOnce({});
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.quarantined.map((p) => p.id)).toEqual(["a"]);
    expect(result.succeeded.map((p) => p.id)).toEqual(["b", "c"]);
    expect(result.remaining).toEqual([]);
    expect(insert).toHaveBeenCalledTimes(3);
  });

  // #484 F3 / #475 F11 — the cautionary case named in the issue: a transient
  // failure (offline, 5xx, a stale/expired auth token) must default to
  // RETRY, never quarantine, however many entries follow it.
  it.each([
    ["auth (PGRST301 — JWT expired)", { code: "PGRST301", message: "JWT expired" }],
    ["network (fetch failure, no code at all)", new TypeError("Failed to fetch")],
    ["an unrecognized 5xx with no matching code", { status: 503, message: "Service Unavailable" }],
  ])("does NOT quarantine a transient failure: %s", async (_label, error) => {
    const queue = [
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t", userId: "user-1", input: rec("b") },
    ];
    const insert = vi.fn().mockRejectedValueOnce(error);
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.quarantined).toEqual([]);
    // Still the pre-existing "stop the pass" behavior for a transient
    // failure — both come back queued for the next drain.
    expect(result.remaining.map((p) => p.id)).toEqual(["a", "b"]);
    expect(insert).toHaveBeenCalledTimes(1);
  });

  it("treats a 23505 (duplicate key) failure as success and keeps draining", async () => {
    const queue = [
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t", userId: "user-1", input: rec("b") },
    ];
    const insert = vi
      .fn()
      .mockRejectedValueOnce({ code: "23505", message: "duplicate key value violates…" })
      .mockResolvedValueOnce({});
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.succeeded.map((p) => p.id)).toEqual(["a", "b"]);
    expect(result.remaining).toEqual([]);
    expect(insert).toHaveBeenCalledTimes(2);
  });

  it("also recognizes a duplicate-key error by message when code is absent", async () => {
    const queue = [{ id: "a", queuedAt: "t", userId: "user-1", input: rec("a") }];
    const insert = vi
      .fn()
      .mockRejectedValueOnce(new Error("duplicate key value violates unique constraint"));
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.succeeded.map((p) => p.id)).toEqual(["a"]);
  });

  it("never attempts (or drops) entries queued under a different user", async () => {
    const queue = [
      { id: "mine", queuedAt: "t", userId: "user-1", input: rec("mine") },
      { id: "theirs", queuedAt: "t", userId: "user-2", input: rec("theirs") },
    ];
    const insert = vi.fn().mockResolvedValue({});
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.succeeded.map((p) => p.id)).toEqual(["mine"]);
    expect(result.remaining.map((p) => p.id)).toEqual(["theirs"]);
    expect(insert).toHaveBeenCalledTimes(1);
  });

  it("leaves an unknown-user (null) entry attemptable by anyone", async () => {
    const queue = [{ id: "legacy", queuedAt: "t", userId: null, input: rec("legacy") }];
    const insert = vi.fn().mockResolvedValue({});
    const result = await drainQueue(queue, "user-1", insert);
    expect(result.succeeded.map((p) => p.id)).toEqual(["legacy"]);
  });
});

/// The DEGRADED arrangement (#269): no IndexedDB at all, so the localStorage
/// lane is the whole queue. Every assertion here is about the fallback the app
/// lands in under private mode / disabled storage.
describe("drainPendingRecordingsQueue without IndexedDB", () => {
  it("persists only what's left after a partial drain", async () => {
    const storage = fakeStorage();
    let queue = enqueueRecording([], rec("a"), "user-1");
    queue = enqueueRecording(queue, rec("b"), "user-1");
    saveQueue(queue, storage);

    const insert = vi
      .fn()
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error("network"));
    const recovered = await drainPendingRecordingsQueue("user-1", insert, noDb, storage);

    expect(recovered).toBe(1);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["b"]);
  });

  it("is a no-op with an empty queue", async () => {
    const storage = fakeStorage();
    const insert = vi.fn();
    expect(await drainPendingRecordingsQueue("user-1", insert, noDb, storage)).toBe(0);
    expect(insert).not.toHaveBeenCalled();
  });

  it("merges a concurrent enqueue instead of clobbering it on write-back", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("a"), "user-1"), storage);

    const gate = deferred();
    const insert = vi.fn(() => gate.promise);

    const drain = drainPendingRecordingsQueue("user-1", insert, noDb, storage);
    await tick(); // let the drain reach the in-flight insert
    // A NEW failure gets queued (synchronously) while "a"'s insert is still
    // in flight — simulates useTindeq's salvage cleanup racing the drain.
    saveQueue(enqueueRecording(loadQueue(storage), rec("b"), "user-1"), storage);

    gate.resolve();
    expect(await drain).toBe(1);
    // "a" succeeded and is gone; "b" (queued mid-drain) must survive.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["b"]);
  });

  // #484 F3 end to end through the production entry point (not just
  // `drainQueue` in isolation): the permanently-rejected entry must actually
  // be removed from the queue (or it would be re-attempted forever, which is
  // its own kind of "stuck"), must NOT count toward the "recovered" number a
  // caller would toast, and its loss must be reported (#264) rather than
  // silently vanish.
  it("removes a quarantined entry from the queue, excludes it from the recovered count, and reports the loss (#484 F3)", async () => {
    const storage = fakeStorage();
    let queue = enqueueRecording([], rec("bad"), "user-1");
    queue = enqueueRecording(queue, rec("good"), "user-1");
    saveQueue(queue, storage);

    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const insert = vi
      .fn()
      .mockRejectedValueOnce({
        code: "23514",
        message: "violates check constraint",
      })
      .mockResolvedValueOnce({});
    const recovered = await drainPendingRecordingsQueue("user-1", insert, noDb, storage);

    expect(recovered).toBe(1); // only "good" — a quarantine is not a recovery
    expect(loadQueue(storage)).toEqual([]); // both are gone: one landed, one never will
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining("upload-rejected"),
      expect.objectContaining({ lost: 1 }),
    );
    warn.mockRestore();
  });

  it("guards against a second concurrent drain double-inserting", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("a"), "user-1"), storage);

    const gate = deferred();
    const insert = vi.fn(() => gate.promise);

    const first = drainPendingRecordingsQueue("user-1", insert, noDb, storage);
    await tick();
    // Fires while the first drain is still in flight — must be a no-op.
    const second = await drainPendingRecordingsQueue("user-1", insert, noDb, storage);
    expect(second).toBe(0);

    gate.resolve();
    expect(await first).toBe(1);
    expect(insert).toHaveBeenCalledTimes(1);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// #269 — the two-store arrangement: IndexedDB main queue + synchronous lane.
// ─────────────────────────────────────────────────────────────────────────────

describe("persistRecordingDurable (the IndexedDB main path)", () => {
  it("queues into IndexedDB and leaves the sync lane empty", async () => {
    const storage = fakeStorage();
    const { loader, map } = fakeDb();
    const result = await persistRecordingDurable(rec("id-1"), "user-1", loader, storage);
    expect(result).toEqual({ persisted: true, evicted: 0 });
    expect([...map.keys()]).toEqual(["id-1"]);
    // The lane exists for the unmount path alone — the async path must not
    // spend any of its tiny budget.
    expect(loadQueue(storage)).toEqual([]);
  });

  it("degrades to the sync lane when IndexedDB is unavailable (private mode)", async () => {
    const storage = fakeStorage();
    const result = await persistRecordingDurable(rec("id-1"), "user-1", noDb, storage);
    expect(result).toEqual({ persisted: true, evicted: 0 });
    // Smaller queue, but still durable — "no IndexedDB" must never mean
    // "no queue".
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["id-1"]);
  });

  it("degrades to the sync lane when opening IndexedDB rejects outright", async () => {
    const storage = fakeStorage();
    const loader: RecordingDbLoader = () => Promise.reject(new Error("SecurityError"));
    const result = await persistRecordingDurable(rec("id-1"), "user-1", loader, storage);
    expect(result.persisted).toBe(true);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["id-1"]);
  });

  it("degrades to the sync lane when the existing queue can't be read", async () => {
    const storage = fakeStorage();
    const { db } = fakeDb();
    db.getAll = () => Promise.reject(new Error("InvalidStateError"));
    const result = await persistRecordingDurable(
      rec("id-1"),
      "user-1",
      () => Promise.resolve(db),
      storage,
    );
    expect(result.persisted).toBe(true);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["id-1"]);
  });

  it("reports persisted:false only when BOTH stores refuse", async () => {
    const { loader } = fakeDb([], () => quotaError());
    const result = await persistRecordingDurable(
      rec("id-1"),
      "user-1",
      loader,
      throwingStorage(),
    );
    // Nothing durable anywhere — the contract is to say so, never to pretend.
    expect(result.persisted).toBe(false);
  });

  it("falls through to the sync lane when IndexedDB refuses but localStorage has room", async () => {
    const storage = fakeStorage();
    const { loader } = fakeDb([], () => quotaError());
    const result = await persistRecordingDurable(rec("id-1"), "user-1", loader, storage);
    expect(result.persisted).toBe(true);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["id-1"]);
  });
});

describe("persistRecordingDurable — the eviction backstop (#269 keeps it)", () => {
  it("drops the OLDEST entry and retries when IndexedDB refuses for quota", async () => {
    const storage = fakeStorage();
    // Refuses the first two puts; the third lands. Same degradation the
    // localStorage path applies, driven by the store's actual answer.
    const { loader, map } = fakeDb(queueOf("old-1", "old-2", "old-3"), (attempt) =>
      attempt <= 2 ? quotaError() : undefined,
    );
    const result = await persistRecordingDurable(rec("new-1"), "user-1", loader, storage);
    expect(result).toEqual({ persisted: true, evicted: 2 });
    // The new rep wins; the two oldest queued entries were the price.
    expect([...map.keys()].sort()).toEqual(["new-1", "old-3"]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("counts every entry dropped on the way down before giving up", async () => {
    const { loader, map } = fakeDb(queueOf("old-1", "old-2"), () => quotaError());
    const result = await persistRecordingDurable(
      rec("new-1"),
      "user-1",
      loader,
      throwingStorage(),
    );
    expect(result).toEqual({ persisted: false, evicted: 2 });
    // It really did sacrifice them, and still lost — which is exactly the
    // finding the monitoring event carries.
    expect([...map.keys()]).toEqual([]);
  });

  it("does NOT evict for a non-quota write failure", async () => {
    const storage = fakeStorage();
    const { loader, map } = fakeDb(queueOf("old-1", "old-2"), () =>
      new DOMException("value could not be cloned", "DataCloneError"),
    );
    const result = await persistRecordingDurable(rec("new-1"), "user-1", loader, storage);
    // A structurally unwritable record would refuse the lone entry just as
    // hard, so dropping queued reps to discover that would be pure loss.
    expect(result.evicted).toBe(0);
    expect([...map.keys()].sort()).toEqual(["old-1", "old-2"]);
    // …and it still reached a durable home via the lane.
    expect(result.persisted).toBe(true);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["new-1"]);
  });
});

describe("absorbSyncLane (migration + the salvage lane draining into the main store)", () => {
  it("moves lane entries into the main store and clears the lane", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("legacy-1", "legacy-2"), storage);
    const { loader, map } = fakeDb();

    expect(await absorbSyncLane(loader, storage)).toBe(2);
    expect([...map.keys()].sort()).toEqual(["legacy-1", "legacy-2"]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("preserves the payload, not just the id", async () => {
    const storage = fakeStorage();
    const lane = queueOf("legacy-1");
    saveQueue(lane, storage);
    const { loader, map } = fakeDb();
    await absorbSyncLane(loader, storage);
    expect(map.get("legacy-1")).toEqual(lane[0]);
  });

  it("is a no-op with an empty lane", async () => {
    const { loader, db } = fakeDb();
    const put = vi.spyOn(db, "put");
    expect(await absorbSyncLane(loader, fakeStorage())).toBe(0);
    expect(put).not.toHaveBeenCalled();
  });

  it("leaves the lane untouched when there is no main store to move into", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("legacy-1"), storage);
    expect(await absorbSyncLane(noDb, storage)).toBe(0);
    // Still durable where it was — a failed migration must never be a deletion.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["legacy-1"]);
  });

  it("leaves the lane untouched when the copy can't commit", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("legacy-1", "legacy-2"), storage);
    const { loader, map } = fakeDb([], () => quotaError());

    expect(await absorbSyncLane(loader, storage)).toBe(0);
    expect([...map.keys()]).toEqual([]);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["legacy-1", "legacy-2"]);
  });

  it("re-copying after an interrupted run overwrites instead of duplicating", async () => {
    // The post-kill state, reproduced exactly: the copy COMMITTED to the main
    // store, and the process died before the lane could be cleared. Both stores
    // now hold the same two entries.
    const storage = fakeStorage();
    const lane = queueOf("legacy-1", "legacy-2");
    saveQueue(lane, storage);
    const { loader, db, map } = fakeDb();
    await db.put(lane);

    // Next launch runs the migration again.
    expect(await absorbSyncLane(loader, storage)).toBe(2);
    // keyPath `id` makes the re-put an overwrite: two entries, not four.
    expect([...map.keys()].sort()).toEqual(["legacy-1", "legacy-2"]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("an interrupted migration inserts each recording exactly ONCE on the next drain", async () => {
    // Same post-kill state, carried through to the thing that actually matters:
    // the server must not receive a recording twice because it briefly existed
    // in both stores.
    const storage = fakeStorage();
    const lane = queueOf("legacy-1", "legacy-2");
    saveQueue(lane, storage);
    const { loader, db, map } = fakeDb();
    await db.put(lane);

    const insert = vi.fn().mockResolvedValue({});
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, storage)).toBe(2);
    expect(insert).toHaveBeenCalledTimes(2);
    expect(insert.mock.calls.map((c) => (c[0] as { id: string }).id).sort()).toEqual([
      "legacy-1",
      "legacy-2",
    ]);
    // Both stores end up empty — nothing stranded in the lane.
    expect([...map.keys()]).toEqual([]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("doesn't clobber a salvage that raced in during the copy", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("legacy-1"), storage);
    const gate = deferred();
    const { db, map } = fakeDb();
    const realPut = db.put.bind(db);
    db.put = (entries) => gate.promise.then(() => realPut(entries));

    const absorb = absorbSyncLane(() => Promise.resolve(db), storage);
    await tick(); // the copy is now in flight
    // useTindeq's unmount cleanup fires mid-copy and writes the lane
    // synchronously — it cannot await, so this really can interleave.
    saveQueue(
      enqueueRecording(loadQueue(storage), rec("salvaged"), "user-1"),
      storage,
    );
    gate.resolve();

    expect(await absorb).toBe(1);
    expect([...map.keys()]).toEqual(["legacy-1"]);
    // Only the ids actually copied were removed; the salvage survives.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["salvaged"]);
  });
});

describe("drainPendingRecordingsQueue with IndexedDB", () => {
  it("absorbs the lane, drains the main store, and deletes only what landed", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("salvaged"), storage);
    const { loader, map } = fakeDb(queueOf("queued-1", "queued-2"));

    const insert = vi
      .fn()
      .mockResolvedValueOnce({})
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error("network"));
    const recovered = await drainPendingRecordingsQueue("user-1", insert, loader, storage);

    expect(recovered).toBe(2);
    // Whatever failed is still queued; nothing was dropped to make a number
    // look better.
    expect([...map.keys()].length).toBe(1);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("still attempts lane entries when the absorb couldn't commit", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("salvaged"), storage);
    // The main store refuses writes, so the migration can't move it — but the
    // recording is real and reachable, and stranding it until IndexedDB
    // recovers would be a choice, not a constraint.
    const { loader } = fakeDb([], () => quotaError());

    const insert = vi.fn().mockResolvedValue({});
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, storage)).toBe(1);
    expect(insert).toHaveBeenCalledTimes(1);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("is a no-op when both stores are empty", async () => {
    const { loader } = fakeDb();
    const insert = vi.fn();
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, fakeStorage())).toBe(0);
    expect(insert).not.toHaveBeenCalled();
  });
});

describe("pendingRecordingsCount", () => {
  it("sums both stores", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("salvaged"), storage);
    const { loader } = fakeDb(queueOf("queued-1", "queued-2"));
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(3);
  });

  it("counts an entry mid-migration (in both stores) once", async () => {
    const storage = fakeStorage();
    const lane = queueOf("legacy-1");
    saveQueue(lane, storage);
    const { loader } = fakeDb(lane);
    // Showing 2 here would make a stalled migration look like a growing
    // backlog.
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(1);
  });

  it("falls back to the lane alone when IndexedDB is unavailable", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("a", "b"), storage);
    expect(await pendingRecordingsCount("user-1", noDb, storage)).toBe(2);
  });

  it("is 0, not an error, with nothing queued anywhere", async () => {
    expect(await pendingRecordingsCount("user-1", noDb, fakeStorage())).toBe(0);
  });

  // #484 F5: PROVED — this used to sum `keys()` across both stores with no
  // regard for whose recordings they were, so account B saw account A's
  // stranded entries in its own count (and the UI told them it would sync).
  it("does NOT count another account's stranded entries (#484 F5)", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("mine"), storage); // queueOf stamps "user-1"
    const theirs = enqueueRecording([], rec("theirs"), "user-2", () => "2026-07-01T00:00:00.000Z");
    const { loader } = fakeDb(theirs);
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(1);
    // The other account sees exactly its own, not zero and not both.
    expect(await pendingRecordingsCount("user-2", loader, storage)).toBe(1);
  });

  it("still counts unknown-user (null) legacy entries for anyone, matching drainQueue's attempt rule", async () => {
    const storage = fakeStorage();
    const legacy = enqueueRecording([], rec("legacy"), null, () => "2026-07-01T00:00:00.000Z");
    const { loader } = fakeDb(legacy);
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(1);
  });
});

describe("clearRecordingQueue", () => {
  // The mechanics only. WHEN this is allowed to run — user-initiated sign-out
  // and nothing else — is `signOut.ts`'s job and lives in `signOut.test.ts`.

  it("empties BOTH stores, not just the main one", async () => {
    const storage = fakeStorage();
    const { loader, map } = fakeDb(queueOf("idb-1", "idb-2"));
    saveQueue(queueOf("lane-1"), storage);

    expect(await clearRecordingQueue(loader, storage)).toBe(3);
    expect([...map.keys()]).toEqual([]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("counts an entry sitting in both stores once", async () => {
    const storage = fakeStorage();
    const lane = queueOf("legacy-1");
    saveQueue(lane, storage);
    const { loader } = fakeDb(lane);
    expect(await clearRecordingQueue(loader, storage)).toBe(1);
  });

  it("still clears the lane when IndexedDB isn't there at all", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("lane-1", "lane-2"), storage);
    expect(await clearRecordingQueue(noDb, storage)).toBe(2);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("reports what it actually removed, not what it was asked to", async () => {
    // A store that refuses the clear must not be counted as emptied — the
    // sign-out path reports the gap rather than assuming success.
    const storage = fakeStorage();
    const { db } = fakeDb(queueOf("idb-1", "idb-2"));
    const refusing: RecordingDb = { ...db, clear: () => Promise.reject(quotaError()) };
    saveQueue(queueOf("lane-1"), storage);

    expect(await clearRecordingQueue(() => Promise.resolve(refusing), storage)).toBe(1);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("is a no-op on an empty queue", async () => {
    const storage = fakeStorage();
    const { loader } = fakeDb();
    expect(await clearRecordingQueue(loader, storage)).toBe(0);
  });

  it("empties a real IndexedDB store", async () => {
    const storage = fakeStorage();
    const db = await openRecordingDb(new IDBFactory());
    if (!db) throw new Error("expected fake-indexeddb to open");
    const loader: RecordingDbLoader = () => Promise.resolve(db);
    await persistRecordingDurable(rec("id-1"), "user-1", loader, storage);
    await persistRecordingDurable(rec("id-2"), "user-1", loader, storage);

    expect(await clearRecordingQueue(loader, storage)).toBe(2);
    expect(await db.getAll()).toEqual([]);
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// The same paths again, but against a REAL IndexedDB (fake-indexeddb's
// implementation) rather than the in-memory stub above — so the transaction
// semantics the migration's safety rests on are actually exercised, not
// assumed. Quota is the one thing this can't reach; fake-indexeddb has no limit
// to exceed, so those cases stay on the stub.
// ─────────────────────────────────────────────────────────────────────────────

describe("the two stores end to end (real IndexedDB)", () => {
  async function realLoader(): Promise<RecordingDbLoader> {
    const db = await openRecordingDb(new IDBFactory());
    if (!db) throw new Error("expected fake-indexeddb to open");
    return () => Promise.resolve(db);
  }

  it("queues into IndexedDB, drains it, and leaves nothing behind", async () => {
    const storage = fakeStorage();
    const loader = await realLoader();
    await persistRecordingDurable(rec("id-1"), "user-1", loader, storage);
    await persistRecordingDurable(rec("id-2"), "user-1", loader, storage);
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(2);

    const insert = vi.fn().mockResolvedValue({});
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, storage)).toBe(2);
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(0);
  });

  it("migrates a pre-#269 localStorage queue on first run", async () => {
    const storage = fakeStorage();
    // Exactly what an older build left behind under the same key.
    saveQueue(queueOf("legacy-1", "legacy-2", "legacy-3"), storage);
    const loader = await realLoader();

    const insert = vi.fn().mockResolvedValue({});
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, storage)).toBe(3);
    expect(insert).toHaveBeenCalledTimes(3);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("survives a migration interrupted between the copy and the clear", async () => {
    const storage = fakeStorage();
    const lane = queueOf("legacy-1", "legacy-2");
    saveQueue(lane, storage);
    const db = await openRecordingDb(new IDBFactory());
    if (!db) throw new Error("expected fake-indexeddb to open");
    const loader: RecordingDbLoader = () => Promise.resolve(db);

    // The interruption, reproduced: the copy transaction COMMITTED and then the
    // process died before the lane was cleared.
    await db.put(lane);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["legacy-1", "legacy-2"]);

    // Next launch. Nothing is dropped, and nothing is inserted twice.
    const insert = vi.fn().mockResolvedValue({});
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, storage)).toBe(2);
    expect(insert).toHaveBeenCalledTimes(2);
    expect(await db.keys()).toEqual([]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("recovers a lane entry the FIRST migration attempt couldn't commit", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("legacy-1"), storage);
    const db = await openRecordingDb(new IDBFactory());
    if (!db) throw new Error("expected fake-indexeddb to open");

    // First attempt: the copy is refused outright. The lane must still hold it.
    const refusing: RecordingDb = { ...db, put: () => Promise.reject(quotaError()) };
    expect(await absorbSyncLane(() => Promise.resolve(refusing), storage)).toBe(0);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["legacy-1"]);

    // Second attempt, IndexedDB healthy again: it moves across.
    expect(await absorbSyncLane(() => Promise.resolve(db), storage)).toBe(1);
    expect(await db.keys()).toEqual(["legacy-1"]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("moves a salvage-on-unmount entry out of the lane on the next foreground", async () => {
    const storage = fakeStorage();
    const loader = await realLoader();
    // What useTindeq's cleanup does — synchronously, into the lane.
    expect(persistRecording(rec("salvaged"), "user-1", storage).persisted).toBe(true);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["salvaged"]);

    expect(await absorbSyncLane(loader, storage)).toBe(1);
    const db = await loader();
    expect(await db!.keys()).toEqual(["salvaged"]);
    // The lane is a lane, not a store — it must not keep a copy.
    expect(loadQueue(storage)).toEqual([]);
  });
});

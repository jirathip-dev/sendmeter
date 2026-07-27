import { describe, it, expect, vi } from "vitest";
import {
  MAX_QUEUE_BYTES,
  drainPendingRecordingsQueue,
  drainQueue,
  drainSalvageLane,
  enqueueRecording,
  loadQueue,
  pendingRecordingCount,
  persistRecording,
  persistRecordingToMainQueue,
  saveQueue,
  type PendingRecording,
} from "./recordingQueue";
import type { MainQueueStore } from "./recordingDB";
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

/// In-memory stand-in for the real IndexedDB-backed `MainQueueStore` — the
/// injected fake this project's tests use instead of `fake-indexeddb` (see
/// recordingDB.ts's file comment for why: this suite runs in node, and the
/// policy logic under test is entirely store-agnostic).
function fakeMainQueueStore(initial: PendingRecording[] = []): MainQueueStore {
  const entries = new Map(initial.map((e) => [e.id, e]));
  const sorted = () =>
    [...entries.values()].sort((a, b) => a.queuedAt.localeCompare(b.queuedAt));
  return {
    getAll: async () => sorted(),
    put: async (entry) => {
      entries.set(entry.id, entry);
    },
    delete: async (ids) => {
      for (const id of ids) entries.delete(id);
    },
    count: async () => entries.size,
    deleteOldest: async () => {
      const oldest = sorted()[0];
      if (!oldest) return false;
      entries.delete(oldest.id);
      return true;
    },
  };
}

/// Wraps a fake store so `put` refuses its first `refusals` calls (quota
/// exceeded) before behaving normally — the IndexedDB-side equivalent of
/// `seededStorage` below.
function quotaLimitedStore(initial: PendingRecording[], refusals: number): MainQueueStore {
  const base = fakeMainQueueStore(initial);
  let refused = 0;
  return {
    ...base,
    put: async (entry) => {
      if (refused < refusals) {
        refused += 1;
        throw new Error("QuotaExceededError");
      }
      await base.put(entry);
    },
  };
}

/// A store whose `put` throws starting on the (1-indexed) `failAt`-th call —
/// simulates a salvage-lane drain interrupted partway through.
function failingAfterStore(failAt: number): MainQueueStore {
  const base = fakeMainQueueStore();
  let calls = 0;
  return {
    ...base,
    put: async (entry) => {
      calls += 1;
      if (calls >= failAt) throw new Error("write failed");
      await base.put(entry);
    },
  };
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

describe("persistRecordingToMainQueue (#269 — the main IndexedDB queue)", () => {
  it("reports persisted with nothing evicted on the happy path", async () => {
    const store = fakeMainQueueStore();
    const result = await persistRecordingToMainQueue(rec("id-1"), "user-1", store);
    expect(result).toEqual({ persisted: true, evicted: 0 });
    expect((await store.getAll()).map((p) => p.id)).toEqual(["id-1"]);
  });

  it("falls back to the sync salvage lane when the main queue is unavailable", async () => {
    const storage = fakeStorage();
    const result = await persistRecordingToMainQueue(rec("id-1"), "user-1", null, storage);
    expect(result).toEqual({ persisted: true, evicted: 0 });
    // Landed in the SALVAGE lane (localStorage), not any main queue.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["id-1"]);
  });

  it("reports a hard failure when BOTH the main queue and the salvage-lane fallback are unavailable", async () => {
    const result = await persistRecordingToMainQueue(rec("id-1"), "user-1", null, null);
    expect(result).toEqual({ persisted: false, evicted: 0 });
  });

  it("runs the eviction backstop (oldest-first) on a quota failure, then succeeds", async () => {
    const seeded: PendingRecording[] = [
      { id: "old-1", queuedAt: "2026-07-01T00:00:00.000Z", userId: "user-1", input: rec("old-1") },
      { id: "old-2", queuedAt: "2026-07-02T00:00:00.000Z", userId: "user-1", input: rec("old-2") },
    ];
    // Refuses twice: the put only lands once both oldest entries are gone.
    const store = quotaLimitedStore(seeded, 2);
    const result = await persistRecordingToMainQueue(rec("new-1"), "user-1", store);
    expect(result).toEqual({ persisted: true, evicted: 2 });
    expect((await store.getAll()).map((p) => p.id)).toEqual(["new-1"]);
  });

  it("falls back to the salvage lane once the eviction backstop is exhausted, and lands there", async () => {
    const seeded: PendingRecording[] = [
      { id: "old-1", queuedAt: "2026-07-01T00:00:00.000Z", userId: "user-1", input: rec("old-1") },
    ];
    // Always refuses — one entry to evict, then nothing left, then fallback.
    const store = quotaLimitedStore(seeded, Infinity);
    const storage = fakeStorage();
    const result = await persistRecordingToMainQueue(rec("new-1"), "user-1", store, storage);
    // 1 evicted from the main queue on the way down, 0 more from the salvage
    // lane (it was empty, so persistRecording's own write just lands).
    expect(result).toEqual({ persisted: true, evicted: 1 });
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["new-1"]);
    expect(await store.count()).toBe(0);
  });

  it("is a genuine hard failure — persisted: false — when the salvage-lane fallback ALSO refuses", async () => {
    const store = quotaLimitedStore([], Infinity); // empty: fails, nothing to evict, falls back
    const result = await persistRecordingToMainQueue(rec("id-1"), "user-1", store, throwingStorage());
    expect(result).toEqual({ persisted: false, evicted: 0 });
  });
});

describe("drainSalvageLane", () => {
  it("moves every salvage-lane entry into the main queue, oldest first, and empties the lane", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("a", "b", "c"), storage);
    const store = fakeMainQueueStore();
    const moved = await drainSalvageLane(store, storage);
    expect(moved).toBe(3);
    expect(loadQueue(storage)).toEqual([]);
    expect((await store.getAll()).map((p) => p.id)).toEqual(["a", "b", "c"]);
  });

  it("is a no-op on an empty salvage lane", async () => {
    const storage = fakeStorage();
    const store = fakeMainQueueStore();
    expect(await drainSalvageLane(store, storage)).toBe(0);
    expect(await store.count()).toBe(0);
  });

  it("leaves the tail in localStorage when the main-queue write fails partway (interrupted drain)", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("a", "b", "c"), storage);
    // Succeeds for "a", fails starting on the 2nd put ("b").
    const store = failingAfterStore(2);
    const moved = await drainSalvageLane(store, storage);
    expect(moved).toBe(1);
    expect((await store.getAll()).map((p) => p.id)).toEqual(["a"]);
    // "b" and "c" are still safely queued in the salvage lane.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["b", "c"]);
  });

  it("resuming an interrupted drain completes with no duplicates (put is idempotent by id)", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("a", "b", "c"), storage);
    const store = fakeMainQueueStore();
    // First pass: simulate "a" already having landed in a PRIOR partial drain
    // (e.g. this same entry, re-queued) by pre-seeding the store with it too.
    await store.put({ id: "a", queuedAt: "2026-07-01T00:00:00.000Z", userId: "user-1", input: rec("a") });
    const moved = await drainSalvageLane(store, storage);
    expect(moved).toBe(3); // still attempts all 3 — put(a) just overwrites
    expect((await store.getAll()).map((p) => p.id)).toEqual(["a", "b", "c"]);
    expect(await store.count()).toBe(3); // no duplicate "a"
    expect(loadQueue(storage)).toEqual([]);
  });
});

describe("pendingRecordingCount", () => {
  it("is 0 when both lanes are empty", async () => {
    expect(await pendingRecordingCount(fakeMainQueueStore(), fakeStorage())).toBe(0);
  });

  it("sums the main queue and the salvage lane", async () => {
    const store = fakeMainQueueStore([
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t", userId: "user-1", input: rec("b") },
    ]);
    const storage = fakeStorage();
    saveQueue(queueOf("c"), storage);
    expect(await pendingRecordingCount(store, storage)).toBe(3);
  });

  it("falls back to just the salvage lane when the main queue is unavailable", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("a", "b"), storage);
    expect(await pendingRecordingCount(null, storage)).toBe(2);
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

describe("drainPendingRecordingsQueue (no main queue this session — the pre-#269 localStorage-only fallback)", () => {
  // No `store` argument is passed anywhere in this block, so
  // `defaultMainQueueStore()` resolves — node has no `indexedDB` — meaning
  // every one of these exercises `drainLocalStorageQueue`, the fallback for a
  // session with no main queue available at all.
  it("persists only what's left after a partial drain", async () => {
    const storage = fakeStorage();
    let queue = enqueueRecording([], rec("a"), "user-1");
    queue = enqueueRecording(queue, rec("b"), "user-1");
    saveQueue(queue, storage);

    const insert = vi
      .fn()
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error("network"));
    const recovered = await drainPendingRecordingsQueue("user-1", insert, storage);

    expect(recovered).toBe(1);
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["b"]);
  });

  it("is a no-op with an empty queue", async () => {
    const storage = fakeStorage();
    const insert = vi.fn();
    expect(await drainPendingRecordingsQueue("user-1", insert, storage)).toBe(0);
    expect(insert).not.toHaveBeenCalled();
  });

  it("merges a concurrent enqueue instead of clobbering it on write-back", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("a"), "user-1"), storage);

    // The racing enqueue happens FROM WITHIN "a"'s insert — i.e. strictly
    // after this drain's queue snapshot (which only saw "a") was already
    // taken, and strictly before the later write-back — rather than
    // immediately after starting the drain: this function now resolves the
    // main-queue store (an async lookup, even when it resolves to "none
    // available") before it ever reads storage, so a synchronous race
    // immediately after the call no longer lands in the right window. Same
    // window `ForceView.queueFailedRecording` racing a live drain would land
    // in either way.
    const insert = vi.fn(async (input: NewTindeqRecording & { id: string }) => {
      if (input.id === "a") {
        saveQueue(enqueueRecording(loadQueue(storage), rec("b"), "user-1"), storage);
      }
    });

    const recovered = await drainPendingRecordingsQueue("user-1", insert, storage);
    expect(recovered).toBe(1);
    // "a" succeeded and is gone; "b" (queued mid-drain) must survive.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["b"]);
  });

  it("guards against a second concurrent drain double-inserting", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("a"), "user-1"), storage);
    const insert = vi.fn().mockResolvedValue({});
    // The `draining` guard is checked and set BEFORE any `await`, so calling
    // it twice back to back (both synchronously, in the same tick) makes the
    // second call deterministically see the flag already set.
    const first = drainPendingRecordingsQueue("user-1", insert, storage);
    const second = await drainPendingRecordingsQueue("user-1", insert, storage);
    expect(second).toBe(0);
    expect(await first).toBe(1);
    expect(insert).toHaveBeenCalledTimes(1);
  });
});

describe("drainPendingRecordingsQueue (#269 — the main IndexedDB queue path, an injected fake store)", () => {
  it("drains the salvage lane into the main queue FIRST, then attempts everything", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("legacy"), storage); // pre-#269 leftover / interrupted migration
    const store = fakeMainQueueStore([
      { id: "a", queuedAt: "t", userId: "user-1", input: rec("a") },
    ]);
    const insert = vi.fn().mockResolvedValue({});
    const recovered = await drainPendingRecordingsQueue("user-1", insert, storage, store);
    expect(recovered).toBe(2);
    expect(insert).toHaveBeenCalledTimes(2);
    // Both lanes ended up empty.
    expect(loadQueue(storage)).toEqual([]);
    expect(await store.count()).toBe(0);
  });

  it("persists only what's left in the main queue after a partial drain", async () => {
    const store = fakeMainQueueStore([
      { id: "a", queuedAt: "t1", userId: "user-1", input: rec("a") },
      { id: "b", queuedAt: "t2", userId: "user-1", input: rec("b") },
    ]);
    const insert = vi
      .fn()
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error("network"));
    const recovered = await drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store);
    expect(recovered).toBe(1);
    expect((await store.getAll()).map((p) => p.id)).toEqual(["b"]);
  });

  it("is a no-op with an empty main queue and an empty salvage lane", async () => {
    const store = fakeMainQueueStore();
    const insert = vi.fn();
    expect(
      await drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store),
    ).toBe(0);
    expect(insert).not.toHaveBeenCalled();
  });

  it("merges a concurrent enqueue into the main queue instead of clobbering it on delete", async () => {
    const store = fakeMainQueueStore([
      { id: "a", queuedAt: "t1", userId: "user-1", input: rec("a") },
    ]);
    // The racing put happens FROM WITHIN "a"'s insert — i.e. strictly after
    // the drain's `getAll()` snapshot (which only saw "a") was already taken,
    // and strictly before the later per-id delete — the same window
    // `ForceView.queueFailedRecording` racing a live drain would land in.
    const insert = vi.fn(async (input: NewTindeqRecording & { id: string }) => {
      if (input.id === "a") {
        await store.put({ id: "b", queuedAt: "t2", userId: "user-1", input: rec("b") });
      }
    });
    const recovered = await drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store);
    expect(recovered).toBe(1);
    // "a" succeeded and is gone (deleted by id); "b" (queued mid-drain) must
    // survive — only the succeeded ids are deleted, never a bulk overwrite.
    expect((await store.getAll()).map((p) => p.id)).toEqual(["b"]);
  });

  it("guards against a second concurrent drain double-inserting", async () => {
    const store = fakeMainQueueStore([
      { id: "a", queuedAt: "t1", userId: "user-1", input: rec("a") },
    ]);
    const insert = vi.fn().mockResolvedValue({});
    // The `draining` guard is checked and set BEFORE any `await` in
    // drainPendingRecordingsQueue, so calling it twice back to back (both
    // synchronously, in the same tick — no manual pending-promise
    // choreography needed) deterministically makes the second call see the
    // flag already set, regardless of how far the first call's internal
    // (now multi-hop: salvage lane → getAll → drainQueue) chain has
    // actually progressed.
    const first = drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store);
    const second = await drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store);
    expect(second).toBe(0);
    expect(await first).toBe(1);
    expect(insert).toHaveBeenCalledTimes(1);
  });

  it("never attempts (or drops) a main-queue entry queued under a different user", async () => {
    const store = fakeMainQueueStore([
      { id: "mine", queuedAt: "t1", userId: "user-1", input: rec("mine") },
      { id: "theirs", queuedAt: "t2", userId: "user-2", input: rec("theirs") },
    ]);
    const insert = vi.fn().mockResolvedValue({});
    const recovered = await drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store);
    expect(recovered).toBe(1);
    expect((await store.getAll()).map((p) => p.id)).toEqual(["theirs"]);
  });

  it("treats a 23505 (duplicate key) main-queue failure as success and removes it", async () => {
    const store = fakeMainQueueStore([
      { id: "a", queuedAt: "t1", userId: "user-1", input: rec("a") },
    ]);
    const insert = vi
      .fn()
      .mockRejectedValueOnce({ code: "23505", message: "duplicate key value violates…" });
    const recovered = await drainPendingRecordingsQueue("user-1", insert, fakeStorage(), store);
    expect(recovered).toBe(1);
    expect(await store.count()).toBe(0);
  });
});

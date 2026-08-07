import { describe, it, expect, vi } from "vitest";
import {
  MAX_QUEUE_BYTES,
  absorbSyncLane,
  clearRecordingQueue,
  drainPendingRecordingsQueue,
  drainQueue,
  enqueueRecording,
  loadQueue,
  pendingRecordingsBreakdown,
  pendingRecordingsCount,
  persistRecording,
  persistRecordingDurable,
  retryStuckRecordings,
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
    getAllForUser: (userId) =>
      Promise.resolve(
        [...map.values()]
          .filter((p) => p.userId === null || p.userId === userId)
          .sort(byQueuedAt),
      ),
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

  // #484 — a constraint rejection keeps draining the healthy entries behind
  // it (the issue's headline defect), but does NOT quarantine on the first
  // sighting. Before this fix, `drainQueue` had no such bucket at all and ANY
  // non-duplicate failure set the single `broken` flag that parks every later
  // entry — "b" and "c" would both come back in `remaining`, `insert` would
  // be called exactly twice, and the healthy "c" would never even be
  // attempted.
  it("does not block healthy entries behind a constraint-rejected one, and does not quarantine on the first rejection", async () => {
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
    const result = await drainQueue(queue, "user-1", insert, () => "t2", () => "build-1");
    expect(result.stuck).toEqual([]);
    expect(result.succeeded.map((p) => p.id)).toEqual(["b", "c"]);
    // "a" is retained and still eligible for the next drain — not deleted,
    // not left out of the result entirely — carrying diagnosis detail.
    expect(result.remaining).toEqual([
      {
        id: "a",
        queuedAt: "t",
        userId: "user-1",
        input: rec("a"),
        rejection: {
          code: "23514",
          message: 'new row for relation "tindeq_recordings" violates check constraint "tindeq_recordings_duration_check"',
          firstVersion: "build-1",
          firstAt: "t2",
          lastVersion: "build-1",
          lastAt: "t2",
          stuck: false,
        },
      },
    ]);
    expect(insert).toHaveBeenCalledTimes(3);
  });

  // #484 — the F1 finding: this repo's CHECK constraints are value
  // allow-lists that migrations WIDEN (the zone check, twice), and a web
  // deploy can go live slightly ahead of its own migration. A rejection
  // under the SAME build that first saw it must not be trusted as permanent —
  // only surviving a build change earns that.
  it("stays retryable across repeated rejections under the SAME app build", async () => {
    const queue = [{ id: "a", queuedAt: "t", userId: "user-1", input: rec("a") }];
    const insert = vi.fn().mockRejectedValue({ code: "23514", message: "violates check constraint" });
    let result = await drainQueue(queue, "user-1", insert, () => "t2", () => "build-1");
    expect(result.stuck).toEqual([]);
    expect(result.remaining[0]?.rejection?.stuck).toBe(false);

    // A second pass, same build, same entry (now carrying its own rejection
    // stamp) — still not stuck.
    result = await drainQueue(result.remaining, "user-1", insert, () => "t3", () => "build-1");
    expect(result.stuck).toEqual([]);
    expect(result.remaining[0]?.rejection).toMatchObject({
      firstVersion: "build-1",
      lastVersion: "build-1",
      lastAt: "t3",
      stuck: false,
    });
  });

  // #484 — PROVED: this is the property F1 exists for. A rejection that
  // survives an app-version change (a deploy that could plausibly have
  // carried the migration fix) is what finally latches `stuck` — retained on
  // device, excluded from further automatic attempts, never deleted.
  it("latches stuck only once a rejection survives an app-version change", async () => {
    const queue = [{ id: "a", queuedAt: "t", userId: "user-1", input: rec("a") }];
    const insert = vi.fn().mockRejectedValue({ code: "23514", message: "violates check constraint" });
    const first = await drainQueue(queue, "user-1", insert, () => "t2", () => "build-1");
    expect(first.remaining[0]?.rejection?.stuck).toBe(false);

    // A NEW build, same payload, same rejection.
    const second = await drainQueue(first.remaining, "user-1", insert, () => "t3", () => "build-2");
    expect(second.remaining).toEqual([]);
    expect(second.stuck.map((p) => p.id)).toEqual(["a"]);
    expect(second.stuck[0]?.rejection).toMatchObject({
      firstVersion: "build-1", // preserved — the window this measures
      lastVersion: "build-2",
      stuck: true,
    });
  });

  it("never auto-attempts an already-stuck entry again", async () => {
    const stuckEntry: PendingRecording = {
      id: "a",
      queuedAt: "t",
      userId: "user-1",
      input: rec("a"),
      rejection: {
        code: "23514",
        message: "violates check constraint",
        firstVersion: "build-1",
        firstAt: "t1",
        lastVersion: "build-2",
        lastAt: "t2",
        stuck: true,
      },
    };
    const insert = vi.fn().mockResolvedValue({});
    const result = await drainQueue([stuckEntry], "user-1", insert);
    expect(insert).not.toHaveBeenCalled();
    expect(result.succeeded).toEqual([]);
    expect(result.remaining).toEqual([]);
    expect(result.stuck).toEqual([stuckEntry]);
  });

  // #484 F3 / #475 F11 — the cautionary case named in the issue: a transient
  // failure (offline, 5xx, a stale/expired auth token) must default to
  // RETRY, never stuck/quarantine, however many entries follow it.
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
    expect(result.stuck).toEqual([]);
    // Still the pre-existing "stop the pass" behavior for a transient
    // failure — both come back queued for the next drain, UNCHANGED (no
    // rejection stamp — a transient failure isn't a content verdict).
    expect(result.remaining).toEqual(queue);
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

  // #487 (F2): a recording queued offline must keep the time it was actually
  // recorded, not whenever the drain finally runs (which can be hours or
  // days later — a delayed drain used to insert with the DB's `recorded_at
  // default now()`, landing the rep in the wrong ACWR day-bucket).
  it("stamps the insert with the entry's queuedAt, not just whatever input it was queued with", async () => {
    const queue = [
      { id: "a", queuedAt: "2026-08-01T09:00:00.000Z", userId: "user-1", input: rec("a") },
    ];
    const insert = vi.fn().mockResolvedValue({});
    await drainQueue(queue, "user-1", insert);
    expect(insert).toHaveBeenCalledWith(
      expect.objectContaining({ recordedAt: "2026-08-01T09:00:00.000Z" }),
    );
  });

  it("does not clobber an input that already carries its own recordedAt", async () => {
    const queue = [
      {
        id: "a",
        queuedAt: "2026-08-01T09:00:00.000Z",
        userId: "user-1",
        input: { ...rec("a"), recordedAt: "2026-08-01T08:30:00.000Z" },
      },
    ];
    const insert = vi.fn().mockResolvedValue({});
    await drainQueue(queue, "user-1", insert);
    expect(insert).toHaveBeenCalledWith(
      expect.objectContaining({ recordedAt: "2026-08-01T08:30:00.000Z" }),
    );
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

  // #484 F1 end to end through the production entry point (not just
  // `drainQueue` in isolation): a constraint-rejected entry must NOT be
  // deleted — it stays queued, excluded from the "recovered" count a caller
  // would toast, but still readable on the next drain, carrying the
  // rejection it just picked up.
  it("retains a constraint-rejected entry in the queue instead of deleting it, and excludes it from the recovered count", async () => {
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

    expect(recovered).toBe(1); // only "good" — a fresh rejection is not a recovery
    // "bad" is still here — not deleted on the first (or any) server response —
    // now carrying a rejection stamp for the next drain to see.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["bad"]);
    expect(loadQueue(storage)[0]?.rejection).toMatchObject({ code: "23514", stuck: false });
    // #264 is for recordings that have no durable home. This one does — it's
    // sitting right there in the queue — so nothing is reported as lost.
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });

  // The other half: once a rejection survives an app-version change, the
  // entry moves to `stuck` — still retained, but no longer auto-attempted —
  // and a subsequent drain must not even try inserting it again.
  it("stops auto-attempting an entry once its rejection survives an app-version change, without ever deleting it", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("bad"), "user-1"), storage);
    const rejected = { code: "23514", message: "violates check constraint" };

    const insert1 = vi.fn().mockRejectedValue(rejected);
    await drainPendingRecordingsQueue(
      "user-1",
      insert1,
      noDb,
      storage,
      () => "t1",
      () => "build-1",
    );
    expect(loadQueue(storage)[0]?.rejection?.stuck).toBe(false);

    const insert2 = vi.fn().mockRejectedValue(rejected);
    const recovered = await drainPendingRecordingsQueue(
      "user-1",
      insert2,
      noDb,
      storage,
      () => "t2",
      () => "build-2", // a deploy happened between the two drains
    );
    expect(recovered).toBe(0);
    expect(insert2).toHaveBeenCalledTimes(1); // one more attempt, THEN it latches
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["bad"]); // still retained
    expect(loadQueue(storage)[0]?.rejection?.stuck).toBe(true);

    // A third drain must not even try — it's stuck.
    const insert3 = vi.fn();
    await drainPendingRecordingsQueue("user-1", insert3, noDb, storage);
    expect(insert3).not.toHaveBeenCalled();
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["bad"]); // still not deleted
  });

  // R2-F1 — PROVED. A lane-only entry is lane-only precisely BECAUSE
  // `absorbSyncLane`'s own `db.put` already failed once (the two failures are
  // CORRELATED, not independent) — so when the drain re-attempts persisting
  // its fresh rejection stamp via `db.put` and that ALSO fails, the entry
  // must not be removed from the lane on the mere attempt. Before the fix,
  // the removal was gated on `db` merely being non-null, not on the put
  // having committed — this test fails against that shape (the entry vanishes
  // from BOTH stores: not in the lane, and never landed in IndexedDB either).
  it("does not remove a lane-only entry from the lane when persisting its rejection stamp fails", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("bad"), "user-1"), storage);
    // Both `absorbSyncLane`'s migration attempt AND the drain's own re-attempt
    // to persist the rejection stamp go through this same refusing `put`.
    const { loader, map } = fakeDb([], () => quotaError());

    const insert = vi.fn().mockRejectedValue({ code: "23514", message: "violates check constraint" });
    const recovered = await drainPendingRecordingsQueue("user-1", insert, loader, storage);

    expect(recovered).toBe(0);
    // Still there — in the ONE store that ever held it.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["bad"]);
    expect(loadQueue(storage)[0]?.rejection).toMatchObject({ code: "23514", stuck: false });
    expect([...map.keys()]).toEqual([]); // never made it into IndexedDB either
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
  // Always scoped to an account — `clearRecordingQueue` no longer accepts
  // `null` at all (#492 F1); see the "scoping (#484 F3)" block below for the
  // property scoping exists to protect. There is deliberately no unscoped
  // variant any more (R2-F1, round-2 review): a whole-device wipe primitive
  // with no `isUserSignOutPending` gate and no structural pin was a second,
  // unguarded deletion site waiting for its first caller — see the doc
  // comment above `clearRecordingQueue` in `recordingQueue.ts`.

  it("empties BOTH stores for the account, not just the main one", async () => {
    const storage = fakeStorage();
    const { loader, map } = fakeDb(queueOf("idb-1", "idb-2"));
    saveQueue(queueOf("lane-1"), storage);

    expect(await clearRecordingQueue("user-1", loader, storage)).toBe(3);
    expect([...map.keys()]).toEqual([]);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("counts an entry sitting in both stores once", async () => {
    const storage = fakeStorage();
    const lane = queueOf("legacy-1");
    saveQueue(lane, storage);
    const { loader } = fakeDb(lane);
    expect(await clearRecordingQueue("user-1", loader, storage)).toBe(1);
  });

  it("still clears the lane when IndexedDB isn't there at all", async () => {
    const storage = fakeStorage();
    saveQueue(queueOf("lane-1", "lane-2"), storage);
    expect(await clearRecordingQueue("user-1", noDb, storage)).toBe(2);
    expect(loadQueue(storage)).toEqual([]);
  });

  it("reports what it actually removed, not what it was asked to", async () => {
    // A store that refuses the delete must not be counted as emptied — the
    // sign-out path reports the gap rather than assuming success.
    const storage = fakeStorage();
    const { db } = fakeDb(queueOf("idb-1", "idb-2"));
    const refusing: RecordingDb = { ...db, delete: () => Promise.reject(quotaError()) };
    saveQueue(queueOf("lane-1"), storage);

    expect(await clearRecordingQueue("user-1", () => Promise.resolve(refusing), storage)).toBe(
      1,
    );
    expect(loadQueue(storage)).toEqual([]);
  });

  it("is a no-op on an empty queue", async () => {
    const storage = fakeStorage();
    const { loader } = fakeDb();
    expect(await clearRecordingQueue("user-1", loader, storage)).toBe(0);
  });

  it("empties a real IndexedDB store", async () => {
    const storage = fakeStorage();
    const db = await openRecordingDb(new IDBFactory());
    if (!db) throw new Error("expected fake-indexeddb to open");
    const loader: RecordingDbLoader = () => Promise.resolve(db);
    await persistRecordingDurable(rec("id-1"), "user-1", loader, storage);
    await persistRecordingDurable(rec("id-2"), "user-1", loader, storage);

    expect(await clearRecordingQueue("user-1", loader, storage)).toBe(2);
    expect(await db.getAll()).toEqual([]);
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(0);
  });

  // #484 F3 — PROVED. Before this fix, `clearRecordingQueue` had no `userId`
  // parameter at all and always wiped the WHOLE store, so a sign-out
  // remainder prompt showing account A's own N (already scoped, #484 F5)
  // would delete N plus every other account's stranded entries on "Delete
  // and sign out" — silently, with no notice, no toast, no monitoring event
  // (`signOut.ts`'s incomplete-discard report only fires when `discarded <
  // remaining`, which a bigger-than-asked-for delete never trips).
  describe("scoping to an account", () => {
    it("does not touch another account's stranded entries when scoped", async () => {
      const storage = fakeStorage();
      const mine = queueOf("mine-1"); // queueOf stamps "user-1"
      const theirs = enqueueRecording([], rec("theirs-1"), "user-2", () => "t");
      const { loader, map } = fakeDb([...mine, ...theirs]);
      saveQueue(queueOf("mine-lane"), storage);

      expect(await clearRecordingQueue("user-1", loader, storage)).toBe(2); // mine-1 + mine-lane
      expect([...map.keys()]).toEqual(["theirs-1"]); // untouched — the whole point
      expect(loadQueue(storage)).toEqual([]);
    });

    it("still clears unattributed legacy (userId: null) entries when scoped, matching the count", async () => {
      const storage = fakeStorage();
      const legacy = enqueueRecording([], rec("legacy"), null, () => "t");
      const { loader, map } = fakeDb(legacy);
      expect(await clearRecordingQueue("user-1", loader, storage)).toBe(1);
      expect([...map.keys()]).toEqual([]);
    });

    // #492 F1 / R2-F1 (review): `clearRecordingQueue` no longer accepts
    // `null` at all, and there is deliberately no separate unscoped
    // primitive any more either (R2-F1: an earlier version of this fix kept
    // one under its own name, but it had no sign-out-marker gate and no
    // structural pin — see `recordingQueue.ts`'s doc comment above
    // `clearRecordingQueue`). The `@ts-expect-error` below is itself the
    // regression guard: if `userId`'s type is ever widened back to `string |
    // null`, this line stops being an error and `tsc --noEmit` fails on the
    // now-unused directive — a compile-time pin, not a runtime assertion.
    it("does not accept a null userId — enforced at the type level", () => {
      // @ts-expect-error — userId is `string`, not `string | null`.
      void clearRecordingQueue(null, noDb, fakeStorage());
    });

    // R2-F3 — PROVED. The IndexedDB half of scoping was pinned, but the
    // LANE half wasn't: `mine`'s filter is exercised here with BOTH accounts'
    // entries sitting in the lane (`noDb`, so there is no IndexedDB path to
    // fall back on), which the earlier tests never did. The lane is the
    // salvage-on-unmount store (#269) — the one holding a recording that
    // reached no other store — so an unscoped lane wipe during account B's
    // sign-out is the worst version of F3's failure scenario.
    it("does not touch another account's entries sitting in the LANE when scoped", async () => {
      const storage = fakeStorage();
      const mine = queueOf("mine-lane");
      const theirs = enqueueRecording(mine, rec("theirs-lane"), "user-2", () => "t");
      saveQueue(theirs, storage);

      expect(await clearRecordingQueue("user-1", noDb, storage)).toBe(1); // only mine-lane
      expect(loadQueue(storage).map((p) => p.id)).toEqual(["theirs-lane"]); // untouched
    });
  });
});

describe("pendingRecordingsBreakdown (#484)", () => {
  it("splits pending vs stuck, and pendingRecordingsCount is their sum", async () => {
    const stuckEntry: PendingRecording = {
      id: "stuck-1",
      queuedAt: "t",
      userId: "user-1",
      input: rec("stuck-1"),
      rejection: {
        code: "23514",
        message: "violates check constraint",
        firstVersion: "build-1",
        firstAt: "t1",
        lastVersion: "build-2",
        lastAt: "t2",
        stuck: true,
      },
    };
    const { loader } = fakeDb([...queueOf("pending-1", "pending-2"), stuckEntry]);
    const storage = fakeStorage();

    expect(await pendingRecordingsBreakdown("user-1", loader, storage)).toEqual({
      pending: 2,
      stuck: 1,
    });
    expect(await pendingRecordingsCount("user-1", loader, storage)).toBe(3);
  });

  it("is all-zero with nothing queued", async () => {
    expect(await pendingRecordingsBreakdown("user-1", noDb, fakeStorage())).toEqual({
      pending: 0,
      stuck: 0,
    });
  });
});

describe("retryStuckRecordings (#484 — the explicit-user-action re-attempt path)", () => {
  function stuckEntry(id: string, userId: string | null): PendingRecording {
    return {
      id,
      queuedAt: "t",
      userId,
      input: rec(id),
      rejection: {
        code: "23514",
        message: "violates check constraint",
        firstVersion: "build-1",
        firstAt: "t1",
        lastVersion: "build-2",
        lastAt: "t2",
        stuck: true,
      },
    };
  }

  it("clears the rejection (not just the stuck flag) so the next drain treats it as fresh", async () => {
    const { loader, map } = fakeDb([stuckEntry("a", "user-1")]);
    const storage = fakeStorage();

    expect(await retryStuckRecordings("user-1", loader, storage)).toBe(1);
    expect(map.get("a")).toEqual({
      id: "a",
      queuedAt: "t",
      userId: "user-1",
      input: rec("a"),
    });
    expect(await pendingRecordingsBreakdown("user-1", loader, storage)).toEqual({
      pending: 1,
      stuck: 0,
    });
  });

  it("does not touch another account's stuck entries", async () => {
    const { loader, map } = fakeDb([stuckEntry("mine", "user-1"), stuckEntry("theirs", "user-2")]);
    const storage = fakeStorage();

    expect(await retryStuckRecordings("user-1", loader, storage)).toBe(1);
    expect(map.get("theirs")?.rejection?.stuck).toBe(true); // untouched
  });

  it("clears a stuck entry sitting in the sync lane too", async () => {
    const storage = fakeStorage();
    saveQueue([stuckEntry("lane-1", "user-1")], storage);
    const { loader } = fakeDb();

    expect(await retryStuckRecordings("user-1", loader, storage)).toBe(1);
    expect(loadQueue(storage)[0]?.rejection).toBeUndefined();
  });

  it("is a no-op when nothing is stuck", async () => {
    const { loader } = fakeDb(queueOf("pending-1"));
    expect(await retryStuckRecordings("user-1", loader, fakeStorage())).toBe(0);
  });

  it("makes the entry attemptable again on the next drain", async () => {
    const storage = fakeStorage();
    const { loader } = fakeDb([stuckEntry("a", "user-1")]);
    await retryStuckRecordings("user-1", loader, storage);

    const insert = vi.fn().mockResolvedValue({});
    expect(await drainPendingRecordingsQueue("user-1", insert, loader, storage)).toBe(1);
    expect(insert).toHaveBeenCalledTimes(1);
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

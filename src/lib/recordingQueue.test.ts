import { describe, it, expect, vi } from "vitest";
import {
  MAX_QUEUE_BYTES,
  drainPendingRecordingsQueue,
  drainQueue,
  enqueueRecording,
  loadQueue,
  saveQueue,
  type PendingRecording,
} from "./recordingQueue";
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

describe("drainPendingRecordingsQueue", () => {
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

    let resolveInsert: () => void = () => {};
    const insert = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveInsert = resolve;
        }),
    );

    const drain = drainPendingRecordingsQueue("user-1", insert, storage);
    // A NEW failure gets queued (synchronously) while "a"'s insert is still
    // in flight — simulates ForceView.queueFailedRecording racing the drain.
    saveQueue(enqueueRecording(loadQueue(storage), rec("b"), "user-1"), storage);

    resolveInsert();
    expect(await drain).toBe(1);
    // "a" succeeded and is gone; "b" (queued mid-drain) must survive.
    expect(loadQueue(storage).map((p) => p.id)).toEqual(["b"]);
  });

  it("guards against a second concurrent drain double-inserting", async () => {
    const storage = fakeStorage();
    saveQueue(enqueueRecording([], rec("a"), "user-1"), storage);

    let resolveInsert: () => void = () => {};
    const insert = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveInsert = resolve;
        }),
    );

    const first = drainPendingRecordingsQueue("user-1", insert, storage);
    // Fires while the first drain is still in flight — must be a no-op.
    const second = await drainPendingRecordingsQueue("user-1", insert, storage);
    expect(second).toBe(0);

    resolveInsert();
    expect(await first).toBe(1);
    expect(insert).toHaveBeenCalledTimes(1);
  });
});

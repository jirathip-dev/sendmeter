import { describe, it, expect } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import { isQuotaError, openRecordingDb, type RecordingDb } from "./recordingDb";
import type { PendingRecording } from "./pendingRecording";
import type { NewTindeqRecording } from "../types";

// These exercise the REAL adapter — the promise wrapping, the transaction
// atomicity, the ordering and the degrade-to-null contract — against
// fake-indexeddb rather than a stub, so the IndexedDB half of #269 isn't taken
// on trust.
//
// What fake-indexeddb CANNOT answer, and is therefore covered by the Chrome
// harness instead (see the PR's verification section):
//   * a real quota refusal, which arrives asynchronously via a request's
//     `onerror`/the transaction's `onabort` rather than as the synchronous
//     throw a fake produces. That is the path the eviction backstop hangs off,
//     so it was driven against a CDP-capped origin quota in real Chrome.
//   * that `put` resolves on transaction COMMIT and not on request success —
//     provable here only indirectly (the atomicity test below), and shown
//     directly in the browser by timing the two events apart.

function input(id: string): NewTindeqRecording & { id: string } {
  return {
    id,
    durationMs: 7000,
    peakKg: 32.1,
    avgKg: 28.4,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: "group-1",
    protocolRunId: null,
    setNo: null,
    zone: null,
    samples: [
      { t: 0, kg: 10 },
      { t: 500, kg: 12 },
    ],
  };
}

function entry(id: string, queuedAt: string): PendingRecording {
  return { id, queuedAt, userId: "user-1", input: input(id) };
}

/// A fresh, isolated database per test — `openRecordingDb` bypasses its
/// module-level memo when handed a factory explicitly.
async function freshDb(): Promise<RecordingDb> {
  const db = await openRecordingDb(new IDBFactory());
  if (!db) throw new Error("expected fake-indexeddb to open");
  return db;
}

describe("openRecordingDb — degrading instead of throwing", () => {
  it("resolves null when there is no IndexedDB at all (private mode)", async () => {
    expect(await openRecordingDb(null)).toBe(null);
  });

  it("resolves null — never rejects — when open() throws synchronously", async () => {
    const factory = {
      open: () => {
        throw new Error("SecurityError: storage is disabled");
      },
    } as unknown as IDBFactory;
    expect(await openRecordingDb(factory)).toBe(null);
  });

  it("resolves null when the open request errors", async () => {
    const factory = {
      open: () => {
        const req: Record<string, unknown> = { error: new Error("nope") };
        setTimeout(() => (req.onerror as () => void)(), 0);
        return req;
      },
    } as unknown as IDBFactory;
    expect(await openRecordingDb(factory)).toBe(null);
  });

  it("resolves null when the open is blocked by another connection", async () => {
    const factory = {
      open: () => {
        const req: Record<string, unknown> = {};
        setTimeout(() => (req.onblocked as () => void)(), 0);
        return req;
      },
    } as unknown as IDBFactory;
    expect(await openRecordingDb(factory)).toBe(null);
  });

  it("opens a real database and creates the store", async () => {
    const db = await freshDb();
    expect(await db.getAll()).toEqual([]);
    expect(await db.keys()).toEqual([]);
  });
});

describe("RecordingDb round-trip", () => {
  it("stores and returns entries whole, including the samples", async () => {
    const db = await freshDb();
    const e = entry("a", "2026-07-01T00:00:00.000Z");
    await db.put([e]);
    expect(await db.getAll()).toEqual([e]);
  });

  it("returns entries OLDEST FIRST regardless of key order", async () => {
    const db = await freshDb();
    // Ids sort the opposite way to the timestamps, so key order alone would
    // get this backwards — which is what the eviction and drain order rely on.
    await db.put([
      entry("z", "2026-07-01T00:00:00.000Z"),
      entry("a", "2026-07-03T00:00:00.000Z"),
      entry("m", "2026-07-02T00:00:00.000Z"),
    ]);
    expect((await db.getAll()).map((p) => p.id)).toEqual(["z", "m", "a"]);
  });

  it("overwrites on a repeated id rather than adding a second copy", async () => {
    const db = await freshDb();
    const e = entry("a", "2026-07-01T00:00:00.000Z");
    await db.put([e]);
    await db.put([e]);
    // This is what makes an interrupted migration safe to re-run.
    expect(await db.keys()).toEqual(["a"]);
  });

  it("drops records that don't parse as a recording instead of failing the read", async () => {
    const db = await freshDb();
    await db.put([entry("good", "2026-07-01T00:00:00.000Z")]);
    // A record from some older/other build.
    await db.put([{ id: "junk" } as unknown as PendingRecording]);
    expect((await db.getAll()).map((p) => p.id)).toEqual(["good"]);
    // …still counted by keys(), which is deliberately payload-blind.
    expect((await db.keys()).sort()).toEqual(["good", "junk"]);
  });

  it("deletes by id, and treats a missing id as a no-op", async () => {
    const db = await freshDb();
    await db.put([
      entry("a", "2026-07-01T00:00:00.000Z"),
      entry("b", "2026-07-02T00:00:00.000Z"),
    ]);
    await db.delete(["a", "never-existed"]);
    expect(await db.keys()).toEqual(["b"]);
  });

  it("treats empty put/delete as no-ops", async () => {
    const db = await freshDb();
    await db.put([]);
    await db.delete([]);
    expect(await db.keys()).toEqual([]);
  });

  it("writes a batch atomically — one bad record lands NONE of them", async () => {
    const db = await freshDb();
    const bad = {
      ...entry("bad", "2026-07-02T00:00:00.000Z"),
      // A function can't be structured-cloned; the request fails and aborts
      // the transaction. This is the property the migration depends on: a
      // half-copied lane that then got cleared would lose the other half.
      input: { ...input("bad"), oops: () => {} },
    } as unknown as PendingRecording;
    await expect(
      db.put([entry("good", "2026-07-01T00:00:00.000Z"), bad]),
    ).rejects.toBeTruthy();
    expect(await db.keys()).toEqual([]);
  });
});

describe("isQuotaError", () => {
  it("recognises the REAL object a full store rejects with", () => {
    // Not a hand-rolled stand-in: this is the exact shape observed coming out
    // of Blink against a CDP-capped origin quota — a DOMException named
    // QuotaExceededError, with an EMPTY message. Matching on the message would
    // have looked fine here and failed on a device.
    const real = new DOMException("", "QuotaExceededError");
    expect(real.message).toBe("");
    expect(isQuotaError(real)).toBe(true);
    expect(isQuotaError(new DOMException("", "NS_ERROR_DOM_QUOTA_REACHED"))).toBe(true);
  });

  it("does not mistake other failures for a full store", () => {
    // Evicting queued reps to work around one of these would be pure loss.
    expect(isQuotaError(new DOMException("could not be cloned", "DataCloneError"))).toBe(
      false,
    );
    expect(isQuotaError(new Error("plain"))).toBe(false);
    expect(isQuotaError(null)).toBe(false);
    expect(isQuotaError("QuotaExceededError")).toBe(false);
  });
});

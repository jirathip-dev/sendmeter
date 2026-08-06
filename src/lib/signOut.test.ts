import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";

// `signOut.ts` imports `./supabase`, whose module-level `createClient(...)`
// constructs a RealtimeClient that throws under Node <22 (no native
// `WebSocket`) — same situation and same fix as useTrainingData.test.ts.
// Every test below injects its own `signOut`/`insert` doubles via
// `SignOutDeps`; the real client is never exercised.
vi.mock("./supabase", () => ({
  supabase: { auth: { signOut: vi.fn() } },
}));

import {
  DRAIN_TIMEOUT_MS,
  discardQueueOnUserSignOut,
  signOutUser,
  type QueueRemainderChoice,
  type SignOutDeps,
} from "./signOut";
import {
  markUserSignOut,
  recordAuthStateChange,
  setDiagnosticsClock,
} from "./authDiagnostics";
import { openRecordingDb, type RecordingDbLoader } from "./recordingDb";
import {
  clearRecordingQueue,
  drainPendingRecordingsQueue,
  loadQueue,
  pendingRecordingsCount,
  persistRecording,
  persistRecordingDurable,
} from "./recordingQueue";
import type { NewTindeqRecording } from "../types";

// #273 — the sign-out path, exercised against REAL stores (fake-indexeddb's
// IndexedDB and an in-memory localStorage) and the REAL sign-out marker from
// `authDiagnostics`. Only the two things that reach the network — the insert
// and `supabase.auth.signOut()` — are doubles.
//
// The marker is deliberately not faked. The property under test is "a sign-out
// the user did not ask for never discards anything", and that property IS the
// marker; a test that stubbed it would be testing its own stub.

function rec(id: string): NewTindeqRecording & { id: string } {
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
      { t: 500, kg: 11 },
    ],
  };
}

function fakeStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
  };
}

const USER = "user-1";

/// A fresh pair of stores plus deps that bind the real queue functions to
/// them. `insert` and `signOut` are the doubles; everything else is production
/// code operating on production stores.
async function harness(
  insert: (input: NewTindeqRecording & { id: string }) => Promise<unknown>,
) {
  const storage = fakeStorage();
  const db = await openRecordingDb(new IDBFactory());
  if (!db) throw new Error("expected fake-indexeddb to open");
  const loader: RecordingDbLoader = () => Promise.resolve(db);
  /// Every network-ish step in the order it happened — the drain finishing
  /// BEFORE the session is torn down is a correctness property, not a detail.
  const calls: string[] = [];
  const signOut = vi.fn(() => {
    calls.push("sign-out");
    return Promise.resolve({ error: null });
  });
  const report = vi.fn();
  const deps: SignOutDeps = {
    insert: (input) => {
      calls.push(`insert:${input.id}`);
      return insert(input);
    },
    drain: (userId, ins) => drainPendingRecordingsQueue(userId, ins, loader, storage),
    count: () => pendingRecordingsCount(USER, loader, storage),
    clear: () => clearRecordingQueue(loader, storage),
    signOut,
    report,
  };
  return {
    db,
    storage,
    loader,
    deps,
    calls,
    signOut,
    report,
    queue: async () => {
      const main = (await db.keys()).sort();
      const lane = loadQueue(storage).map((p) => p.id);
      return { main, lane };
    },
  };
}

const ok = () => Promise.resolve({});
const offline = () => Promise.reject(new Error("Failed to fetch"));

let now = 1_000_000;

beforeEach(() => {
  // Move well past any mark a previous test left behind (the marker is module
  // state with a TTL, and there is no reset by design — see #202).
  now += 10_000_000;
  setDiagnosticsClock(() => now);
});

afterEach(() => {
  setDiagnosticsClock(() => Date.now());
});

describe("signOutUser — nothing queued", () => {
  it("signs out with no prompt and nothing to upload", async () => {
    const h = await harness(ok);
    const onRemainder = vi.fn<() => QueueRemainderChoice>(() => "keep");

    const outcome = await signOutUser({ userId: USER, onRemainder }, h.deps);

    expect(onRemainder).not.toHaveBeenCalled();
    expect(outcome).toMatchObject({
      signedOut: true,
      uploaded: 0,
      remaining: 0,
      discarded: 0,
      timedOut: false,
    });
    expect(h.signOut).toHaveBeenCalledOnce();
    expect(await h.queue()).toEqual({ main: [], lane: [] });
  });
});

describe("signOutUser — a user-initiated sign-out that fully drains", () => {
  it("uploads everything first, leaves both stores empty, and never prompts", async () => {
    const h = await harness(ok);
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);
    await persistRecordingDurable(rec("idb-2"), USER, h.loader, h.storage);
    // …and one that only ever reached the synchronous salvage lane.
    expect(persistRecording(rec("lane-1"), USER, h.storage).persisted).toBe(true);
    expect(await pendingRecordingsCount(USER, h.loader, h.storage)).toBe(3);

    const onRemainder = vi.fn<() => QueueRemainderChoice>(() => "keep");
    const outcome = await signOutUser({ userId: USER, onRemainder }, h.deps);

    expect(outcome).toMatchObject({
      signedOut: true,
      uploaded: 3,
      remaining: 0,
      discarded: 0,
    });
    expect(onRemainder).not.toHaveBeenCalled();
    // The whole point of draining first: every insert happens while the
    // session is still alive. Reversed, they would all 401.
    expect(h.calls).toEqual([
      "insert:idb-1",
      "insert:idb-2",
      "insert:lane-1",
      "sign-out",
    ]);
    // Uploaded, so cleared — the privacy property, with no prompt and no loss.
    expect(await h.queue()).toEqual({ main: [], lane: [] });
  });
});

describe("signOutUser — an undrainable remainder", () => {
  /// Two entries that cannot upload, one in each store, so every assertion
  /// below is about both lanes rather than the main queue alone.
  async function stuck() {
    const h = await harness(offline);
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);
    expect(persistRecording(rec("lane-1"), USER, h.storage).persisted).toBe(true);
    return h;
  }

  it("prompts with the count and, on keep, signs out with the queue intact", async () => {
    const h = await stuck();
    const onRemainder = vi.fn<() => QueueRemainderChoice>(() => "keep");

    const outcome = await signOutUser({ userId: USER, onRemainder }, h.deps);

    expect(onRemainder).toHaveBeenCalledExactlyOnceWith(2);
    expect(outcome).toMatchObject({
      signedOut: true,
      uploaded: 0,
      remaining: 2,
      discarded: 0,
    });
    expect(h.signOut).toHaveBeenCalledOnce();
    // The accepted residual: kept entries stay until this account signs back
    // in. The absorb during the drain moved the lane entry into the main
    // store, which is where it will be retried from.
    expect(await h.queue()).toEqual({ main: ["idb-1", "lane-1"], lane: [] });
  });

  it("on discard, clears BOTH stores and then signs out", async () => {
    const h = await stuck();
    // Put something back in the lane after the absorb, so the discard has to
    // clear a genuinely non-empty lane and not just an empty one.
    expect(persistRecording(rec("lane-2"), USER, h.storage).persisted).toBe(true);
    const onRemainder = vi.fn<() => QueueRemainderChoice>(() => "discard");

    const outcome = await signOutUser({ userId: USER, onRemainder }, h.deps);

    expect(outcome).toMatchObject({ signedOut: true, remaining: 3, discarded: 3 });
    expect(await h.queue()).toEqual({ main: [], lane: [] });
    expect(h.signOut).toHaveBeenCalledOnce();
    expect(h.report).not.toHaveBeenCalled();
  });

  it("on cancel, stays signed in and touches nothing", async () => {
    const h = await stuck();

    const outcome = await signOutUser(
      { userId: USER, onRemainder: () => "cancel" },
      h.deps,
    );

    expect(outcome).toMatchObject({ signedOut: false, discarded: 0, remaining: 2 });
    expect(h.signOut).not.toHaveBeenCalled();
    expect(await h.queue()).toEqual({ main: ["idb-1", "lane-1"], lane: [] });
    // No mark either — an abandoned sign-out must not leave a marker lying
    // around that a revocation minutes later could be absolved by.
    expect(await discardQueueOnUserSignOut(h.deps)).toBe(0);
    expect(await h.queue()).toEqual({ main: ["idb-1", "lane-1"], lane: [] });
  });

  it("says so when a discard could not remove everything", async () => {
    const h = await stuck();
    const outcome = await signOutUser(
      { userId: USER, onRemainder: () => "discard" },
      { ...h.deps, clear: () => Promise.resolve(1) }, // one store refused
    );

    expect(outcome).toMatchObject({ remaining: 2, discarded: 1 });
    expect(h.report).toHaveBeenCalledWith(
      "tindeq-queue: discard-on-signout-incomplete",
      { requested: 2, discarded: 1 },
    );
  });

  it("falls through to the prompt rather than hanging on a slow network", async () => {
    // An insert that never settles — the case the deadline exists for.
    const h = await harness(() => new Promise(() => {}));
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);
    const onRemainder = vi.fn<() => QueueRemainderChoice>(() => "keep");

    const outcome = await signOutUser(
      { userId: USER, onRemainder },
      { ...h.deps, timeoutMs: 20 },
    );

    expect(outcome).toMatchObject({
      signedOut: true,
      timedOut: true,
      uploaded: 0,
      remaining: 1,
    });
    expect(onRemainder).toHaveBeenCalledExactlyOnceWith(1);
    expect(h.signOut).toHaveBeenCalledOnce();
    expect(await h.queue()).toEqual({ main: ["idb-1"], lane: [] });
  });

  it("gives the drain a deadline measured in seconds, not minutes", () => {
    // A sign-out has to stay completable. Pinned because the failure mode of
    // getting this wrong is a button that appears to do nothing.
    expect(DRAIN_TIMEOUT_MS).toBeGreaterThanOrEqual(2000);
    expect(DRAIN_TIMEOUT_MS).toBeLessThanOrEqual(15_000);
  });
});

describe("a forced sign-out never discards anything", () => {
  // The test the issue asks for: the one that fails if the two paths are ever
  // merged into a flat "clear on sign-out". #265 was a real production session
  // revocation with no user action behind it — under that rule it would have
  // destroyed every unsynced rep on the device.

  it("refuses to discard when the user did not ask to sign out", async () => {
    const h = await harness(offline);
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);
    expect(persistRecording(rec("lane-1"), USER, h.storage).persisted).toBe(true);

    // What a revocation looks like from the app's side: auth-js emits
    // SIGNED_OUT on its own, with no marker set by anyone. Asserting the
    // classification first, so this really is the forced path and not a
    // user-initiated one with the mark forgotten.
    expect(recordAuthStateChange("SIGNED_OUT", { storage: null })).toBe("revoked");

    expect(await discardQueueOnUserSignOut(h.deps)).toBe(0);
    expect(await h.queue()).toEqual({ main: ["idb-1"], lane: ["lane-1"] });
  });

  it("is not absolved by a stale mark from an earlier sign-out", async () => {
    const h = await harness(offline);
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);

    markUserSignOut();
    now += 60_000; // the mark's TTL is 15 s

    expect(await discardQueueOnUserSignOut(h.deps)).toBe(0);
    expect(await h.queue()).toEqual({ main: ["idb-1"], lane: [] });
  });

  it("still discards for the sign-out the user is actually taking", async () => {
    // The other half of the same invariant: the guard must not be so strict it
    // never fires, or "we never discard" would pass for the wrong reason.
    const h = await harness(offline);
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);

    markUserSignOut();
    expect(await discardQueueOnUserSignOut(h.deps)).toBe(1);
    expect(await h.queue()).toEqual({ main: [], lane: [] });
  });
});

describe("signOutUser — account deletion", () => {
  it("discards without attempting an upload or asking", async () => {
    const h = await harness(ok);
    await persistRecordingDurable(rec("idb-1"), USER, h.loader, h.storage);
    expect(persistRecording(rec("lane-1"), USER, h.storage).persisted).toBe(true);
    const onRemainder = vi.fn<() => QueueRemainderChoice>(() => "keep");

    const outcome = await signOutUser(
      { userId: null, queue: "discard", onRemainder },
      h.deps,
    );

    // The account's rows are gone server-side; there is nothing to upload into
    // and nothing to ask about.
    expect(h.calls).toEqual(["sign-out"]);
    expect(onRemainder).not.toHaveBeenCalled();
    expect(outcome).toMatchObject({ signedOut: true, discarded: 2 });
    expect(await h.queue()).toEqual({ main: [], lane: [] });
    // `remaining` is 0 on this path (nothing was measured), so the
    // incomplete-discard report must not fire off it.
    expect(h.report).not.toHaveBeenCalled();
  });
});

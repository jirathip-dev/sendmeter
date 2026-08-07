import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import type { NewTindeqRecording } from "../../types";

// #492 F1 (review) — the end-to-end proof the implementer's own HANDOFF.md
// admitted skipping: drives the REAL `deleteAccount()` all the way through
// the REAL `signOutUser` → `discardQueueOnUserSignOut` → `clearRecordingQueue`
// chain, against a REAL IndexedDB (fake-indexeddb, installed as the global
// `deleteAccount()`'s default deps resolve to via `openRecordingDb()`) and a
// real in-memory `localStorage` (the sync lane). Only `../supabase` is
// faked (`auth.getSession` / `rpc` / `auth.signOut`) — everything else,
// including the sign-out marker (`markUserSignOut`/`isUserSignOutPending`)
// that gates the discard, is production code.
//
// This is what caught F1: the unit-level `settings.test.ts` (mocks
// `signOutUser` itself) proves `deleteAccount()` PASSES the right argument;
// it cannot prove what happens to a SECOND account's data when that argument
// is wrong. This file proves the actual consequence, in both directions.

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

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
    key: () => null,
    get length() {
      return map.size;
    },
  } as Storage;
}

const h = vi.hoisted(() => ({
  session: null as { user: { id: string } } | null,
  rpcResult: { data: null as unknown, error: null as unknown },
  signOutCalls: 0,
}));

vi.mock("../supabase", () => ({
  supabase: {
    auth: {
      getSession: () => Promise.resolve({ data: { session: h.session }, error: null }),
      signOut: () => {
        h.signOutCalls += 1;
        return Promise.resolve({ error: null });
      },
    },
    rpc: (name: string) => {
      if (name !== "delete_account") {
        throw new Error(`deleteAccount.e2e.test.ts fake doesn't know rpc: ${name}`);
      }
      return Promise.resolve(h.rpcResult);
    },
  },
}));

const { deleteAccount } = await import("./settings");
const { persistRecordingDurable, persistRecording, pendingRecordingsCount } = await import(
  "../recordingQueue"
);
const { resetRecordingDbCache } = await import("../recordingDb");

beforeEach(() => {
  h.session = null;
  h.rpcResult = { data: null, error: null };
  h.signOutCalls = 0;
  resetRecordingDbCache();
  Object.defineProperty(globalThis, "indexedDB", {
    value: new IDBFactory(),
    configurable: true,
  });
  Object.defineProperty(globalThis, "localStorage", {
    value: memoryStorage(),
    configurable: true,
  });
});

afterEach(() => {
  resetRecordingDbCache();
  Reflect.deleteProperty(globalThis, "indexedDB");
  Reflect.deleteProperty(globalThis, "localStorage");
});

/// Seeds A with 2 IndexedDB entries + 1 lane entry (3 total), B with 1
/// IndexedDB entry + 1 lane entry (2 total) — both stores, both accounts, so
/// nothing here is provable by accident.
async function seedTwoAccounts() {
  await persistRecordingDurable(rec("a-idb-1"), "user-A");
  await persistRecordingDurable(rec("a-idb-2"), "user-A");
  expect(persistRecording(rec("a-lane"), "user-A").persisted).toBe(true);
  await persistRecordingDurable(rec("b-idb-1"), "user-B");
  expect(persistRecording(rec("b-lane"), "user-B").persisted).toBe(true);
}

describe("deleteAccount() end-to-end (#492 F1)", () => {
  it("PROVED. deleting account B's account destroys only B's queue — A's survives and stays counted", async () => {
    await seedTwoAccounts();
    expect(await pendingRecordingsCount("user-A")).toBe(3);
    expect(await pendingRecordingsCount("user-B")).toBe(2);

    h.session = { user: { id: "user-B" } };

    await deleteAccount();

    expect(await pendingRecordingsCount("user-B")).toBe(0);
    expect(await pendingRecordingsCount("user-A")).toBe(3); // untouched, and still counted for A
    expect(h.signOutCalls).toBe(1);
  });

  it("PROVED. a null session resolution (the getSession()/RPC race) discards NEITHER account's queue", async () => {
    // This models the review's reproduced interleaving: this local
    // `getSession()` read resolves `{ session: null }` (e.g. a token
    // rotation race with another tab) while the `delete_account` RPC's own,
    // independent session read still succeeds.
    await seedTwoAccounts();
    expect(await pendingRecordingsCount("user-A")).toBe(3);
    expect(await pendingRecordingsCount("user-B")).toBe(2);

    h.session = null;
    h.rpcResult = { data: null, error: null }; // the RPC still succeeds

    await deleteAccount(); // must not throw

    // The headline regression this test exists to catch: pre-fix, this
    // resolved with NO error and both counts went to 0 — identical to a
    // real, attributed deletion of EVERYONE's queue. Post-fix, an
    // unattributable discard removes nothing from either account.
    expect(await pendingRecordingsCount("user-A")).toBe(3);
    expect(await pendingRecordingsCount("user-B")).toBe(2);
    expect(h.signOutCalls).toBe(1); // the local session still ends either way
  });
});

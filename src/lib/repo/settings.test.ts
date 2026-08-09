import { beforeEach, describe, expect, it, vi } from "vitest";

// #492 — `deleteAccount()` used to call `signOutUser({ userId: null, queue:
// "discard" })` unconditionally. `null` there is `clearRecordingQueue`'s
// UNSCOPED-WIPE sentinel (see its doc comment in `recordingQueue.ts`), not
// "nothing to scope to" — so on a shared/handed-down device, deleting
// account B's account wiped account A's queued recordings too, with no
// report and no prompt naming them.
//
// `signOut.ts` / `recordingQueue.ts`'s OWN scoping (given a real userId) is
// already proved correct in `signOut.test.ts` and `recordingQueue.test.ts`'s
// "scoping to an account" suite (#484 F3) — the defect lived entirely in
// what THIS module passed in. So this test mocks `../signOut` and asserts
// the exact argument `deleteAccount()` hands it, which is where #492's fix
// belongs and where a regression would reappear.
//
// `../supabase` is mocked for the same reason `tindeq.recalcDuration.test.ts`
// mocks it: the real module's `createClient(...)` builds a RealtimeClient
// that needs a `WebSocket` global not every Node has, and this test has no
// need to exercise the real client.

const h = vi.hoisted(() => ({
  session: { user: { id: "user-A" } } as { user: { id: string } } | null,
  sessionError: null as unknown,
  rpcResult: { data: null as unknown, error: null as unknown },
  order: [] as string[],
  signOutUser: vi.fn(() =>
    Promise.resolve({
      signedOut: true,
      error: null,
      uploaded: 0,
      remaining: 0,
      discarded: 0,
      timedOut: false,
    }),
  ),
  captureDataLoss: vi.fn(),
}));

vi.mock("../supabase", () => ({
  supabase: {
    rpc: (name: string) => {
      if (name !== "delete_account") {
        throw new Error(`settings.test.ts fake doesn't know rpc: ${name}`);
      }
      h.order.push("rpc");
      return Promise.resolve(h.rpcResult);
    },
    auth: {
      getSession: () => {
        h.order.push("getSession");
        return Promise.resolve({ data: { session: h.session }, error: h.sessionError });
      },
    },
  },
}));

vi.mock("../signOut", () => ({ signOutUser: h.signOutUser }));
vi.mock("../monitoring", () => ({ captureDataLoss: h.captureDataLoss }));

const { deleteAccount } = await import("./settings");

beforeEach(() => {
  h.session = { user: { id: "user-A" } };
  h.sessionError = null;
  h.rpcResult = { data: null, error: null };
  h.order = [];
  h.signOutUser.mockClear();
  h.captureDataLoss.mockClear();
});

describe("deleteAccount", () => {
  it("#492 — PROVED. scopes the queue discard to the deleting account, not an unscoped wipe", async () => {
    await deleteAccount();

    // Pre-fix this observed `{ userId: null, queue: "discard" }` — a wrong
    // VALUE (the unscoped-wipe sentinel instead of the deleting user's own
    // id), not a missing symbol.
    expect(h.signOutUser).toHaveBeenCalledExactlyOnceWith({
      userId: "user-A",
      queue: "discard",
    });
  });

  it("captures the user id BEFORE the delete RPC runs, not after", async () => {
    // Matters because after the RPC succeeds, the account row is gone
    // server-side — resolving the id from a POST-delete lookup would be
    // asking the server about a user it just erased.
    await deleteAccount();

    expect(h.order).toEqual(["getSession", "rpc"]);
    expect(h.signOutUser).toHaveBeenCalledExactlyOnceWith({
      userId: "user-A",
      queue: "discard",
    });
  });

  // #492 F3 (review) — the ORIGINAL version of this test was named "falls
  // back to an unscoped discard" and asserted `{ userId: null, queue:
  // "discard" }`, which PASSES against pre-fix `settings.ts` too — it pinned
  // the #492 shape as correct instead of guarding against it. This module
  // has no way to prove "nothing gets wiped" on its own (it mocks
  // `signOutUser` entirely, precisely so it can assert what `deleteAccount`
  // PASSES rather than re-testing `signOutUser`'s own logic) — that
  // property now lives where it can actually be checked: `signOut.test.ts`
  // ("userId: null discards nothing and reports") and
  // `deleteAccount.e2e.test.ts` (real stores, real chain, both accounts'
  // queues proven untouched). This test's job is narrower and honest about
  // it: `deleteAccount()` passes `userId` through AS-IS, including `null` —
  // it invents no fallback of its own, because the actual safety boundary is
  // downstream.
  it("passes userId through as-is (including null) when there is no session to attribute to — safety is downstream, not here", async () => {
    h.session = null;

    await deleteAccount();

    expect(h.signOutUser).toHaveBeenCalledExactlyOnceWith({
      userId: null,
      queue: "discard",
    });
  });

  it("#492 F1 (review) — reports, but does not throw or skip the RPC, when getSession() itself errors", async () => {
    h.session = null;
    h.sessionError = new Error("network error");

    await expect(deleteAccount()).resolves.toBeUndefined();

    // Pre-fix, `getSession()`'s `error` was destructured away and silently
    // discarded — this is the "stop discarding it" fix: the failure is now
    // visible, even though nothing downstream can turn it into an unscoped
    // wipe any more.
    expect(h.captureDataLoss).toHaveBeenCalledWith(
      "account.delete-session-read-failed",
      {},
    );
    expect(h.order).toEqual(["getSession", "rpc"]); // the RPC still runs
    expect(h.signOutUser).toHaveBeenCalledExactlyOnceWith({
      userId: null,
      queue: "discard",
    });
  });
});

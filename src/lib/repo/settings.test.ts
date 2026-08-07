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
        return Promise.resolve({ data: { session: h.session }, error: null });
      },
    },
  },
}));

vi.mock("../signOut", () => ({ signOutUser: h.signOutUser }));

const { deleteAccount } = await import("./settings");

beforeEach(() => {
  h.session = { user: { id: "user-A" } };
  h.rpcResult = { data: null, error: null };
  h.order = [];
  h.signOutUser.mockClear();
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

  it("falls back to an unscoped discard only when there is genuinely no session to attribute to", async () => {
    h.session = null;

    await deleteAccount();

    expect(h.signOutUser).toHaveBeenCalledExactlyOnceWith({
      userId: null,
      queue: "discard",
    });
  });
});

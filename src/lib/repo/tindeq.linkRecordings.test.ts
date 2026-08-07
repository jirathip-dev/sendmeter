import { beforeEach, describe, expect, it, vi } from "vitest";

/// #490: `linkRecordingsToSession` used to perform three separate,
/// non-transactional requests (`.from("sessions").update(...)`, then
/// `.from("tindeq_recordings").update(...)`, then a third round trip inside
/// `recalcTindeqSessionDuration`) — a failure on the 2nd or 3rd left the 1st
/// stranded (proven against a scratch Postgres outside this repo: a forced
/// mid-flow failure left the session re-grouped with zero of the intended
/// recordings actually joined to it). The fix moves all three writes into
/// one DB transaction via `link_tindeq_recordings_to_session` (see
/// supabase/migrations/20260807090000_link_tindeq_recordings_rpc.sql) and
/// this function now does nothing but call it.
///
/// This test pins that structurally: it fails for a REAL reason on pre-fix
/// code (not a missing symbol) — the old implementation calls
/// `supabase.from(...)` (this fake throws if it's ever touched) instead of
/// `supabase.rpc(...)`, so asserting `from` was never called catches the
/// non-atomic three-request shape directly, and asserting the exact `rpc`
/// call args catches a call that silently drops a parameter.
const h = vi.hoisted(() => ({
  rpcResult: { data: null as unknown, error: null as unknown },
}));

const rpc = vi.fn(() => Promise.resolve(h.rpcResult));
const from = vi.fn(() => {
  throw new Error(
    "linkRecordingsToSession must not touch supabase.from(...) directly — " +
      "every write belongs inside the link_tindeq_recordings_to_session RPC.",
  );
});

vi.mock("../supabase", () => ({
  supabase: { rpc, from },
}));

const { linkRecordingsToSession } = await import("./tindeq");

describe("linkRecordingsToSession (#490)", () => {
  beforeEach(() => {
    rpc.mockClear();
    from.mockClear();
    h.rpcResult = { data: null, error: null };
  });

  it("does nothing for an empty recording list — no RPC call at all", async () => {
    await linkRecordingsToSession("session-1", []);
    expect(rpc).not.toHaveBeenCalled();
  });

  it("links via exactly one RPC call carrying the session id and every recording id", async () => {
    await linkRecordingsToSession("session-1", ["rec-1", "rec-2"]);
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith("link_tindeq_recordings_to_session", {
      p_session_id: "session-1",
      p_recording_ids: ["rec-1", "rec-2"],
    });
  });

  it("throws — does not swallow — when the RPC reports a Postgrest error", async () => {
    h.rpcResult = { data: null, error: { message: "permission denied" } };
    await expect(linkRecordingsToSession("session-1", ["rec-1"])).rejects.toMatchObject({
      message: "permission denied",
    });
  });
});

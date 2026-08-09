import { beforeEach, describe, expect, it, vi } from "vitest";

/// #494 (N4): `deleteHealthMetrics` used to return `void`, so its caller had
/// no way to tell "deleted 0 rows" (nothing to lose) apart from "deleted 50
/// rows" (real history, real stakes) — the discriminator `healthClearFailed`
/// (see `lib/healthClearOutcome.ts`) needs. This pins the mechanical part:
/// the count reflects how many rows the DELETE actually matched, read off
/// the returned rows rather than assumed.
const h = vi.hoisted(() => ({
  getUserResult: { data: { user: { id: "user-1" } }, error: null as unknown },
  deleteResult: { data: [] as unknown[], error: null as unknown },
}));

function chainable(result: { data: unknown; error: unknown }) {
  const obj: Record<string, unknown> = {};
  const passthrough = () => obj;
  obj.delete = passthrough;
  obj.gte = passthrough;
  obj.lte = passthrough;
  obj.select = passthrough;
  obj.then = (resolve: (v: unknown) => void, reject?: (e: unknown) => void) =>
    Promise.resolve(result).then(resolve, reject);
  return obj;
}

vi.mock("../supabase", () => ({
  supabase: {
    auth: { getUser: () => Promise.resolve(h.getUserResult) },
    from: () => chainable(h.deleteResult),
  },
}));

const { deleteHealthMetrics } = await import("./health");

describe("deleteHealthMetrics (#494, N4)", () => {
  beforeEach(() => {
    h.getUserResult = { data: { user: { id: "user-1" } }, error: null };
    h.deleteResult = { data: [], error: null };
  });

  it("returns 0 when nothing matched the delete", async () => {
    h.deleteResult = { data: [], error: null };
    await expect(deleteHealthMetrics()).resolves.toBe(0);
  });

  it("returns the number of rows actually deleted", async () => {
    h.deleteResult = {
      data: [{ date: "2026-08-01" }, { date: "2026-08-02" }, { date: "2026-08-03" }],
      error: null,
    };
    await expect(deleteHealthMetrics()).resolves.toBe(3);
  });
});

import { beforeEach, describe, expect, it, vi } from "vitest";

/// #487 (F3) / review finding 7: the original `duration.test.ts` only
/// exercised the brand-new `computeGroupDurationMin` helper — on pre-fix
/// code that file can't even resolve `./duration` (it didn't exist yet), so
/// it fails for an import-resolution reason, not because a duration came out
/// wrong. That's the "pins nothing" failure mode. This file instead drives
/// `recalcTindeqSessionDuration` itself — the function the reported bug
/// actually lives in — through a minimal fake Supabase client, so the
/// pre-fix version's unclamped `Math.max(1, Math.round(spanMs / 60000))`
/// produces a wrong VALUE (51_840, not 600) that this test catches.
///
/// The fake only implements the two chains this function's call path
/// actually uses (`tindeq_recordings` select, `sessions` update) — every
/// chain method returns the same thenable object, so it doesn't matter which
/// one the real code calls last.
const h = vi.hoisted(() => ({
  recordingsResult: { data: [] as unknown[], error: null as unknown },
  updateResult: { data: [{ id: "session-1" }] as unknown[], error: null as unknown },
}));

function chainable(result: { data: unknown; error: unknown }) {
  const obj: Record<string, unknown> = {};
  const passthrough = () => obj;
  obj.select = passthrough;
  obj.eq = passthrough;
  obj.is = passthrough;
  obj.order = passthrough;
  obj.update = passthrough;
  obj.then = (resolve: (v: unknown) => void, reject?: (e: unknown) => void) =>
    Promise.resolve(result).then(resolve, reject);
  return obj;
}

vi.mock("../supabase", () => ({
  supabase: {
    from: (table: string) => {
      if (table === "tindeq_recordings") return chainable(h.recordingsResult);
      if (table === "sessions") return chainable(h.updateResult);
      throw new Error(`recalcDuration.test.ts fake doesn't know table: ${table}`);
    },
  },
}));

const { recalcTindeqSessionDuration } = await import("./tindeq");

function recordingRow(recordedAt: string, durationMs: number) {
  return {
    id: crypto.randomUUID(),
    recorded_at: recordedAt,
    duration_ms: durationMs,
    peak_kg: 20,
    avg_kg: 18,
    sample_count: 10,
    note: "",
    tag: "FDP",
    side: "left",
    group_id: "group-1",
    protocol_run_id: null,
    set_no: null,
    zone: null,
    source: "dynamometer",
    external_load_kg: null,
    outcome: null,
    planned_duration_ms: null,
    actual_duration_ms: null,
    rep_no: null,
    protocol_mode: "hold",
    target_kg: null,
    target_low_kg: null,
    target_high_kg: null,
    cadence_out_s: null,
    cadence_return_s: null,
    cadence_markers: null,
    set_metrics: null,
    setup_note: "",
  };
}

describe("recalcTindeqSessionDuration (#487, F3)", () => {
  beforeEach(() => {
    h.recordingsResult = { data: [], error: null };
    h.updateResult = { data: [{ id: "session-1" }], error: null };
  });

  it("returns null and writes nothing for a group with no live recordings", async () => {
    h.recordingsResult = { data: [], error: null };
    await expect(recalcTindeqSessionDuration("group-1")).resolves.toBeNull();
  });

  it("writes the actual span for an in-range group", async () => {
    h.recordingsResult = {
      data: [
        recordingRow("2026-08-06T10:00:00.000Z", 20_000),
        recordingRow("2026-08-06T10:05:00.000Z", 20_000),
      ],
      error: null,
    };
    await expect(recalcTindeqSessionDuration("group-1")).resolves.toBe(5);
  });

  // THE regression case: a group whose recordings span far more than the
  // DB's 600-minute `duration_min` ceiling. Pre-fix, this computed 51_840
  // (36 days in minutes) and attempted to write it — failing the DB's
  // `duration_min between 1 and 600` check *after* the caller
  // (linkRecordingsToSession) had already re-grouped the recordings onto
  // the session, per the issue's exact complaint.
  it("clamps a multi-day span to 600 minutes instead of an out-of-range value", async () => {
    h.recordingsResult = {
      data: [
        recordingRow("2026-07-01T10:00:00.000Z", 20_000),
        recordingRow("2026-08-06T10:00:00.000Z", 20_000), // 36 days later
      ],
      error: null,
    };
    await expect(recalcTindeqSessionDuration("group-1")).resolves.toBe(600);
  });
});

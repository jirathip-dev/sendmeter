import { describe, it, expect } from "vitest";
import {
  applyRecordingRealtimeEvents,
  recordingEventsAllApplied,
  type RealtimeRecordingRowEvent,
} from "./realtimeRecordingApply";
import type { TindeqRecordingMeta } from "../types";

function meta(id: string, overrides: Partial<TindeqRecordingMeta> = {}): TindeqRecordingMeta {
  return {
    id,
    recordedAt: "2026-07-29T10:00:00.000Z",
    durationMs: 5000,
    peakKg: 20,
    avgKg: 15,
    sampleCount: 100,
    note: "",
    tag: "FDP",
    side: "",
    groupId: "g1",
    protocolRunId: null,
    setNo: null,
    zone: null,
    source: "dynamometer",
    ...overrides,
  };
}

/// A plausible `tindeq_recordings` row as postgres_changes would deliver it —
/// snake_case columns, the shape `toRecording` parses.
function row(id: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id,
    recorded_at: "2026-07-29T10:00:00.000Z",
    duration_ms: 5000,
    peak_kg: 20,
    avg_kg: 15,
    sample_count: 100,
    note: "",
    tag: "FDP",
    side: "",
    group_id: "g1",
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
    ...overrides,
  };
}

function event(overrides: Partial<RealtimeRecordingRowEvent> = {}): RealtimeRecordingRowEvent {
  return {
    eventType: "INSERT",
    row: row("r1"),
    oldRow: null,
    ...overrides,
  };
}

describe("applyRecordingRealtimeEvents (#613 — payload reconciliation)", () => {
  it("prepends an INSERT for a row we don't have yet", () => {
    const next = applyRecordingRealtimeEvents([meta("old")], [event()]);
    expect(next.map((r) => r.id)).toEqual(["r1", "old"]);
    expect(next[0]).toMatchObject({
      tag: "FDP",
      durationMs: 5000,
      groupId: "g1",
      source: "dynamometer",
    });
  });

  it("replaces by id rather than duplicating an INSERT for a row already present", () => {
    const next = applyRecordingRealtimeEvents([meta("r1", { peakKg: 19 })], [event()]);
    expect(next).toHaveLength(1);
    expect(next[0]!.peakKg).toBe(20); // updated from the payload
  });

  it("replaces by id on UPDATE", () => {
    const next = applyRecordingRealtimeEvents(
      [meta("r1", { peakKg: 19 }), meta("other")],
      [event({ eventType: "UPDATE", row: row("r1", { peak_kg: 33 }) })],
    );
    expect(next).toHaveLength(2);
    expect(next.find((r) => r.id === "r1")!.peakKg).toBe(33);
    expect(next.find((r) => r.id === "other")).toBeDefined();
  });

  it("prepends on UPDATE for a row we never loaded (missed earlier event)", () => {
    const next = applyRecordingRealtimeEvents(
      [meta("other")],
      [event({ eventType: "UPDATE", row: row("r1") })],
    );
    expect(next.map((r) => r.id)).toEqual(["r1", "other"]);
  });

  it("removes on DELETE", () => {
    const next = applyRecordingRealtimeEvents(
      [meta("r1"), meta("keep")],
      [event({ eventType: "DELETE", row: null, oldRow: row("r1") })],
    );
    expect(next.map((r) => r.id)).toEqual(["keep"]);
  });

  it("removes on a soft-delete UPDATE (deleted_at set)", () => {
    const next = applyRecordingRealtimeEvents(
      [meta("r1")],
      [event({ eventType: "UPDATE", row: row("r1", { deleted_at: "2026-07-29T12:00:00.000Z" }) })],
    );
    expect(next).toEqual([]);
  });

  it("applies a batch oldest-first", () => {
    const next = applyRecordingRealtimeEvents([], [
      event({ row: row("a") }),
      event({ row: row("b") }),
      event({ eventType: "DELETE", row: null, oldRow: row("a") }),
    ]);
    expect(next.map((r) => r.id)).toEqual(["b"]);
  });

  it("is idempotent — re-applying the same events is a no-op", () => {
    const events = [event()];
    const once = applyRecordingRealtimeEvents([], events);
    const twice = applyRecordingRealtimeEvents(once, events);
    expect(twice).toEqual(once);
  });

  it("skips a row that fails to parse (schema drift) instead of crashing", () => {
    const next = applyRecordingRealtimeEvents(
      [meta("keep")],
      [event({ row: { id: "broken" } })], // missing every toRecording field
    );
    expect(next.map((r) => r.id)).toEqual(["keep"]);
  });
});

describe("recordingEventsAllApplied (#613 — the refetch guard)", () => {
  it("true when every INSERT/UPDATE row is present", () => {
    const events = [event(), event({ row: row("r2") })];
    expect(recordingEventsAllApplied(events, [meta("r1"), meta("r2")])).toBe(true);
  });

  it("false when a row is missing (a write we haven't reconciled)", () => {
    expect(recordingEventsAllApplied([event()], [])).toBe(false);
  });

  it("false when a DELETE's row is still present", () => {
    expect(
      recordingEventsAllApplied(
        [event({ eventType: "DELETE", row: null, oldRow: row("r1") })],
        [meta("r1")],
      ),
    ).toBe(false);
  });

  it("true when a DELETE's row is gone", () => {
    expect(
      recordingEventsAllApplied(
        [event({ eventType: "DELETE", row: null, oldRow: row("r1") })],
        [],
      ),
    ).toBe(true);
  });

  it("true on an empty queue — the guard's own `length > 0` check forces the mount fetch", () => {
    // Vacuous truth: zero events are trivially all applied. ForceView's guard
    // combines this with `recordingEvents.length > 0`, so an empty queue still
    // refetches on mount.
    expect(recordingEventsAllApplied([], [meta("r1")])).toBe(true);
  });

  it("false when a soft-deleted row is still present", () => {
    expect(
      recordingEventsAllApplied(
        [event({ eventType: "UPDATE", row: row("r1", { deleted_at: "2026-07-29T12:00:00.000Z" }) })],
        [meta("r1")],
      ),
    ).toBe(false);
  });
});

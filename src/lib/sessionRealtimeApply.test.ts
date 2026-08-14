import { describe, it, expect } from "vitest";
import type { Session } from "../types";
import type { RealtimeSessionRowEvent } from "./sessionRealtimeApply";
import {
  applySessionRealtimeEvents,
  sessionEventsAllApplied,
} from "./sessionRealtimeApply";

function row(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "s-1",
    date: "2026-08-14",
    type: "gym",
    type_label: "Gym",
    duration_min: 45,
    rpe: 6,
    rpe_confirmed: false,
    load: 270,
    note: "3 boulders",
    phase: "capacity",
    group_id: null,
    workout_source: "phone",
    ...overrides,
  };
}

function insertEvent(rowData: Record<string, unknown>): RealtimeSessionRowEvent {
  return { eventType: "INSERT", row: rowData, oldRow: null };
}

function canonical(id: string): Session {
  return {
    id,
    date: "2026-08-14",
    type: "gym",
    typeLabel: "Gym",
    duration: 45,
    rpe: 6,
    rpeConfirmed: false,
    load: 270,
    note: "3 boulders",
    phase: "capacity",
    groupId: null,
    workoutSource: "phone",
  };
}

describe("applySessionRealtimeEvents", () => {
  it("replaces a pending placeholder by id (realtime-after-optimistic)", () => {
    const pending: Session = { ...canonical("s-1"), pending: true };
    const out = applySessionRealtimeEvents([pending], [insertEvent(row())]);
    expect(out).toHaveLength(1);
    expect(out[0]!.pending).toBeUndefined();
    expect(out[0]!.rpeConfirmed).toBe(false);
  });

  it("appends a server row never seen before (realtime-before-optimistic)", () => {
    const out = applySessionRealtimeEvents([], [insertEvent(row())]);
    expect(out.map((s) => s.id)).toEqual(["s-1"]);
  });

  it("is idempotent under re-application (notification + event overlap)", () => {
    const once = applySessionRealtimeEvents([], [insertEvent(row())]);
    const twice = applySessionRealtimeEvents(once, [insertEvent(row())]);
    expect(twice).toHaveLength(1);
  });

  it("ignores UPDATE/DELETE events (the refetch reconciles those)", () => {
    const update: RealtimeSessionRowEvent = {
      eventType: "UPDATE",
      row: { ...row(), deleted_at: "2026-08-14T12:00:00Z" },
      oldRow: row(),
    };
    const out = applySessionRealtimeEvents([canonical("s-1")], [update]);
    expect(out).toHaveLength(1);
  });

  it("skips a malformed row (schema drift) — the refetch guard reconciles", () => {
    const out = applySessionRealtimeEvents([], [insertEvent({ id: "x" })]);
    expect(out).toHaveLength(0);
  });

  it("sorts after appending", () => {
    const older = row({ id: "s-old", date: "2026-08-13" });
    const out = applySessionRealtimeEvents(
      [canonical("s-2")],
      [insertEvent(older), insertEvent(row({ id: "s-new", date: "2026-08-15" }))],
    );
    expect(out.map((s) => s.id)).toEqual(["s-new", "s-2", "s-old"]);
  });
});

describe("sessionEventsAllApplied", () => {
  it("true when every INSERT landed by id", () => {
    const events = [insertEvent(row()), insertEvent(row({ id: "s-2" }))];
    expect(sessionEventsAllApplied(events, [canonical("s-1"), canonical("s-2")])).toBe(true);
  });

  it("false when a row is missing (un-applied event forces the refetch)", () => {
    expect(sessionEventsAllApplied([insertEvent(row())], [])).toBe(false);
  });

  it("false on UPDATE/DELETE or a malformed row", () => {
    const update: RealtimeSessionRowEvent = { eventType: "UPDATE", row: row(), oldRow: row() };
    expect(sessionEventsAllApplied([update], [canonical("s-1")])).toBe(false);
    expect(sessionEventsAllApplied([insertEvent({ id: "x" })], [])).toBe(false);
  });
});

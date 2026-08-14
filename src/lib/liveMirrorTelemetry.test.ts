import { afterEach, describe, expect, it, vi } from "vitest";
import {
  MIRROR_RING_LIMIT,
  TELEMETRY_THROTTLE_MS,
  recordLiveMirrorTrace,
  resetLiveMirrorDiagnostics,
  snapshotLiveMirrorDiagnostics,
  type LiveMirrorTraceInput,
} from "./liveMirrorTelemetry";

function trace(overrides: Partial<LiveMirrorTraceInput> = {}): LiveMirrorTraceInput {
  return {
    kind: "workout",
    path: "watch-direct",
    event: "start",
    accepted: true,
    ...overrides,
  };
}

describe("liveMirrorTelemetry", () => {
  afterEach(() => {
    resetLiveMirrorDiagnostics();
    vi.useRealTimers();
  });

  it("records accepted and rejected traces and separates them per path", () => {
    recordLiveMirrorTrace(trace({ kind: "workout", path: "watch-direct", accepted: true }));
    recordLiveMirrorTrace(trace({ kind: "workout", path: "server-fallback", accepted: true }));
    recordLiveMirrorTrace(
      trace({ kind: "workout", path: "watch-direct", accepted: false, rejection: "duplicate" }),
    );
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.byPath["watch-direct"]?.accepted).toBe(1);
    expect(diag.workout.byPath["watch-direct"]?.rejected).toBe(1);
    expect(diag.workout.byPath["server-fallback"]?.accepted).toBe(1);
    expect(diag.force.byPath["watch-direct"]).toBeUndefined();
  });

  it("tallies rejection reasons", () => {
    recordLiveMirrorTrace(trace({ accepted: false, rejection: "duplicate" }));
    recordLiveMirrorTrace(trace({ accepted: false, rejection: "outOfOrder" }));
    recordLiveMirrorTrace(trace({ accepted: false, rejection: "duplicate" }));
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.rejections["duplicate"]).toBe(2);
    expect(diag.workout.rejections["outOfOrder"]).toBe(1);
    expect(diag.workout.rejections["afterTerminal"]).toBeUndefined();
  });

  it("computes latency summaries per path so the two transports stay separate", () => {
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 100 }));
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 300 }));
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 500 }));
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 900 }));
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 1200 }));
    // A server-fallback trace must not pollute the direct-path summary.
    recordLiveMirrorTrace(trace({ path: "server-fallback", latencyMs: 9_000 }));

    const direct = snapshotLiveMirrorDiagnostics().workout.byPath["watch-direct"]!;
    expect(direct.latency.n).toBe(5);
    expect(direct.latency.min).toBe(100);
    expect(direct.latency.max).toBe(1200);
    // True nearest-rank over [100,300,500,900,1200]: p50 = 3rd, p95 = 5th.
    expect(direct.latency.p50).toBe(500);
    expect(direct.latency.avg).toBe(600);
    expect(direct.latency.p95).toBe(1200);
    const server = snapshotLiveMirrorDiagnostics().workout.byPath["server-fallback"]!;
    expect(server.latency.n).toBe(1);
    expect(server.latency.min).toBe(9_000);
  });

  it("p95 of two samples is the slower one, never the minimum (#614 review F3)", () => {
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 80 }));
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 2400 }));
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.byPath["watch-direct"]!.latency.p95).toBe(2400);
  });

  it("p95 of a single sample is that sample", () => {
    recordLiveMirrorTrace(trace({ path: "watch-direct", latencyMs: 500 }));
    expect(snapshotLiveMirrorDiagnostics().workout.byPath["watch-direct"]!.latency.p95).toBe(500);
  });

  it("only accepted packets contribute latency samples (#614 review F1)", () => {
    recordLiveMirrorTrace(trace({ latencyMs: 100 }));
    recordLiveMirrorTrace(trace({ latencyMs: 200, accepted: false, rejection: "duplicate" }));
    const diag = snapshotLiveMirrorDiagnostics();
    const path = diag.workout.byPath["watch-direct"]!;
    expect(path.rejected).toBe(1);
    expect(path.latency.n).toBe(1);
    expect(path.latency.min).toBe(100);
    expect(path.latency.max).toBe(100);
  });

  it("data age never contributes to latency summaries (#614 review F1)", () => {
    recordLiveMirrorTrace(trace({ latencyMs: 120, ageMs: 35_000 }));
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.byPath["watch-direct"]!.latency.n).toBe(1);
    expect(diag.workout.byPath["watch-direct"]!.latency.min).toBe(120);
    // An age-only trace (a stale hide) contributes nothing to latency.
    recordLiveMirrorTrace(trace({ accepted: false, rejection: "stale", ageMs: 30_012 }));
    const after = snapshotLiveMirrorDiagnostics();
    expect(after.workout.byPath["watch-direct"]!.latency.n).toBe(1);
  });

  it("reports wire and bridge segments separately from the total", () => {
    recordLiveMirrorTrace(trace({ latencyMs: 2500, wireMs: 2400, bridgeMs: 100 }));
    const diag = snapshotLiveMirrorDiagnostics();
    const path = diag.workout.byPath["watch-direct"]!;
    expect(path.latency.n).toBe(1);
    expect(path.latency.min).toBe(2500);
    expect(path.wire.n).toBe(1);
    expect(path.wire.min).toBe(2400);
    expect(path.bridge.n).toBe(1);
    expect(path.bridge.min).toBe(100);
  });

  it("keeps the ring bounded and counts drops", () => {
    for (let i = 0; i < MIRROR_RING_LIMIT + 25; i++) {
      recordLiveMirrorTrace(trace({ event: "phase" }));
    }
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.traces.length).toBe(MIRROR_RING_LIMIT);
    expect(diag.dropped).toBe(25);
  });

  it("throttles telemetry per kind+path so one transport never starves the other (#614 review F4)", () => {
    vi.useFakeTimers();
    // Back-to-back telemetry on the same kind+path: only the first records.
    expect(recordLiveMirrorTrace(trace({ kind: "force", path: "watch-direct", event: "telemetry" }))).toBe(true);
    expect(recordLiveMirrorTrace(trace({ kind: "force", path: "watch-direct", event: "telemetry" }))).toBe(false);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(1);

    // The SAME kind on a DIFFERENT path is not throttled — this is the F4
    // defect: with per-kind throttling, whichever transport wins each beat
    // race monopolizes the ring and the fallback shows n = 0.
    expect(recordLiveMirrorTrace(trace({ kind: "force", path: "server-fallback", event: "telemetry" }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(2);

    // And a different kind is independent too.
    expect(recordLiveMirrorTrace(trace({ kind: "workout", path: "watch-direct", event: "telemetry" }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().workout.traces.length).toBe(1);

    // Each path's own window: force server-fallback is throttled inside its
    // window, force watch-direct gets a fresh window once it elapses.
    expect(recordLiveMirrorTrace(trace({ kind: "force", path: "server-fallback", event: "telemetry" }))).toBe(false);
    vi.setSystemTime(Date.now() + TELEMETRY_THROTTLE_MS);
    expect(recordLiveMirrorTrace(trace({ kind: "force", path: "server-fallback", event: "telemetry" }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(3);
  });

  it("discrete events are never throttled and never impose a window (#614 review F4)", () => {
    vi.useFakeTimers();
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "start" }))).toBe(true);
    // A discrete event right after telemetry is still recorded…
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "end" }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(2);
    // …but it must not have silenced the next telemetry.
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "telemetry" }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(3);
  });

  it("reset clears the ring and counters", () => {
    recordLiveMirrorTrace(trace());
    resetLiveMirrorDiagnostics();
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.traces.length).toBe(0);
    expect(diag.dropped).toBe(0);
  });
});

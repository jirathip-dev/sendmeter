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
    // Nearest-rank percentiles over [100,300,500,900,1200].
    expect(direct.latency.p50).toBe(500);
    expect(direct.latency.avg).toBe(600);
    expect(direct.latency.p95).toBe(900);
    const server = snapshotLiveMirrorDiagnostics().workout.byPath["server-fallback"]!;
    expect(server.latency.n).toBe(1);
    expect(server.latency.min).toBe(9_000);
  });

  it("reports wireMs (watch→plugin) separately from latencyMs", () => {
    recordLiveMirrorTrace(trace({ latencyMs: 120, wireMs: 80 }));
    const diag = snapshotLiveMirrorDiagnostics();
    const path = diag.workout.byPath["watch-direct"]!;
    expect(path.latency.n).toBe(1);
    expect(path.latency.min).toBe(120);
    expect(path.wire.n).toBe(1);
    expect(path.wire.min).toBe(80);
  });

  it("keeps the ring bounded and counts drops", () => {
    for (let i = 0; i < MIRROR_RING_LIMIT + 25; i++) {
      recordLiveMirrorTrace(trace({ event: "phase" }));
    }
    const diag = snapshotLiveMirrorDiagnostics();
    expect(diag.workout.traces.length).toBe(MIRROR_RING_LIMIT);
    expect(diag.dropped).toBe(25);
  });

  it("throttles telemetry but never discrete transitions", () => {
    vi.useFakeTimers();
    // Back-to-back telemetry: only the first is recorded.
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "telemetry", accepted: true }))).toBe(true);
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "telemetry", accepted: true }))).toBe(false);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(1);

    // A discrete transition is always recorded, even immediately after.
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "end", accepted: true }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().force.traces.length).toBe(2);

    // The throttle is per-kind: a workout telemetry right after a force one
    // is not throttled by the force telemetry's window.
    vi.setSystemTime(Date.now() + 1_000);
    expect(recordLiveMirrorTrace(trace({ kind: "workout", event: "telemetry", accepted: true }))).toBe(true);
    expect(snapshotLiveMirrorDiagnostics().workout.traces.length).toBe(1);

    // After the window elapses, telemetry records again.
    vi.setSystemTime(Date.now() + TELEMETRY_THROTTLE_MS);
    expect(recordLiveMirrorTrace(trace({ kind: "force", event: "telemetry", accepted: true }))).toBe(true);
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

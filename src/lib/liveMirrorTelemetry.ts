/// Bounded, privacy-safe latency/path observability for the live Workout and
/// Force mirrors (#614). Records the aggregate transport path, its latency and
/// a rejection reason for each admitted/rejected mirror packet — never HR
/// traces, force samples, credentials, account ids or raw backend payloads —
/// in a bounded in-memory ring surfaced in Settings → Troubleshooting so the
/// active transport and its latency are visible during diagnosis.
///
/// In-memory by design: the ring exists to answer "which path is this mirror
/// on and how slow is it, right now" while the user is mid-outage. It
/// deliberately leaves no record of workout timing on disk, and a relaunch
/// starts clean — there is nothing to wipe, and nothing to leak.

import type { LiveMirrorEvent } from "sendlog-auth-bridge";

export type LiveMirrorKind = "workout" | "force";
export type LiveMirrorPath = "watch-direct" | "server-fallback";

/// Why a mirror packet did not reach React state. `stale` is recorded by the
/// hooks when a live row hides because its own `updatedAt` aged out, rather
/// than because a packet was rejected.
export type LiveMirrorRejection =
  | "duplicate"
  | "outOfOrder"
  | "staleRun"
  | "afterTerminal"
  | "ownerMismatch"
  | "notFresh"
  | "stale";

export interface LiveMirrorTrace {
  kind: LiveMirrorKind;
  path: LiveMirrorPath;
  event?: LiveMirrorEvent;
  accepted: boolean;
  rejection?: LiveMirrorRejection;
  /// Phone-internal latency, ms: native plugin receipt (or DB commit for the
  /// server path) → WebView listener. Direct-path values are the same phone
  /// wall clock end to end; server-path values include cross-device clock
  /// skew and network/realtime overhead, so the two must never be averaged
  /// together (the issue's "reported separately" requirement).
  latencyMs?: number;
  /// Watch capture → native plugin receipt, ms. Cross-device wall clocks, so
  /// a small negative value just means the watch clock runs ahead.
  wireMs?: number;
  /// Phone wall-clock ms when the trace was recorded.
  atMs: number;
}

/// Cap on the in-memory ring. Large enough to show a few minutes of workout
/// beats and every discrete transition, small enough that `snapshot` stays
/// trivially cheap and the diagnostics stay glanceable.
export const MIRROR_RING_LIMIT = 120;

/// Force telemetry beats at ~2 Hz; recording every one would drown the ring
/// (and the workout telemetry at ~0.2 Hz needs no throttle at all, but the
/// rule is per-kind so the same clock applies). Telemetry is recorded at most
/// once per window per kind; discrete transitions bypass the throttle.
export const TELEMETRY_THROTTLE_MS = 5_000;

const ring: LiveMirrorTrace[] = [];
let dropped = 0;
const lastTelemetryAt: Partial<Record<LiveMirrorKind, number>> = {};

export interface LiveMirrorLatencySummary {
  n: number;
  min: number | null;
  p50: number | null;
  avg: number | null;
  p95: number | null;
  max: number | null;
}

export interface LiveMirrorPathStats {
  accepted: number;
  rejected: number;
  /// `latencyMs` summary over the ring window, per path.
  latency: LiveMirrorLatencySummary;
  /// `wireMs` summary over the ring window, per path.
  wire: LiveMirrorLatencySummary;
}

export interface LiveMirrorKindDiagnostics {
  /// Ring contents for this kind, oldest → newest.
  traces: LiveMirrorTrace[];
  byPath: Partial<Record<LiveMirrorPath, LiveMirrorPathStats>>;
  rejections: Partial<Record<LiveMirrorRejection, number>>;
}

export interface LiveMirrorDiagnostics {
  workout: LiveMirrorKindDiagnostics;
  force: LiveMirrorKindDiagnostics;
  /// Traces dropped because the ring hit `MIRROR_RING_LIMIT`. Non-zero is
  /// expected on a long session; it means the view is a recent window, not
  /// the whole session.
  dropped: number;
}

function summarize(values: number[]): LiveMirrorLatencySummary {
  if (values.length === 0) {
    return { n: 0, min: null, p50: null, avg: null, p95: null, max: null };
  }
  const sorted = [...values].sort((a, b) => a - b);
  const percentile = (p: number): number | null => {
    const v = sorted[Math.max(0, Math.min(sorted.length - 1, Math.floor((p / 100) * (sorted.length - 1))))];
    return v ?? null;
  };
  const sum = sorted.reduce((acc, v) => acc + v, 0);
  return {
    n: sorted.length,
    min: sorted[0] ?? null,
    p50: percentile(50),
    avg: sum / sorted.length,
    p95: percentile(95),
    max: sorted[sorted.length - 1] ?? null,
  };
}

export interface LiveMirrorTraceInput {
  kind: LiveMirrorKind;
  path: LiveMirrorPath;
  event?: LiveMirrorEvent;
  accepted: boolean;
  rejection?: LiveMirrorRejection;
  latencyMs?: number;
  wireMs?: number;
}

/// Records one mirror packet observation. Returns false when throttled (a
/// telemetry event inside `TELEMETRY_THROTTLE_MS` of the last recorded one of
/// the same kind) so callers can tell a recorded from a skipped trace.
export function recordLiveMirrorTrace(input: LiveMirrorTraceInput): boolean {
  const atMs = Date.now();
  if (
    input.event === "telemetry" &&
    atMs - (lastTelemetryAt[input.kind] ?? -Infinity) < TELEMETRY_THROTTLE_MS
  ) {
    return false;
  }
  lastTelemetryAt[input.kind] = atMs;
  const trace: LiveMirrorTrace = {
    kind: input.kind,
    path: input.path,
    accepted: input.accepted,
    atMs,
  };
  if (input.event !== undefined) trace.event = input.event;
  if (input.rejection !== undefined) trace.rejection = input.rejection;
  if (input.latencyMs !== undefined) trace.latencyMs = input.latencyMs;
  if (input.wireMs !== undefined) trace.wireMs = input.wireMs;
  ring.push(trace);
  if (ring.length > MIRROR_RING_LIMIT) {
    ring.shift();
    dropped += 1;
  }
  return true;
}

/// Test/observation seam: clears the ring and counters.
export function resetLiveMirrorDiagnostics(): void {
  ring.length = 0;
  dropped = 0;
  for (const key of Object.keys(lastTelemetryAt) as LiveMirrorKind[]) {
    delete lastTelemetryAt[key];
  }
}

function kindDiagnostics(kind: LiveMirrorKind): LiveMirrorKindDiagnostics {
  const traces = ring.filter((t) => t.kind === kind);
  const byPath: LiveMirrorKindDiagnostics["byPath"] = {};
  const rejections: LiveMirrorKindDiagnostics["rejections"] = {};
  for (const trace of traces) {
    if (trace.accepted) {
      byPath[trace.path] ??= {
        accepted: 0,
        rejected: 0,
        latency: { n: 0, min: null, p50: null, avg: null, p95: null, max: null },
        wire: { n: 0, min: null, p50: null, avg: null, p95: null, max: null },
      };
      byPath[trace.path]!.accepted += 1;
    } else {
      byPath[trace.path] ??= {
        accepted: 0,
        rejected: 0,
        latency: { n: 0, min: null, p50: null, avg: null, p95: null, max: null },
        wire: { n: 0, min: null, p50: null, avg: null, p95: null, max: null },
      };
      byPath[trace.path]!.rejected += 1;
    }
    if (trace.rejection !== undefined) {
      rejections[trace.rejection] = (rejections[trace.rejection] ?? 0) + 1;
    }
  }
  // Latency/wire summaries are computed over the path's ring traces so the
  // two transports stay reported separately (never averaged together).
  for (const [path, stats] of Object.entries(byPath) as [LiveMirrorPath, LiveMirrorPathStats][]) {
    const latencies = traces
      .filter((t) => t.path === path && t.latencyMs !== undefined)
      .map((t) => t.latencyMs as number);
    const wire = traces
      .filter((t) => t.path === path && t.wireMs !== undefined)
      .map((t) => t.wireMs as number);
    stats.latency = summarize(latencies);
    stats.wire = summarize(wire);
  }
  return { traces, byPath, rejections };
}

/// Read-only snapshot of the current ring. Derived on every call (the ring is
/// bounded, so scanning it is trivially cheap); callers must not hold the
/// result across mutations expecting a live view.
export function snapshotLiveMirrorDiagnostics(): LiveMirrorDiagnostics {
  return {
    workout: kindDiagnostics("workout"),
    force: kindDiagnostics("force"),
    dropped,
  };
}

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
/// hooks when a live row hides because the phone stopped receiving packets,
/// rather than because a packet was rejected.
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
  /// TOTAL watch-capture → WebView, ms (now − `updated_at`), for BOTH
  /// transports. `updated_at` is the watch's own clock at the beat on both
  /// paths (the durable row carries the watch's stamp), so direct and server
  /// totals bound the same span and are comparable. Cross-device clock skew
  /// applies equally to both; a small negative value means the watch clock
  /// runs ahead. Latency summaries only include accepted packets.
  latencyMs?: number;
  /// Direct only: watch → native plugin, ms (`received_at` − `updated_at`).
  /// Cross-device clocks, may be negative — reported separately from the
  /// phone-local segments (see `bridgeMs`).
  wireMs?: number;
  /// Direct only: native plugin → WebView, ms (now − `received_at`). The
  /// same phone clock end to end, so it is skew-free.
  bridgeMs?: number;
  /// DATA age, ms — the row's age at the initial fetch, or the mirror's age
  /// when it hides as stale. Deliberately NOT a transport latency and never
  /// contributed to latency summaries (#614 review F1).
  ageMs?: number;
  /// Phone wall-clock ms when the trace was recorded.
  atMs: number;
}

/// Cap on the in-memory ring. Large enough to show a few minutes of workout
/// beats and every discrete transition, small enough that `snapshot` stays
/// trivially cheap and the diagnostics stay glanceable.
export const MIRROR_RING_LIMIT = 120;

/// Force telemetry beats at ~2 Hz; recording every one would drown the ring.
/// Telemetry is recorded at most once per window per kind+path, so a healthy
/// direct path never starves the server path of samples (they race per beat
/// and each keeps its own window) and vice versa. Discrete transitions are
/// never throttled AND never impose a window (#614 review F4).
export const TELEMETRY_THROTTLE_MS = 5_000;

const ring: LiveMirrorTrace[] = [];
let dropped = 0;
const lastTelemetryAt: Partial<Record<string, number>> = {};

function telemetryKey(kind: LiveMirrorKind, path: LiveMirrorPath): string {
  return `${kind}:${path}`;
}

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
  /// Total watch-capture → WebView latency summary (accepted packets only),
  /// per path — direct and server are never averaged together.
  latency: LiveMirrorLatencySummary;
  /// Direct-only: watch → native plugin segment (accepted packets only).
  wire: LiveMirrorLatencySummary;
  /// Direct-only: native plugin → WebView segment (accepted packets only).
  bridge: LiveMirrorLatencySummary;
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

/// True nearest-rank percentile (#614 review F3): rank = ceil(p/100 × n),
/// 1-indexed, so p95 of two samples is the slower one, not the fastest — the
/// old `floor(p/100 × (n−1))` made p95 of n=2 read the minimum and p95 of
/// n=5 read the 80th percentile.
function percentile(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null;
  const rank = Math.min(sorted.length, Math.max(1, Math.ceil((p / 100) * sorted.length)));
  return sorted[rank - 1] ?? null;
}

function summarize(values: number[]): LiveMirrorLatencySummary {
  if (values.length === 0) {
    return { n: 0, min: null, p50: null, avg: null, p95: null, max: null };
  }
  const sorted = [...values].sort((a, b) => a - b);
  const sum = sorted.reduce((acc, v) => acc + v, 0);
  return {
    n: sorted.length,
    min: sorted[0] ?? null,
    p50: percentile(sorted, 50),
    avg: sum / sorted.length,
    p95: percentile(sorted, 95),
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
  bridgeMs?: number;
  ageMs?: number;
}

/// Records one mirror packet observation. Returns false when throttled (a
/// telemetry event inside `TELEMETRY_THROTTLE_MS` of the last recorded one of
/// the same kind+path) so callers can tell a recorded from a skipped trace.
/// Discrete events are never throttled and never impose a window on telemetry.
export function recordLiveMirrorTrace(input: LiveMirrorTraceInput): boolean {
  const atMs = Date.now();
  if (input.event === "telemetry") {
    const key = telemetryKey(input.kind, input.path);
    if (atMs - (lastTelemetryAt[key] ?? -Infinity) < TELEMETRY_THROTTLE_MS) {
      return false;
    }
    lastTelemetryAt[key] = atMs;
  }
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
  if (input.bridgeMs !== undefined) trace.bridgeMs = input.bridgeMs;
  if (input.ageMs !== undefined) trace.ageMs = input.ageMs;
  ring.push(trace);
  if (ring.length > MIRROR_RING_LIMIT) {
    ring.shift();
    dropped += 1;
  }
  return true;
}

/// Clears the ring and counters. Test seam AND the production call on an
/// account change/sign-out (#614 review F13): the ring is process-global, so
/// it must not keep showing the previous account's mirror timeline.
export function resetLiveMirrorDiagnostics(): void {
  ring.length = 0;
  dropped = 0;
  for (const key of Object.keys(lastTelemetryAt)) {
    delete lastTelemetryAt[key];
  }
}

const EMPTY_SUMMARY: LiveMirrorLatencySummary = {
  n: 0,
  min: null,
  p50: null,
  avg: null,
  p95: null,
  max: null,
};

function kindDiagnostics(kind: LiveMirrorKind): LiveMirrorKindDiagnostics {
  const traces = ring.filter((t) => t.kind === kind);
  const byPath: LiveMirrorKindDiagnostics["byPath"] = {};
  const rejections: LiveMirrorKindDiagnostics["rejections"] = {};
  for (const trace of traces) {
    byPath[trace.path] ??= {
      accepted: 0,
      rejected: 0,
      latency: { ...EMPTY_SUMMARY },
      wire: { ...EMPTY_SUMMARY },
      bridge: { ...EMPTY_SUMMARY },
    };
    if (trace.accepted) {
      byPath[trace.path]!.accepted += 1;
    } else {
      byPath[trace.path]!.rejected += 1;
    }
    if (trace.rejection !== undefined) {
      rejections[trace.rejection] = (rejections[trace.rejection] ?? 0) + 1;
    }
  }
  // Latency/wire/bridge summaries are computed over ACCEPTED ring traces per
  // path (#614 review F1): the ring is a window, the sheets' p95 is a render
  // latency, and only accepted packets render. `ageMs` never contributes.
  for (const [path, stats] of Object.entries(byPath) as [LiveMirrorPath, LiveMirrorPathStats][]) {
    const acceptedForPath = traces.filter((t) => t.path === path && t.accepted);
    stats.latency = summarize(
      acceptedForPath
        .filter((t) => t.latencyMs !== undefined)
        .map((t) => t.latencyMs as number),
    );
    stats.wire = summarize(
      acceptedForPath
        .filter((t) => t.wireMs !== undefined)
        .map((t) => t.wireMs as number),
    );
    stats.bridge = summarize(
      acceptedForPath
        .filter((t) => t.bridgeMs !== undefined)
        .map((t) => t.bridgeMs as number),
    );
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

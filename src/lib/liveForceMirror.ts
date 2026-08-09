/// Pure merge/staleness logic behind `useLiveForce` (#309, #521), pulled out
/// so the spark-buffer re-anchoring, run cursor, overlap dedup and rolling
/// window trim are unit-testable without React or WatchConnectivity.

import type {
  LiveForceMessage,
  LiveMirrorEvent,
} from "sendlog-auth-bridge";

/// How long the beat may go quiet before the mirror hides. The watch beats
/// ~2 Hz while measuring and on every status change; 8s of silence means the
/// gauge screen closed, the watch app died, or the phone went unreachable.
export const STALE_MS = 8_000;

/// How far back the phone's own sparkline buffer reaches (SL-95).
export const SPARK_WINDOW_MS = 45_000;

export interface LiveForceSample {
  atMs: number; // wall-clock epoch ms, re-anchored from the beat's relative t
  kg: number;
}

export interface LiveForce {
  runId: string;
  sequence: number | null;
  event: LiveMirrorEvent;
  terminal: boolean;
  status: "connected" | "measuring";
  kg: number;
  peakKg: number;
  elapsedMs: number;
  sessionCount: number;
  tag: string;
  side: string;
  updatedAt: number; // ms epoch
  /// Rolling ~45s buffer of recent force samples for the mirror sparkline.
  spark: LiveForceSample[];
}

export interface LiveForceCursor {
  runId: string | null;
  sequence: number | null;
  terminal: boolean;
  updatedAtMs: number | null;
}

export interface LiveForceMirrorState {
  beat: LiveForce | null;
  cursor: LiveForceCursor;
}

/// Empty cursor state for a newly authenticated account. The hook applies
/// this before installing the next account's listener; otherwise a prior
/// account's terminal/high-sequence cursor could reject a valid new run.
export function emptyLiveForceMirrorState(): LiveForceMirrorState {
  return {
    beat: null,
    cursor: { runId: null, sequence: null, terminal: false, updatedAtMs: null },
  };
}

export interface LiveForceReduceResult {
  state: LiveForceMirrorState;
  accepted: boolean;
}

const EVENTS: ReadonlySet<string> = new Set([
  "start",
  "telemetry",
  "phase",
  "count",
  "end",
]);

function safeSequence(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : null;
}

function normalizeRunId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.toLowerCase() : null;
}

function eventFor(msg: LiveForceMessage, previous: LiveForce | null): LiveMirrorEvent {
  if (msg.status === "idle" || msg.terminal === true) return "end";
  if (EVENTS.has(msg.event ?? "")) return msg.event as LiveMirrorEvent;
  if (previous && previous.status !== msg.status) return "phase";
  return "telemetry";
}

function isTerminal(msg: LiveForceMessage): boolean {
  return msg.status === "idle" || msg.terminal === true || msg.event === "end";
}

function accepts(
  cursor: LiveForceCursor,
  runId: string,
  sequence: number | null,
  terminal: boolean,
  updatedAtMs: number,
): boolean {
  if (!cursor.runId) return true;
  if (cursor.runId !== runId) {
    // A fresh run supersedes the old one; once that run has been observed,
    // an old packet arriving with an older wall clock is stale even though
    // its UUID is different.
    return cursor.updatedAtMs === null || updatedAtMs >= cursor.updatedAtMs;
  }
  if (cursor.terminal) return false;
  if (terminal) return true;
  if (cursor.sequence !== null && sequence !== null) return sequence > cursor.sequence;
  // Mixed-version fallback. New packets with no sequence use the wall clock;
  // equal timestamps are tolerated here but spark/consumer dedupe remains
  // strict, which keeps old and new watch builds interoperable.
  return cursor.updatedAtMs === null || updatedAtMs >= cursor.updatedAtMs;
}

function mergedSpark(
  previous: LiveForce | null,
  incoming: LiveForceMessage,
  updatedAtMs: number,
  elapsedMs: number,
): LiveForceSample[] {
  const originMs = updatedAtMs - elapsedMs;
  const points = (incoming.spark ?? []).map(([t, kg]) => ({
    atMs: originMs + t,
    kg,
  }));
  const byTime = new Map<number, number>();
  for (const p of previous?.spark ?? []) byTime.set(Math.round(p.atMs), p.kg);
  for (const p of points) byTime.set(Math.round(p.atMs), p.kg);
  const cutoff = updatedAtMs - SPARK_WINDOW_MS;
  return Array.from(byTime.entries())
    .filter(([atMs]) => atMs >= cutoff)
    .sort((a, b) => a[0] - b[0])
    .map(([atMs, kg]) => ({ atMs, kg }));
}

/// Merges one accepted watch beat. An `idle` beat is terminal and hides the
/// visible state, but `reduceForceBeat` retains its cursor so a delayed
/// measuring packet cannot re-open the mirror.
export function mergeForceBeat(
  prev: LiveForce | null,
  msg: LiveForceMessage,
): LiveForce | null {
  const result = reduceForceBeat(
    {
      beat: prev,
      cursor: {
        runId: prev?.runId ?? null,
        sequence: prev?.sequence ?? null,
        terminal: prev?.terminal ?? false,
        updatedAtMs: prev?.updatedAt ?? null,
      },
    },
    msg,
  );
  return result.accepted ? result.state.beat : prev;
}

/// Reducer used by the hook. It keeps a terminal cursor even when `beat` is
/// null, so End/Disconnect dominates late live force data.
export function reduceForceBeat(
  previous: LiveForceMirrorState,
  msg: LiveForceMessage,
): LiveForceReduceResult {
  const updatedAtMs = msg.updated_at * 1000;
  const explicitRunId = normalizeRunId(msg.run_id);
  // A pre-#521 force payload has no run identity or start timestamp. A
  // connected transition is the one unambiguous signal that a new BLE run
  // began after a terminal idle; rotate a deterministic fallback identity at
  // that boundary. Late measuring data still shares the old fallback and is
  // therefore rejected by terminal dominance. If an old build skips the
  // connected transition, there is no wire-level fact that can distinguish a
  // new run from a late packet, so the safe choice remains rejection.
  const runId = explicitRunId || (
    previous.cursor.terminal
      && msg.status === "connected"
      && (previous.cursor.updatedAtMs === null || updatedAtMs > previous.cursor.updatedAtMs)
      ? `legacy-force-${updatedAtMs}`
      : previous.cursor.runId || "legacy-force"
  );
  const sequence = safeSequence(msg.sequence);
  const terminal = isTerminal(msg);
  if (!accepts(previous.cursor, runId, sequence, terminal, updatedAtMs)) {
    return { state: previous, accepted: false };
  }

  const nextCursor: LiveForceCursor = {
    runId,
    sequence: sequence ?? previous.cursor.sequence,
    terminal,
    updatedAtMs,
  };
  if (terminal) {
    return {
      accepted: true,
      state: { beat: null, cursor: nextCursor },
    };
  }

  // `isTerminal` already catches idle; keep this explicit narrowing so the
  // remaining state is exactly the visible connected/measuring union.
  if (msg.status === "idle") return { state: previous, accepted: false };
  const status = msg.status;
  const elapsedMs = msg.elapsed_ms ?? 0;
  const next: LiveForce = {
    runId,
    sequence,
    event: eventFor(msg, previous.beat),
    terminal: false,
    status,
    kg: msg.kg ?? 0,
    peakKg: msg.peak_kg ?? 0,
    elapsedMs,
    sessionCount: msg.session_count ?? 0,
    tag: msg.tag ?? "",
    side: msg.side ?? "",
    updatedAt: updatedAtMs,
    spark: mergedSpark(
      previous.beat?.runId === runId ? previous.beat : null,
      msg,
      updatedAtMs,
      elapsedMs,
    ),
  };
  return {
    accepted: true,
    state: { beat: next, cursor: nextCursor },
  };
}

/// Whether the given beat is still within the staleness window.
export function isFresh(beat: LiveForce, nowMs: number): boolean {
  return nowMs - beat.updatedAt <= STALE_MS;
}

import { captureForceLatency } from "./monitoring";

// #613: cross-module realtime-echo timing. The ForceView durable-first save
// marks the moment it starts the Supabase insert; RealtimeVersionProvider
// reads the mark when the resulting `tindeq_recordings` postgres_changes event
// arrives. The delta is the realtime receipt latency — how long after our own
// write the echo lands, which is what the refetch-skip guard is about.
//
// A single module-level slot is deliberate: a burst of concurrent inserts all
// measure against the most recent mark, which is exactly the "how fast is the
// echo right now" sample worth keeping, and the once-per-minute throttle in
// `captureForceLatency` bounds the volume anyway.

let realtimeInsertMark: number | null = null;

/// Call immediately before the network insert of a recording.
export function markRealtimeInsertStart(): void {
  realtimeInsertMark = performance.now();
}

/// Called by the realtime channel when a `tindeq_recordings` event arrives.
/// Measures against the most recent mark (if any) and clears it.
export function noteRealtimeRecordingReceipt(): void {
  if (realtimeInsertMark === null) return;
  captureForceLatency(
    "realtime.recv",
    performance.now() - realtimeInsertMark,
  );
  realtimeInsertMark = null;
}

/// Clear a mark whose insert is done (success or failure) so a later echo is
/// not measured against a stale start.
export function clearRealtimeInsertMark(): void {
  realtimeInsertMark = null;
}

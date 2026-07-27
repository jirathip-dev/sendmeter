// #269: the phone-side counterpart to `watchBuild.ts`'s `watchSyncLine` (#21)
// — the recording queue no longer evicts silently once eviction is
// unreachable in ordinary use (see recordingQueue.ts), so the backlog needs
// to be visible somewhere instead of just "eventually syncing quietly".
// `pendingRecordingCount` (recordingQueue.ts) is the read side; this module
// is the pure presentation half, kept separate and dependency-free so it's
// trivially unit-testable.

export type PhoneQueueTone = "muted";

export interface PhoneQueueLine {
  text: string;
  tone: PhoneQueueTone;
}

/// Renders the pending-recordings count as a line of copy, or `null` when
/// there's nothing worth saying: zero pending (the honest "all synced" state
/// — no line, not a "0 pending" line) or an unknown count (still loading —
/// `null` input, same "say nothing until there's something to say" rule
/// `watchSyncLine` follows for its own not-yet-reported case).
export function phoneQueueLine(count: number | null): PhoneQueueLine | null {
  if (count === null || count <= 0) return null;
  return {
    text: `${count} recording${count === 1 ? "" : "s"} pending sync`,
    tone: "muted",
  };
}

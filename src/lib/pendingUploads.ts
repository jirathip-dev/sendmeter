// #269: how many recordings are sitting in the offline queue, and how that
// reads. Until now the queue was completely invisible: a rep that failed to
// reach Supabase got a one-off toast and then nothing, so a backlog building up
// across a long offline session was indistinguishable from everything being
// fine — right up until the user went looking for a rep that wasn't there.
//
// Deliberately AMBIENT, not an interrupt. The alternative shape — a toast or
// alert per failed upload / per eviction — fires exactly when the user is
// mid-session and can do nothing about it, and then fires again for the next
// rep. A count that sits there and shrinks as the queue drains is the thing
// worth having: it is visible BEFORE anything is lost, and it costs nothing to
// ignore. Mirrors what the watch already reports for its own queue (#21,
// `uploadWarningPresentation` in `watchBuild.ts`) — same honest-states rule,
// same wording shape, so the two devices read as one idea in History.

/// At this depth the backlog stops being "a rep or two waiting for signal" and
/// starts being "this isn't draining". Same threshold the watch uses for its
/// own queue (`WatchSyncReport.backedUpThreshold`), so the phone and watch
/// lines don't disagree about what "a lot" means.
export const PENDING_BACKED_UP = 5;

const listeners = new Set<() => void>();

/// Subscribe to "the queue depth may have changed". Deliberately a bare signal
/// rather than a value: the depth lives in two stores and the subscriber is the
/// one that decides whether it still cares enough to go and read it.
export function subscribePendingUploads(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// Fired by every path that enqueues or drains. Never throws — it runs inside
/// an unmount cleanup (the salvage path), where a listener's exception would
/// take out the rest of the teardown.
export function notifyPendingUploadsChanged(): void {
  for (const listener of [...listeners]) {
    try {
      listener();
    } catch {
      // a stale subscriber is not the queue's problem
    }
  }
}

export type PendingUploadsTone = "muted" | "warning";

export interface PendingUploadsLine {
  text: string;
  tone: PendingUploadsTone;
}

/// The queue depth, split — see `pendingRecordingsBreakdown` in
/// recordingQueue.ts. `pending` is still being actively retried; `stuck` is
/// what a drain has stopped attempting automatically because the server has
/// rejected it across an app-version change (the policy block above
/// `drainQueue`).
export interface PendingUploadsBreakdown {
  pending: number;
  stuck: number;
}

/// How the depth reads, kept out of the view so the honest-states rule is
/// testable: "not known yet" must never render as "empty", and an empty queue
/// must say so rather than render as silence — a row that disappears when
/// there's nothing to report is indistinguishable from a row that's broken.
///
/// `null` means the depth hasn't been read yet (both stores are async to
/// count); `{pending: 0, stuck: 0}` means genuinely nothing queued.
///
/// #484: a non-zero `stuck` is its OWN state, never folded silently into
/// `pending` or excluded from the line — #475 F1 on the watch was a BLOCKER
/// for exactly that shape (a quarantine count written into a slot with zero
/// readers). It always renders (tone "warning", since nothing will move on
/// its own), whether or not anything is still pending too.
export function pendingUploadsLine(breakdown: PendingUploadsBreakdown | null): PendingUploadsLine {
  if (breakdown === null) return { text: "This device · queue not read yet", tone: "muted" };
  const { pending, stuck } = breakdown;
  if (pending === 0 && stuck === 0) {
    return { text: "This device · empty, everything synced", tone: "muted" };
  }
  if (stuck > 0) {
    const stuckWords = `${stuck} recording${stuck === 1 ? "" : "s"} stuck, not retrying`;
    if (pending === 0) return { text: `This device · ${stuckWords}`, tone: "warning" };
    const pendingWords = `${pending} pending sync`;
    return { text: `This device · ${pendingWords}, ${stuckWords}`, tone: "warning" };
  }
  const items = `${pending} recording${pending === 1 ? "" : "s"} pending sync`;
  return {
    text: `This device · ${items}`,
    // A couple of reps waiting on signal is normal and not worth alarm; a
    // backlog this deep means the drain isn't getting through.
    tone: pending >= PENDING_BACKED_UP ? "warning" : "muted",
  };
}

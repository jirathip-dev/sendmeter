import { appendUniqueById } from "./manualForceSubmission";

/// #462: `retryUnqueued` snapshots `unqueued` into `pending` before its
/// multi-round-trip retry loop, then must commit the result without
/// clobbering anything `queueFailedRecording` appended to `unqueued` while
/// the retry was in flight (a guided/hands-free run keeps saving reps
/// concurrently). Pure so the interleaving can be pinned without a component
/// or fake timers: `current` is `unqueued` at commit time, `pending` is the
/// snapshot the retry loop actually processed, `stillLost` is the subset of
/// `pending` that failed again.
export function mergeUnqueuedAfterRetry<T extends { id: string }>(
  current: T[],
  pending: T[],
  stillLost: T[],
): T[] {
  const processedIds = new Set(pending.map((item) => item.id));
  const survivors = current.filter((item) => !processedIds.has(item.id));
  return stillLost.reduce((list, item) => appendUniqueById(list, item), survivors);
}

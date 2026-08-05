import type { TindeqRecordingMeta } from "../types";

/**
 * `assignedIds` in HistoryView optimistically hides a recording from the
 * loose list the instant it's grouped (New session / Assign…), so it
 * doesn't flash back into the loose list before the realtime refetch
 * confirms the new `groupId`. It must not stay add-only forever: an id left
 * in the set after the grouping is confirmed permanently overrides the
 * orphan-rescue rule (a recording whose groupId has no matching session
 * falls back to loose) if that session is later deleted. Once a fresh row
 * shows a non-null groupId, the hide has done its job and the id is dropped.
 */
export function prunePendingAssignedIds(
  assignedIds: Set<string>,
  freshRecordings: TindeqRecordingMeta[],
): Set<string> {
  const byId = new Map(freshRecordings.map((r) => [r.id, r]));
  const next = new Set(
    [...assignedIds].filter((id) => {
      const fresh = byId.get(id);
      return !fresh || fresh.groupId === null;
    }),
  );
  return next.size === assignedIds.size ? assignedIds : next;
}

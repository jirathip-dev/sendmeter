import type { Session, TindeqRecordingMeta } from "../types";

export type HistoryTypeFilter = string | null;
export type HistoryTagFilter = string | null;

export interface HistoryFilterOptions {
  types: { id: string; label: string }[];
  tags: string[];
  activeType: HistoryTypeFilter;
  activeTag: HistoryTagFilter;
}

/**
 * Options always come from the complete effective timeline. Invalid selections
 * are treated as All during render, avoiding an effect that synchronizes stale
 * state after realtime updates. `hiddenTags` (SL-92) only trims the chip
 * list — matching still uses the recordings' raw tags, so hidden-tag
 * recordings stay visible in the timeline, just unreachable by a chip.
 */
export function historyFilterOptions(
  sessions: Session[],
  looseRecordings: TindeqRecordingMeta[],
  recordingsByGroup: Map<string, TindeqRecordingMeta[]>,
  hiddenTags: string[],
  selectedType: HistoryTypeFilter,
  selectedTag: HistoryTagFilter,
): HistoryFilterOptions {
  const labels = new Map<string, string>();
  for (const session of sessions) labels.set(session.type, session.typeLabel);
  if (looseRecordings.length > 0 && !labels.has("tindeq")) {
    labels.set("tindeq", "Tindeq");
  }

  const hidden = new Set(hiddenTags);
  const tags = new Set<string>();
  for (const recording of looseRecordings) {
    if (recording.tag && !hidden.has(recording.tag)) tags.add(recording.tag);
  }
  for (const recordings of recordingsByGroup.values()) {
    for (const recording of recordings) {
      if (recording.tag && !hidden.has(recording.tag)) tags.add(recording.tag);
    }
  }

  const types = [...labels].map(([id, label]) => ({ id, label }));
  const sortedTags = [...tags].sort((a, b) => a.localeCompare(b));
  return {
    types,
    tags: sortedTags,
    activeType: selectedType && labels.has(selectedType) ? selectedType : null,
    activeTag: selectedTag && tags.has(selectedTag) ? selectedTag : null,
  };
}

export function sessionMatchesHistoryFilters(
  session: Session,
  recordingsByGroup: Map<string, TindeqRecordingMeta[]>,
  type: HistoryTypeFilter,
  tag: HistoryTagFilter,
): boolean {
  if (type && session.type !== type) return false;
  if (!tag) return true;
  if (!session.groupId) return false;
  return (recordingsByGroup.get(session.groupId) ?? []).some(
    (recording) => recording.tag === tag,
  );
}

export function looseRecordingMatchesHistoryFilters(
  recording: TindeqRecordingMeta,
  type: HistoryTypeFilter,
  tag: HistoryTagFilter,
): boolean {
  return (!type || type === "tindeq") && (!tag || recording.tag === tag);
}

/** A watch workout will become an Auto-tracked session when it lands. It has
 * no Force recordings yet, so any Force-tag filter excludes it. */
export function liveWorkoutMatchesHistoryFilters(
  type: HistoryTypeFilter,
  tag: HistoryTagFilter,
): boolean {
  return !tag && (!type || type === "auto");
}

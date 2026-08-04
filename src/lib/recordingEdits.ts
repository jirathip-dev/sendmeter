import type { TindeqRecordingMeta } from "../types";

/**
 * History's local edit overlay (`editedRecs`) shows a tag/side/note edit
 * immediately, before the realtime refetch delivers the saved row. It must
 * only ever override those user-editable fields — substituting the whole
 * override row would resurrect a stale `groupId` (or any other server-owned
 * field) after a later action like "New session"/"Assign…" moves the
 * recording, corrupting group membership until the overlay entry expires.
 */
export function applyRecordingEdits(
  recordings: TindeqRecordingMeta[],
  edits: Map<string, TindeqRecordingMeta>,
): TindeqRecordingMeta[] {
  return recordings.map((r) => {
    const edit = edits.get(r.id);
    if (!edit) return r;
    return { ...r, tag: edit.tag, side: edit.side, note: edit.note };
  });
}

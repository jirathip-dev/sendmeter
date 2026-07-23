import { useEffect, useState } from "react";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import {
  fetchUnlinkedRecordingsForDate,
  linkRecordingsToSession,
} from "../lib/repo";
import { today } from "../lib/dates";
import type { Session } from "../types";

interface Props {
  session: Session;
  onDismiss: () => void;
}

/// SL-21: after logging a session, nudge to link any same-LOCAL-day Tindeq
/// gauge recordings that were never grouped into a session — reuses the
/// group_id convention History's multi-select → create/assign-session flow
/// already writes (see `linkRecordingsToSession`); doesn't invent a new
/// linking mechanism. Renders nothing while checking and once the count
/// comes back zero.
export default function UnlinkedSessionNudge({ session, onDismiss }: Props) {
  const [recordingIds, setRecordingIds] = useState<string[] | null>(null);
  const [linking, setLinking] = useState(false);
  const bumpRealtime = useRealtimeBump();
  const toast = useToast();

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const recs = await fetchUnlinkedRecordingsForDate(session.date);
        if (!cancelled) setRecordingIds(recs.map((r) => r.id));
      } catch {
        // Silent — this is a nudge, not a critical fetch; just don't show it.
        if (!cancelled) setRecordingIds([]);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [session.date]);

  if (!recordingIds || recordingIds.length === 0) return null;
  const n = recordingIds.length;

  async function link() {
    setLinking(true);
    try {
      await linkRecordingsToSession(
        { id: session.id, groupId: session.groupId, type: session.type },
        recordingIds!,
      );
      bumpRealtime();
      toast(`Linked ${n} recording${n === 1 ? "" : "s"} to this session`);
      onDismiss();
    } catch (e) {
      toast(e instanceof Error ? e.message : "Failed to link", "error");
      setLinking(false);
    }
  }

  return (
    <div className="nudge-banner">
      <span className="msg">
        {n} unlinked gauge recording{n === 1 ? "" : "s"} from{" "}
        {session.date === today() ? "today" : session.date} — link to this
        session?
      </span>
      <button className="nudge-link" onClick={() => void link()} disabled={linking}>
        {linking ? "Linking…" : "Link"}
      </button>
      <button className="nudge-x" onClick={onDismiss} aria-label="Dismiss">
        ×
      </button>
    </div>
  );
}

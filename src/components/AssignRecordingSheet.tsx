import type { TindeqRecordingMeta } from "../types";
import Sheet from "./Sheet";

interface Props {
  recording: TindeqRecordingMeta;
  /// All loaded recordings — candidate groups are derived from these.
  recordings: TindeqRecordingMeta[];
  onAssign: (groupId: string) => void;
  onClose: () => void;
}

/// Assign an ungrouped recording to an existing gauge-session group (SL-44).
/// Candidates come from the already-loaded recording list (same grouping as
/// GroupedRecordings), most recent first. Assignment only fixes grouping —
/// the logged session's note/duration/RPE stay as they were.
export default function AssignRecordingSheet({
  recording,
  recordings,
  onAssign,
  onClose,
}: Props) {
  type Candidate = {
    id: string;
    recs: TindeqRecordingMeta[];
    latest: string;
  };
  const groups = new Map<string, TindeqRecordingMeta[]>();
  for (const rec of recordings) {
    if (!rec.groupId) continue;
    const list = groups.get(rec.groupId);
    if (list) list.push(rec);
    else groups.set(rec.groupId, [rec]);
  }
  const candidates: Candidate[] = [...groups.entries()]
    .map(([id, recs]) => ({ id, recs, latest: recs[0]!.recordedAt }))
    .sort((a, b) => b.latest.localeCompare(a.latest));

  const fmtTime = (iso: string) => {
    const d = new Date(iso);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  };
  const fmtDate = (iso: string) => {
    const d = new Date(iso);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  };

  return (
    <Sheet onClose={onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: 20,
          fontWeight: 800,
          marginBottom: 2,
        }}
      >
        Assign to Session
      </div>
      <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 12 }}>
        Adds this {recording.peakKg.toFixed(1)} kg recording to the session's
        list. The session's logged duration and RPE stay unchanged.
      </div>

      {candidates.length === 0 ? (
        <div style={{ fontSize: 12, color: "var(--ink-faint)", padding: "16px 0" }}>
          No gauge sessions yet — recordings group into a session when you use
          "Group recordings into a session" before pulling.
        </div>
      ) : (
        candidates.map((c) => {
          const tags = [...new Set(c.recs.map((r) => r.tag).filter(Boolean))];
          return (
            <button
              key={c.id}
              className="btn-ghost"
              style={{ textAlign: "left", marginBottom: 8 }}
              onClick={() => {
                onAssign(c.id);
                onClose();
              }}
            >
              <div style={{ fontSize: 12, color: "var(--ink)", fontWeight: 600 }}>
                {fmtDate(c.recs[c.recs.length - 1]!.recordedAt)} ·{" "}
                {fmtTime(c.recs[c.recs.length - 1]!.recordedAt)}–
                {fmtTime(c.recs[0]!.recordedAt)}
              </div>
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 2 }}>
                {c.recs.length} recording{c.recs.length === 1 ? "" : "s"}
                {tags.length > 0 && ` · ${tags.join(" · ")}`}
              </div>
            </button>
          );
        })
      )}

      <div style={{ marginTop: 8 }}>
        <button className="btn-ghost" onClick={onClose}>
          Cancel
        </button>
      </div>
    </Sheet>
  );
}

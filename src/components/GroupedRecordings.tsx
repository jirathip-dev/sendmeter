import type { TindeqRecordingMeta } from "../types";
import RecordingRow from "./RecordingRow";

/// Recordings sharing a group_id render as one session block with a header;
/// ungrouped recordings render as standalone rows. Blocks are ordered by
/// their most recent recording.
export default function GroupedRecordings({
  recordings,
  onDelete,
  onAssign,
}: {
  recordings: TindeqRecordingMeta[];
  onDelete: (id: string) => void;
  onAssign?: (rec: TindeqRecordingMeta) => void;
}) {
  type Block =
    | { kind: "single"; rec: TindeqRecordingMeta; latest: string }
    | { kind: "group"; id: string; recs: TindeqRecordingMeta[]; latest: string };

  const groups = new Map<string, TindeqRecordingMeta[]>();
  const blocks: Block[] = [];
  for (const rec of recordings) {
    if (!rec.groupId) {
      blocks.push({ kind: "single", rec, latest: rec.recordedAt });
    } else if (groups.has(rec.groupId)) {
      groups.get(rec.groupId)!.push(rec);
    } else {
      const recs = [rec];
      groups.set(rec.groupId, recs);
      blocks.push({ kind: "group", id: rec.groupId, recs, latest: rec.recordedAt });
    }
  }
  blocks.sort((a, b) => b.latest.localeCompare(a.latest));

  const fmtTime = (iso: string) => {
    const d = new Date(iso);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  };
  const fmtDate = (iso: string) => {
    const d = new Date(iso);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  };

  return (
    <div>
      {blocks.map((b) =>
        b.kind === "single" ? (
          <RecordingRow
            key={b.rec.id}
            rec={b.rec}
            onDelete={onDelete}
            onAssign={onAssign}
          />
        ) : (
          <div
            key={b.id}
            style={{
              border: "1px solid var(--border)",
              borderRadius: 10,
              padding: "10px 8px 2px",
              marginBottom: 8,
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "baseline",
                gap: 8,
                flexWrap: "wrap",
                padding: "0 6px 8px",
              }}
            >
              <span style={{ fontSize: 11, color: "var(--ink)" }}>
                {fmtDate(b.recs[b.recs.length - 1]!.recordedAt)}
              </span>
              <span style={{ fontSize: 10, color: "var(--ink-faint)" }}>
                {fmtTime(b.recs[b.recs.length - 1]!.recordedAt)}–
                {fmtTime(b.recs[0]!.recordedAt)} · {b.recs.length} recording
                {b.recs.length === 1 ? "" : "s"}
              </span>
              <span style={{ fontSize: 10, color: "var(--ink-faint)" }}>
                {[...new Set(b.recs.map((r) => r.tag).filter(Boolean))].join(
                  " · ",
                )}
              </span>
            </div>
            {b.recs.map((rec) => (
              <RecordingRow key={rec.id} rec={rec} onDelete={onDelete} />
            ))}
          </div>
        ),
      )}
    </div>
  );
}

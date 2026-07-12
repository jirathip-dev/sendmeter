import type { Session } from "../types";
import SessionRow from "./SessionRow";

interface Props {
  sessions: Session[];
  onDelete: (id: string) => void;
  onOpenTrash: () => void;
}

export default function HistoryView({
  sessions,
  onDelete,
  onOpenTrash,
}: Props) {
  const total = sessions.reduce((s, x) => s + x.load, 0);
  return (
    <div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
        }}
      >
        <div className="section-head">HISTORY</div>
        <button
          onClick={onOpenTrash}
          style={{
            background: "none",
            border: "none",
            color: "var(--ink-faint)",
            fontSize: 9,
            textTransform: "uppercase",
            letterSpacing: "0.08em",
            cursor: "pointer",
            padding: 4,
            fontFamily: "Inter, sans-serif",
          }}
        >
          Trash
        </button>
      </div>
      <div className="section-sub">
        {sessions.length} sessions · {total.toLocaleString()} AU total
      </div>
      {sessions.length === 0 && (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: 13,
            padding: "60px 0",
          }}
        >
          No sessions yet.
        </div>
      )}
      {sessions.map((s) => (
        <SessionRow key={s.id} s={s} onDelete={onDelete} />
      ))}
    </div>
  );
}

import type { Session } from "../types";
import SessionRow from "./SessionRow";

interface Props {
  sessions: Session[];
  onDelete: (id: string) => void;
}

export default function HistoryView({ sessions, onDelete }: Props) {
  const total = sessions.reduce((s, x) => s + x.load, 0);
  return (
    <div>
      <div className="section-head">HISTORY</div>
      <div className="section-sub">
        {sessions.length} sessions · {total.toLocaleString()} AU total
      </div>
      {sessions.length === 0 && (
        <div
          style={{
            textAlign: "center",
            color: "#98989D",
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

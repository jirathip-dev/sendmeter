import { useState, type CSSProperties } from "react";
import type { Session } from "../types";
import RpeScatterCard from "./RpeScatterCard";
import SessionRow from "./SessionRow";
import Sheet from "./Sheet";

interface Props {
  sessions: Session[];
  onDelete: (id: string) => void;
  onOpenTrash: () => void;
}

const HEADER_BTN_STYLE: CSSProperties = {
  background: "none",
  border: "none",
  color: "var(--ink-faint)",
  fontSize: 9,
  textTransform: "uppercase",
  letterSpacing: "0.08em",
  cursor: "pointer",
  padding: 4,
  fontFamily: "Inter, sans-serif",
};

export default function HistoryView({
  sessions,
  onDelete,
  onOpenTrash,
}: Props) {
  const [showRpeModel, setShowRpeModel] = useState(false);
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
        <div style={{ display: "flex", gap: 4 }}>
          <button style={HEADER_BTN_STYLE} onClick={() => setShowRpeModel(true)}>
            RPE Model
          </button>
          <button style={HEADER_BTN_STYLE} onClick={onOpenTrash}>
            Trash
          </button>
        </div>
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

      {showRpeModel && (
        <Sheet onClose={() => setShowRpeModel(false)}>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 20,
              fontWeight: 800,
              marginBottom: 12,
            }}
          >
            RPE Model
          </div>
          <RpeScatterCard />
          <div style={{ marginTop: 12 }}>
            <button className="btn-ghost" onClick={() => setShowRpeModel(false)}>
              Close
            </button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

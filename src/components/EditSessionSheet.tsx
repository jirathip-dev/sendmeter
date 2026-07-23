import { useState } from "react";
import { SESSION_TYPES } from "../constants";
import type { Session, SessionPatch } from "../types";
import { stepRpe } from "../lib/rpe";
import Sheet from "./Sheet";

interface Props {
  session: Session;
  onSave: (patch: SessionPatch) => void;
  onClose: () => void;
}

/// Edit a logged session's type / duration / RPE / note (SL-43). Date and
/// phase are intentionally not editable, and workout_source (the immutable
/// auto-tracked badge) is never touched — an auto-tracked workout can be
/// re-typed to "Board Climbing" etc. while keeping its AUTO provenance tag.
export default function EditSessionSheet({ session, onSave, onClose }: Props) {
  const [type, setType] = useState(session.type);
  const [duration, setDuration] = useState(session.duration);
  const [rpe, setRpe] = useState(session.rpe);
  const [note, setNote] = useState(session.note);

  // Selectable types: real training types only. `tindeq` and `auto` are
  // system-assigned — offered only as the current value so the select isn't
  // ever in an invalid state.
  const options = SESSION_TYPES.filter(
    (t) => (t.id !== "tindeq" && t.id !== "auto") || t.id === session.type,
  );

  function save() {
    const typeInfo = SESSION_TYPES.find((t) => t.id === type);
    onSave({
      type,
      typeLabel: typeInfo?.label || type,
      duration,
      rpe,
      note,
    });
    onClose();
  }

  return (
    <Sheet onClose={onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: "var(--t-xl)",
          fontWeight: 800,
          marginBottom: 2,
        }}
      >
        Edit Session
      </div>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 4 }}>
        {session.date}
        {session.workoutSource && (
          <span>
            {" "}
            · {session.workoutSource === "watch" ? "auto-tracked" : "phone"}{" "}
            workout — stays flagged after editing
          </span>
        )}
      </div>

      <span className="field-label">Session Type</span>
      <select
        className="field"
        value={type}
        onChange={(e) => setType(e.target.value)}
      >
        {options.map((t) => (
          <option key={t.id} value={t.id}>
            {t.label}
          </option>
        ))}
      </select>

      <span className="field-label">Duration (minutes)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() => setDuration((d) => Math.max(5, d - 5))}
        >
          −
        </button>
        <span className="stepper-val">{duration}</span>
        <button
          className="stepper-btn"
          onClick={() => setDuration((d) => Math.min(300, d + 5))}
        >
          +
        </button>
      </div>

      <span className="field-label">RPE (1–10)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() => setRpe((r) => stepRpe(r, -1))}
        >
          −
        </button>
        <span className="stepper-val">{rpe}</span>
        <button
          className="stepper-btn"
          onClick={() => setRpe((r) => stepRpe(r, 1))}
        >
          +
        </button>
      </div>

      <div className="load-preview">
        <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>Session Load</span>
        <span
          style={{
            fontSize: 24,
            color: "var(--ink)",
            fontFamily: "Inter, sans-serif",
            fontWeight: 800,
          }}
        >
          {Math.round(duration * rpe)}{" "}
          <span style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}>AU</span>
        </span>
      </div>

      <span className="field-label">Notes (optional)</span>
      <textarea
        className="field"
        rows={3}
        value={note}
        onChange={(e) => setNote(e.target.value)}
        placeholder="Finger feel, grade attempts, injury notes…"
      />

      <div style={{ marginTop: 14 }}>
        <button className="btn-primary" onClick={save}>
          Save Changes
        </button>
      </div>
      <div style={{ marginTop: 10 }}>
        <button className="btn-ghost" onClick={onClose}>
          Cancel
        </button>
      </div>
    </Sheet>
  );
}

import type { Dispatch, SetStateAction } from "react";
import { PHASES, SESSION_TYPES } from "../constants";
import type { LogFormState, PhaseId } from "../types";
import { stepRpe } from "../lib/rpe";

interface Props {
  form: LogFormState;
  setForm: Dispatch<SetStateAction<LogFormState>>;
  onSubmit: () => void;
}

export default function LogForm({ form, setForm, onSubmit }: Props) {
  const load = Math.round(form.duration * form.rpe);

  function handleType(e: React.ChangeEvent<HTMLSelectElement>) {
    const t = SESSION_TYPES.find((x) => x.id === e.target.value);
    setForm((f) => ({
      ...f,
      type: e.target.value,
      duration: t?.defaultDuration || f.duration,
      rpe: t?.defaultRpe || f.rpe,
    }));
  }

  return (
    <div>
      <span className="field-label">Date</span>
      <input
        className="field"
        type="date"
        value={form.date}
        onChange={(e) => setForm((f) => ({ ...f, date: e.target.value }))}
      />

      <span className="field-label">Session Type</span>
      <select className="field" value={form.type} onChange={handleType}>
        {SESSION_TYPES.map((t) => (
          <option key={t.id} value={t.id}>
            {t.label}
          </option>
        ))}
      </select>

      <span className="field-label">Phase</span>
      <select
        className="field"
        value={form.phase}
        onChange={(e) =>
          setForm((f) => ({ ...f, phase: e.target.value as PhaseId }))
        }
      >
        {PHASES.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </select>

      <span className="field-label">Duration (minutes)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, duration: Math.max(5, f.duration - 5) }))
          }
        >
          −
        </button>
        <span className="stepper-val">{form.duration}</span>
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, duration: Math.min(300, f.duration + 5) }))
          }
        >
          +
        </button>
      </div>

      <span className="field-label">RPE (1–10)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, rpe: stepRpe(f.rpe, -1) }))
          }
        >
          −
        </button>
        <span className="stepper-val">{form.rpe}</span>
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, rpe: stepRpe(f.rpe, 1) }))
          }
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
          {load} <span style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}>AU</span>
        </span>
      </div>

      <span className="field-label">Notes (optional)</span>
      <textarea
        className="field"
        rows={3}
        value={form.note}
        onChange={(e) => setForm((f) => ({ ...f, note: e.target.value }))}
        placeholder="Finger feel, grade attempts, injury notes…"
      />

      <div style={{ marginTop: 14 }}>
        <button className="btn-primary" onClick={onSubmit}>
          Save Session
        </button>
      </div>
    </div>
  );
}

import { useEffect, useState } from "react";
import { SESSION_TYPES } from "../constants";
import type {
  PhoneWorkoutAction,
  PhoneWorkoutState,
} from "../lib/phoneWorkout";

interface Props {
  state: PhoneWorkoutState;
  dispatch: (action: PhoneWorkoutAction) => void;
  saving: boolean;
  onSave: (input: { type: string; typeLabel: string; rpe: number }) => void;
}

// Loggable types for a phone workout — real training types only.
const TYPE_OPTIONS = SESSION_TYPES.filter(
  (t) => t.id !== "auto" && t.id !== "tindeq",
);

function fmtElapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`
    : `${m}:${String(sec).padStart(2, "0")}`;
}

/// Phone-only workout logging (SL-41): start → tap Start boulder / Done
/// (rest) per attempt → end → pick type + RPE → save. No HR without the
/// watch — attempts store timing only.
export default function PhoneWorkoutCard({
  state,
  dispatch,
  saving,
  onSave,
}: Props) {
  const [type, setType] = useState("gym");
  const [rpe, setRpe] = useState(6);
  const [now, setNow] = useState(() => Date.now());
  const running = state.phase === "running";
  useEffect(() => {
    if (!running) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [running]);

  if (state.phase === "idle") {
    return (
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="label-eyebrow" style={{ marginBottom: 8 }}>
          Phone workout
        </div>
        <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
          No watch? Track a session here — tap when you get on the wall and
          when you drop off to count boulders.
        </div>
        <button
          className="btn-primary"
          onClick={() =>
            dispatch({ type: "start", at: new Date().toISOString() })
          }
        >
          Start Workout
        </button>
      </div>
    );
  }

  if (state.phase === "running") {
    const climbing = state.climbingSince !== null;
    const elapsed = now - new Date(state.startedAt).getTime();
    const attemptElapsed = climbing
      ? now - new Date(state.climbingSince!).getTime()
      : 0;
    return (
      <div
        className="card"
        style={{
          marginBottom: 12,
          border: `1px solid color-mix(in srgb, ${climbing ? "var(--success)" : "var(--primary)"} 45%, transparent)`,
        }}
      >
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            marginBottom: 10,
          }}
        >
          <span className="label-eyebrow">Phone workout</span>
          <span
            className="tag"
            style={{
              background: climbing
                ? "color-mix(in srgb, var(--success) 16%, transparent)"
                : "transparent",
              color: climbing ? "var(--success)" : "var(--ink-muted)",
              border: `1px solid ${climbing ? "var(--success)" : "var(--border)"}`,
            }}
          >
            {climbing ? "CLIMBING" : "RESTING"}
          </span>
        </div>

        <div style={{ display: "flex", alignItems: "baseline", gap: 14, marginBottom: 14, flexWrap: "wrap" }}>
          <span
            style={{
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: 32,
              fontVariantNumeric: "tabular-nums",
            }}
          >
            {fmtElapsed(elapsed)}
          </span>
          <span style={{ fontSize: 13, color: "var(--ink-muted)" }}>
            {state.attempts.length} boulder
            {state.attempts.length === 1 ? "" : "s"}
            {climbing && (
              <span style={{ color: "var(--success)" }}>
                {" "}
                · on the wall {fmtElapsed(attemptElapsed)}
              </span>
            )}
          </span>
        </div>

        {climbing ? (
          <button
            className="btn-primary"
            style={{ background: "var(--success)" }}
            onClick={() =>
              dispatch({ type: "endBoulder", at: new Date().toISOString() })
            }
          >
            Done — resting
          </button>
        ) : (
          <button
            className="btn-primary"
            onClick={() =>
              dispatch({ type: "beginBoulder", at: new Date().toISOString() })
            }
          >
            Start boulder
          </button>
        )}
        <div style={{ marginTop: 8 }}>
          <button
            className="btn-ghost"
            onClick={() => dispatch({ type: "end", at: new Date().toISOString() })}
          >
            End Workout
          </button>
        </div>
      </div>
    );
  }

  // confirming
  const durationMin = Math.max(
    1,
    Math.round(
      (new Date(state.endedAt).getTime() -
        new Date(state.startedAt).getTime()) /
        60000,
    ),
  );
  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="label-eyebrow" style={{ marginBottom: 8 }}>
        Log workout
      </div>
      <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 4 }}>
        {durationMin} min · {state.attempts.length} boulder
        {state.attempts.length === 1 ? "" : "s"}
      </div>

      <span className="field-label">Session Type</span>
      <select
        className="field"
        value={type}
        onChange={(e) => setType(e.target.value)}
      >
        {TYPE_OPTIONS.map((t) => (
          <option key={t.id} value={t.id}>
            {t.label}
          </option>
        ))}
      </select>

      <span className="field-label">RPE (1–10)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() => setRpe((r) => Math.max(1, r - 1))}
        >
          −
        </button>
        <span className="stepper-val">{rpe}</span>
        <button
          className="stepper-btn"
          onClick={() => setRpe((r) => Math.min(10, r + 1))}
        >
          +
        </button>
      </div>

      <div style={{ marginTop: 14 }}>
        <button
          className="btn-primary"
          disabled={saving}
          onClick={() => {
            const typeInfo = TYPE_OPTIONS.find((t) => t.id === type);
            onSave({ type, typeLabel: typeInfo?.label || type, rpe });
          }}
        >
          {saving ? "Saving…" : "Save Workout"}
        </button>
      </div>
      <div style={{ marginTop: 8 }}>
        <button
          className="btn-ghost"
          disabled={saving}
          onClick={() => dispatch({ type: "reset" })}
        >
          Discard
        </button>
      </div>
    </div>
  );
}

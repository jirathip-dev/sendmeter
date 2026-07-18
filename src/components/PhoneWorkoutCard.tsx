import { useState } from "react";
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
  /// Open the full-screen immersive view (fresh start, or resume from the bar).
  onOpen: () => void;
}

// Loggable types for a phone workout — real training types only.
const TYPE_OPTIONS = SESSION_TYPES.filter(
  (t) => t.id !== "auto" && t.id !== "tindeq",
);

/// Phone-only workout logging (SL-41): Start opens the immersive full-screen
/// timer (PhoneWorkoutFullscreen). This card shows the idle prompt, a
/// minimized "resume" bar while a workout runs, and the log/confirm form.
export default function PhoneWorkoutCard({
  state,
  dispatch,
  saving,
  onSave,
  onOpen,
}: Props) {
  const [type, setType] = useState("gym");
  const [rpe, setRpe] = useState(6);
  const onResume = onOpen;

  if (state.phase === "idle") {
    return (
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 8 }}>
          Phone workout
        </div>
        <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
          No watch? Track a session here — tap when you get on the wall and
          when you drop off to count boulders.
        </div>
        <button
          className="btn-primary"
          onClick={() => {
            onOpen();
            dispatch({ type: "start", at: new Date().toISOString() });
          }}
        >
          Start Workout
        </button>
      </div>
    );
  }

  if (state.phase === "running") {
    // The immersive full-screen view owns the running workout; this is just
    // the "minimized" resume bar shown behind it in the tab.
    const climbing = state.climbingSince !== null;
    return (
      <button
        onClick={onResume}
        style={{
          width: "100%",
          textAlign: "left",
          cursor: "pointer",
          marginBottom: 12,
          background: "var(--canvas)",
          border: `1px solid color-mix(in srgb, ${climbing ? "var(--success)" : "var(--primary)"} 45%, transparent)`,
          borderRadius: 12,
          padding: 16,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          fontFamily: "inherit",
        }}
      >
        <div>
          <div className="card-title" style={{ marginBottom: 4 }}>
            Workout in progress
          </div>
          <div style={{ fontSize: 13, color: "var(--ink-muted)" }}>
            {state.attempts.length} boulder{state.attempts.length === 1 ? "" : "s"} ·{" "}
            {climbing ? "climbing" : "resting"}
          </div>
        </div>
        <span style={{ color: climbing ? "var(--success)" : "var(--primary)", fontWeight: 700, fontSize: 13 }}>
          Resume ›
        </span>
      </button>
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
      <div className="card-title" style={{ marginBottom: 8 }}>
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

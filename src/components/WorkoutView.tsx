import { useState } from "react";
import { useLiveWorkout } from "../hooks/useLiveWorkout";
import { usePhoneWorkout } from "../hooks/usePhoneWorkout";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { insertPhoneWorkout } from "../lib/repo";
import type { PhaseId } from "../types";
import LiveWorkoutCard from "./LiveWorkoutCard";
import PhoneWorkoutCard from "./PhoneWorkoutCard";
import PhoneWorkoutFullscreen from "./PhoneWorkoutFullscreen";

interface Props {
  userId: string;
  currentPhase: PhaseId;
  /// Opens the manual Log Session sheet (moved here from Home).
  onLog: () => void;
}

/// The Workout tab: start/track a workout (live watch mirror or phone
/// full-screen timer) and manually log a session. Past workouts live in
/// History.
export default function WorkoutView({ userId, currentPhase, onLog }: Props) {
  const bumpRealtime = useRealtimeBump();
  const live = useLiveWorkout(userId);
  const [phone, dispatch] = usePhoneWorkout();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // A running phone workout takes over full-screen; "minimize" drops back to
  // a resume bar so the rest of the tab is reachable. Defaults to minimized so
  // a workout resumed from localStorage on load doesn't hijack the screen —
  // the Start/Resume buttons open it.
  const [minimized, setMinimized] = useState(true);

  async function savePhoneWorkout(meta: {
    type: string;
    typeLabel: string;
    rpe: number;
  }) {
    if (phone.phase !== "confirming") return;
    setSaving(true);
    setError(null);
    try {
      await insertPhoneWorkout({
        startedAt: phone.startedAt,
        endedAt: phone.endedAt,
        attempts: phone.attempts,
        type: meta.type,
        typeLabel: meta.typeLabel,
        rpe: meta.rpe,
        phase: currentPhase,
      });
      dispatch({ type: "reset" });
      // Silent refetch of the workout list + the training data (Dashboard/
      // History/ACWR) — NOT reload(), which flips the global loading spinner
      // and would unmount this view mid-save, dropping the reset above. The
      // insert also publishes a realtime change; this bump is belt-and-braces.
      bumpRealtime();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save workout");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div>
      <div className="section-head">WORKOUT</div>
      <div className="section-sub">
        Live watch tracking, phone logging, and your recent climbs.
      </div>

      {live && <LiveWorkoutCard live={live} />}

      {/* Hide the phone-logging card while a watch workout is live — one
          active workout at a time avoids double-logging the same session. */}
      {!live && (
        <PhoneWorkoutCard
          state={phone}
          dispatch={dispatch}
          saving={saving}
          onSave={(meta) => void savePhoneWorkout(meta)}
          onOpen={() => setMinimized(false)}
        />
      )}

      {/* Immersive full-screen timer (overlays everything) while running and
          not minimized. */}
      {!live && phone.phase === "running" && !minimized && (
        <PhoneWorkoutFullscreen
          state={phone}
          dispatch={dispatch}
          onMinimize={() => setMinimized(true)}
        />
      )}

      {error && (
        <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 8 }}>
          {error}
        </div>
      )}

      {/* Manual entry — the Log Session sheet (moved from Home) */}
      <div className="card" style={{ marginTop: 2 }}>
        <div className="label-eyebrow" style={{ marginBottom: 8 }}>
          Already trained?
        </div>
        <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
          Log a finished session manually — date, type, duration and RPE.
        </div>
        <button className="btn-ghost" onClick={onLog}>
          + Log Session
        </button>
      </div>

      <div style={{ fontSize: 11, color: "var(--ink-faint)", marginTop: 16, textAlign: "center" }}>
        Past workouts and sessions live in History.
      </div>
    </div>
  );
}

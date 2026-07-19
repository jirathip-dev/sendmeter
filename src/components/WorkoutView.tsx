import { useState } from "react";
import { useLiveWorkout } from "../hooks/useLiveWorkout";
import { usePhoneWorkout } from "../hooks/usePhoneWorkout";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { insertPhoneWorkout } from "../lib/repo";
import type { PhaseId } from "../types";
import LiveWorkoutCard from "./LiveWorkoutCard";
import LiveWorkoutFullscreen from "./LiveWorkoutFullscreen";
import PhoneWorkoutCard from "./PhoneWorkoutCard";
import PhoneWorkoutFullscreen from "./PhoneWorkoutFullscreen";
import RoutineCard from "./RoutineCard";
import RpeScatterCard from "./RpeScatterCard";
import Sheet from "./Sheet";

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
  const [showRpeModel, setShowRpeModel] = useState(false);
  // Fullscreen mirror of a live WATCH workout (read-only; watch owns it).
  const [liveOpen, setLiveOpen] = useState(false);

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
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
        }}
      >
        <div className="section-head">WORKOUT</div>
        <button className="header-btn" onClick={() => setShowRpeModel(true)}>
          RPE Model
        </button>
      </div>
      <div className="section-sub">
        Live watch tracking, phone logging, and your recent climbs.
      </div>

      {live && <LiveWorkoutCard live={live} onOpen={() => setLiveOpen(true)} />}
      {live && liveOpen && (
        <LiveWorkoutFullscreen live={live} onMinimize={() => setLiveOpen(false)} />
      )}

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
        <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginBottom: 8 }}>
          {error}
        </div>
      )}

      {/* Guided routine presets (warm-ups, circuits) — utility, saves nothing */}
      <RoutineCard />

      {/* Manual entry — the Log Session sheet (moved from Home) */}
      <div className="card" style={{ marginTop: 2 }}>
        <div className="card-title" style={{ marginBottom: 8 }}>
          Log a past workout
        </div>
        <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
          Log a finished session manually — date, type, duration and RPE.
        </div>
        <button className="btn-ghost" onClick={onLog}>
          Log Session
        </button>
      </div>

      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", marginTop: 16, textAlign: "center" }}>
        Past workouts and sessions live in History.
      </div>

      {/* RPE Model sheet — predicted vs confirmed effort (moved from History;
          it's about how workouts feel, which belongs with "do"). */}
      {showRpeModel && (
        <Sheet onClose={() => setShowRpeModel(false)}>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: "var(--t-xl)",
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

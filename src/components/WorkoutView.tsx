import { useState } from "react";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useLiveWorkout } from "../hooks/useLiveWorkout";
import { usePhoneWorkout } from "../hooks/usePhoneWorkout";
import {
  useRealtimeBump,
  useRealtimeVersion,
} from "../hooks/useRealtimeVersion";
import { fetchWorkouts, insertPhoneWorkout } from "../lib/repo";
import type { PhaseId, WorkoutListItem } from "../types";
import LiveWorkoutCard from "./LiveWorkoutCard";
import PhoneWorkoutCard from "./PhoneWorkoutCard";
import PhoneWorkoutFullscreen from "./PhoneWorkoutFullscreen";
import WorkoutRow from "./WorkoutRow";

interface Props {
  userId: string;
  currentPhase: PhaseId;
}

/// The Workout tab (SL-41): a live mirror of the in-progress watch workout,
/// phone-only workout logging, and the recent-workouts list.
export default function WorkoutView({ userId, currentPhase }: Props) {
  const realtimeVersion = useRealtimeVersion();
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

  const workouts = useCancellableFetch<WorkoutListItem[]>(
    () => fetchWorkouts(30),
    [],
    realtimeVersion,
  );

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

      <div className="label-eyebrow" style={{ margin: "18px 0 10px" }}>
        Recent workouts
      </div>
      {workouts.length === 0 ? (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: 13,
            padding: "40px 0",
          }}
        >
          No workouts yet. Track one on your watch or log one above.
        </div>
      ) : (
        workouts.map((w) => <WorkoutRow key={w.id} w={w} />)
      )}
    </div>
  );
}

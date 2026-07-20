import { useEffect, useRef, useState } from "react";
import { SESSION_TYPES } from "../constants";
import { useLiveWorkout } from "../hooks/useLiveWorkout";
import { usePhoneWorkout } from "../hooks/usePhoneWorkout";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import { insertPhoneWorkout, updateSession } from "../lib/repo";
import type { PhaseId, Session, SessionPatch } from "../types";
import EditSessionSheet from "./EditSessionSheet";
import LiveWorkoutCard from "./LiveWorkoutCard";
import LiveWorkoutFullscreen from "./LiveWorkoutFullscreen";
import PhoneWorkoutCard from "./PhoneWorkoutCard";
import PhoneWorkoutFullscreen from "./PhoneWorkoutFullscreen";
import RoutineCard from "./RoutineCard";
import RpeScatterCard from "./RpeScatterCard";
import WorkoutStatsCard from "./WorkoutStatsCard";
import Sheet from "./Sheet";

// Auto-save-on-stop defaults: RPE banked without a prompt, and the last type
// the user picked (via the edit sheet) so it's not always "gym".
const LAST_TYPE_KEY = "sendmeter:last-workout-type";
const DEFAULT_RPE = 6;

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
  const toast = useToast();
  const live = useLiveWorkout(userId);
  const [phone, dispatch] = usePhoneWorkout();
  const [error, setError] = useState<string | null>(null);
  // A running phone workout takes over full-screen; "minimize" drops back to
  // a resume bar so the rest of the tab is reachable. Defaults to minimized so
  // a workout resumed from localStorage on load doesn't hijack the screen —
  // the Start/Resume buttons open it.
  const [minimized, setMinimized] = useState(true);
  const [showRpeModel, setShowRpeModel] = useState(false);
  // Fullscreen mirror of a live WATCH workout (read-only; watch owns it).
  const [liveOpen, setLiveOpen] = useState(false);
  // The just-saved workout, opened for editing from the toast's "Set RPE"
  // action (auto-save-on-stop has no blocking confirm form anymore).
  const [editingSession, setEditingSession] = useState<Session | null>(null);

  // Stopping a workout SAVES it immediately — no RPE/type confirm form (that
  // was friction). It banks a default RPE + the last-used type; the success
  // toast offers "Set RPE" to tweak either. Runs once per confirming state.
  const autoSaveInFlightRef = useRef(false);

  async function autoSaveWorkout() {
    if (phone.phase !== "confirming") return;
    const { startedAt, endedAt, attempts } = phone;
    const n = attempts.length;
    const typeId = localStorage.getItem(LAST_TYPE_KEY) || "gym";
    const typeInfo =
      SESSION_TYPES.find((t) => t.id === typeId) ??
      SESSION_TYPES.find((t) => t.id === "gym")!;
    setError(null);
    try {
      const saved = await insertPhoneWorkout({
        startedAt,
        endedAt,
        attempts,
        type: typeInfo.id,
        typeLabel: typeInfo.label,
        rpe: DEFAULT_RPE,
        phase: currentPhase,
      });
      dispatch({ type: "reset" });
      // Silent refetch (NOT reload(), which flips the global spinner + unmounts
      // this view mid-save). The insert also publishes realtime; belt-and-braces.
      bumpRealtime();
      toast(`Workout saved · ${n} boulder${n === 1 ? "" : "s"}`, "success", {
        label: "Set RPE",
        onClick: () => setEditingSession(saved),
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save workout");
    }
  }

  useEffect(() => {
    // Reset the guard once we leave "confirming" (save done → reset → idle) so
    // the next workout auto-saves. All ref writes stay inside this effect.
    if (phone.phase !== "confirming") {
      autoSaveInFlightRef.current = false;
      return;
    }
    if (autoSaveInFlightRef.current) return;
    autoSaveInFlightRef.current = true;
    void autoSaveWorkout();
    // autoSaveWorkout reads phone/currentPhase at call time; depending on it
    // would re-run every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phone.phase]);

  function saveEditedWorkout(patch: SessionPatch) {
    const id = editingSession?.id;
    if (!id) return;
    localStorage.setItem(LAST_TYPE_KEY, patch.type); // remember the pick
    void (async () => {
      try {
        await updateSession(id, patch);
        bumpRealtime();
        toast("Workout updated");
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to update workout");
      }
    })();
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
          onOpen={() => setMinimized(false)}
        />
      )}

      {/* Edit the just-saved workout (RPE / type / duration / note) from the
          success toast's "Set RPE" action. */}
      {editingSession && (
        <EditSessionSheet
          session={editingSession}
          onSave={saveEditedWorkout}
          onClose={() => setEditingSession(null)}
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
      <RoutineCard currentPhase={currentPhase} />

      {/* Summary stats across recent workouts (SL-85) */}
      <WorkoutStatsCard />

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

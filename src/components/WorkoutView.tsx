import { useEffect, useRef, useState } from "react";
import { SESSION_TYPES } from "../constants";
import { useLiveWorkout } from "../hooks/useLiveWorkout";
import { usePhoneWorkout } from "../hooks/usePhoneWorkout";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import { insertPhoneWorkout, updateSession } from "../lib/repo";
import { captureHandledOperationalFailure } from "../lib/monitoring";
import {
  accountUnchangedSinceSave,
  pendingSessionFromPhoneWorkout,
  type PendingWorkout,
} from "../lib/pendingWorkouts";
import {
  phoneWorkoutBlockedReason,
  routineBlockedReason,
} from "../lib/workoutGuard";
import type { PhaseId, Session, SessionPatch } from "../types";
import EditSessionSheet from "./EditSessionSheet";
import LiveWorkoutCard from "./LiveWorkoutCard";
import LiveWorkoutFullscreen from "./LiveWorkoutFullscreen";
import PhoneWorkoutCard from "./PhoneWorkoutCard";
import PhoneWorkoutFullscreen from "./PhoneWorkoutFullscreen";
import RoutineCard from "./RoutineCard";
import WorkoutStatsCard from "./WorkoutStatsCard";

// Auto-save-on-stop defaults: RPE banked without a prompt, and the last type
// the user picked (via the edit sheet) so it's not always "gym".
const LAST_TYPE_KEY = "sendmeter:last-workout-type";
const DEFAULT_RPE = 6;

interface Props {
  userId: string;
  currentPhase: PhaseId;
  /// All sessions (manual + auto-tracked) — feeds WorkoutStatsCard's
  /// per-day RPE trend so a manually-logged past workout shows up there too.
  sessions: Session[];
  /// Opens the manual Log Session sheet (moved here from Home).
  onLog: () => void;
  /// #615: optimistic completed-workout plumbing (from useTrainingData) —
  /// the completed session shows in History the moment End is tapped, then
  /// reconciles by stable id when the atomic save RPC lands.
  onPhoneWorkoutPending: (pending: PendingWorkout) => void;
  onPhoneWorkoutReconciled: (saved: Session) => void;
  onPhoneWorkoutRollback: (id: string) => void;
}

/// The Workout tab: start/track a workout (live watch mirror or phone
/// full-screen timer) and manually log a session. Past workouts live in
/// History.
export default function WorkoutView({
  userId,
  currentPhase,
  sessions,
  onLog,
  onPhoneWorkoutPending,
  onPhoneWorkoutReconciled,
  onPhoneWorkoutRollback,
}: Props) {
  const bumpRealtime = useRealtimeBump();
  const toast = useToast();
  const [live, , liveSyncState] = useLiveWorkout(userId);
  const [phone, dispatch] = usePhoneWorkout();
  const [error, setError] = useState<string | null>(null);
  // A running phone workout takes over full-screen; "minimize" drops back to
  // a resume bar so the rest of the tab is reachable. Defaults to minimized so
  // a workout resumed from localStorage on load doesn't hijack the screen —
  // the Start/Resume buttons open it.
  const [minimized, setMinimized] = useState(true);
  // Fullscreen mirror of a live WATCH workout (read-only; watch owns it).
  const [liveOpen, setLiveOpen] = useState(false);
  // The just-saved workout, opened for editing from the toast's "Set RPE"
  // action (auto-save-on-stop has no blocking confirm form anymore).
  const [editingSession, setEditingSession] = useState<Session | null>(null);
  // #222: RoutineCard's running flag, lifted here so the phone-workout card can
  // refuse to start a second timer (and vice-versa — this view owns live/phone).
  const [routineRunning, setRoutineRunning] = useState(false);

  const activity = {
    liveWorkout: !!live,
    phoneWorkout: phone.phase === "running",
    routine: routineRunning,
  };

  // Stopping a workout SAVES it immediately — no RPE/type confirm form (that
  // was friction). It banks a default RPE + the last-used type; the success
  // toast offers "Set RPE" to tweak either. Runs once per confirming state.
  // #615: the completed session is added to History as a PENDING row the
  // moment the save starts (synchronous, before any await — the End tap to
  // visible-in-History latency is one render), then reconciled by the stable
  // session id when the atomic RPC returns. No global realtime refetch is
  // needed for the local transition; the realtime echo of the RPC's insert
  // reconciles any OTHER device's view.
  const autoSaveInFlightRef = useRef(false);
  // #615 F4: the account this render belongs to, in a ref — `autoSaveWorkout`'s
  // resolve path runs after a network await, so it must compare the account
  // it started the save under against the CURRENT one: a switch mid-flight
  // must not land the old account's row in the new account's History.
  const userIdRef = useRef(userId);
  useEffect(() => {
    userIdRef.current = userId;
  }, [userId]);

  async function autoSaveWorkout() {
    if (phone.phase !== "confirming") return;
    const { startedAt, endedAt, attempts, sessionId, workoutId } = phone;
    const n = attempts.length;
    const typeId = localStorage.getItem(LAST_TYPE_KEY) || "gym";
    const typeInfo =
      SESSION_TYPES.find((t) => t.id === typeId) ??
      SESSION_TYPES.find((t) => t.id === "gym")!;
    setError(null);
    const pending = pendingSessionFromPhoneWorkout({
      sessionId,
      startedAt,
      endedAt,
      attempts,
      type: typeInfo.id,
      typeLabel: typeInfo.label,
      rpe: DEFAULT_RPE,
      phase: currentPhase,
      accountUserId: userId,
    });
    // Optimistic: History shows the completed workout immediately. The
    // state transition (reset) still waits for the durable RPC — the toast
    // and the card's "Saving…" state are honest about the server commit.
    // #615 F4: the save-start account stamp, captured before the first
    // await — the guard below compares against the CURRENT account when the
    // RPC resolves.
    const saveAccountUserId = userIdRef.current;
    onPhoneWorkoutPending(pending);
    try {
      const saved = await insertPhoneWorkout({
        sessionId,
        workoutId,
        startedAt,
        endedAt,
        attempts,
        type: typeInfo.id,
        typeLabel: typeInfo.label,
        rpe: DEFAULT_RPE,
        phase: currentPhase,
      });
      if (!accountUnchangedSinceSave(saveAccountUserId, userIdRef.current)) {
        // #615 F4: the account switched while the save was in flight — the
        // row committed to the OLD account's data (the RPC ran under the old
        // session's token). The pending row was already dropped by the
        // userId-change effect; resetting is still owed so a restart can't
        // re-save this workout into the new account.
        dispatch({ type: "reset" });
        return;
      }
      // Reconcile by id — the pending row becomes the canonical row. The
      // RPC's own realtime echo bumps the version, but this direct update
      // is what makes the local transition immediate; the bump is harmless
      // (the refetch merge is id-identical).
      onPhoneWorkoutReconciled(saved);
      dispatch({ type: "reset" });
      toast(`Workout saved · ${n} boulder${n === 1 ? "" : "s"}`, "success", {
        label: "Set RPE",
        onClick: () => setEditingSession(saved),
      });
    } catch (e) {
      if (!accountUnchangedSinceSave(saveAccountUserId, userIdRef.current)) {
        // #615 F4: the account switched while the save was in flight — the
        // rollback belongs to the OLD account's pending row, which the
        // userId-change effect already dropped.
        return;
      }
      // Roll back the pending row — nothing durable exists for it. The
      // confirming state stays persisted (with the SAME stable ids), so a
      // retry — including after a process restart — replays idempotently.
      onPhoneWorkoutRollback(sessionId);
      captureHandledOperationalFailure("workout.insert", e, {
        automatic: true,
      });
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
        captureHandledOperationalFailure("session.update", e, {
          automatic: false,
        });
        setError(e instanceof Error ? e.message : "Failed to update workout");
      }
    })();
  }

  return (
    <div className="workout-view">
      <div className="section-head">WORKOUT</div>
      <div className="section-sub">
        Live watch tracking, phone logging, and your recent climbs.
      </div>

      {live && (
        <LiveWorkoutCard
          live={live}
          syncState={liveSyncState}
          onOpen={() => setLiveOpen(true)}
        />
      )}
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
          blockedReason={phoneWorkoutBlockedReason(activity)}
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

      {/* Guided routine presets (warm-ups, circuits). A completed run — and an
          early exit past a minute — IS logged as a `routine` session (SL-83 /
          SL-97), so it feeds ACWR and History like any other workout. */}
      <RoutineCard
        currentPhase={currentPhase}
        blockedReason={routineBlockedReason(activity)}
        onRunningChange={setRoutineRunning}
      />

      {/* Summary stats across recent workouts (SL-85 / #108) */}
      <WorkoutStatsCard sessions={sessions} />

      {/* Manual entry — the Log Session sheet (moved from Home) */}
      <div className="card surface-workout" style={{ marginTop: 2 }}>
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
    </div>
  );
}

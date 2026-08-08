import { useToast } from "../hooks/useToast";
import type {
  PhoneWorkoutAction,
  PhoneWorkoutState,
} from "../lib/phoneWorkout";

interface Props {
  state: PhoneWorkoutState;
  dispatch: (action: PhoneWorkoutAction) => void;
  /// Open the full-screen immersive view (fresh start, or resume from the bar).
  onOpen: () => void;
  /// Why Start is blocked right now — a guided routine is running (#222).
  /// Null when free to start.
  blockedReason?: string | null;
}

/// Phone-only workout logging (SL-41): Start opens the immersive full-screen
/// timer (PhoneWorkoutFullscreen). This card shows the idle prompt and a
/// minimized "resume" bar while a workout runs. Stopping auto-saves (no
/// confirm form) — WorkoutView owns that + the "Set RPE" edit toast.
export default function PhoneWorkoutCard({
  state,
  dispatch,
  onOpen,
  blockedReason = null,
}: Props) {
  const toast = useToast();
  const onResume = onOpen;

  if (state.phase === "idle") {
    return (
      <div className="card surface-workout" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 8 }}>
          Phone workout
        </div>
        <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
          No watch? Track a session here — tap when you get on the wall and
          when you drop off to count boulders.
        </div>
        <button
          className="btn-primary"
          // #222: one timer at a time. Kept clickable while blocked (rather
          // than `disabled`) so the tap names the reason instead of doing
          // nothing — the aria-disabled state and semantic fill carry the
          // "off" state.
          aria-disabled={blockedReason ? true : undefined}
          onClick={() => {
            if (blockedReason) {
              toast(blockedReason, "info");
              return;
            }
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
        className={`phone-workout-resume surface-workout ${climbing ? "climbing" : "resting"}`}
        onClick={onResume}
        style={{
          width: "100%",
          textAlign: "left",
          cursor: "pointer",
          marginBottom: 12,
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
          <div style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)" }}>
            {state.attempts.length} boulder{state.attempts.length === 1 ? "" : "s"} ·{" "}
            {climbing ? "climbing" : "resting"}
          </div>
        </div>
        <span className="phone-workout-resume-action">
          Resume ›
        </span>
      </button>
    );
  }

  // confirming — the workout auto-saves the instant it's stopped (WorkoutView
  // effect); this card is just the momentary "saving" placeholder.
  return (
    <div className="card surface-workout" style={{ marginBottom: 12 }}>
      <div className="card-title" style={{ marginBottom: 6 }}>
        Saving workout…
      </div>
      <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>
        <span style={{ color: "var(--primary)", fontWeight: 700 }}>
          {state.attempts.length}
        </span>{" "}
        boulder{state.attempts.length === 1 ? "" : "s"} logged
      </div>
    </div>
  );
}

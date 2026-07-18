import { Capacitor } from "@capacitor/core";
import { SendLogLiveActivity } from "sendlog-live-activity";
import type { ActivitySegment } from "sendlog-live-activity";
import type { PhoneWorkoutAction, PhoneWorkoutState } from "./phoneWorkout";
import type { ProtocolSegment } from "./protocol";

/// Lock-screen Live Activity glue (iOS only; every call no-ops on web).
/// The card renders its timers natively from timestamps, so JS only speaks
/// on state transitions — never on a tick.

const NATIVE = Capacitor.isNativePlatform();
const REST_KEY = "sendmeter:rest-target-s";

function restTargetS(): number {
  const v = Number(localStorage.getItem(REST_KEY));
  return [60, 120, 180, 300].includes(v) ? v : 180;
}

/// When the current phase began: the open boulder's start while climbing,
/// else the last attempt's end (or workout start) while resting — the same
/// derivation PhoneWorkoutFullscreen renders from.
function phaseStartedAtMs(state: Extract<PhoneWorkoutState, { phase: "running" }>): number {
  if (state.climbingSince) return new Date(state.climbingSince).getTime();
  const last = state.attempts[state.attempts.length - 1];
  if (last) return new Date(last.startedAt).getTime() + last.durationS * 1000;
  return new Date(state.startedAt).getTime();
}

let workoutActive = false;
let permissionAsked = false;

/// Mirror the reducer state onto the lock-screen activity. Called from the
/// usePhoneWorkout persistence effect — start on entering running, update on
/// every running transition, end on confirming (card lingers) / idle (gone).
export async function syncWorkoutActivity(state: PhoneWorkoutState): Promise<void> {
  if (!NATIVE) return;
  try {
    if (state.phase === "running") {
      const payload = {
        phase: state.climbingSince ? ("climbing" as const) : ("resting" as const),
        phaseStartedAtMs: phaseStartedAtMs(state),
        restTargetS: restTargetS(),
        boulderCount: state.attempts.length,
      };
      if (!workoutActive) {
        workoutActive = true;
        if (!permissionAsked) {
          permissionAsked = true;
          void SendLogLiveActivity.requestNotificationPermission();
        }
        await SendLogLiveActivity.startWorkoutActivity({
          startedAtMs: new Date(state.startedAt).getTime(),
          ...payload,
        });
      } else {
        await SendLogLiveActivity.updateWorkoutActivity(payload);
      }
    } else if (workoutActive) {
      workoutActive = false;
      // confirming = workout over, let the card linger briefly (like Music);
      // idle = discarded/saved, take it down now.
      await SendLogLiveActivity.endWorkoutActivity({ immediate: state.phase === "idle" });
    }
  } catch {
    // Live Activity failures must never break the workout itself
  }
}

/// Replay lock-screen intent taps (Boulder/Stop) into the reducer. The
/// reducer's phase guards make duplicates and already-applied actions no-ops.
export async function drainPendingActions(
  dispatch: (action: PhoneWorkoutAction) => void,
): Promise<void> {
  if (!NATIVE) return;
  try {
    const { actions } = await SendLogLiveActivity.getPendingActions();
    for (const a of actions) dispatch({ type: a.type, at: a.at });
  } catch {
    // ignore
  }
}

// ---- Tindeq (guided protocol) activity ----

let tindeqActive = false;

export async function startTindeqLiveActivity(
  title: string,
  targetKg: number | null,
  startEpochMs: number,
  timeline: ProtocolSegment[],
): Promise<void> {
  if (!NATIVE) return;
  try {
    tindeqActive = true;
    const segments: ActivitySegment[] = timeline.map((seg) => ({
      p: seg.phase,
      s: seg.side ?? undefined,
      rep: seg.rep,
      set: seg.set,
      startS: seg.startS,
      durS: seg.durS,
    }));
    await SendLogLiveActivity.startTindeqActivity({
      title,
      targetKg: targetKg ?? undefined,
      startEpochMs,
      segments,
    });
  } catch {
    // ignore
  }
}

export async function updateTindeqLivePeak(peakKg: number): Promise<void> {
  if (!NATIVE || !tindeqActive) return;
  try {
    await SendLogLiveActivity.updateTindeqStats({ peakKg });
  } catch {
    // ignore
  }
}

export async function endTindeqLiveActivity(): Promise<void> {
  if (!NATIVE || !tindeqActive) return;
  tindeqActive = false;
  try {
    await SendLogLiveActivity.endTindeqActivity();
  } catch {
    // ignore
  }
}

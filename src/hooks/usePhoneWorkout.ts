import { useCallback, useEffect, useReducer } from "react";
import { Capacitor } from "@capacitor/core";
import { App } from "@capacitor/app";
import { SendLogLiveActivity } from "sendlog-live-activity";
import { drainPendingActions, syncWorkoutActivity } from "../lib/liveActivity";
import {
  phoneWorkoutReducer,
  type PhoneWorkoutAction,
  type PhoneWorkoutState,
} from "../lib/phoneWorkout";

const KEY = "sendmeter:phone-workout";

function load(): PhoneWorkoutState {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const state = JSON.parse(raw) as PhoneWorkoutState;
      if (state.phase === "confirming") {
        // #615: a confirming state persisted by a pre-#615 build carries no
        // stable ids. Mint them now so the retried save is idempotent — a
        // fresh pair is fine here (only THIS save attempt will use them).
        if (!state.sessionId || !state.workoutId) {
          return {
            ...state,
            sessionId: crypto.randomUUID(),
            workoutId: crypto.randomUUID(),
          };
        }
      }
      return state;
    }
  } catch {
    // corrupt/absent → fresh
  }
  return { phase: "idle" };
}

/// Phone-workout state machine with localStorage persistence — every
/// transition is written through, so a tab refresh (or the PWA being
/// relaunched) resumes the running workout instead of losing it. On iOS the
/// state is also mirrored onto a lock-screen Live Activity, and Boulder/Stop
/// taps made THERE are queued natively and replayed into the reducer here
/// (the reducer's phase guards make replays idempotent).
export function usePhoneWorkout(): [
  PhoneWorkoutState,
  (action: PhoneWorkoutAction) => void,
] {
  const [state, rawDispatch] = useReducer(phoneWorkoutReducer, undefined, load);

  // #615: mint the stable save ids the moment the workout ENDS (wherever
  // the end action came from — the fullscreen End button or a replayed
  // lock-screen intent), so the confirming state persisted to localStorage
  // carries them and a retried save after a restart replays the same ids.
  // Minting here (not in the reducer) keeps the reducer pure and testable.
  const dispatch = useCallback((action: PhoneWorkoutAction) => {
    if (action.type === "end") {
      rawDispatch({
        ...action,
        sessionId: crypto.randomUUID(),
        workoutId: crypto.randomUUID(),
      });
      return;
    }
    rawDispatch(action);
  }, []);

  useEffect(() => {
    try {
      if (state.phase === "idle") localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, JSON.stringify(state));
    } catch {
      // storage unavailable (private mode) — the workout just won't survive
      // a refresh
    }
    void syncWorkoutActivity(state);
  }, [state]);

  // Drain lock-screen intent actions: on mount (cold launch after taps),
  // whenever the app returns to foreground, and instantly when an intent
  // fires while the WebView is alive.
  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return;
    void drainPendingActions(dispatch);
    const subs = [
      App.addListener("appStateChange", ({ isActive }) => {
        if (isActive) void drainPendingActions(dispatch);
      }),
      SendLogLiveActivity.addListener("liveActivityAction", () => {
        void drainPendingActions(dispatch);
      }),
    ];
    return () => {
      for (const sub of subs) void sub.then((h) => h.remove());
    };
  }, [dispatch]);

  return [state, dispatch];
}

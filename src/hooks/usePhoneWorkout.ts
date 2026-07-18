import { useEffect, useReducer } from "react";
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
    if (raw) return JSON.parse(raw) as PhoneWorkoutState;
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
  const [state, dispatch] = useReducer(phoneWorkoutReducer, undefined, load);

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
  }, []);

  return [state, dispatch];
}

import { useEffect, useReducer } from "react";
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
/// relaunched) resumes the running workout instead of losing it.
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
  }, [state]);

  return [state, dispatch];
}

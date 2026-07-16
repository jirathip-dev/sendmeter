/// Pure state machine for a phone-logged workout (SL-41): start → alternate
/// "start boulder" / "stop (rest)" to log attempts → end → confirm & save.
/// Kept free of React/IO so the transitions are unit-testable; the hook
/// persists every state to localStorage so a tab refresh resumes mid-workout.

export interface PhoneAttempt {
  startedAt: string; // ISO
  durationS: number;
}

export type PhoneWorkoutState =
  | { phase: "idle" }
  | {
      phase: "running";
      startedAt: string;
      attempts: PhoneAttempt[];
      /// Non-null while a boulder attempt is open ("climbing"); null = resting.
      climbingSince: string | null;
    }
  | {
      phase: "confirming";
      startedAt: string;
      endedAt: string;
      attempts: PhoneAttempt[];
    };

export type PhoneWorkoutAction =
  | { type: "start"; at: string }
  | { type: "beginBoulder"; at: string }
  | { type: "endBoulder"; at: string } // = "rest"
  | { type: "end"; at: string }
  | { type: "reset" }; // discard, or after a successful save

function closeAttempt(
  attempts: PhoneAttempt[],
  climbingSince: string,
  at: string,
): PhoneAttempt[] {
  const durationS = Math.max(
    1,
    (new Date(at).getTime() - new Date(climbingSince).getTime()) / 1000,
  );
  return [...attempts, { startedAt: climbingSince, durationS }];
}

export function phoneWorkoutReducer(
  state: PhoneWorkoutState,
  action: PhoneWorkoutAction,
): PhoneWorkoutState {
  switch (action.type) {
    case "start":
      if (state.phase !== "idle") return state;
      return {
        phase: "running",
        startedAt: action.at,
        attempts: [],
        climbingSince: null,
      };
    case "beginBoulder":
      if (state.phase !== "running" || state.climbingSince !== null) {
        return state;
      }
      return { ...state, climbingSince: action.at };
    case "endBoulder":
      if (state.phase !== "running" || state.climbingSince === null) {
        return state;
      }
      return {
        ...state,
        attempts: closeAttempt(state.attempts, state.climbingSince, action.at),
        climbingSince: null,
      };
    case "end": {
      if (state.phase !== "running") return state;
      // An attempt still open at End counts — close it at the end time.
      const attempts =
        state.climbingSince !== null
          ? closeAttempt(state.attempts, state.climbingSince, action.at)
          : state.attempts;
      return {
        phase: "confirming",
        startedAt: state.startedAt,
        endedAt: action.at,
        attempts,
      };
    }
    case "reset":
      return { phase: "idle" };
  }
}

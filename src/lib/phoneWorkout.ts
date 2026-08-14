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
      /// #615: stable ids minted when the workout ENDED and persisted with
      /// the confirming state — a retried save (tab restart mid-save, the
      /// PWA relaunched) replays the SAME session/workout ids, so the
      /// atomic save RPC reconciles idempotently instead of duplicating.
      sessionId: string;
      workoutId: string;
    };

export type PhoneWorkoutAction =
  | { type: "start"; at: string }
  | { type: "beginBoulder"; at: string }
  | { type: "endBoulder"; at: string } // = "rest"
  // `sessionId`/`workoutId` are injected by the hook's dispatch wrapper (the
  // single minting point) before the reducer sees the action — optional
  // here so non-React replay sources (lock-screen intents, liveActivity.ts)
  // can keep emitting the plain `{type, at}` shape. The reducer fails
  // closed on a missing id rather than producing an unreconcilable state.
  | { type: "end"; at: string; sessionId?: string; workoutId?: string }
  | { type: "reset" }; // discard, or after a successful save

function closeAttempt(
  attempts: PhoneAttempt[],
  climbingSince: string,
  at: string,
): PhoneAttempt[] {
  // #475 F10: the watch's AttemptDetector now DROPS a same-tick boulder
  // entirely (a same-tick Play/Stop is "not a climb" — see
  // AttemptDetector.processedAttempts()'s duration guard) rather than
  // clamping it like this. Deliberately not unified here: the phone's timer
  // is a manual fullscreen stopwatch with an explicit Boulder/Stop tap,
  // not a same-tick sensor race, so a 1s clamp is the right floor for it —
  // flagged only so the two devices' same-tick behavior is a known
  // divergence, not a discovered one.
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
      // The hook wrapper always injects the minted ids (see the action
      // type's doc comment); a missing id fails closed rather than
      // producing a confirming state that could never save idempotently.
      if (!action.sessionId || !action.workoutId) return state;
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
        sessionId: action.sessionId,
        workoutId: action.workoutId,
      };
    }
    case "reset":
      return { phase: "idle" };
  }
}

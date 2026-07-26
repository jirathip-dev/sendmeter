/// One timer at a time on the Workout tab (#222). The phone/watch workout and
/// the guided routine used to run fully independently — a routine started
/// mid-workout competed with it for the screen and could go unrecorded. These
/// are the pure rules; WorkoutView owns the state and the two cards render the
/// verdict (visibly disabled control + a toast naming the reason, never a
/// silently dead button).

/// What's running on the Workout tab right now.
export interface WorkoutTabActivity {
  /// A live WATCH workout is being mirrored (WorkoutView's `live`).
  liveWorkout: boolean;
  /// The phone workout timer is in its running phase.
  phoneWorkout: boolean;
  /// A guided routine is running (RoutineFullscreen open).
  routine: boolean;
}

/// Why a routine can't be started right now, or null when it's free to start.
/// The watch takes precedence over the phone: WorkoutView hides the phone card
/// entirely while a watch workout is live, so that's the truer reason to name.
export function routineBlockedReason(a: WorkoutTabActivity): string | null {
  if (a.liveWorkout) return "Finish your watch workout first";
  if (a.phoneWorkout) return "Finish your workout first";
  return null;
}

/// Why a phone workout can't be started right now, or null when it's free.
export function phoneWorkoutBlockedReason(a: WorkoutTabActivity): string | null {
  if (a.routine) return "Finish your routine first";
  return null;
}

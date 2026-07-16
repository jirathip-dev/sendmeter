export type PhaseId = "capacity" | "strength" | "power" | "execution";
export type ViewId = "dashboard" | "workout" | "history" | "tindeq";

export interface Phase {
  id: PhaseId;
  name: string;
  color: string;
  bg: string;
  border: string;
  acwr: string; // display band, e.g. "0.9–1.1"
  acwrLow: number; // structured target band bounds (match `acwr`)
  acwrHigh: number;
  weeks: string;
  desc: string;
  tools: string[];
  intensity: string;
}

export interface SessionType {
  id: string;
  label: string;
  defaultRpe: number;
  defaultDuration: number;
}

export interface NavItem {
  id: ViewId;
  icon: string;
  label: string;
}

export type WorkoutSource = "watch" | "phone";

export interface Session {
  id: string;
  date: string; // YYYY-MM-DD
  type: string;
  typeLabel: string;
  duration: number; // minutes
  rpe: number; // 1-10
  load: number; // duration * rpe
  note: string;
  phase: PhaseId;
  groupId: string | null; // Tindeq gauge session this was logged from
  // Immutable provenance: set when a device workout created this session
  // (drives the AUTO/PHONE badge + workout-detail expansion). The edit UI
  // never touches it, so editing `type` can't erase the auto-tracked marker.
  workoutSource: WorkoutSource | null;
}

/// Editable subset of a session (SL-43). Date and phase stay fixed — moving
/// an auto-tracked session's date would desync it from its workout's
/// started_at.
export interface SessionPatch {
  type: string;
  typeLabel: string;
  duration: number;
  rpe: number;
  note: string;
}

export interface DeletedSession extends Session {
  deletedAt: string;
}

export interface LogFormState {
  date: string;
  type: string;
  duration: number;
  rpe: number;
  note: string;
  phase: PhaseId;
}

export interface HealthMetric {
  date: string; // YYYY-MM-DD
  readiness: number | null;
  zone: string | null;
  hrvSdnnMs: number | null;
  restingHr: number | null;
  sleepHours: number | null;
  sleepDeepHours: number | null;
  sleepRemHours: number | null;
  bodyMassKg: number | null;
  respRateBpm: number | null;
}

export interface RpePair {
  predicted: number;
  confirmed: number;
  startedAt: string;
}

export interface PhasePeriod {
  id: string;
  phase: PhaseId;
  startedOn: string; // YYYY-MM-DD
  endedOn: string | null; // null = current open period
}

export interface AcwrData {
  acute: number;
  chronic: number;
  acwr: number | null;
}

export interface WeeklyLoad {
  label: string;
  total: number;
}

export interface AcwrStatus {
  label: string;
  color: string;
}

export interface TindeqSample {
  t: number; // ms since measurement start
  kg: number;
}

export type TindeqSide = "" | "left" | "right" | "both";

export interface TindeqRecordingMeta {
  id: string;
  recordedAt: string; // ISO timestamp
  durationMs: number;
  peakKg: number;
  avgKg: number;
  sampleCount: number;
  note: string;
  tag: string; // exercise, e.g. "FDP" — trends group by this
  side: TindeqSide;
  groupId: string | null; // gauge session this recording belongs to
}

export interface DeletedTindeqRecording extends TindeqRecordingMeta {
  deletedAt: string;
}

export interface NewTindeqRecording {
  durationMs: number;
  peakKg: number;
  avgKg: number;
  note: string;
  tag: string;
  side: TindeqSide;
  groupId: string | null;
  samples: TindeqSample[];
}

export interface WorkoutAttempt {
  startedAt: string;
  durationS: number;
  elevationGainM: number;
  avgHr: number | null;
  peakHr: number | null;
  effortScore: number | null;
  source: "auto" | "manual";
}

export interface WorkoutDetail {
  id: string;
  startedAt: string;
  endedAt: string;
  source: WorkoutSource;
  avgHr: number | null;
  maxHr: number | null;
  activeKcal: number | null;
  elevationGainM: number;
  attemptsDetected: number;
  attemptsConfirmed: number;
  rpePredicted: number | null;
  rpeConfirmed: number | null;
  attempts: WorkoutAttempt[];
}

/// One point of the workout-level 1Hz HR trace (sliced from
/// climb_workouts.raw). t is seconds from workout start; hr may be null
/// where the sensor lagged.
export interface WorkoutHrSample {
  t: number;
  hr: number | null;
}

/// Row of the Workout tab's recent-workouts list (metadata only — the
/// expanded detail lazy-loads via fetchWorkoutById).
export interface WorkoutListItem {
  id: string;
  sessionId: string | null;
  startedAt: string;
  endedAt: string;
  avgHr: number | null;
  attemptsConfirmed: number;
  attemptsDetected: number;
  rpeConfirmed: number | null;
  source: WorkoutSource;
}

/// The single live_workouts heartbeat row the watch upserts every ~5s
/// while a workout is running (SL-41 live mirror).
export interface LiveWorkout {
  workoutId: string;
  status: "live" | "ended";
  startedAt: string;
  hr: number | null;
  attemptCount: number;
  activeKcal: number | null;
  elevationGainM: number | null;
  climbing: boolean;
  updatedAt: string;
}

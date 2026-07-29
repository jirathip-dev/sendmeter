// Type-only, and therefore erased at build time — force-curve.ts imports
// TindeqSample back from here, so a value import would be a real cycle.
import type { RecordedZone } from "./lib/force-curve";

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
  // Whether a human has reviewed/confirmed this RPE — false for a phone
  // auto-save still sitting at the hardcoded DEFAULT_RPE until edited
  // (issue #114). Manual entries and edits are always true.
  rpeConfirmed: boolean;
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
  computedAt: string; // timestamptz — when readiness was (re)computed, NOT last sync (#112: score freezes at noon)
  hrvSdnnMs: number | null;
  restingHr: number | null;
  sleepHours: number | null;
  sleepDeepHours: number | null;
  sleepRemHours: number | null;
  bodyMassKg: number | null;
  respRateBpm: number | null;
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
  /// Guided-protocol provenance (SL-79) — reps of one run share a run id and
  /// carry their set number; null for free holds / older rows.
  protocolRunId: string | null;
  setNo: number | null;
  /// The zone this hold was actually PERFORMED under (#259), stamped from the
  /// armed zone/preset at save time — the LOAD-AWARE classification, which a
  /// duration-only re-derivation can't recover. `RecordedZone` (#325) admits
  /// "prehab" alongside the four training qualities — a Prehab hold MUST
  /// carry it, since a 30s null-zone hold would otherwise infer as Endurance.
  /// Null when there is nothing to record (freehand hold, watch recording) or
  /// the row predates the column; readers then infer it from `durationMs`
  /// (see lib/zoneHistory.ts `recordingZone`). Deliberately not backfilled.
  zone: RecordedZone | null;
}

/// A saved hang protocol (hold / reps / sets / rests) — drives the guided
/// timer in the fullscreen gauge.
export interface TindeqPreset {
  id: string;
  name: string;
  holdS: number;
  reps: number;
  sets: number;
  restRepsS: number;
  restSetsS: number;
  /// Optional target load — drawn as the target band on the live chart.
  targetKg: number | null;
  /// Optional target as % of a reference (see pctBasis). Overrides targetKg.
  targetPct: number | null;
  /// What targetPct is a percentage of: "pr" = best recorded peak (max
  /// strength), "cf" = critical force (sustainable / endurance).
  pctBasis: "pr" | "cf";
  /// Per-set ramp: set N targets (targetPct + (N-1)·pctStep)% of the basis.
  pctStep: number;
  /// Smart target (SL-62): derive the load from the exercise's force-duration
  /// curve at holdS — the force sustainable for exactly that hold (CF + W'/t).
  /// Overrides targetKg/targetPct when true.
  targetCurve: boolean;
  /// Alternate left/right each SET (switch hands during the set rest).
  alternateSides: boolean;
}

/// One timed step of a guided routine. (A type alias, not an interface, so it
/// stays assignable to the Supabase Json column type.)
export type RoutineStep = {
  label: string;
  /// Optional coaching hint shown under the step name.
  detail?: string;
  /// Duration in seconds (per repetition).
  s: number;
  /// Repeat the step this many times (SL-83). Default/absent = 1.
  reps?: number;
  /// Rest between repetitions of this step, in seconds. Default/absent = 0.
  restS?: number;
};

/// User-defined guided routine (Workout tab) — an ordered list of timed steps
/// (warm-up, conditioning circuit, mobility flow, …). Mirrors TindeqPreset.
export interface RoutinePreset {
  id: string;
  name: string;
  steps: RoutineStep[];
}

export interface DeletedTindeqRecording extends TindeqRecordingMeta {
  deletedAt: string;
}

export interface NewTindeqRecording {
  /// Optional client-generated id (#106): when a save might need to be
  /// retried from the offline queue (see lib/recordingQueue.ts), the caller
  /// mints this up front and reuses it across every retry — insertRecording
  /// passes it straight through as the row's primary key, so a retry of an
  /// insert that actually landed server-side (but whose response the client
  /// never saw) collides on the unique constraint instead of duplicating the
  /// row. Omitted for normal (non-retried) saves — the DB default applies.
  id?: string;
  durationMs: number;
  peakKg: number;
  avgKg: number;
  note: string;
  tag: string;
  side: TindeqSide;
  groupId: string | null;
  /// Guided-protocol provenance (SL-79): reps of one run share a run id and
  /// carry their set number. Null for free holds.
  protocolRunId: string | null;
  setNo: number | null;
  /// The quality this hold was performed under (#259) — the armed zone's own
  /// quality, or a custom preset's LOAD-AWARE badge. Null for a freehand hold:
  /// with no protocol armed there is no intent to record, and storing a
  /// duration guess here would make it indistinguishable from a real one.
  /// Required (not optional) so every save path has to make that call
  /// deliberately; queue entries written before #259 simply carry `undefined`
  /// and insert as null.
  zone: RecordedZone | null;
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
  /// Phase timestamps (absolute, so the mirror renders exact timers even
  /// though heartbeats are ~5s apart). Null on rows from old watch builds.
  climbingSince: string | null;
  restStartedAt: string | null;
  restTargetS: number | null;
  updatedAt: string;
}

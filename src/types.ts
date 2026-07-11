export type PhaseId = "capacity" | "strength" | "power" | "execution";
export type ViewId = "dashboard" | "log" | "phases" | "history" | "tindeq";

export interface Phase {
  id: PhaseId;
  name: string;
  color: string;
  bg: string;
  border: string;
  acwr: string;
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
}

export interface TrainingData {
  sessions: Session[];
  currentPhase: PhaseId;
  phaseStartDate: string; // YYYY-MM-DD
}

export interface LogFormState {
  date: string;
  type: string;
  duration: number;
  rpe: number;
  note: string;
  phase: PhaseId;
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

export interface TindeqRecordingMeta {
  id: string;
  recordedAt: string; // ISO timestamp
  durationMs: number;
  peakKg: number;
  avgKg: number;
  sampleCount: number;
  note: string;
}

export interface NewTindeqRecording {
  durationMs: number;
  peakKg: number;
  avgKg: number;
  note: string;
  samples: TindeqSample[];
}

export interface WorkoutAttempt {
  startedAt: string;
  durationS: number;
  elevationGainM: number;
  avgHr: number | null;
  peakHr: number | null;
  effortScore: number | null;
}

export interface WorkoutDetail {
  id: string;
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

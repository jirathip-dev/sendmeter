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

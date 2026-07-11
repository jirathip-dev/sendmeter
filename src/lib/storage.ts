import type { TrainingData } from "../types";
import { today } from "./dates";

export const STORAGE_KEY = "climbing_tracker_v1";

export function loadData(): TrainingData {
  try {
    const r = localStorage.getItem(STORAGE_KEY);
    if (r) return JSON.parse(r) as TrainingData;
  } catch {
    // fall through to defaults
  }
  return { sessions: [], currentPhase: "capacity", phaseStartDate: today() };
}

export function saveData(d: TrainingData): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(d));
  } catch {
    // storage unavailable; ignore
  }
}

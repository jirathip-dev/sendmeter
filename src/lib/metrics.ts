import type { AcwrData, AcwrStatus, Session, WeeklyLoad } from "../types";
import { daysAgo, today } from "./dates";

export function getACWRStatus(acwr: number | null): AcwrStatus {
  if (acwr === null) return { label: "No data", color: "#64748b" };
  if (acwr < 0.7) return { label: "Under-training", color: "#818cf8" };
  if (acwr <= 0.8) return { label: "Low", color: "#60a5fa" };
  if (acwr <= 1.3) return { label: "Optimal", color: "#4ade80" };
  if (acwr <= 1.5) return { label: "Caution", color: "#facc15" };
  return { label: "Danger", color: "#f87171" };
}

export function computeAcwr(sessions: Session[]): AcwrData {
  const acute = sessions
    .filter((s) => s.date >= daysAgo(6) && s.date <= today())
    .reduce((sum, s) => sum + s.load, 0);
  const chronic =
    sessions
      .filter((s) => s.date >= daysAgo(27) && s.date <= today())
      .reduce((sum, s) => sum + s.load, 0) / 4;
  return { acute, chronic, acwr: chronic > 0 ? acute / chronic : null };
}

export function computeWeeklyLoads(sessions: Session[]): WeeklyLoad[] {
  return [3, 2, 1, 0].map((wb) => {
    const start = daysAgo(wb * 7 + 6);
    const end = daysAgo(wb * 7);
    const total = sessions
      .filter((s) => s.date >= start && s.date <= end)
      .reduce((sum, s) => sum + s.load, 0);
    return { label: wb === 0 ? "Now" : `${wb}w`, total };
  });
}

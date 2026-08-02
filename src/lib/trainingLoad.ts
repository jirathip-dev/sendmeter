import { SESSION_TYPES } from "../constants";
import { dateStr, parseLocalDate } from "./dates";
import type { Session } from "../types";

export interface ActivityLoad {
  type: string;
  label: string;
  load: number;
  percentage: number;
}

const KNOWN_LABELS = new Map(SESSION_TYPES.map((type) => [type.id, type.label]));

function fallbackLabel(type: string): string {
  return type
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase()) || "Unknown activity";
}

/** AU grouped by activity over the 28 calendar days ending on `endDate`. */
export function activityMix(
  sessions: Pick<Session, "date" | "type" | "typeLabel" | "load">[],
  endDate: string,
): { total: number; activities: ActivityLoad[] } {
  const start = parseLocalDate(endDate);
  start.setDate(start.getDate() - 27);
  const startDate = dateStr(start);
  const grouped = new Map<string, { load: number; label: string }>();

  for (const session of sessions) {
    if (session.date < startDate || session.date > endDate) continue;
    const current = grouped.get(session.type);
    const legacyLabel = session.typeLabel.trim();
    grouped.set(session.type, {
      load: (current?.load ?? 0) + session.load,
      label:
        KNOWN_LABELS.get(session.type) ??
        current?.label ??
        (legacyLabel || null) ??
        fallbackLabel(session.type),
    });
  }

  const total = Array.from(grouped.values()).reduce((sum, item) => sum + item.load, 0);
  const activities = Array.from(grouped, ([type, item]) => ({
    type,
    label: item.label || fallbackLabel(type),
    load: item.load,
    percentage: total > 0 ? (item.load / total) * 100 : 0,
  }))
    .filter((item) => item.load > 0)
    .sort((a, b) => b.load - a.load || a.label.localeCompare(b.label));

  return { total, activities };
}

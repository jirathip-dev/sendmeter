import { SESSION_TYPES } from "../constants";

export const ACTIVITY_COLORS: Record<string, string> = {
  board: "var(--chart-activity-board)",
  fingerboard: "var(--chart-activity-fingerboard)",
  gym: "var(--chart-activity-gym)",
  outdoor: "var(--chart-activity-outdoor)",
  arc: "var(--chart-activity-arc)",
  antagonist: "var(--chart-activity-antagonist)",
  routine: "var(--chart-activity-routine)",
  campus: "var(--chart-activity-campus)",
  tindeq: "var(--chart-activity-tindeq)",
  auto: "var(--chart-activity-auto)",
  custom: "var(--chart-activity-custom)",
};

const DEFAULT_TYPE_COLOR = "#8E8E93";
const TYPE_LABEL = new Map(SESSION_TYPES.map((type) => [type.id, type.label]));

export function activityColor(type: string): string {
  return ACTIVITY_COLORS[type] ?? DEFAULT_TYPE_COLOR;
}

export function activityLabel(type: string): string {
  const label =
    TYPE_LABEL.get(type) ??
    type
      .trim()
      .replace(/[_-]+/g, " ")
      .replace(/\b\w/g, (letter) => letter.toUpperCase());
  return label || "Unknown activity";
}

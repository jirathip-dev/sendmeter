import { SESSION_TYPES } from "../constants";

export const ACTIVITY_COLORS: Record<string, string> = {
  board: "#2E96F0",
  fingerboard: "#7B83EB",
  gym: "#5B5FC7",
  outdoor: "#2FB6C0",
  arc: "#56C2E6",
  antagonist: "#9B6BE0",
  campus: "#E5743A",
  tindeq: "#E0913D",
  auto: "#3DA5F4",
  custom: "#8E8E93",
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

import type { NavItem, Phase, SessionType } from "./types";

export const PHASES: Phase[] = [
  {
    id: "capacity",
    name: "Capacity",
    color: "#34C759",
    bg: "rgba(52,199,89,0.12)",
    border: "rgba(52,199,89,0.35)",
    acwr: "0.9–1.1",
    weeks: "4–6 wks",
    desc: "Aerobic base, density repeaters, high volume low intensity",
    tools: ["Density repeaters", "ARC traversing", "Low-intensity hangs"],
    intensity: "50–65%",
  },
  {
    id: "strength",
    name: "Strength",
    color: "#FFB800",
    bg: "rgba(255,184,0,0.12)",
    border: "rgba(255,184,0,0.35)",
    acwr: "0.8–1.0",
    weeks: "3–5 wks",
    desc: "Max recruitment, heavy hangs, limit bouldering",
    tools: ["Max hangs 7–10s", "Limit bouldering", "Weighted fingerboard"],
    intensity: "85–100%",
  },
  {
    id: "power",
    name: "Power",
    color: "#FF9500",
    bg: "rgba(255,149,0,0.12)",
    border: "rgba(255,149,0,0.35)",
    acwr: "0.8–1.0",
    weeks: "2–4 wks",
    desc: "Explosive contact strength, campus board, dynamic moves",
    tools: ["Campus board", "Dynamic bouldering", "Limit board problems"],
    intensity: "Max effort",
  },
  {
    id: "execution",
    name: "Execution",
    color: "#7B83EB",
    bg: "rgba(91,95,199,0.12)",
    border: "rgba(91,95,199,0.35)",
    acwr: "0.7–0.9",
    weeks: "2–3 wks",
    desc: "Performance consolidation, projecting, fatigue clearance",
    tools: ["Projecting", "Footwork drills", "Easy-moderate volume"],
    intensity: "Moderate",
  },
];

export const SESSION_TYPES: SessionType[] = [
  {
    id: "fingerboard",
    label: "Fingerboard",
    defaultRpe: 6,
    defaultDuration: 45,
  },
  { id: "board", label: "Board Climbing", defaultRpe: 8, defaultDuration: 60 },
  {
    id: "outdoor",
    label: "Outdoor / Projecting",
    defaultRpe: 5,
    defaultDuration: 180,
  },
  {
    id: "antagonist",
    label: "Antagonist / Mobility",
    defaultRpe: 4,
    defaultDuration: 30,
  },
  { id: "arc", label: "ARC / Traversing", defaultRpe: 4, defaultDuration: 40 },
  { id: "campus", label: "Campus Board", defaultRpe: 9, defaultDuration: 30 },
  { id: "custom", label: "Custom", defaultRpe: 6, defaultDuration: 60 },
  { id: "auto", label: "Auto-tracked", defaultRpe: 6, defaultDuration: 60 },
  { id: "tindeq", label: "Tindeq", defaultRpe: 5, defaultDuration: 30 },
];

export const NAV: NavItem[] = [
  { id: "dashboard", icon: "⬡", label: "Home" },
  { id: "tindeq", icon: "◉", label: "Tindeq" },
  { id: "history", icon: "≡", label: "History" },
];

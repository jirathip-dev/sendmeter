import type { NavItem, Phase, SessionType } from "./types";

// Accessibility note (#547 light-theme contrast audit, closed by #557): these
// four `color` hexes are used both as chart/phase accents (fine — decorative,
// large) and as small (9-15px) text/tag foreground on near-white light
// surfaces (phase banner name, History session-type tags) — e.g. Strength
// #DDB13A on white measures ~2.0:1, well under WCAG AA's 4.5:1 for normal
// text. Each color is shared with dark mode, where the same hex reads at a
// healthy ~8:1+ on the dark canvas, so this is not a per-theme mistake — the
// palette was simply never tuned for use as light-mode text. `textColor`
// (below) is the fix: a `var(--phase-text-<id>)` reference resolved per theme
// in index.css — darkened in light mode to clear AA on every real consumer
// background (plain near-white AND the ~12%-phase-tinted tag/card fills),
// equal to `color` in dark mode. Every text consumer of the palette must use
// `textColor`, never `color` — `color` stays for chart/chip/border/background
// (non-text) uses, where the original saturated hue is correct in both
// themes.
export const PHASES: Phase[] = [
  {
    id: "capacity",
    name: "Capacity",
    color: "#2E96F0",
    textColor: "var(--phase-text-capacity)",
    bg: "rgba(46,150,240,0.12)",
    border: "rgba(46,150,240,0.35)",
    acwr: "0.9–1.1",
    acwrLow: 0.9,
    acwrHigh: 1.1,
    weeks: "4–6 wks",
    desc: "Aerobic base, density repeaters, high volume low intensity",
    tools: ["Density repeaters", "ARC traversing", "Low-intensity hangs"],
    intensity: "50–65%",
  },
  {
    id: "strength",
    name: "Strength",
    color: "#DDB13A",
    textColor: "var(--phase-text-strength)",
    bg: "rgba(221,177,58,0.12)",
    border: "rgba(221,177,58,0.35)",
    acwr: "0.8–1.0",
    acwrLow: 0.8,
    acwrHigh: 1.0,
    weeks: "3–5 wks",
    desc: "Max recruitment, heavy hangs, limit bouldering",
    tools: ["Max hangs 7–10s", "Limit bouldering", "Weighted fingerboard"],
    intensity: "85–100%",
  },
  {
    id: "power",
    name: "Power",
    color: "#E5743A",
    textColor: "var(--phase-text-power)",
    bg: "rgba(229,116,58,0.12)",
    border: "rgba(229,116,58,0.35)",
    acwr: "0.8–1.0",
    acwrLow: 0.8,
    acwrHigh: 1.0,
    weeks: "2–4 wks",
    desc: "Explosive contact strength, campus board, dynamic moves",
    tools: ["Campus board", "Dynamic bouldering", "Limit board problems"],
    intensity: "Max effort",
  },
  {
    id: "execution",
    name: "Execution",
    color: "#7B83EB",
    textColor: "var(--phase-text-execution)",
    bg: "rgba(123,131,235,0.12)",
    border: "rgba(123,131,235,0.35)",
    acwr: "0.7–0.9",
    acwrLow: 0.7,
    acwrHigh: 0.9,
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
  { id: "gym", label: "Gym Session", defaultRpe: 6, defaultDuration: 90 },
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
  // Guided step routines (SL-83) — warm-ups, calisthenics, conditioning.
  { id: "routine", label: "Routine", defaultRpe: 4, defaultDuration: 20 },
  { id: "arc", label: "ARC / Traversing", defaultRpe: 4, defaultDuration: 40 },
  { id: "campus", label: "Campus Board", defaultRpe: 9, defaultDuration: 30 },
  { id: "custom", label: "Custom", defaultRpe: 6, defaultDuration: 60 },
  { id: "auto", label: "Auto-tracked", defaultRpe: 6, defaultDuration: 60 },
  { id: "tindeq", label: "Tindeq", defaultRpe: 5, defaultDuration: 30 },
];

export const NAV: NavItem[] = [
  { id: "dashboard", icon: "⬡", label: "Dashboard" },
  { id: "workout", icon: "▲", label: "Workout" },
  // Display name only — the ViewId stays "tindeq" (internal ids don't churn;
  // the tab may host other force gauges later).
  { id: "tindeq", icon: "◉", label: "Force" },
  { id: "history", icon: "≡", label: "History" },
];

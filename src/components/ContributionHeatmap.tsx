import { useMemo, useState } from "react";
import { SESSION_TYPES } from "../constants";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAY_ROWS = [1, 3, 5] as const; // Mon / Wed / Fri
const WEEKDAY_NAMES = ["Mon", "Wed", "Fri"];
const GAP = 2;

// Each day is colored by its dominant activity type (SL-60); load magnitude
// modulates the opacity (the 4 GitHub-style intensity levels). Hues stay in the
// theme scale — cool blues/teals/purples + warm orange/amber, no red or green.
const TYPE_COLORS: Record<string, string> = {
  board: "#2E96F0",       // electric blue
  fingerboard: "#7B83EB", // violet
  gym: "#5B5FC7",         // indigo
  outdoor: "#2FB6C0",     // teal
  arc: "#56C2E6",         // sky
  antagonist: "#9B6BE0",  // purple
  campus: "#E5743A",      // orange (high intensity)
  tindeq: "#E0913D",      // amber
  auto: "#3DA5F4",        // azure
  custom: "#8E8E93",      // neutral
};
const DEFAULT_TYPE_COLOR = "#8E8E93";
const LEVEL_ALPHA = [0, 0.34, 0.55, 0.78, 1]; // index by level 0..4
const TYPE_LABEL: Record<string, string> = Object.fromEntries(
  SESSION_TYPES.map((t) => [t.id, t.label]),
);

/// #RRGGBB → rgba() at the given alpha (CSS vars can't take a runtime alpha).
function withAlpha(hex: string, a: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

function fmt(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

interface Cell {
  key: string;
  month: number;
  value: number;
  type: string;
  future: boolean;
}

/// Daily training-load heatmap in the GitHub-contribution style: one square per
/// day, columns are Sun–Sat weeks oldest→newest. Each day is hued by its
/// dominant activity type and shaded by total AU (SL-60). Cells are fluid (CSS
/// grid, aspect-ratio 1) so the whole year always fits the container width — no
/// horizontal scrolling, even on a phone.
export default function ContributionHeatmap({
  values,
  weeks = 53,
  unit = "AU",
}: {
  values: Map<string, { total: number; type: string }>;
  weeks?: number;
  unit?: string;
}) {
  const [sel, setSel] = useState<Cell | null>(null);

  const { columns, max } = useMemo(() => {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    // End on the Saturday of the current week; start `weeks` Sundays back.
    const end = new Date(today);
    end.setDate(end.getDate() + (6 - end.getDay()));
    const start = new Date(end);
    start.setDate(start.getDate() - (weeks * 7 - 1));

    const cols: Cell[][] = [];
    const cur = new Date(start);
    let mx = 0;
    for (let w = 0; w < weeks; w++) {
      const col: Cell[] = [];
      for (let d = 0; d < 7; d++) {
        const key = fmt(cur);
        const entry = values.get(key);
        const value = entry?.total ?? 0;
        if (value > mx) mx = value;
        col.push({
          key,
          month: cur.getMonth(),
          value,
          type: entry?.type ?? "",
          future: cur > today,
        });
        cur.setDate(cur.getDate() + 1);
      }
      cols.push(col);
    }
    return { columns: cols, max: Math.max(1, mx) };
  }, [values, weeks]);

  const level = (v: number) => (v <= 0 ? 0 : Math.min(4, Math.ceil((v / max) * 4)));
  const cellColor = (cell: Cell) =>
    cell.value <= 0
      ? "var(--surface-2)"
      : withAlpha(TYPE_COLORS[cell.type] ?? DEFAULT_TYPE_COLOR, LEVEL_ALPHA[level(cell.value)]!);

  // Activity types that actually appear (for the legend), in the palette order.
  const presentTypes = useMemo(() => {
    const seen = new Set<string>();
    for (const v of values.values()) if (v.total > 0) seen.add(v.type);
    return Object.keys(TYPE_COLORS).filter((t) => seen.has(t));
  }, [values]);

  // Month labels: mark a column when the month of its first (Sunday) cell
  // changes; skip a label that would collide with the previous one.
  const monthLabels = useMemo(() => {
    const out: { col: number; label: string }[] = [];
    let last = -1;
    let lastCol = -10;
    columns.forEach((col, i) => {
      const m = col[0]!.month;
      if (m !== last) {
        if (i - lastCol >= 3) {
          out.push({ col: i, label: MONTHS[m]! });
          lastCol = i;
        }
        last = m;
      }
    });
    return out;
  }, [columns]);

  return (
    <div>
      <div style={{ display: "flex", gap: 5 }}>
        {/* Weekday labels — pinned to rows 2/4/6 of the 7-row grid */}
        <div
          style={{
            flexShrink: 0,
            display: "grid",
            gridTemplateRows: "repeat(7, 1fr)",
            rowGap: GAP,
            paddingTop: 14,
          }}
        >
          {[0, 1, 2, 3, 4, 5, 6].map((r) => (
            <div
              key={r}
              style={{
                fontSize: 8,
                color: "var(--ink-faint)",
                display: "flex",
                alignItems: "center",
              }}
            >
              {WEEKDAY_ROWS.includes(r as 1 | 3 | 5)
                ? WEEKDAY_NAMES[WEEKDAY_ROWS.indexOf(r as 1 | 3 | 5)]
                : ""}
            </div>
          ))}
        </div>

        <div style={{ flex: 1, minWidth: 0 }}>
          {/* Month labels at their column's percentage position */}
          <div style={{ position: "relative", height: 14 }}>
            {monthLabels.map(({ col, label }) => (
              <span
                key={col}
                style={{
                  position: "absolute",
                  left: `${(col / columns.length) * 100}%`,
                  fontSize: 9,
                  color: "var(--ink-faint)",
                }}
              >
                {label}
              </span>
            ))}
          </div>
          {/* Fluid grid: 1 column per week, square cells, fills the width */}
          <div
            style={{
              display: "grid",
              gridTemplateColumns: `repeat(${columns.length}, 1fr)`,
              columnGap: GAP,
            }}
          >
            {columns.map((col, ci) => (
              <div
                key={ci}
                style={{
                  display: "grid",
                  gridTemplateRows: "repeat(7, 1fr)",
                  rowGap: GAP,
                }}
              >
                {col.map((cell) => (
                  <div
                    key={cell.key}
                    onClick={() => !cell.future && setSel(cell)}
                    title={cell.future ? "" : `${cell.key} · ${cell.value} ${unit}`}
                    style={{
                      aspectRatio: "1",
                      width: "100%",
                      borderRadius: 2,
                      // Future days are greyed out, not blank, so "today" reads
                      // as the leading edge of the grid (SL-68).
                      background: cell.future ? "var(--surface-1)" : cellColor(cell),
                      opacity: cell.future ? 0.35 : 1,
                      outline: sel?.key === cell.key ? "1.5px solid var(--ink)" : "none",
                      cursor: cell.future ? "default" : "pointer",
                    }}
                  />
                ))}
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Selected day readout — includes the day's dominant activity type */}
      <div style={{ marginTop: 10, fontSize: 10, color: "var(--ink-muted)" }}>
        {sel
          ? `${sel.key} · ${sel.value} ${unit}${sel.type ? ` · ${TYPE_LABEL[sel.type] ?? sel.type}` : ""}`
          : "Tap a day for its load"}
      </div>

      {/* Per-activity-type legend (only the types that appear) */}
      {presentTypes.length > 0 && (
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: "6px 12px",
            marginTop: 8,
            fontSize: 9,
            color: "var(--ink-faint)",
          }}
        >
          {presentTypes.map((t) => (
            <span key={t} style={{ display: "flex", alignItems: "center", gap: 4 }}>
              <span
                style={{
                  width: 9,
                  height: 9,
                  borderRadius: 2,
                  background: TYPE_COLORS[t],
                }}
              />
              {TYPE_LABEL[t] ?? t}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

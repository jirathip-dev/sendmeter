import { useMemo } from "react";
import { useChartHover } from "../hooks/useChartHover";
import { useChartId } from "../hooks/useChartId";
import { ACTIVITY_COLORS, activityColor, activityLabel } from "../lib/activityTypes";
import ChartTooltip from "./ChartTooltip";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAY_ROWS = [1, 3, 5] as const; // Mon / Wed / Fri
const WEEKDAY_NAMES = ["Mon", "Wed", "Fri"];
const GAP = 2;

// Each day is colored by its dominant activity type (SL-60); load magnitude
// modulates the opacity (the 4 GitHub-style intensity levels). Hues stay in the
// theme scale — cool blues/teals/purples + warm orange/amber, no red or green.
const LEVEL_ALPHA = [0, 0.34, 0.55, 0.78, 1]; // index by level 0..4

/// Mix a colour token with transparency without forcing a component to know
/// the current light/dark value. Legacy hex colours still work for callers
/// that pass one directly.
function withAlpha(hex: string, a: number): string {
  if (hex.startsWith("var(")) {
    return `color-mix(in srgb, ${hex} ${Math.round(a * 100)}%, transparent)`;
  }
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
  const [hovered, hoverProps] = useChartHover<string>();
  const summaryId = useChartId("contribution-summary");

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
      : withAlpha(activityColor(cell.type), LEVEL_ALPHA[level(cell.value)]!);

  // Activity types that actually appear (for the legend), in the palette order.
  const presentTypes = useMemo(() => {
    const seen = new Set<string>();
    for (const v of values.values()) if (v.total > 0) seen.add(v.type);
    return Array.from(seen).sort((a, b) => {
      const ai = Object.keys(ACTIVITY_COLORS).indexOf(a);
      const bi = Object.keys(ACTIVITY_COLORS).indexOf(b);
      return (ai < 0 ? Number.MAX_SAFE_INTEGER : ai) - (bi < 0 ? Number.MAX_SAFE_INTEGER : bi);
    });
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
    <div
      role="group"
      aria-label={`Training load contribution heatmap for ${columns.length} weeks`}
      aria-describedby={summaryId}
    >
      <span id={summaryId} className="chart-a11y-summary">
        Each day is a keyboard-accessible data point. Focus a day to hear its training
        load and activity type; future days are unavailable.
      </span>
      <div style={{ display: "flex", gap: 5 }}>
        {/* Weekday labels — absolutely pinned to the Mon/Wed/Fri cell-row
            centers so they track the (tiny, fluid) grid rows. A text-sized grid
            can't compress to the ~4px cell rows on a phone, which is what made
            the labels drift out of alignment. The 14px offset clears the
            month-label row; `100% - 14px` is the exact cell-grid height. */}
        <div style={{ flexShrink: 0, position: "relative", width: 22 }}>
          {WEEKDAY_ROWS.map((r, i) => (
            <span
              key={r}
              style={{
                position: "absolute",
                right: 3,
                top: `calc(14px + (100% - 14px) * ${((r + 0.5) / 7).toFixed(4)})`,
                transform: "translateY(-50%)",
                fontSize: "var(--t-eyebrow)",
                lineHeight: 1,
                whiteSpace: "nowrap",
                color: "var(--ink-faint)",
              }}
            >
              {WEEKDAY_NAMES[i]}
            </span>
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
                  fontSize: "var(--t-eyebrow)",
                  color: "var(--ink-faint)",
                }}
              >
                {label}
              </span>
            ))}
          </div>
          {/* Fluid grid: 1 column per week, square cells, fills the width */}
          <div
            className="chart-scrub"
            style={{
              display: "grid",
              gridTemplateColumns: `repeat(${columns.length}, 1fr)`,
              columnGap: GAP,
            }}
          >
            {columns.map((col, ci) => {
              const hAlign =
                ci < columns.length / 3 ? "start" : ci > (columns.length * 2) / 3 ? "end" : "center";
              return (
                <div
                  key={ci}
                  style={{
                    display: "grid",
                    gridTemplateRows: "repeat(7, 1fr)",
                    rowGap: GAP,
                  }}
                >
                  {col.map((cell, di) => (
                    <button
                      key={cell.key}
                      type="button"
                      disabled={cell.future}
                      style={{
                        position: "relative",
                        aspectRatio: "1",
                        width: "100%",
                        minWidth: 0,
                        minHeight: 0,
                        padding: 0,
                        border: 0,
                        borderRadius: 2,
                        appearance: "none",
                        font: "inherit",
                        color: "inherit",
                        // Future days are greyed out, not blank, so "today" reads
                        // as the leading edge of the grid (SL-68).
                        background: cell.future ? "var(--surface-1)" : cellColor(cell),
                        opacity: cell.future ? 0.35 : 1,
                        outline: hovered === cell.key ? "1.5px solid var(--ink)" : "none",
                        cursor: cell.future ? "default" : "pointer",
                      }}
                      aria-label={`${cell.key}: ${cell.value > 0 ? `${cell.value} ${unit}${cell.type ? `, ${activityLabel(cell.type)}` : ""}` : "rest"}`}
                      {...(cell.future ? {} : hoverProps(cell.key))}
                    >
                      {hovered === cell.key && (
                        <ChartTooltip
                          align={hAlign}
                          style={di < 4 ? { bottom: "auto", top: "100%", marginTop: 6 } : undefined}
                        >
                          {cell.value > 0
                            ? `${cell.key} · ${cell.value} ${unit}${cell.type ? ` · ${activityLabel(cell.type)}` : ""}`
                            : `${cell.key} · rest`}
                        </ChartTooltip>
                      )}
                    </button>
                  ))}
                </div>
              );
            })}
          </div>
        </div>
      </div>

      {/* Per-activity-type legend (only the types that appear) */}
      {presentTypes.length > 0 && (
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: "6px 12px",
            marginTop: 8,
            fontSize: "var(--t-eyebrow)",
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
                  background: activityColor(t),
                }}
              />
              {activityLabel(t)}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

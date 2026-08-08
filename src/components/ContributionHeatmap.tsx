import { useMemo } from "react";
import type { KeyboardEvent as ReactKeyboardEvent } from "react";
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
  const [hovered, , select, , surface2DProps] = useChartHover<string>();
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

  const selectableCells = columns.flatMap((column, ci) =>
    column.map((cell, di) => ({ cell, ci, di })).filter(({ cell }) => !cell.future),
  );
  const selectedCell = hovered === null
    ? undefined
    : selectableCells.find(({ cell }) => cell.key === hovered);
  const selectAt = (ci: number, di: number) => {
    const cell = columns[ci]?.[di];
    if (cell && !cell.future) select(cell.key);
  };
  const onGridKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (selectableCells.length === 0) return;
    const origin = selectedCell ?? selectableCells[0]!;
    let ci = origin.ci;
    let di = origin.di;
    const direction = event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 1;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") ci += direction;
    if (event.key === "ArrowUp" || event.key === "ArrowDown") di += direction;
    if (event.key === "Home") ci = 0;
    if (event.key === "End") ci = columns.length - 1;
    if (event.key === "Enter" || event.key === " ") {
      ci = origin.ci;
      di = origin.di;
    }
    const isNavigation = event.key.startsWith("Arrow") || event.key === "Home" || event.key === "End" || event.key === "Enter" || event.key === " ";
    if (!isNavigation) return;
    event.preventDefault();
    // Clamp at visual edges and never move into a future/unavailable cell.
    if (ci >= 0 && ci < columns.length && di >= 0 && di < 7) {
      const next = columns[ci]![di]!;
      if (!next.future) selectAt(ci, di);
    }
  };

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
        Use the heatmap's single keyboard surface and arrow keys to inspect each day;
        future days are unavailable.
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
            data-chart-hit-surface="contribution-heatmap"
            role="grid"
            tabIndex={0}
            aria-rowcount={7}
            aria-colcount={columns.length}
            aria-activedescendant={
              selectedCell ? `${summaryId}-cell-${selectedCell.cell.key}` : undefined
            }
            aria-label={
              selectedCell
                ? `${selectedCell.cell.key}: ${selectedCell.cell.value > 0 ? `${selectedCell.cell.value} ${unit}${selectedCell.cell.type ? `, ${activityLabel(selectedCell.cell.type)}` : ""}` : "rest"}`
                : "Daily training load; use arrow keys to inspect days"
            }
            aria-describedby={summaryId}
            onKeyDown={onGridKeyDown}
            {...surface2DProps(
              selectableCells.map(({ cell }) => cell.key),
              { width: columns.length, height: 7 },
              (index) => {
                const point = selectableCells[index]!;
                return { x: point.ci + 0.5, y: point.di + 0.5 };
              },
            )}
            style={{
              display: "grid",
              gridTemplateColumns: `repeat(${columns.length}, 1fr)`,
              columnGap: GAP,
              gridTemplateRows: `repeat(7, auto)`,
              rowGap: GAP,
              minHeight: 44,
            }}
          >
            {Array.from({ length: 7 }, (_, di) => (
              <div
                key={di}
                role="row"
                aria-rowindex={di + 1}
                style={{
                  display: "grid",
                  gridTemplateColumns: `repeat(${columns.length}, 1fr)`,
                  columnGap: GAP,
                  gridColumn: "1 / -1",
                }}
              >
                {columns.map((col, ci) => {
                  const cell = col[di]!;
                  const hAlign =
                    ci < columns.length / 3 ? "start" : ci > (columns.length * 2) / 3 ? "end" : "center";
                  return (
                    <div
                      key={cell.key}
                      id={`${summaryId}-cell-${cell.key}`}
                      role="gridcell"
                      aria-colindex={ci + 1}
                      aria-selected={hovered === cell.key}
                      aria-disabled={cell.future}
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
                    </div>
                  );
                })}
              </div>
            ))}
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

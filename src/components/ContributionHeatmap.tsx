import { useEffect, useMemo, useRef, useState } from "react";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["", "Mon", "", "Wed", "", "Fri", ""]; // Sun-start rows; label odd rows
const CELL = 12;
const GAP = 3;
const STEP = CELL + GAP;
const MONTH_ROW = 15;

// GitHub-style level colors — themed empty cell + 4 green intensities.
const COLORS = [
  "var(--surface-2)",
  "rgba(52,199,89,0.32)",
  "rgba(52,199,89,0.52)",
  "rgba(52,199,89,0.74)",
  "rgba(52,199,89,0.96)",
];

function fmt(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

interface Cell {
  key: string;
  month: number;
  value: number;
  future: boolean;
}

/// Daily training-load heatmap in the GitHub-contribution style: one square per
/// day, columns are Sun–Sat weeks oldest→newest, colored by that day's total AU.
export default function ContributionHeatmap({
  values,
  weeks = 53,
  unit = "AU",
}: {
  values: Map<string, number>;
  weeks?: number;
  unit?: string;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
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
        const value = values.get(key) ?? 0;
        if (value > mx) mx = value;
        col.push({ key, month: cur.getMonth(), value, future: cur > today });
        cur.setDate(cur.getDate() + 1);
      }
      cols.push(col);
    }
    return { columns: cols, max: Math.max(1, mx) };
  }, [values, weeks]);

  const level = (v: number) => (v <= 0 ? 0 : Math.min(4, Math.ceil((v / max) * 4)));

  // Month labels: mark a column when the month of its first (Sunday) cell changes.
  const monthLabels = useMemo(() => {
    const out: { col: number; label: string }[] = [];
    let last = -1;
    columns.forEach((col, i) => {
      const m = col[0]!.month;
      if (m !== last) {
        out.push({ col: i, label: MONTHS[m]! });
        last = m;
      }
    });
    return out;
  }, [columns]);

  // Start scrolled to the most recent weeks.
  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollLeft = scrollRef.current.scrollWidth;
  }, [columns]);

  return (
    <div>
      <div style={{ display: "flex", gap: 6 }}>
        {/* Weekday labels */}
        <div style={{ flexShrink: 0, paddingTop: MONTH_ROW }}>
          <div style={{ display: "flex", flexDirection: "column", gap: GAP }}>
            {WEEKDAYS.map((w, i) => (
              <div
                key={i}
                style={{ height: CELL, fontSize: 8, lineHeight: `${CELL}px`, color: "var(--ink-faint)" }}
              >
                {w}
              </div>
            ))}
          </div>
        </div>

        {/* Scrollable grid */}
        <div ref={scrollRef} style={{ overflowX: "auto", flex: 1 }}>
          <div style={{ width: columns.length * STEP }}>
            {/* Month labels */}
            <div style={{ position: "relative", height: MONTH_ROW }}>
              {monthLabels.map(({ col, label }) => (
                <span
                  key={col}
                  style={{
                    position: "absolute",
                    left: col * STEP,
                    fontSize: 9,
                    color: "var(--ink-faint)",
                  }}
                >
                  {label}
                </span>
              ))}
            </div>
            {/* Cells */}
            <div style={{ display: "flex", gap: GAP }}>
              {columns.map((col, ci) => (
                <div key={ci} style={{ display: "flex", flexDirection: "column", gap: GAP }}>
                  {col.map((cell) => (
                    <div
                      key={cell.key}
                      onClick={() => !cell.future && setSel(cell)}
                      title={cell.future ? "" : `${cell.key} · ${cell.value} ${unit}`}
                      style={{
                        width: CELL,
                        height: CELL,
                        borderRadius: 2,
                        background: cell.future ? "transparent" : COLORS[level(cell.value)],
                        outline:
                          sel?.key === cell.key ? "1.5px solid var(--ink)" : "none",
                        outlineOffset: 0,
                        cursor: cell.future ? "default" : "pointer",
                      }}
                    />
                  ))}
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Selected day readout + legend */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginTop: 10,
          fontSize: 10,
          color: "var(--ink-faint)",
        }}
      >
        <span style={{ color: "var(--ink-muted)" }}>
          {sel ? `${sel.key} · ${sel.value} ${unit}` : "Tap a day for its load"}
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
          Less
          {COLORS.map((c, i) => (
            <span key={i} style={{ width: 10, height: 10, borderRadius: 2, background: c }} />
          ))}
          More
        </span>
      </div>
    </div>
  );
}

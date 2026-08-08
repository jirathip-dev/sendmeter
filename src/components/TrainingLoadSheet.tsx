import { useMemo } from "react";
import { useChartHover } from "../hooks/useChartHover";
import { today } from "../lib/dates";
import { activityMix } from "../lib/trainingLoad";
import { activityColor } from "../lib/activityTypes";
import type { Session, WeeklyLoad } from "../types";
import ChartTooltip from "./ChartTooltip";
import ContributionHeatmap from "./ContributionHeatmap";
import Sheet from "./Sheet";

/** Rounds a share for display; a real but sub-1% sliver reads as "<1%" rather than "0%". */
function formatSharePercent(percentage: number): string {
  if (percentage > 0 && percentage < 1) return "<1%";
  return `${Math.round(percentage)}%`;
}

function ActivityMixBar({ activities }: { activities: ReturnType<typeof activityMix>["activities"] }) {
  const description = activities
    .map((activity) => `${activity.label} ${formatSharePercent(activity.percentage)}`)
    .join(", ");

  return (
    <div
      role="img"
      aria-label={`Activity mix: ${description}`}
      data-testid="activity-mix-bar"
      style={{
        display: "flex",
        width: "100%",
        height: 10,
        overflow: "hidden",
        borderRadius: 5,
        background: "var(--surface-2)",
        marginBottom: 12,
      }}
    >
      {activities.map((activity, index) => (
        <span
          key={activity.type}
          aria-hidden="true"
          data-activity-type={activity.type}
          style={{
            width: `${activity.percentage}%`,
            height: "100%",
            flexShrink: 0,
            background: activityColor(activity.type),
            boxShadow:
              index < activities.length - 1 && activity.percentage >= 1
                ? "inset -1px 0 rgba(255, 255, 255, 0.7)"
                : "none",
          }}
        />
      ))}
    </div>
  );
}

function weekDelta(cur: number, prev: number): { pct: number; arrow: string; color: string } | null {
  if (prev <= 0) return null;
  const pct = ((cur - prev) / prev) * 100;
  return {
    pct,
    arrow: pct > 0 ? "▲" : pct < 0 ? "▼" : "",
    color: Math.abs(pct) < 1 ? "var(--ink-muted)" : pct > 0 ? "var(--success)" : "var(--danger)",
  };
}

export default function TrainingLoadSheet({
  weeklyLoads,
  sessions,
  onClose,
}: {
  weeklyLoads: WeeklyLoad[];
  sessions: Session[];
  onClose: () => void;
}) {
  const [hoveredWeek, hoverWeekProps] = useChartHover<number>();
  const maxW = Math.max(...weeklyLoads.map((week) => week.total), 1);
  const current = weeklyLoads[weeklyLoads.length - 1]?.total ?? 0;
  const previous = weeklyLoads[weeklyLoads.length - 2]?.total ?? 0;
  const currentDelta = weekDelta(current, previous);
  const endDate = today();
  const daily = useMemo(() => {
    const accumulated = new Map<string, { total: number; byType: Map<string, number> }>();
    for (const session of sessions) {
      const entry = accumulated.get(session.date) ?? { total: 0, byType: new Map<string, number>() };
      entry.total += session.load;
      entry.byType.set(session.type, (entry.byType.get(session.type) ?? 0) + session.load);
      accumulated.set(session.date, entry);
    }
    const result = new Map<string, { total: number; type: string }>();
    for (const [date, entry] of accumulated) {
      const dominant = Array.from(entry.byType).sort((a, b) => b[1] - a[1])[0]?.[0] ?? "";
      result.set(date, { total: entry.total, type: dominant });
    }
    return result;
  }, [sessions]);
  const mix = useMemo(() => activityMix(sessions, endDate), [sessions, endDate]);

  return (
    <Sheet
      title="Training Load"
      subtitle="Your training volume in arbitrary units (AU)."
      onClose={onClose}
    >

      <div className="card">
        <div
          className="card-title"
          style={{
            marginBottom: 12,
            display: "flex",
            justifyContent: "space-between",
            alignItems: "baseline",
          }}
        >
          <span>Weekly load</span>
          {currentDelta && (
            <span
              style={{
                fontSize: "var(--t-2xs)",
                fontVariantNumeric: "tabular-nums",
                color: currentDelta.color,
              }}
            >
              {currentDelta.arrow} {Math.abs(currentDelta.pct).toFixed(0)}% vs prior wk
            </span>
          )}
        </div>
        <div
          className="chart-scrub"
          style={{ display: "flex", gap: 8, alignItems: "flex-end", height: 88 }}
        >
          {weeklyLoads.map((week, index) => {
            const delta = index > 0 ? weekDelta(week.total, weeklyLoads[index - 1]!.total) : null;
            return (
              <div
                key={index}
                style={{
                  flex: 1,
                  position: "relative",
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 4,
                  height: "100%",
                  justifyContent: "flex-end",
                }}
                {...hoverWeekProps(index)}
              >
                {hoveredWeek === index && (
                  <ChartTooltip
                    align={
                      index < 2
                        ? "start"
                        : index > weeklyLoads.length - 3
                          ? "end"
                          : "center"
                    }
                  >
                    <div style={{ fontWeight: 600 }}>{week.label}</div>
                    <div style={{ color: "var(--ink-muted)" }}>
                      {week.total.toLocaleString()} AU
                    </div>
                    {delta && (
                      <div style={{ color: delta.color }}>
                        {delta.arrow} {Math.abs(delta.pct).toFixed(0)}% vs prior wk
                      </div>
                    )}
                  </ChartTooltip>
                )}
                <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>
                  {week.total.toLocaleString()}
                </span>
                <div
                  style={{
                    width: "100%",
                    height: Math.max((week.total / maxW) * 64, 2),
                    background:
                      index === weeklyLoads.length - 1 ? "var(--success)" : "var(--border)",
                    borderRadius: 3,
                    opacity: hoveredWeek === null || hoveredWeek === index ? 1 : 0.5,
                    boxShadow: hoveredWeek === index ? "0 0 0 1.5px var(--ink)" : "none",
                    cursor: "pointer",
                    transition: "opacity 0.1s",
                  }}
                />
                <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)" }}>
                  {week.label}
                </span>
              </div>
            );
          })}
        </div>
      </div>

      <div className="card" style={{ marginTop: 10 }}>
        <div className="card-title" style={{ marginBottom: 12 }}>
          Daily load
        </div>
        <ContributionHeatmap values={daily} />
      </div>

      <div className="card" style={{ marginTop: 10 }}>
        <div className="card-title">Activity mix</div>
        <div className="label-eyebrow" style={{ marginTop: 2, marginBottom: 12 }}>
          Last 28 days · {mix.total.toLocaleString()} AU
        </div>
        {mix.activities.length === 0 ? (
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.5 }}>
            No training load in the last 28 days. Log a session to see how your activities
            contribute.
          </div>
        ) : (
          <>
            <ActivityMixBar activities={mix.activities} />
            {mix.activities.map((activity) => (
              <div
                key={activity.type}
                style={{
                  display: "grid",
                  gridTemplateColumns: "10px minmax(0, 1fr) auto",
                  gap: 8,
                  alignItems: "center",
                  marginTop: 9,
                }}
              >
                <span
                  aria-hidden="true"
                  style={{
                    width: 9,
                    height: 9,
                    borderRadius: 2,
                    background: activityColor(activity.type),
                  }}
                />
                <span
                  style={{
                    fontSize: "var(--t-xs)",
                    color: "var(--ink)",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {activity.label}
                </span>
                <span
                  style={{
                    fontSize: "var(--t-xs)",
                    color: "var(--ink-muted)",
                    fontVariantNumeric: "tabular-nums",
                  }}
                >
                  {activity.load.toLocaleString()} AU · {formatSharePercent(activity.percentage)}
                </span>
              </div>
            ))}
          </>
        )}
      </div>

    </Sheet>
  );
}

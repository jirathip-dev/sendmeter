import { useChartHover } from "../hooks/useChartHover";
import type { WorkoutDetail } from "../types";
import ChartTooltip from "./ChartTooltip";
import WorkoutHrChart from "./WorkoutHrChart";

interface Props {
  detail: WorkoutDetail;
}

function StatRow({ label, value }: { label: string; value: string }) {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        fontSize: "var(--t-xs)",
        marginBottom: 4,
      }}
    >
      <span style={{ color: "var(--ink-muted)" }}>{label}</span>
      <span style={{ color: "var(--ink)" }}>{value}</span>
    </div>
  );
}

export default function WorkoutDetailPanel({ detail }: Props) {
  const [hovered, hoverProps] = useChartHover<number>();
  const attemptCount = detail.attempts.length;
  const edgeThird = Math.max(1, Math.floor(attemptCount / 3));

  return (
    <div
      style={{
        marginTop: 10,
        paddingTop: 10,
        borderTop: "1px solid var(--hairline)",
      }}
    >
      <div className="grid-2" style={{ gap: 16 }}>
        <div>
          <StatRow
            label="Avg HR"
            value={detail.avgHr ? `${Math.round(detail.avgHr)} bpm` : "—"}
          />
          <StatRow
            label="Max HR"
            value={detail.maxHr ? `${Math.round(detail.maxHr)} bpm` : "—"}
          />
          <StatRow
            label="Active"
            value={
              detail.activeKcal ? `${Math.round(detail.activeKcal)} kcal` : "—"
            }
          />
        </div>
        <div>
          <StatRow
            label="Elev gain"
            value={`+${detail.elevationGainM.toFixed(1)}m`}
          />
          <StatRow
            label="Attempts"
            value={`${detail.attemptsConfirmed} conf · ${detail.attemptsDetected} det`}
          />
          <StatRow
            label="RPE"
            value={`${detail.rpeConfirmed ?? "—"} conf · ${
              detail.rpePredicted !== null
                ? detail.rpePredicted.toFixed(1)
                : "—"
            } pred`}
          />
        </div>
      </div>

      {/* Continuous HR timeline with climb/rest segments (SL-42); renders
          nothing when the workout kept no raw trace */}
      <WorkoutHrChart
        workoutId={detail.id}
        startedAt={detail.startedAt}
        attempts={detail.attempts}
        source={detail.source}
      />

      {detail.attempts.length === 0 ? (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
          No attempts detected
        </div>
      ) : (
        <>
          <div className="label-eyebrow" style={{ margin: "10px 0 6px" }}>
            Attempts · effort
          </div>
          <div
            className="chart-scrub"
            style={{
              display: "flex",
              gap: 3,
              alignItems: "flex-end",
              height: 56,
            }}
          >
            {detail.attempts.map((a, i) => (
              <div
                key={i}
                style={{
                  flex: 1,
                  maxWidth: 22,
                  position: "relative",
                  height: "100%",
                  display: "flex",
                  alignItems: "flex-end",
                  cursor: "pointer",
                }}
                {...hoverProps(i)}
              >
                {hovered === i && (
                  <ChartTooltip
                    align={
                      i < edgeThird
                        ? "start"
                        : i > attemptCount - 1 - edgeThird
                          ? "end"
                          : "center"
                    }
                  >
                    <div>Attempt {i + 1}</div>
                    {a.effortScore != null && (
                      <div>Effort {a.effortScore.toFixed(1)}</div>
                    )}
                    <div>
                      {Math.round(a.durationS)}s · +{a.elevationGainM.toFixed(1)}m
                    </div>
                    {a.avgHr != null && (
                      <div>
                        avg {Math.round(a.avgHr)}
                        {a.peakHr != null ? ` / peak ${Math.round(a.peakHr)}` : ""} bpm
                      </div>
                    )}
                  </ChartTooltip>
                )}
                <div
                  style={{
                    width: "100%",
                    height: Math.max(4, ((a.effortScore ?? 0) / 10) * 48),
                    background: "var(--success)",
                    borderRadius: 2,
                    opacity: hovered === null || hovered === i ? 1 : 0.5,
                    boxShadow: hovered === i ? "0 0 0 1.5px var(--ink)" : "none",
                    transition: "opacity 0.1s",
                  }}
                />
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

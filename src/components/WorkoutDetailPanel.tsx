import { useEffect, useRef, useState } from "react";
import { fetchWorkoutRaw } from "../lib/repo";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { workoutTimeMaxS } from "../lib/workoutChartAxis";
import type { WorkoutDetail, WorkoutHrSample } from "../types";
import WorkoutEffortChart from "./WorkoutEffortChart";
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
  // The HR trace is fetched here, not inside the HR chart, because the effort
  // chart needs the same x domain — and that domain depends on where the
  // trace ends (SL-183).
  const samples = useCancellableFetch<WorkoutHrSample[] | null>(
    () => fetchWorkoutRaw(detail.id),
    null,
    detail.id,
  );

  // One measured width for the whole stack: PAD is in viewBox units, so two
  // charts with different viewBox widths would reserve different fractions
  // of their rendered width for the y-label gutter and drift apart.
  const hostRef = useRef<HTMLDivElement>(null);
  const [chartW, setChartW] = useState(300);
  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setChartW(Math.max(200, el.clientWidth)));
    ro.observe(el);
    setChartW(Math.max(200, el.clientWidth));
    return () => ro.disconnect();
  }, []);

  const tMax = workoutTimeMaxS({
    startedAt: detail.startedAt,
    endedAt: detail.endedAt,
    attempts: detail.attempts,
    samples,
  });
  const hasAttempts = detail.attempts.length > 0;

  return (
    <div
      ref={hostRef}
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
        startedAt={detail.startedAt}
        attempts={detail.attempts}
        samples={samples}
        tMax={tMax}
        width={chartW}
        // The effort chart below carries the shared time axis when it renders.
        showTimeAxis={!hasAttempts}
        source={detail.source}
      />

      {!hasAttempts ? (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
          No attempts detected
        </div>
      ) : (
        <>
          <div className="label-eyebrow" style={{ margin: "10px 0 6px" }}>
            Attempts · effort
          </div>
          <WorkoutEffortChart
            startedAt={detail.startedAt}
            attempts={detail.attempts}
            tMax={tMax}
            width={chartW}
            showTimeAxis
          />
        </>
      )}
    </div>
  );
}

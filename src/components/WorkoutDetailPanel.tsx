import { useState } from "react";
import type { WorkoutDetail } from "../types";

interface Props {
  detail: WorkoutDetail;
}

function StatRow({ label, value }: { label: string; value: string }) {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        fontSize: 11,
        marginBottom: 4,
      }}
    >
      <span style={{ color: "var(--ink-muted)" }}>{label}</span>
      <span style={{ color: "var(--ink)" }}>{value}</span>
    </div>
  );
}

export default function WorkoutDetailPanel({ detail }: Props) {
  const [selectedIdx, setSelectedIdx] = useState<number | null>(null);

  const selected =
    selectedIdx !== null ? detail.attempts[selectedIdx] : undefined;

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

      {detail.attempts.length === 0 ? (
        <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 8 }}>
          No attempts detected
        </div>
      ) : (
        <>
          <div className="label-eyebrow" style={{ margin: "10px 0 6px" }}>
            Attempts · effort
          </div>
          <div
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
                title={`${Math.round(a.durationS)}s · effort ${
                  a.effortScore?.toFixed(1) ?? "—"
                } · +${a.elevationGainM.toFixed(1)}m`}
                onClick={(e) => {
                  e.stopPropagation();
                  setSelectedIdx(selectedIdx === i ? null : i);
                }}
                style={{
                  flex: 1,
                  maxWidth: 22,
                  height: Math.max(4, ((a.effortScore ?? 0) / 10) * 48),
                  background: selectedIdx === i ? "var(--warning)" : "var(--success)",
                  borderRadius: 2,
                  cursor: "pointer",
                }}
              />
            ))}
          </div>
          {selected && selectedIdx !== null && (
            <div style={{ fontSize: 10, color: "var(--ink-muted)", marginTop: 6 }}>
              Attempt {selectedIdx + 1} — {Math.round(selected.durationS)}s ·
              effort {selected.effortScore?.toFixed(1) ?? "—"} · +
              {selected.elevationGainM.toFixed(1)}m
              {selected.avgHr &&
                ` · avg ${Math.round(selected.avgHr)}${
                  selected.peakHr ? ` / peak ${Math.round(selected.peakHr)}` : ""
                } bpm`}
            </div>
          )}
        </>
      )}
    </div>
  );
}

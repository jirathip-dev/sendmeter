import { PHASES } from "../constants";
import { today } from "../lib/dates";
import { useChartHover } from "../hooks/useChartHover";
import ChartTooltip from "./ChartTooltip";
import type { PhaseId, PhasePeriod } from "../types";

interface Props {
  currentPhase: PhaseId;
  phasePeriods: PhasePeriod[];
  onSetPhase: (id: PhaseId) => void;
}

function periodDays(p: PhasePeriod): number {
  const end = p.endedOn ?? today();
  return (
    Math.floor(
      (new Date(end).getTime() - new Date(p.startedOn).getTime()) / 86400000,
    ) + 1
  );
}

const ZONES = [
  { range: "< 0.7", label: "Under-training", color: "#7B83EB" },
  { range: "0.7–0.8", label: "Low — build carefully", color: "#7B83EB" },
  { range: "0.8–1.3", label: "Optimal — safe progression", color: "#34C759" },
  { range: "1.3–1.5", label: "Caution — monitor closely", color: "#FFB800" },
  { range: "> 1.5", label: "Danger — injury risk", color: "#FF453A" },
];

export default function PhasesView({
  currentPhase,
  phasePeriods,
  onSetPhase,
}: Props) {
  const [hoveredPeriod, hoverPeriodProps] = useChartHover<number>();
  const chronological = [...phasePeriods].sort((a, b) =>
    a.startedOn.localeCompare(b.startedOn),
  );
  const totalDays = chronological.reduce((s, p) => s + periodDays(p), 0);

  const segments = chronological.reduce<
    { p: PhasePeriod; days: number; startPct: number; widthPct: number }[]
  >((acc, p) => {
    const days = periodDays(p);
    const prevEnd = acc.length > 0 ? acc[acc.length - 1]!.startPct + acc[acc.length - 1]!.widthPct : 0;
    const widthPct = totalDays > 0 ? (days / totalDays) * 100 : 0;
    acc.push({ p, days, startPct: prevEnd, widthPct });
    return acc;
  }, []);

  function phaseHistory(id: PhaseId): string | null {
    const mine = phasePeriods.filter((p) => p.phase === id);
    if (mine.length === 0) return null;
    const days = mine.reduce((s, p) => s + periodDays(p), 0);
    const wks = (days / 7).toFixed(1);
    return `${mine.length} period${mine.length === 1 ? "" : "s"} · ${wks} wks total`;
  }

  return (
    <div>
      <div className="section-head">PHASES</div>
      <div className="section-sub">Tap to set your current training phase.</div>

      {PHASES.map((p) => (
        <div
          key={p.id}
          className="phase-card"
          style={{
            background: p.bg,
            border: `1px solid ${currentPhase === p.id ? p.color : p.border}`,
          }}
          onClick={() => onSetPhase(p.id)}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "flex-start",
            }}
          >
            <div style={{ flex: 1 }}>
              <div
                style={{
                  display: "flex",
                  gap: 8,
                  alignItems: "center",
                  marginBottom: 6,
                }}
              >
                <span
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontSize: 18,
                    fontWeight: 800,
                    color: p.color,
                  }}
                >
                  {p.name.toUpperCase()}
                </span>
                {currentPhase === p.id && (
                  <span
                    className="tag"
                    style={{ background: p.color, color: "var(--ink)" }}
                  >
                    Active
                  </span>
                )}
              </div>
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 10 }}>
                {p.desc}
              </div>
              <div style={{ display: "flex", gap: 5, flexWrap: "wrap" }}>
                {p.tools.map((t) => (
                  <span
                    key={t}
                    className="tag"
                    style={{
                      background: "var(--surface-1)",
                      color: "var(--ink-muted)",
                      border: "1px solid var(--border)",
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
            </div>
            <div style={{ textAlign: "right", flexShrink: 0, marginLeft: 12 }}>
              <div
                style={{
                  fontSize: 9,
                  color: "var(--ink-muted)",
                  textTransform: "uppercase",
                  marginBottom: 3,
                }}
              >
                ACWR
              </div>
              <div
                style={{
                  fontSize: 17,
                  color: p.color,
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                }}
              >
                {p.acwr}
              </div>
              <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 3 }}>
                {p.weeks}
              </div>
              <div style={{ fontSize: 10, color: "var(--ink-faint)" }}>
                {p.intensity}
              </div>
              {phaseHistory(p.id) && (
                <div style={{ fontSize: 9, color: "var(--ink-muted)", marginTop: 4 }}>
                  {phaseHistory(p.id)}
                </div>
              )}
            </div>
          </div>
        </div>
      ))}

      {/* Phase timeline */}
      {chronological.length >= 2 && totalDays > 0 && (
        <div className="card" style={{ marginBottom: 10 }}>
          <div
            style={{
              fontSize: 10,
              color: "var(--ink-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 10,
            }}
          >
            Phase Timeline
          </div>
          <div style={{ position: "relative" }}>
            {hoveredPeriod !== null &&
              segments[hoveredPeriod] &&
              (() => {
                const seg = segments[hoveredPeriod]!;
                const info = PHASES.find((x) => x.id === seg.p.phase);
                return (
                  <ChartTooltip
                    align="center"
                    style={{ left: `${seg.startPct + seg.widthPct / 2}%` }}
                  >
                    {info?.name ?? seg.p.phase} · {seg.p.startedOn} →{" "}
                    {seg.p.endedOn ?? "now"} · {(seg.days / 7).toFixed(1)} wks
                  </ChartTooltip>
                );
              })()}
            <div
              style={{
                display: "flex",
                height: 10,
                borderRadius: 3,
                overflow: "hidden",
              }}
            >
              {segments.map(({ p, widthPct }, i) => {
                const info = PHASES.find((x) => x.id === p.phase);
                return (
                  <div
                    key={p.id}
                    style={{
                      width: `${widthPct}%`,
                      minWidth: 4,
                      background: info?.color ?? "var(--border)",
                      opacity:
                        hoveredPeriod === null
                          ? p.endedOn === null
                            ? 1
                            : 0.65
                          : hoveredPeriod === i
                            ? 1
                            : 0.3,
                      cursor: "pointer",
                      transition: "opacity 0.1s",
                    }}
                    {...hoverPeriodProps(i)}
                  />
                );
              })}
            </div>
          </div>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: 9,
              color: "var(--ink-faint)",
              marginTop: 5,
            }}
          >
            <span>{chronological[0]!.startedOn}</span>
            <span>now</span>
          </div>
        </div>
      )}

      <div className="card" style={{ marginTop: 6 }}>
        <div
          style={{
            fontSize: 10,
            color: "var(--ink-muted)",
            textTransform: "uppercase",
            letterSpacing: "0.1em",
            marginBottom: 12,
          }}
        >
          ACWR Risk Zones
        </div>
        {ZONES.map((z) => (
          <div key={z.range} className="zone-row">
            <div className="zone-dot" style={{ background: z.color }} />
            <span style={{ fontSize: 11, color: "var(--ink-muted)", width: 64 }}>
              {z.range}
            </span>
            <span style={{ fontSize: 11, color: "var(--ink-muted)" }}>{z.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

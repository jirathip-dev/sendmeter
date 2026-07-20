import { useState } from "react";
import { predictForce } from "../lib/force-curve";
import type { ForceCurveModel, PeriodCurve } from "../lib/force-curve";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import InfoDot from "./InfoDot";
import SvgChartTooltip from "./SvgChartTooltip";

export interface GaugeTarget {
  kg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  label: string;
}

interface Props {
  tag: string;
  /// Computed by the parent (ForceView auto-computes per selected tag).
  model: ForceCurveModel | null;
  /// Trailing-window models for the curve-shift overlays (SL-80c).
  periods: PeriodCurve[];
  computing: boolean;
  error: string | null;
}

/// One hue per trailing window — hex literals because SVG attributes can't
/// resolve CSS vars (matches the palette's chart convention).
const PERIOD_COLORS: Record<string, string> = {
  "30d": "#2E96F0",
  "90d": "#7B83EB",
  "180d": "#DDB13A",
  "1y": "#E0913D",
  "2y": "#E5743A",
  "3y": "#8E8E93",
};

interface Overlay {
  label: string;
  color: string;
  model: ForceCurveModel;
}

const W = 300;
const H = 130;
const PAD = { top: 10, bottom: 18, left: 30, right: 8 };

function CurvePlot({ model, overlays }: { model: ForceCurveModel; overlays: Overlay[] }) {
  const [hovered, hoverProps] = useChartHover<number>();
  const pts = model.points;
  const tMin = Math.log10(pts[0]!.windowS);
  const tMax = Math.log10(Math.max(pts[pts.length - 1]!.windowS, 10));
  const yMax = Math.max(model.maxF, ...overlays.map((o) => o.model.maxF)) * 1.1;
  // x is log-scaled (window size spans 1-120s) so it stays a custom
  // function; useSvgScale only covers linear scales.
  const px = (w: number) =>
    PAD.left +
    ((Math.log10(w) - tMin) / Math.max(tMax - tMin, 0.01)) *
      (W - PAD.left - PAD.right);
  const { y: py } = useSvgScale(W, H, PAD, 0, 1, 0, yMax);

  // A model's fitted hyperbola sampled along the FULL axis (1s → end). At
  // short durations CF + W′/t exceeds the best short-window force, so
  // predictForce clamps to maxF — the flat left segment is that cap (short
  // efforts are peak/RFD-dominated and excluded from the fit).
  const hyperbola = (m: ForceCurveModel): string => {
    const steps = 40;
    const parts: string[] = [];
    for (let i = 0; i <= steps; i++) {
      const logT = tMin + ((tMax - tMin) * i) / steps;
      const t = Math.pow(10, logT);
      parts.push(`${px(t).toFixed(1)},${py(predictForce(m, t)).toFixed(1)}`);
    }
    return parts.join(" ");
  };
  const fitted = model.cf !== null ? hyperbola(model) : "";

  const yTicks = [0, yMax / 2, yMax];
  const xTicks = [1, 10, 60, 120].filter((t) => Math.log10(t) <= tMax + 0.01);

  return (
    <svg className="chart-scrub" viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
      {/* axis gridlines */}
      {yTicks.map((v, i) => (
        <g key={`y-${i}`}>
          <line
            x1={PAD.left}
            y1={py(v)}
            x2={W - PAD.right}
            y2={py(v)}
            style={{ stroke: "var(--hairline)" }}
            strokeWidth={1}
          />
          <text
            x={2}
            y={py(v) + (i === yTicks.length - 1 ? 4 : i === 0 ? -2 : 2.5)}
            fontSize={7.5}
            style={{ fill: "var(--ink-faint)" }}
          >
            {v.toFixed(0)}
            {i === yTicks.length - 1 ? "kg" : ""}
          </text>
        </g>
      ))}
      {xTicks.map((t) => (
        <line
          key={`x-${t}`}
          x1={px(t)}
          y1={PAD.top}
          x2={px(t)}
          y2={H - PAD.bottom}
          style={{ stroke: "var(--hairline)" }}
          strokeWidth={1}
        />
      ))}
      {model.cf !== null && (
        <>
          <line
            x1={PAD.left}
            y1={py(model.cf)}
            x2={W - PAD.right}
            y2={py(model.cf)}
            stroke="#E0913D"
            strokeWidth={1}
            strokeDasharray="4 3"
          />
          <text
            x={W - PAD.right}
            y={py(model.cf) - 4}
            fontSize={8}
            fill="#E0913D"
            textAnchor="end"
          >
            CF {model.cf.toFixed(1)}kg
          </text>
        </>
      )}
      {/* Every effort's mean-max — the raw spread behind the envelope */}
      {(model.scatter ?? []).map((p, i) => (
        <circle
          key={`sc-${i}`}
          cx={px(p.windowS)}
          cy={py(p.kg)}
          r={1.4}
          fill="#7B83EB"
          opacity={0.3}
        />
      ))}
      {/* Curve-shift overlays: each active trailing window's fit (SL-80c) */}
      {overlays.map((o) => (
        <polyline
          key={o.label}
          points={hyperbola(o.model)}
          fill="none"
          stroke={o.color}
          strokeWidth={1.2}
          strokeDasharray="5 3"
          opacity={0.75}
          vectorEffect="non-scaling-stroke"
        />
      ))}
      {fitted && (
        <polyline
          points={fitted}
          fill="none"
          stroke="#5B5FC7"
          strokeWidth={1.5}
          opacity={0.8}
          vectorEffect="non-scaling-stroke"
        />
      )}
      {pts.map((p, i) => (
        <circle
          key={p.windowS}
          cx={px(p.windowS)}
          cy={py(p.kg)}
          r={hovered === i ? 5 : 3}
          fill="#7B83EB"
          style={{ cursor: "pointer", transition: "r 0.1s" }}
          {...hoverProps(i)}
        />
      ))}
      {xTicks.map((t) => (
        <text
          key={t}
          x={px(t)}
          y={H - 5}
          fontSize={8}
          style={{ fill: "var(--ink-faint)" }}
          textAnchor="middle"
        >
          {t}s
        </text>
      ))}
      {hovered !== null && pts[hovered] && (
        <line
          x1={px(pts[hovered]!.windowS)}
          y1={PAD.top}
          x2={px(pts[hovered]!.windowS)}
          y2={H - PAD.bottom}
          style={{ stroke: "var(--ink-faint)" }}
          strokeDasharray="2 2"
          strokeWidth={1}
        />
      )}
      {hovered !== null && pts[hovered] && (
        <SvgChartTooltip
          x={px(pts[hovered]!.windowS)}
          y={py(pts[hovered]!.kg)}
          viewW={W}
          viewH={H}
          lines={[`${pts[hovered]!.windowS}s`, `${pts[hovered]!.kg.toFixed(1)} kg`]}
        />
      )}
    </svg>
  );
}

export default function ForceCurveCard({ tag, model, periods, computing, error }: Props) {
  // Which trailing windows are overlaid (multi-select chips).
  const [activePeriods, setActivePeriods] = useState<Set<string>>(new Set());
  const overlays: Overlay[] = periods.flatMap((p) =>
    activePeriods.has(p.label) && p.model
      ? [{ label: p.label, color: PERIOD_COLORS[p.label] ?? "#8E8E93", model: p.model }]
      : [],
  );
  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div
        className="label-eyebrow"
        style={{
          marginBottom: 10,
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
        }}
      >
        <span>Force Curve · {tag}</span>
        <InfoDot topic="forceCurve" />
      </div>

      {!model ? (
        <div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
            {computing
              ? "Computing your force–duration curve…"
              : error ??
                "The force–duration curve builds from this tag's recordings and fits the critical-force model F(t) = CF + W′/t."}
          </div>
        </div>
      ) : (
        <div>
          <CurvePlot model={model} overlays={overlays} />

          {/* Curve shift over time: toggle a trailing window to overlay its
              fitted curve (dashed, hue-coded) against the current one. */}
          {periods.some((p) => p.model) && (
            <div style={{ display: "flex", gap: 5, flexWrap: "wrap", marginTop: 8 }}>
              {periods.map((p) => {
                const has = p.model !== null;
                const active = activePeriods.has(p.label);
                const color = PERIOD_COLORS[p.label] ?? "#8E8E93";
                return (
                  <button
                    key={p.label}
                    className="tag"
                    disabled={!has}
                    onClick={() =>
                      setActivePeriods((prev) => {
                        const next = new Set(prev);
                        if (next.has(p.label)) next.delete(p.label);
                        else next.add(p.label);
                        return next;
                      })
                    }
                    style={{
                      background: active ? color : "var(--surface-1)",
                      color: active ? "#ffffff" : has ? color : "var(--ink-faint)",
                      border: `1px solid ${has ? color : "var(--border)"}`,
                      opacity: has ? 1 : 0.4,
                      cursor: has ? "pointer" : "default",
                      fontFamily: "Inter, sans-serif",
                    }}
                  >
                    {p.label}
                    {active && p.model?.cf != null && ` · CF ${p.model.cf.toFixed(1)}`}
                  </button>
                );
              })}
            </div>
          )}
          {(() => {
            const longest = model.points[model.points.length - 1]!.windowS;
            if (longest < 30) {
              return (
                <div
                  style={{
                    fontSize: "var(--t-2xs)",
                    color: "var(--warning)",
                    background: "rgba(221,177,58,0.08)",
                    border: "1px solid rgba(221,177,58,0.25)",
                    borderRadius: 6,
                    padding: "7px 10px",
                    marginTop: 8,
                  }}
                >
                  Longest effort so far: {longest}s. CF and W′ are
                  extrapolated — do one all-out 30–60s hold with this tag to
                  make them (and the Pow End / Endurance targets) trustworthy.
                </div>
              );
            }
            if (longest < 60) {
              return (
                <div
                  style={{
                    fontSize: "var(--t-2xs)",
                    color: "var(--ink-muted)",
                    marginTop: 8,
                  }}
                >
                  Tip: an all-out 60s+ hold would sharpen the CF fit further.
                </div>
              );
            }
            return null;
          })()}
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: "var(--t-2xs)",
              color: "var(--ink-muted)",
              margin: "6px 0 12px",
            }}
          >
            <span>
              max{" "}
              <span style={{ color: "var(--ink)" }}>
                {model.maxF.toFixed(1)} kg
              </span>
            </span>
            <span>
              CF{" "}
              <span style={{ color: "var(--orange)" }}>
                {model.cf !== null ? `${model.cf.toFixed(1)} kg` : "—"}
              </span>
            </span>
            <span>
              W′{" "}
              <span style={{ color: "var(--ink-muted)" }}>
                {model.wPrime !== null ? `${model.wPrime.toFixed(0)} kg·s` : "—"}
              </span>
            </span>
          </div>

          {/* Training zones live in the Gauge Target card up top — this card
              is the analysis view (curve + CF/W′) only. */}
        </div>
      )}
    </div>
  );
}

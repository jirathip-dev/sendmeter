import { useState } from "react";
import type { ForceCurveModel, PeriodCurve } from "../lib/force-curve";
import {
  qualityRegions,
  sampleDisplayBand,
  sampleDisplayCurve,
} from "../lib/forceCurveDisplay";
import { QUALITY_COLORS } from "../lib/zoneSelection";
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
  const yMax = Math.max(
    model.maxF,
    ...overlays.map((o) => o.model.maxF),
    ...(model.confidenceBand ?? []).map((point) => point.highKg),
  ) * 1.1;
  // x is log-scaled (window size spans 1-120s) so it stays a custom
  // function; useSvgScale only covers linear scales.
  const px = (w: number) =>
    PAD.left +
    ((Math.log10(w) - tMin) / Math.max(tMax - tMin, 0.01)) *
      (W - PAD.left - PAD.right);
  const { y: py } = useSvgScale(W, H, PAD, 0, 1, 0, yMax);

  const displayCurve = (m: ForceCurveModel): string => {
    const start = Math.max(10 ** tMin, m.points[0]?.windowS ?? Infinity);
    const end = Math.min(10 ** tMax, m.points.at(-1)?.windowS ?? -Infinity);
    if (end < start) return "";
    return sampleDisplayCurve(m, start, end, 64)
      .map((p) => `${px(p.durationS).toFixed(1)},${py(p.kg).toFixed(1)}`)
      .join(" ");
  };
  const displayed = model.points.length >= 2 ? displayCurve(model) : "";
  const band = sampleDisplayBand(
    (model.confidenceBand ?? []).filter((p) =>
      Math.log10(p.windowS) >= tMin - 0.01 && Math.log10(p.windowS) <= tMax + 0.01),
    64,
  );
  const bandPolygon = band.length >= 2
    ? [
        ...band.map((p) => `${px(p.durationS).toFixed(1)},${py(p.highKg).toFixed(1)}`),
        ...[...band].reverse().map((p) => `${px(p.durationS).toFixed(1)},${py(p.lowKg).toFixed(1)}`),
      ].join(" ")
    : "";

  const yTicks = [0, yMax / 2, yMax];
  const xTicks = [1, 10, 60, 120].filter((t) => Math.log10(t) <= tMax + 0.01);

  return (
    <svg className="chart-scrub" viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
      <g aria-label="Training quality regions">
        {qualityRegions(model, 10 ** tMin, 10 ** tMax, yMax).map((r, i) => (
          <rect
            key={`${r.quality}-${i}`}
            x={px(r.t0)}
            y={py(r.kg1)}
            width={Math.max(0, px(r.t1) - px(r.t0))}
            height={Math.max(0, py(r.kg0) - py(r.kg1))}
            fill={QUALITY_COLORS[r.quality]}
            opacity={0.08}
          />
        ))}
      </g>
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
      {bandPolygon && (
        <polygon
          aria-label="95% bootstrap confidence band"
          points={bandPolygon}
          fill="#7B83EB"
          opacity={0.14}
        />
      )}
      {/* Curve-shift overlays: each active trailing window's fit (SL-80c) */}
      {overlays.map((o) => (
        <polyline
          key={o.label}
          points={displayCurve(o.model)}
          fill="none"
          stroke={o.color}
          strokeWidth={1.2}
          strokeDasharray="5 3"
          opacity={0.75}
          vectorEffect="non-scaling-stroke"
        />
      ))}
      {displayed && (
        <polyline
          aria-label={`${model.capabilityFit?.family ?? "Measured"} capability curve`}
          points={displayed}
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
                "The force–duration curve builds from this tag's recordings. The purple constrained Hill capability curve drives Power Endurance and Auto curve targets. CF remains the Endurance reference; W′ stays internal to fatigue, RPE, and dose accounting."}
          </div>
        </div>
      ) : (
        <div>
          <CurvePlot model={model} overlays={overlays} />
          <div aria-label="Training quality legend" style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 5, fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
            {([
              ["power", "Power · ≤6s · ≥90% max"],
              ["strength", "Strength · ≤20s · ≥80% max (except Power)"],
              ["power-endurance", `Pow End · ≤20s · <80% max${model.cf == null ? "" : " · >CF"}`],
              ["endurance", model.cf == null ? "Endurance · >20s" : "Endurance · ≤CF or >20s"],
            ] as const).map(([quality, label]) => (
              <span key={quality} style={{ display: "inline-flex", alignItems: "center", gap: 3 }}>
                <span aria-hidden="true" style={{ width: 7, height: 7, borderRadius: 2, background: QUALITY_COLORS[quality] }} />
                {label}
              </span>
            ))}
          </div>

          {/* Curve shift over time: toggle a trailing window to overlay its
              historical capability fit (dashed, hue-coded) against the current one. */}
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
            if (model.coverage?.quality === "weak") {
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
                  {model.coverage.message}{" "}
                  {model.capabilityFit
                    ? "The Hill curve and its targets are provisional; CF and W′ are extrapolated, and the confidence band may be unavailable until more durations exist."
                    : "A Hill capability fit is not available yet, so curve-based targets are unavailable; the chart shows only the measured envelope."}
                </div>
              );
            }
            if (model.coverage?.quality === "fair") {
              return (
                <div
                  style={{
                    fontSize: "var(--t-2xs)",
                    color: "var(--ink-muted)",
                    marginTop: 8,
                  }}
                >
                  {model.coverage.message}{" "}
                  {model.capabilityFit
                    ? "Hill curve targets remain provisional."
                    : "Curve-based targets remain unavailable until a Hill capability fit can be resolved."}
                </div>
              );
            }
            return null;
          })()}
          <div
            style={{
              display: "flex",
              gap: 8,
              flexWrap: "wrap",
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
            <span
              title={
                model.capabilityFit
                  ? "Purple Hill/log-logistic capability curve used by Power Endurance and Auto curve targets"
                  : "Purple interpolation of the measured envelope; it does not resolve curve-based targets"
              }
            >
              {model.capabilityFit ? "Hill capability curve" : "Measured envelope"}
            </span>
            <span title="Pointwise 95% interval from a deterministic recording-level bootstrap">
              95% band{" "}
              <span style={{ color: "var(--ink-muted)" }}>
                {(model.confidenceBand?.length ?? 0) >= 2 ? "shown" : "—"}
              </span>
            </span>
          </div>

          {/* Training zones live in the Gauge Target card up top — this card
              is the analysis view only. */}
        </div>
      )}
    </div>
  );
}

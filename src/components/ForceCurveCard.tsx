import { useState } from "react";
import {
  computeForceCurve,
  predictForce,
  QUALITIES,
  zoneTarget,
} from "../lib/force-curve";
import type { ForceCurveModel, TrainingQuality } from "../lib/force-curve";
import { fetchRecordingSamples } from "../lib/repo";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import SvgChartTooltip from "./SvgChartTooltip";
import type { TindeqRecordingMeta } from "../types";

export interface GaugeTarget {
  kg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  label: string;
}

interface Props {
  tag: string;
  recordings: TindeqRecordingMeta[]; // already filtered to this tag
  onUseTarget: (t: GaugeTarget) => void;
}

const MAX_RECORDINGS_FETCHED = 15;
const W = 300;
const H = 130;
const PAD = { top: 10, bottom: 18, left: 30, right: 8 };

function CurvePlot({ model }: { model: ForceCurveModel }) {
  const [hovered, hoverProps] = useChartHover<number>();
  const pts = model.points;
  const tMin = Math.log10(pts[0]!.windowS);
  const tMax = Math.log10(Math.max(pts[pts.length - 1]!.windowS, 10));
  const yMax = model.maxF * 1.1;
  // x is log-scaled (window size spans 1-120s) so it stays a custom
  // function; useSvgScale only covers linear scales.
  const px = (w: number) =>
    PAD.left +
    ((Math.log10(w) - tMin) / Math.max(tMax - tMin, 0.01)) *
      (W - PAD.left - PAD.right);
  const { y: py } = useSvgScale(W, H, PAD, 0, 1, 0, yMax);

  // fitted hyperbola sampled along the axis
  let fitted = "";
  if (model.cf !== null) {
    const steps = 40;
    const parts: string[] = [];
    for (let i = 0; i <= steps; i++) {
      const logT = tMin + ((tMax - tMin) * i) / steps;
      const t = Math.pow(10, logT);
      parts.push(`${px(t).toFixed(1)},${py(predictForce(model, t)).toFixed(1)}`);
    }
    fitted = parts.join(" ");
  }

  const yTicks = [0, yMax / 2, yMax];
  const xTicks = [1, 10, 60, 120].filter((t) => Math.log10(t) <= tMax + 0.01);

  return (
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
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
            stroke="#FF9500"
            strokeWidth={1}
            strokeDasharray="4 3"
          />
          <text
            x={W - PAD.right}
            y={py(model.cf) - 4}
            fontSize={8}
            fill="#FF9500"
            textAnchor="end"
          >
            CF {model.cf.toFixed(1)}kg
          </text>
        </>
      )}
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

export default function ForceCurveCard({ tag, recordings, onUseTarget }: Props) {
  const [model, setModel] = useState<ForceCurveModel | null>(null);
  const [computing, setComputing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [quality, setQuality] = useState<TrainingQuality>("strength");

  // parent remounts this card per tag via key={tag}, so state resets naturally

  async function compute() {
    setComputing(true);
    setError(null);
    try {
      const recent = recordings.slice(0, MAX_RECORDINGS_FETCHED);
      const all = await Promise.all(
        recent.map((r) => fetchRecordingSamples(r.id)),
      );
      const m = computeForceCurve(all);
      if (!m) setError("No usable samples in these recordings.");
      setModel(m);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to compute curve");
    } finally {
      setComputing(false);
    }
  }

  const target = model ? zoneTarget(model, quality) : null;

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 10 }}>
        Force Curve · {tag}
      </div>

      {!model ? (
        <div>
          <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 10 }}>
            Builds your force–duration curve from the last{" "}
            {Math.min(recordings.length, MAX_RECORDINGS_FETCHED)} recordings of
            this exercise and fits the critical-force model F(t) = CF + W′/t.
          </div>
          <button
            className="btn-ghost"
            disabled={computing || recordings.length === 0}
            onClick={() => void compute()}
          >
            {computing ? "Computing…" : "Compute Force Curve"}
          </button>
          {error && (
            <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 8 }}>
              {error}
            </div>
          )}
        </div>
      ) : (
        <div>
          <CurvePlot model={model} />
          {(() => {
            const longest = model.points[model.points.length - 1]!.windowS;
            if (longest < 30) {
              return (
                <div
                  style={{
                    fontSize: 10,
                    color: "var(--warning)",
                    background: "rgba(255,184,0,0.08)",
                    border: "1px solid rgba(255,184,0,0.25)",
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
                    fontSize: 10,
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
              fontSize: 10,
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

          {/* quality selector */}
          <div style={{ display: "flex", gap: 5, flexWrap: "wrap", marginBottom: 10 }}>
            {QUALITIES.map((q) => (
              <button
                key={q.id}
                className="tag"
                onClick={() => setQuality(q.id)}
                style={{
                  background: quality === q.id ? "var(--primary)" : "var(--surface-1)",
                  color: quality === q.id ? "#ffffff" : "var(--ink-muted)",
                  border: `1px solid ${quality === q.id ? "var(--primary)" : "var(--border)"}`,
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                }}
              >
                {q.label}
              </button>
            ))}
          </div>

          {target ? (
            <div>
              <div
                style={{ display: "flex", alignItems: "baseline", gap: 8 }}
              >
                <span
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontSize: 26,
                    fontWeight: 800,
                    color: "var(--success)",
                  }}
                >
                  {target.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: 11, color: "var(--ink-muted)" }}>
                  ({target.lowKg.toFixed(1)}–{target.highKg.toFixed(1)}) ·{" "}
                  {target.workS}s work
                </span>
              </div>
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 4 }}>
                {target.protocol}
              </div>
              <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 2 }}>
                {target.basis}
              </div>
              <div style={{ marginTop: 10 }}>
                <button
                  className="btn-primary"
                  onClick={() =>
                    onUseTarget({
                      kg: target.targetKg,
                      lowKg: target.lowKg,
                      highKg: target.highKg,
                      workS: target.workS,
                      label: `${target.label} · ${tag}`,
                    })
                  }
                >
                  Use as Gauge Target
                </button>
              </div>
            </div>
          ) : (
            <div style={{ fontSize: 11, color: "var(--ink-faint)" }}>
              Needs a critical-force fit — record some longer holds (30s+) with
              this tag to unlock this zone.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

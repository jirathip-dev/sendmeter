import { useState } from "react";
import {
  computeForceCurve,
  predictForce,
  QUALITIES,
  zoneTarget,
} from "../lib/force-curve";
import type { ForceCurveModel, TrainingQuality } from "../lib/force-curve";
import { fetchRecordingSamples } from "../lib/repo";
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
  const pts = model.points;
  const tMin = Math.log10(pts[0]!.windowS);
  const tMax = Math.log10(Math.max(pts[pts.length - 1]!.windowS, 10));
  const yMax = model.maxF * 1.1;
  const px = (w: number) =>
    PAD.left +
    ((Math.log10(w) - tMin) / Math.max(tMax - tMin, 0.01)) *
      (W - PAD.left - PAD.right);
  const py = (kg: number) =>
    PAD.top + (1 - kg / yMax) * (H - PAD.top - PAD.bottom);

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

  return (
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }}>
      <text x={2} y={PAD.top + 4} fontSize={8} fill="#8E8E93">
        {yMax.toFixed(0)}kg
      </text>
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
      {pts.map((p) => (
        <circle key={p.windowS} cx={px(p.windowS)} cy={py(p.kg)} r={3} fill="#7B83EB">
          <title>{`${p.windowS}s · ${p.kg.toFixed(1)} kg`}</title>
        </circle>
      ))}
      {[1, 10, 60, 120]
        .filter((t) => Math.log10(t) <= tMax + 0.01)
        .map((t) => (
          <text
            key={t}
            x={px(t)}
            y={H - 5}
            fontSize={8}
            fill="#8E8E93"
            textAnchor="middle"
          >
            {t}s
          </text>
        ))}
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
      <div
        style={{
          fontSize: 9,
          color: "#6E6E73",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 10,
        }}
      >
        Force Curve · {tag}
      </div>

      {!model ? (
        <div>
          <div style={{ fontSize: 11, color: "#6E6E73", marginBottom: 10 }}>
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
            <div style={{ fontSize: 11, color: "#FF453A", marginTop: 8 }}>
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
                    color: "#FFB800",
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
                    color: "#6E6E73",
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
              color: "#6E6E73",
              margin: "6px 0 12px",
            }}
          >
            <span>
              max{" "}
              <span style={{ color: "#1C1C1E" }}>
                {model.maxF.toFixed(1)} kg
              </span>
            </span>
            <span>
              CF{" "}
              <span style={{ color: "#FF9500" }}>
                {model.cf !== null ? `${model.cf.toFixed(1)} kg` : "—"}
              </span>
            </span>
            <span>
              W′{" "}
              <span style={{ color: "#6E6E73" }}>
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
                  background: quality === q.id ? "#5B5FC7" : "#F5F5F7",
                  color: quality === q.id ? "#ffffff" : "#6E6E73",
                  border: `1px solid ${quality === q.id ? "#5B5FC7" : "#D8D8DC"}`,
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
                    color: "#34C759",
                  }}
                >
                  {target.targetKg.toFixed(1)} kg
                </span>
                <span style={{ fontSize: 11, color: "#6E6E73" }}>
                  ({target.lowKg.toFixed(1)}–{target.highKg.toFixed(1)}) ·{" "}
                  {target.workS}s work
                </span>
              </div>
              <div style={{ fontSize: 11, color: "#6E6E73", marginTop: 4 }}>
                {target.protocol}
              </div>
              <div style={{ fontSize: 10, color: "#8E8E93", marginTop: 2 }}>
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
            <div style={{ fontSize: 11, color: "#8E8E93" }}>
              Needs a critical-force fit — record some longer holds (30s+) with
              this tag to unlock this zone.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

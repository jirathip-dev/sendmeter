import { useEffect, useRef, useState } from "react";
import { useSvgScale } from "../hooks/useSvgScale";
import { useChartId } from "../hooks/useChartId";
import {
  cadenceMarkerLabel,
  reverseActionMetricItems,
} from "../lib/reverseActionHistory";
import type { TindeqRecordingMeta, TindeqSample } from "../types";
import ChartDefs from "./ChartDefs";
import { chartColor, chartGradientUrl } from "../lib/chartTheme";

const H = 178;
const PAD = { top: 32, right: 10, bottom: 20, left: 30 };

function Trace({ rec, samples }: { rec: TindeqRecordingMeta; samples: TindeqSample[] }) {
  const chartId = useChartId("reverse-action");
  const hostRef = useRef<HTMLDivElement>(null);
  const [hostWidth, setHostWidth] = useState(300);
  useEffect(() => {
    const element = hostRef.current;
    if (!element) return;
    const observer = new ResizeObserver(() =>
      setHostWidth(Math.max(240, element.clientWidth)),
    );
    observer.observe(element);
    setHostWidth(Math.max(240, element.clientWidth));
    return () => observer.disconnect();
  }, []);

  const markers = rec.cadenceMarkers ?? [];
  const targetKg = rec.targetKg ?? null;
  const targetLowKg = rec.targetLowKg ?? null;
  const targetHighKg = rec.targetHighKg ?? null;
  const clean = samples
    .filter((sample) => Number.isFinite(sample.t) && Number.isFinite(sample.kg))
    .slice()
    .sort((a, b) => a.t - b.t);
  const W = Math.max(hostWidth, markers.length * 48, 300);
  const tMax = Math.max(
    clean.at(-1)?.t ?? 0,
    rec.plannedDurationMs ?? 0,
    rec.actualDurationMs ?? 0,
    1,
  );
  const kgMax =
    Math.max(
      ...clean.map((sample) => sample.kg),
      targetHighKg ?? 0,
      1,
    ) * 1.08;
  const { x: px, y: py } = useSvgScale(W, H, PAD, 0, tMax, 0, kgMax);
  const points = clean
    .map((sample) => `${px(sample.t).toFixed(1)},${py(sample.kg).toFixed(1)}`)
    .join(" ");
  const baseline = H - PAD.bottom;
  const areaPath = clean.length >= 2
    ? `M ${px(clean[0]!.t).toFixed(1)},${baseline} ${points} L ${px(clean.at(-1)!.t).toFixed(1)},${baseline} Z`
    : "";

  return (
    <div ref={hostRef} style={{ width: "100%", overflowX: "auto" }}>
      <svg
        role="img"
        aria-label={`Reverse Action set ${rec.setNo ?? 1} force trace with ${markers.length} prescribed cadence markers`}
        viewBox={`0 0 ${W} ${H}`}
        style={{ width: W, height: H, display: "block" }}
      >
        <ChartDefs instanceId={chartId} />
        {markers.map((marker, index) => {
          const nextMs = markers[index + 1]?.tMs ?? tMax;
          const startX = px(marker.tMs);
          const endX = px(Math.min(tMax, nextMs));
          return (
            <rect
              key={`phase-${marker.tMs}-${marker.direction}`}
              x={startX}
              y={PAD.top}
              width={Math.max(0, endX - startX)}
              height={H - PAD.top - PAD.bottom}
              style={{
                fill:
                  marker.direction === "out"
                    ? `color-mix(in srgb, ${chartColor("force")} 8%, transparent)`
                    : `color-mix(in srgb, ${chartColor("forceSecondary")} 8%, transparent)`,
              }}
            />
          );
        })}
        {targetLowKg !== null && targetHighKg !== null && (
          <rect
            x={PAD.left}
            y={py(targetHighKg)}
            width={W - PAD.left - PAD.right}
            height={Math.max(0, py(targetLowKg) - py(targetHighKg))}
            style={{ fill: `color-mix(in srgb, ${chartColor("optimal")} 13%, transparent)` }}
          />
        )}
        {[0, kgMax / 2, kgMax].map((kg, index) => (
          <g key={index}>
            <line
              x1={PAD.left}
              x2={W - PAD.right}
              y1={py(kg)}
              y2={py(kg)}
              style={{ stroke: chartColor("grid") }}
            />
            <text x={2} y={py(kg) + 3} fontSize={8} style={{ fill: "var(--ink-faint)" }}>
              {kg.toFixed(0)}{index === 2 ? "kg" : ""}
            </text>
          </g>
        ))}
        {markers.map((marker, index) => (
          <g key={`marker-${marker.tMs}-${marker.direction}`}>
            <line
              x1={px(marker.tMs)}
              x2={px(marker.tMs)}
              y1={PAD.top - 5}
              y2={H - PAD.bottom}
              stroke={marker.direction === "out" ? chartColor("force") : chartColor("forceSecondary")}
              strokeDasharray="3 3"
            />
            <text
              x={px(marker.tMs) + 3}
              y={index % 2 === 0 ? 10 : 23}
              fontSize={8}
              fontWeight={700}
              style={{ fill: marker.direction === "out" ? chartColor("force") : chartColor("forceSecondary") }}
            >
              {cadenceMarkerLabel(marker)}
            </text>
          </g>
        ))}
        {targetKg !== null && (
          <line
            x1={PAD.left}
            x2={W - PAD.right}
            y1={py(targetKg)}
            y2={py(targetKg)}
            stroke={chartColor("optimal")}
            strokeWidth={1.2}
          />
        )}
        {clean.length >= 2 && (
          <>
            {areaPath && <path d={areaPath} fill={chartGradientUrl(chartId, "force-area")} />}
            <polyline
              points={points}
              fill="none"
              stroke={chartColor("caution")}
              strokeWidth={2}
              vectorEffect="non-scaling-stroke"
            />
          </>
        )}
        {[0, tMax / 2, tMax].map((ms, index) => (
          <text
            key={index}
            x={px(ms)}
            y={H - 4}
            fontSize={8}
            textAnchor={index === 0 ? "start" : index === 2 ? "end" : "middle"}
            style={{ fill: chartColor("axis") }}
          >
            {(ms / 1_000).toFixed(1)}s
          </text>
        ))}
      </svg>
    </div>
  );
}

export default function ReverseActionSetDetail({
  rec,
  samples,
}: {
  rec: TindeqRecordingMeta;
  samples: TindeqSample[];
}) {
  const metrics = reverseActionMetricItems(rec.setMetrics ?? null, rec.peakKg);
  if (rec.source === "manual") {
    return <div style={{ marginTop: 10, padding: 10, borderRadius: 9, background: "var(--surface-1)", color: "var(--ink-muted)", fontSize: "var(--t-xs)", lineHeight: 1.55 }}>
      <strong style={{ color: "var(--ink)" }}>Cadence only · clock-guided, not detected</strong><br />
      Set {rec.setNo ?? 1} · {rec.completedReps ?? 0} completed rep{rec.completedReps === 1 ? "" : "s"} · {rec.completionStatus ?? "partial"} · {((rec.actualDurationMs ?? rec.durationMs) / 1_000).toFixed(1)}s actual / {((rec.plannedDurationMs ?? rec.durationMs) / 1_000).toFixed(1)}s planned
      {rec.cadenceOutS != null && rec.cadenceReturnS != null ? ` · ${rec.cadenceOutS}s OUT / ${rec.cadenceReturnS}s RETURN` : ""}
      <br />Equipment resistance{rec.setupNote ? ` · ${rec.setupNote}` : " · setup not recorded"}. No force, target band, or movement detection was recorded.
    </div>;
  }
  return (
    <div style={{ marginTop: 10 }}>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 7 }}>
        {rec.targetKg !== null && rec.targetKg !== undefined
          ? `Target ${rec.targetKg.toFixed(1)} kg${rec.targetLowKg != null && rec.targetHighKg != null ? ` (${rec.targetLowKg.toFixed(1)}–${rec.targetHighKg.toFixed(1)})` : ""}`
          : "Equipment resistance · no kg target"}
        {rec.cadenceOutS != null && rec.cadenceReturnS != null
          ? ` · ${rec.cadenceOutS}s OUT / ${rec.cadenceReturnS}s RETURN`
          : ""}
      </div>
      <Trace rec={rec} samples={samples} />
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(88px, 1fr))",
          gap: 7,
          marginTop: 9,
        }}
      >
        {metrics.map((metric) => (
          <div
            key={metric.label}
            title={metric.explanation}
            style={{
              border: "1px solid var(--border)",
              borderRadius: 9,
              padding: "8px 9px",
              background: "var(--surface-1)",
            }}
          >
            <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
              {metric.label}
            </div>
            <div style={{ fontWeight: 750, color: "var(--ink)", marginTop: 2 }}>
              {metric.value}
            </div>
          </div>
        ))}
      </div>
      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8, lineHeight: 1.45 }}>
        Markers are the prescribed OUT/RETURN clock; force alone does not detect joint position.
        {rec.setupNote ? ` Setup: ${rec.setupNote}` : ""}
      </div>
    </div>
  );
}

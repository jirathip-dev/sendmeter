import { useEffect, useRef, useState } from "react";
import { fetchRecordingSamples } from "../lib/repo";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import SvgChartTooltip from "./SvgChartTooltip";
import type { TindeqRecordingMeta, TindeqSample } from "../types";

interface Props {
  rec: TindeqRecordingMeta;
  onDelete: (id: string) => void;
  /// Edit tag/side/note (pencil). Omitted where editing isn't offered.
  onEdit?: (rec: TindeqRecordingMeta) => void;
  /// Multi-select mode (History): loose recordings can be ticked and turned
  /// into a session together.
  selectable?: boolean;
  selected?: boolean;
  onToggleSelect?: (id: string) => void;
}

const H = 80;
const PAD = { top: 6, right: 6, bottom: 14, left: 26 };

function SamplesPreview({ samples }: { samples: TindeqSample[] }) {
  const [hovered, hoverProps] = useChartHover<number>();
  // The trace spans the full card width: measure the container and use its
  // real width as the viewBox width (a fixed 300px viewBox letterboxed
  // inside wide desktop cards).
  const hostRef = useRef<HTMLDivElement>(null);
  const [W, setW] = useState(300);
  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setW(Math.max(200, el.clientWidth)));
    ro.observe(el);
    setW(Math.max(200, el.clientWidth));
    return () => ro.disconnect();
  }, []);
  const tMax = (samples.length ? samples[samples.length - 1]!.t : 0) || 1;
  const kgMax = Math.max(...samples.map((s) => s.kg), 1) * 1.08;
  const { x: px, y: py } = useSvgScale(W, H, PAD, 0, tMax, 0, kgMax);
  if (samples.length < 2) return null;

  const points = samples.map((s) => `${px(s.t).toFixed(1)},${py(s.kg).toFixed(1)}`).join(" ");

  const yTicks = [0, kgMax / 2, kgMax];
  const xTicks = [0, tMax / 2, tMax];

  // Downsample hover targets so we're not attaching handlers to hundreds of
  // raw samples — pick ~40 evenly spaced indices across the trace.
  const hoverStep = Math.max(1, Math.floor(samples.length / 40));
  const hoverIndices: number[] = [];
  for (let i = 0; i < samples.length; i += hoverStep) hoverIndices.push(i);
  if (hoverIndices[hoverIndices.length - 1] !== samples.length - 1) {
    hoverIndices.push(samples.length - 1);
  }

  const hoveredSample = hovered !== null ? samples[hovered] : undefined;

  return (
    <div ref={hostRef} style={{ width: "100%" }}>
    <svg
      className="chart-scrub"
      viewBox={`0 0 ${W} ${H}`}
      style={{ width: "100%", height: H, display: "block", marginTop: 10 }}
    >
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
      {xTicks.map((t, i) => (
        <text
          key={`x-${i}`}
          x={px(t)}
          y={H - 3}
          fontSize={7.5}
          style={{ fill: "var(--ink-faint)" }}
          textAnchor={i === 0 ? "start" : i === xTicks.length - 1 ? "end" : "middle"}
        >
          {(t / 1000).toFixed(1)}s
        </text>
      ))}
      <polyline
        points={points}
        fill="none"
        stroke="#5B5FC7"
        strokeWidth="1.5"
        vectorEffect="non-scaling-stroke"
      />
      {hoverIndices.map((i) => (
        <circle
          key={i}
          cx={px(samples[i]!.t)}
          cy={py(samples[i]!.kg)}
          r={7}
          fill="transparent"
          style={{ cursor: "pointer" }}
          {...hoverProps(i)}
        />
      ))}
      {hovered !== null && hoveredSample && (
        <>
          <line
            x1={px(hoveredSample.t)}
            y1={PAD.top}
            x2={px(hoveredSample.t)}
            y2={H - PAD.bottom}
            style={{ stroke: "var(--ink-faint)" }}
            strokeDasharray="2 2"
            strokeWidth={1}
          />
          <circle
            cx={px(hoveredSample.t)}
            cy={py(hoveredSample.kg)}
            r={3}
            fill="#5B5FC7"
          />
          <SvgChartTooltip
            x={px(hoveredSample.t)}
            y={py(hoveredSample.kg)}
            viewW={W}
            viewH={H}
            lines={[`${(hoveredSample.t / 1000).toFixed(1)}s`, `${hoveredSample.kg.toFixed(1)} kg`]}
          />
        </>
      )}
    </svg>
    </div>
  );
}

export default function RecordingRow({
  rec,
  onDelete,
  onEdit,
  selectable,
  selected,
  onToggleSelect,
}: Props) {
  const [expanded, setExpanded] = useState(false);
  const [samples, setSamples] = useState<TindeqSample[] | null>(null);
  const [loadError, setLoadError] = useState(false);

  async function toggle() {
    const next = !expanded;
    setExpanded(next);
    if (next && !samples) {
      try {
        setSamples(await fetchRecordingSamples(rec.id));
      } catch {
        setLoadError(true);
      }
    }
  }

  const date = new Date(rec.recordedAt);
  const dateLabel = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")} ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;

  return (
    <div
      className="session-row"
      style={{ flexDirection: "column", alignItems: "stretch", gap: 0 }}
    >
      {/* #171: on the header only — the expanded chart below carries its own
          per-point scrub tick and must not also fire the row's. */}
      <div
        data-haptic="light"
        style={{ display: "flex", alignItems: "center", gap: 12, cursor: "pointer" }}
        onClick={() => void toggle()}
      >
        {selectable && (
          <button
            aria-label={selected ? "Deselect recording" : "Select recording"}
            onClick={(e) => {
              e.stopPropagation();
              onToggleSelect?.(rec.id);
            }}
            style={{
              width: 20,
              height: 20,
              borderRadius: "50%",
              flexShrink: 0,
              border: `2px solid ${selected ? "var(--primary)" : "var(--border)"}`,
              background: selected ? "var(--primary)" : "transparent",
              color: "#ffffff",
              fontSize: "var(--t-sm)",
              lineHeight: 1,
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              padding: 0,
            }}
          >
            {selected ? "✓" : ""}
          </button>
        )}
        <div className="session-phase-bar" style={{ background: "var(--success)" }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div
            style={{
              fontSize: "var(--t-base)",
              color: "var(--ink)",
              marginBottom: 4,
              display: "flex",
              alignItems: "center",
              gap: 7,
              flexWrap: "wrap",
            }}
          >
            <span>
              <span
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                  color: "var(--success)",
                }}
              >
                {rec.peakKg.toFixed(1)} kg
              </span>{" "}
              peak
            </span>
            {rec.tag && (
              <span
                className="tag"
                style={{
                  background: "rgba(123,131,235,0.12)",
                  color: "var(--info)",
                  border: "1px solid rgba(123,131,235,0.35)",
                }}
              >
                {rec.tag}
              </span>
            )}
            {rec.side && (
              <span
                className="tag"
                style={{
                  background: "rgba(221,177,58,0.10)",
                  color: "var(--warning)",
                  border: "1px solid rgba(221,177,58,0.3)",
                }}
              >
                {rec.side === "both" ? "L+R" : rec.side === "left" ? "L" : "R"}
              </span>
            )}
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
            {dateLabel} · {(rec.durationMs / 1000).toFixed(1)}s · avg{" "}
            {rec.avgKg.toFixed(1)} kg
            {rec.setNo !== null && (
              <span style={{ color: "var(--info)" }}> · set {rec.setNo}</span>
            )}
          </div>
          {rec.note && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)", marginTop: 3 }}>
              {rec.note}
            </div>
          )}
        </div>
        {onEdit && (
          <button
            className="del-btn"
            aria-label="Edit recording"
            style={{ fontSize: "var(--t-base)" }}
            onClick={(e) => {
              e.stopPropagation();
              onEdit(rec);
            }}
          >
            ✎
          </button>
        )}
        <button
          className="del-btn"
          onClick={(e) => {
            e.stopPropagation();
            onDelete(rec.id);
          }}
        >
          ×
        </button>
      </div>
      {expanded &&
        (samples ? (
          <SamplesPreview samples={samples} />
        ) : (
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 8 }}>
            {loadError ? "Failed to load trace" : "Loading trace…"}
          </div>
        ))}
    </div>
  );
}

import { useEffect, useId, useRef, useState } from "react";
import { boxStats, type BoxStats } from "../lib/boxplot";
import { useChartHover } from "../hooks/useChartHover";
import { useSvgScale } from "../hooks/useSvgScale";
import SvgChartTooltip from "./SvgChartTooltip";
import type { TindeqRecordingMeta, TindeqSide } from "../types";

interface Props {
  /// This tag's recordings, in the group's stored (newest-first) order —
  /// reversed internally so the chart reads chronologically left→right.
  recs: TindeqRecordingMeta[];
  /// Recording id → raw kg samples for the whole session, fetched once by
  /// the parent (`fetchSamplesForRecordings`, scoped to this session's
  /// recording ids). An id missing from the map means "not fetched yet"
  /// (still loading); an id present with an `[]` value means "fetched,
  /// genuinely no samples" — these render differently below (see
  /// `RepState`, SL-102 #2).
  samplesById: Map<string, number[]>;
}

/// Per-rep loading state, distinguishing "haven't heard back yet" from
/// "heard back, this rep just has no samples" — collapsing both into `null`
/// (as a plain `BoxStats | null` would) is what let an all-empty group get
/// stuck on the loading placeholder forever (SL-102 #2): every rep read as
/// "not loaded" and `loadedAny` never flipped.
type RepState =
  | { loaded: false }
  | { loaded: true; stats: null } // fetched, but samples were empty
  | { loaded: true; stats: BoxStats };

const H = 120;
const PAD = { top: 10, right: 8, bottom: 8, left: 28 };
const MIN_BOX_W = 10;
const MAX_BOX_W = 34;
const MAX_OUTLIER_DOTS = 12;
const DIM_OPACITY = 0.45;

function sideLabel(side: TindeqSide): "L" | "R" | null {
  if (side === "left") return "L";
  if (side === "right") return "R";
  return null; // "both" or "" (unset) carries no useful distinction here
}

/// Left → primary (indigo), right → success (electric blue); "both"/unset
/// keeps the plain success color used everywhere else in this file.
function sideColor(side: TindeqSide): string {
  return side === "left" ? "var(--primary)" : "var(--success)";
}

/// Thins a rep's outliers (can be hundreds from a raw force trace) down to
/// at most `max` rendered dots: quantize to the pixel-y grid first (values
/// that would land on the same dot are redundant), then if still over the
/// cap, take an evenly spaced sample across the sorted survivors.
function pickOutlierDots(outliers: number[], py: (v: number) => number, max: number): number[] {
  const byPixel = new Map<number, number>();
  for (const v of outliers) {
    const pixel = Math.round(py(v));
    if (!byPixel.has(pixel)) byPixel.set(pixel, v);
  }
  const values = [...byPixel.values()].sort((a, b) => a - b);
  if (values.length <= max) return values;
  const picked: number[] = [];
  const step = (values.length - 1) / (max - 1);
  for (let i = 0; i < max; i++) {
    picked.push(values[Math.round(i * step)]!);
  }
  return [...new Set(picked)];
}

/// Per-rep vertical box plot for one tag group (issue #100) — the force
/// distribution (from raw samples) of every rep, side by side in
/// chronological order, at a glance without expanding the group. Classic
/// Tukey box: Q1–Q3 box + median tick, whiskers clamped to the furthest
/// in-fence point, outliers as small hollow dots beyond them. Boxes are
/// side-colored (left = primary, right = success) with a subtle top-heavy
/// gradient fill; the session-best rep's median tick is called out in the
/// warning color, matching `ForceTrendChart`'s "Best" convention.
export default function RepBoxPlotChart({ recs, samplesById }: Props) {
  const [hovered, hoverProps] = useChartHover<number>();
  // Gradient ids must be unique per chart instance — several tag groups (and
  // therefore several of this component) render at once on the same page.
  const uid = useId().replace(/:/g, "");

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

  const chrono = [...recs].reverse();
  const stats: RepState[] = chrono.map((r) => {
    const samples = samplesById.get(r.id);
    if (samples === undefined) return { loaded: false };
    if (samples.length === 0) return { loaded: true, stats: null };
    // boxStats only returns null for empty input, already ruled out above.
    return { loaded: true, stats: boxStats(samples)! };
  });
  // A completed fetch of empty arrays still counts as "loaded" (SL-102 #2) —
  // otherwise a group whose every rep genuinely has no samples never flips
  // out of the "Loading force curves…" placeholder.
  const loadedAny = stats.some((s) => s.loaded);

  const allYs: number[] = [];
  stats.forEach((s) => {
    if (!s.loaded || !s.stats) return;
    allYs.push(s.stats.whiskerLo, s.stats.whiskerHi, ...s.stats.outliers);
  });
  // Fall back to a placeholder domain while nothing has loaded yet — the
  // hook below must run on every render regardless (rules of hooks), so the
  // "still loading" bail-out happens after it, not before.
  const yMin = allYs.length ? Math.min(...allYs) : 0;
  const yMax = allYs.length ? Math.max(...allYs) : 1;
  // Samples include the near-zero load/unload ramp, so this naturally
  // reaches down close to 0 — that's expected, not a bug.
  const yPad = Math.max((yMax - yMin) * 0.08, 0.5);

  const { x: px, y: py } = useSvgScale(
    W,
    H,
    PAD,
    0,
    chrono.length || 1,
    yMin - yPad,
    yMax + yPad,
  );

  if (!loadedAny) {
    return (
      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 6 }}>
        Loading force curves…
      </div>
    );
  }

  const bandW = (W - PAD.left - PAD.right) / chrono.length;
  const boxW = Math.min(MAX_BOX_W, Math.max(MIN_BOX_W, bandW * 0.6));
  const capW = boxW * 0.4;

  const yTicks = [yMin, (yMin + yMax) / 2, yMax];

  const hoveredState = hovered !== null ? stats[hovered] : null;
  const hoveredRec = hovered !== null ? chrono[hovered] : undefined;

  // The session-best rep (by peak kg) gets its median tick called out in the
  // warning color — first rep wins on a tie, so exactly one is ever flagged.
  let bestIdx = 0;
  chrono.forEach((r, i) => {
    if ((r.peakKg ?? -Infinity) > (chrono[bestIdx]!.peakKg ?? -Infinity)) bestIdx = i;
  });

  // Only show the L/R legend when the group actually mixes sides — a
  // single-side (or side-less) group has nothing to disambiguate.
  const sidesPresent = new Set(chrono.map((r) => sideLabel(r.side)).filter(Boolean));
  const showLegend = sidesPresent.has("L") && sidesPresent.has("R");

  return (
    <div style={{ width: "100%" }}>
      {showLegend && (
        <div
          style={{
            display: "flex",
            gap: 10,
            alignItems: "center",
            fontSize: "var(--t-2xs)",
            color: "var(--ink-faint)",
            marginTop: 6,
          }}
        >
          <span style={{ display: "inline-flex", alignItems: "center", gap: 3 }}>
            <span
              style={{
                width: 6,
                height: 6,
                borderRadius: "50%",
                background: "var(--primary)",
                display: "inline-block",
              }}
            />
            L
          </span>
          <span style={{ display: "inline-flex", alignItems: "center", gap: 3 }}>
            <span
              style={{
                width: 6,
                height: 6,
                borderRadius: "50%",
                background: "var(--success)",
                display: "inline-block",
              }}
            />
            R
          </span>
        </div>
      )}
      <div ref={hostRef} style={{ width: "100%" }}>
        <svg
          className="chart-scrub"
          viewBox={`0 0 ${W} ${H}`}
          style={{ width: "100%", height: H, display: "block", marginTop: 6 }}
        >
          <defs>
            {/* Vertical, top-heavy glass fill — echoes the app's --iris
                aesthetic without hard-coding a color: same idea (a soft
                gradient wash), driven by each rep's side token. */}
            <linearGradient id={`${uid}-primary`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" style={{ stopColor: "var(--primary)", stopOpacity: 0.35 }} />
              <stop offset="100%" style={{ stopColor: "var(--primary)", stopOpacity: 0.06 }} />
            </linearGradient>
            <linearGradient id={`${uid}-success`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" style={{ stopColor: "var(--success)", stopOpacity: 0.35 }} />
              <stop offset="100%" style={{ stopColor: "var(--success)", stopOpacity: 0.06 }} />
            </linearGradient>
          </defs>

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
                y={py(v) + (i === 0 ? -2 : i === yTicks.length - 1 ? 7 : 2.5)}
                fontSize={7.5}
                style={{ fill: "var(--ink-faint)" }}
              >
                {v.toFixed(0)}
                {i === yTicks.length - 1 ? "kg" : ""}
              </text>
            </g>
          ))}

          {chrono.map((r, i) => {
            const state = stats[i]!;
            const cx = px(i + 0.5);
            const isHovered = hovered === i;
            const dimmed = hovered !== null && !isHovered;

            // Still waiting on this rep's fetch (rare post-SL-102: samples
            // only start loading once the group expands, so this is only
            // momentarily true) — nothing to draw yet.
            if (!state.loaded) return null;

            // Fetched, but genuinely no samples (SL-102 #2) — a faint
            // baseline tick instead of leaving a silent gap with no box and
            // no hit target, so the rep is still visible/hoverable.
            if (!state.stats) {
              return (
                <g key={r.id} opacity={dimmed ? DIM_OPACITY : 1}>
                  <line
                    x1={cx - MIN_BOX_W / 2}
                    y1={py(yMin)}
                    x2={cx + MIN_BOX_W / 2}
                    y2={py(yMin)}
                    stroke="var(--ink-faint)"
                    strokeOpacity={0.5}
                    strokeWidth={1.5}
                    strokeDasharray="2 2"
                    vectorEffect="non-scaling-stroke"
                  />
                  <rect
                    x={px(i)}
                    y={PAD.top}
                    width={Math.max(1, px(i + 1) - px(i))}
                    height={H - PAD.top - PAD.bottom}
                    fill="transparent"
                    style={{ cursor: "pointer" }}
                    {...hoverProps(i)}
                  />
                </g>
              );
            }

            const s = state.stats;
            const outlierDots = pickOutlierDots(s.outliers, py, MAX_OUTLIER_DOTS);
            const color = sideColor(r.side);
            const gradientId = r.side === "left" ? `${uid}-primary` : `${uid}-success`;
            return (
              <g key={r.id} opacity={dimmed ? DIM_OPACITY : 1}>
                {/* Whisker + caps */}
                <line
                  x1={cx}
                  y1={py(s.whiskerLo)}
                  x2={cx}
                  y2={py(s.whiskerHi)}
                  stroke="var(--ink-faint)"
                  strokeOpacity={0.7}
                  strokeWidth={1}
                  vectorEffect="non-scaling-stroke"
                />
                <line
                  x1={cx - capW / 2}
                  y1={py(s.whiskerLo)}
                  x2={cx + capW / 2}
                  y2={py(s.whiskerLo)}
                  stroke="var(--ink-faint)"
                  strokeOpacity={0.7}
                  strokeWidth={1}
                  vectorEffect="non-scaling-stroke"
                />
                <line
                  x1={cx - capW / 2}
                  y1={py(s.whiskerHi)}
                  x2={cx + capW / 2}
                  y2={py(s.whiskerHi)}
                  stroke="var(--ink-faint)"
                  strokeOpacity={0.7}
                  strokeWidth={1}
                  vectorEffect="non-scaling-stroke"
                />
                {/* Q1–Q3 box — glassy gradient fill, rounded corners */}
                <rect
                  x={cx - boxW / 2}
                  y={py(s.q3)}
                  width={boxW}
                  height={Math.max(0.5, py(s.q1) - py(s.q3))}
                  rx={2.5}
                  fill={`url(#${gradientId})`}
                  stroke={color}
                  strokeWidth={isHovered ? 1.5 : 1}
                  vectorEffect="non-scaling-stroke"
                />
                {/* Hover emphasis: a flat wash on top of the gradient reads
                    as "fill slightly stronger" without extra gradients. */}
                {isHovered && (
                  <rect
                    x={cx - boxW / 2}
                    y={py(s.q3)}
                    width={boxW}
                    height={Math.max(0.5, py(s.q1) - py(s.q3))}
                    rx={2.5}
                    fill={color}
                    fillOpacity={0.12}
                  />
                )}
                {/* Median tick — warning color for the session-best rep */}
                <line
                  x1={cx - boxW / 2}
                  y1={py(s.median)}
                  x2={cx + boxW / 2}
                  y2={py(s.median)}
                  stroke={i === bestIdx ? "var(--warning)" : color}
                  strokeWidth={2}
                  strokeLinecap="round"
                  vectorEffect="non-scaling-stroke"
                />
                {/* Outlier dots (thinned) — texture, not noise */}
                {outlierDots.map((v, oi) => (
                  <circle
                    key={oi}
                    cx={cx}
                    cy={py(v)}
                    r={1.5}
                    fill="none"
                    stroke="var(--ink-faint)"
                    strokeOpacity={0.55}
                    strokeWidth={1}
                    vectorEffect="non-scaling-stroke"
                  />
                ))}
                {/* Hit band: full chart height so a scrub anywhere over this
                    rep's column selects it. */}
                <rect
                  x={px(i)}
                  y={PAD.top}
                  width={Math.max(1, px(i + 1) - px(i))}
                  height={H - PAD.top - PAD.bottom}
                  fill="transparent"
                  style={{ cursor: "pointer" }}
                  {...hoverProps(i)}
                />
              </g>
            );
          })}

          {hovered !== null && hoveredState?.loaded && hoveredRec && (
            <>
              <line
                x1={px(hovered + 0.5)}
                y1={PAD.top}
                x2={px(hovered + 0.5)}
                y2={H - PAD.bottom}
                style={{ stroke: "var(--ink-faint)" }}
                strokeDasharray="2 2"
                strokeWidth={1}
              />
              <SvgChartTooltip
                x={px(hovered + 0.5)}
                y={hoveredState.stats ? py(hoveredState.stats.median) : py(yMin)}
                viewW={W}
                viewH={H}
                lines={
                  hoveredState.stats
                    ? [
                        `Rep ${hovered + 1}${sideLabel(hoveredRec.side) ? ` · ${sideLabel(hoveredRec.side)}` : ""}`,
                        `median ${hoveredState.stats.median.toFixed(1)} kg`,
                        `peak ${hoveredRec.peakKg?.toFixed(1)} kg`,
                      ]
                    : [
                        `Rep ${hovered + 1}${sideLabel(hoveredRec.side) ? ` · ${sideLabel(hoveredRec.side)}` : ""}`,
                        "no samples recorded",
                      ]
                }
              />
            </>
          )}
        </svg>
      </div>
    </div>
  );
}

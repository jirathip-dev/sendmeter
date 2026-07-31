import { useSvgScale } from "../hooks/useSvgScale";
import { fmtHoldS } from "../lib/protocol";
import type { PresetRefs } from "../lib/protocol";
import {
  buildPresetPlan,
  planLabelVisibility,
  planMetric,
  planVaries,
  presetHasTarget,
} from "../lib/presetPlan";
import type { PlanPreset } from "../lib/presetPlan";

const W = 320;
const H = 64;
const PAD = { top: 14, right: 6, bottom: 16, left: 6 };

interface Props {
  preset: PlanPreset;
  refs: PresetRefs;
  resolvedTargets?: readonly (number | null)[];
}

/// Part 2 of #332/#331: a compact per-set bar chart of the plan a preset (or
/// the editor's live draft) resolves to — bar height ∝ that set's hold (or,
/// when holds are flat and only the target ramps, ∝ that set's target kg —
/// see `planMetric`), with the resolved target kg and (when alternating)
/// hand underneath each bar. Renders nothing when the plan doesn't actually
/// vary (`planVaries`) — a flat preset already reads fine as the existing
/// text summary, so the chart would just be noise. Shared between the
/// editor form and the fullscreen READY block so both read off the same
/// `buildPresetPlan`.
export default function PresetPlanChart({ preset, refs, resolvedTargets }: Props) {
  const rows = buildPresetPlan(preset, refs, resolvedTargets);
  const metric = planMetric(rows);
  const maxVal =
    metric === "hold"
      ? Math.max(1, ...rows.map((r) => r.holdS))
      : Math.max(1, ...rows.map((r) => r.targetKg ?? 0));
  const { y } = useSvgScale(W, H, PAD, 0, 1, 0, maxVal);
  if (!planVaries(rows, preset.sets)) return null;

  const plotW = W - PAD.left - PAD.right;
  const gap = 4;
  const barW = (plotW - gap * (rows.length - 1)) / rows.length;
  const baseline = y(0);
  const { showHold, showBelow } = planLabelVisibility(barW + gap);
  // "Not resolvable yet" only applies when a target was actually chosen
  // (curve / %-of-PR / fixed kg) — a preset left on Target load: None also
  // resolves every targetKg to null, but has nothing pending to report.
  const targetPending = presetHasTarget(preset) && rows.every((r) => r.targetKg == null);

  return (
    <div style={{ marginTop: 10 }}>
      <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", display: "block" }} aria-hidden="true">
        <line x1={PAD.left} y1={baseline} x2={W - PAD.right} y2={baseline} stroke="var(--border)" strokeWidth={1} />
        {rows.map((r, i) => {
          const x = PAD.left + i * (barW + gap);
          const cx = x + barW / 2;
          const barTop = y(metric === "hold" ? r.holdS : (r.targetKg ?? 0));
          const topLabel =
            metric === "hold" ? fmtHoldS(r.holdS) : r.targetKg != null ? `${r.targetKg.toFixed(1)}kg` : null;
          const below =
            metric === "hold"
              ? [
                  r.targetKg != null ? `${r.targetKg.toFixed(1)}kg` : null,
                  r.side ? (r.side === "left" ? "L" : "R") : null,
                ]
                  .filter(Boolean)
                  .join(" · ")
              : (r.side ? (r.side === "left" ? "L" : "R") : "");
          return (
            <g key={r.set}>
              <rect
                x={x}
                y={barTop}
                width={barW}
                height={Math.max(baseline - barTop, 1)}
                fill="var(--success)"
                opacity={0.75}
                rx={2}
              />
              {showHold && topLabel && (
                <text x={cx} y={barTop - 3} textAnchor="middle" fontSize={8} fill="var(--ink)">
                  {topLabel}
                </text>
              )}
              {showBelow && below && (
                <text x={cx} y={H - 4} textAnchor="middle" fontSize={7.5} fill="var(--ink-muted)">
                  {below}
                </text>
              )}
            </g>
          );
        })}
      </svg>
      {targetPending && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 2, textAlign: "center" }}>
          target not resolvable yet
        </div>
      )}
    </div>
  );
}

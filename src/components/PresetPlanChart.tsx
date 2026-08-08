import { useSvgScale } from "../hooks/useSvgScale";
import { useChartId } from "../hooks/useChartId";
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
import type { ResolvedAlternatingPlanSet } from "../lib/presetPlan";
import ChartDefs from "./ChartDefs";
import { chartColor, chartGradientUrl } from "../lib/chartTheme";

const W = 320;
const H = 64;
const PAD = { top: 14, right: 6, bottom: 16, left: 6 };

interface Props {
  preset: PlanPreset;
  refs: PresetRefs;
  resolvedAlternating?: readonly ResolvedAlternatingPlanSet[];
}

/// Part 2 of #332/#331: a compact per-set bar chart of the plan a preset (or
/// the editor's live draft) resolves to — bar height ∝ that set's hold (or,
/// when holds are flat and only the target ramps, ∝ that set's target kg —
/// see `planMetric`), with the resolved target kg and (when alternating)
/// "L+R" underneath each bar when alternating. Renders nothing when the plan doesn't actually
/// vary (`planVaries`) — a flat preset already reads fine as the existing
/// text summary, so the chart would just be noise. Shared between the
/// editor form and the fullscreen READY block so both read off the same
/// `buildPresetPlan`.
export default function PresetPlanChart({ preset, refs, resolvedAlternating }: Props) {
  const chartId = useChartId("preset-plan");
  const rows = buildPresetPlan(preset, refs, resolvedAlternating);
  const metric = planMetric(rows);
  const holdValue = (row: (typeof rows)[number]) =>
    Math.max(row.holdS, row.leftHoldS ?? 0, row.rightHoldS ?? 0);
  const targetValue = (row: (typeof rows)[number]) =>
    Math.max(row.targetKg ?? 0, row.leftTargetKg ?? 0, row.rightTargetKg ?? 0);
  const maxVal =
    metric === "hold"
      ? Math.max(1, ...rows.map(holdValue))
      : Math.max(1, ...rows.map(targetValue));
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
  const targetPending =
    presetHasTarget(preset) &&
    rows.every(
      (r) => r.targetKg == null && r.leftTargetKg == null && r.rightTargetKg == null,
    );

  return (
    <div style={{ marginTop: 10 }}>
      <svg
        role="img"
        aria-label="Preset plan progression chart"
        viewBox={`0 0 ${W} ${H}`}
        style={{ width: "100%", display: "block" }}
      >
        <ChartDefs instanceId={chartId} />
        <line x1={PAD.left} y1={baseline} x2={W - PAD.right} y2={baseline} stroke={chartColor("grid")} strokeWidth={1} />
        {rows.map((r, i) => {
          const x = PAD.left + i * (barW + gap);
          const cx = x + barW / 2;
          const barTop = y(metric === "hold" ? holdValue(r) : targetValue(r));
          const handHoldsDiffer =
            r.leftHoldS != null && r.rightHoldS != null && r.leftHoldS !== r.rightHoldS;
          const handTargetsDiffer =
            r.leftTargetKg != null &&
            r.rightTargetKg != null &&
            r.leftTargetKg !== r.rightTargetKg;
          const compactHandLabelFits = barW + gap >= 56;
          const topLabel =
            metric === "hold"
              ? handHoldsDiffer
                ? `L${fmtHoldS(r.leftHoldS!)} / R${fmtHoldS(r.rightHoldS!)}`
                : fmtHoldS(r.leftHoldS ?? r.holdS)
              : handTargetsDiffer
                ? `L${r.leftTargetKg!.toFixed(1)} / R${r.rightTargetKg!.toFixed(1)}`
                : r.leftTargetKg != null
                  ? `${r.leftTargetKg.toFixed(1)}kg`
                  : r.targetKg != null
                    ? `${r.targetKg.toFixed(1)}kg`
                    : null;
          const below =
            metric === "hold"
              ? [handTargetsDiffer
                  ? `L${r.leftTargetKg!.toFixed(1)} / R${r.rightTargetKg!.toFixed(1)}kg`
                  : r.leftTargetKg != null
                    ? `${r.leftTargetKg.toFixed(1)}kg`
                    : r.targetKg != null
                      ? `${r.targetKg.toFixed(1)}kg`
                      : null,
                  r.side ? "L+R" : null]
                  .filter(Boolean)
                  .join(" · ")
              : (r.side ? "L+R" : "");
          return (
            <g key={r.set}>
              <rect
                x={x}
                y={barTop}
                width={barW}
                height={Math.max(baseline - barTop, 1)}
                fill={chartGradientUrl(chartId, "load-area")}
                opacity={0.75}
                rx={2}
              />
              {showHold && topLabel &&
                ((!handHoldsDiffer && !handTargetsDiffer) || compactHandLabelFits) && (
                  <text x={cx} y={barTop - 3} textAnchor="middle" fontSize={8} fill={chartColor("axis")}>
                  {topLabel}
                </text>
                )}
              {showBelow && below && (
                <text x={cx} y={H - 4} textAnchor="middle" fontSize={7.5} fill={chartColor("axis")}>
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

import {
  CHART_GRADIENTS,
  chartColor,
  chartGradientId,
} from "../lib/chartTheme";

/**
 * Shared, deliberately filter-free SVG definitions. Every chart passes its
 * own `instanceId`, so multiple charts can safely be mounted together.
 */
export default function ChartDefs({ instanceId }: { instanceId: string }) {
  return (
    <defs>
      <linearGradient id={chartGradientId(instanceId, CHART_GRADIENTS.focusArea)} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stopColor={chartColor("focus")} stopOpacity="var(--chart-area-opacity)" />
        <stop offset="100%" stopColor={chartColor("focus")} stopOpacity={0.03} />
      </linearGradient>
      <linearGradient id={chartGradientId(instanceId, CHART_GRADIENTS.healthArea)} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stopColor={chartColor("health")} stopOpacity="var(--chart-area-opacity)" />
        <stop offset="100%" stopColor={chartColor("health")} stopOpacity={0.03} />
      </linearGradient>
      <linearGradient id={chartGradientId(instanceId, CHART_GRADIENTS.loadArea)} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stopColor={chartColor("load")} stopOpacity="var(--chart-area-opacity)" />
        <stop offset="100%" stopColor={chartColor("load")} stopOpacity={0.04} />
      </linearGradient>
      <linearGradient id={chartGradientId(instanceId, CHART_GRADIENTS.forceArea)} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stopColor={chartColor("force")} stopOpacity="var(--chart-area-opacity)" />
        <stop offset="100%" stopColor={chartColor("force")} stopOpacity={0.04} />
      </linearGradient>
      <linearGradient id={chartGradientId(instanceId, CHART_GRADIENTS.referenceBand)} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stopColor={chartColor("reference")} stopOpacity="var(--chart-band-opacity)" />
        <stop offset="100%" stopColor={chartColor("reference")} stopOpacity={0.04} />
      </linearGradient>
      <radialGradient id={chartGradientId(instanceId, CHART_GRADIENTS.selectedHalo)}>
        <stop offset="0%" stopColor={chartColor("focus")} stopOpacity={0.28} />
        <stop offset="70%" stopColor={chartColor("focus")} stopOpacity={0.08} />
        <stop offset="100%" stopColor={chartColor("focus")} stopOpacity={0} />
      </radialGradient>
    </defs>
  );
}

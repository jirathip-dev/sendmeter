import { useId } from "react";
import { chartInstanceId } from "../lib/chartTheme";

/** Stable, per-mounted-chart id for SVG definitions and URL references. */
export function useChartId(prefix: string): string {
  return chartInstanceId(prefix, useId());
}

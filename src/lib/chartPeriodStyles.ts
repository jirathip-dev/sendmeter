import { chartColor } from "./chartTheme";

/**
 * Every trailing force-curve window gets both a semantic token and a unique
 * dash rhythm. Colour is helpful when available, but the time-window label
 * and dash are the durable cues for monochrome print and colour-vision
 * differences.
 */
export interface CurvePeriodStyle {
  color: string;
  dash: string;
}

export const CURVE_PERIOD_STYLES: Readonly<Record<string, CurvePeriodStyle>> = {
  "30d": { color: chartColor("forceSecondary"), dash: "2 2" },
  "90d": { color: chartColor("load"), dash: "6 2" },
  "180d": { color: chartColor("caution"), dash: "1 2" },
  "1y": { color: chartColor("alert"), dash: "8 3 2 3" },
  "2y": { color: chartColor("focus"), dash: "4 2 1 2" },
  "3y": { color: chartColor("reference"), dash: "12 3" },
};

const DEFAULT_PERIOD_STYLE: CurvePeriodStyle = {
  color: chartColor("reference"),
  dash: "1 3",
};

export function curvePeriodStyle(label: string): CurvePeriodStyle {
  return CURVE_PERIOD_STYLES[label] ?? DEFAULT_PERIOD_STYLE;
}

import { chartColor } from "./chartTheme";

/**
 * Every trailing force-curve window gets both a semantic token and a unique
 * dash rhythm. Colour is helpful when available, but the time-window label
 * and dash are the durable cues for monochrome print and colour-vision
 * differences.
 */
export interface CurvePeriodStyle {
  color: string;
  foreground: string;
  dash: string;
}

export const CURVE_PERIOD_STYLES: Readonly<Record<string, CurvePeriodStyle>> = {
  "30d": { color: chartColor("forceSecondary"), foreground: chartColor("onForceSecondary"), dash: "2 2" },
  "90d": { color: chartColor("load"), foreground: chartColor("onLoad"), dash: "6 2" },
  "180d": { color: chartColor("caution"), foreground: chartColor("onCaution"), dash: "1 2" },
  "1y": { color: chartColor("alert"), foreground: chartColor("onAlert"), dash: "8 3 2 3" },
  "2y": { color: chartColor("focus"), foreground: chartColor("onFocus"), dash: "4 2 1 2" },
  "3y": { color: chartColor("reference"), foreground: chartColor("onReference"), dash: "12 3" },
};

const DEFAULT_PERIOD_STYLE: CurvePeriodStyle = {
  color: chartColor("reference"),
  foreground: chartColor("onReference"),
  dash: "1 3",
};

export function curvePeriodStyle(label: string): CurvePeriodStyle {
  return CURVE_PERIOD_STYLES[label] ?? DEFAULT_PERIOD_STYLE;
}

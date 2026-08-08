/**
 * Shared semantic chart palette.
 *
 * Charts deliberately consume semantic names instead of reaching for a
 * component's UI color directly.  The CSS variables behind these names are
 * theme-aware (and have a higher-contrast variant), while the labels below
 * document the non-colour cues that should accompany each mark.
 */
export const CHART_TOKENS = {
  focus: "--chart-focus",
  health: "--chart-health",
  load: "--chart-load",
  force: "--chart-force",
  forceSecondary: "--chart-force-secondary",
  optimal: "--chart-optimal",
  caution: "--chart-caution",
  alert: "--chart-alert",
  reference: "--chart-reference",
  grid: "--chart-grid",
  axis: "--chart-axis",
  tooltip: "--chart-tooltip",
  tooltipBorder: "--chart-tooltip-border",
} as const;

export type ChartSemantic = keyof typeof CHART_TOKENS;

/** Minimum SVG viewBox extent used for an interactive chart hit target. */
export const CHART_TOUCH_TARGET_UNITS = 44;

export const CHART_SEMANTICS: Readonly<Record<ChartSemantic, string>> = {
  focus: "active series or selected point",
  health: "readiness and recovery input",
  load: "training load and volume",
  force: "force curve and measured force",
  forceSecondary: "secondary force series or side",
  optimal: "within the target or healthy direction",
  caution: "reference, caution, or provisional value",
  alert: "outside target or concerning direction",
  reference: "comparison, forecast, or quiet context",
  grid: "chart gridline",
  axis: "chart axis label",
  tooltip: "tooltip surface",
  tooltipBorder: "tooltip boundary",
};

/** CSS variable reference for a semantic chart mark. */
export function chartColor(semantic: ChartSemantic): string {
  return `var(${CHART_TOKENS[semantic]})`;
}

/** A restrained tint that keeps the semantic hue while preserving depth. */
export function chartTint(semantic: ChartSemantic, percentage: number): string {
  const clamped = Math.max(0, Math.min(100, percentage));
  return `color-mix(in srgb, ${chartColor(semantic)} ${clamped}%, transparent)`;
}

/**
 * Make an SVG id safe for XML/CSS URL references. React's `useId()` includes
 * punctuation (for example `:r0:`); stripping it also keeps snapshots useful.
 */
export function chartInstanceId(prefix: string, seed: string): string {
  const safePrefix = prefix.replace(/[^a-zA-Z0-9_-]/g, "-") || "chart";
  const safeSeed = seed.replace(/[^a-zA-Z0-9_-]/g, "-").replace(/^-+|-+$/g, "") || "instance";
  return `${safePrefix}-${safeSeed}`;
}

export const CHART_GRADIENTS = {
  focusArea: "focus-area",
  healthArea: "health-area",
  loadArea: "load-area",
  forceArea: "force-area",
  referenceBand: "reference-band",
  selectedHalo: "selected-halo",
} as const;

export type ChartGradient = (typeof CHART_GRADIENTS)[keyof typeof CHART_GRADIENTS];

export function chartGradientId(instanceId: string, gradient: ChartGradient): string {
  return `${instanceId}-${gradient}`;
}

export function chartGradientUrl(instanceId: string, gradient: ChartGradient): string {
  return `url(#${chartGradientId(instanceId, gradient)})`;
}

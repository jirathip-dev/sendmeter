import { describe, expect, it } from "vitest";
import {
  CHART_GRADIENTS,
  CHART_SEMANTICS,
  CHART_TOKENS,
  chartColor,
  chartGradientId,
  chartGradientUrl,
  chartInstanceId,
  chartTint,
} from "./chartTheme";

describe("chart visual system", () => {
  it("keeps semantic decisions in the shared token table", () => {
    expect(chartColor("health")).toBe("var(--chart-health)");
    expect(chartColor("load")).toBe("var(--chart-load)");
    expect(chartColor("force")).toBe("var(--chart-force)");
    expect(CHART_SEMANTICS.optimal).toContain("target");
    expect(CHART_TOKENS.tooltip).toBe("--chart-tooltip");
  });

  it("clamps tints instead of producing invalid percentages", () => {
    expect(chartTint("focus", -10)).toBe("color-mix(in srgb, var(--chart-focus) 0%, transparent)");
    expect(chartTint("focus", 140)).toBe("color-mix(in srgb, var(--chart-focus) 100%, transparent)");
  });

  it("makes unique SVG ids safe for URL references", () => {
    const first = chartInstanceId("force curve", ":r0:");
    const second = chartInstanceId("force curve", ":r1:");
    expect(first).toBe("force-curve-r0");
    expect(second).not.toBe(first);
    expect(chartGradientId(first, CHART_GRADIENTS.forceArea)).toBe("force-curve-r0-force-area");
    expect(chartGradientUrl(first, CHART_GRADIENTS.forceArea)).toBe("url(#force-curve-r0-force-area)");
    expect(chartGradientId(first, CHART_GRADIENTS.forceArea)).not.toContain(":");
  });
});

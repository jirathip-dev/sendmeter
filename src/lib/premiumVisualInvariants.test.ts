import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = join(import.meta.dirname, "..");
const css = readFileSync(join(SRC, "index.css"), "utf8");

function component(name: string): string {
  return readFileSync(join(SRC, "components", name), "utf8");
}

describe("premium visual language contracts (#517)", () => {
  it("keeps semantic accents, material depth and theme-specific values in CSS", () => {
    const tokens = [
      "--accent-readiness",
      "--accent-caution",
      "--accent-load",
      "--accent-force",
      "--accent-interaction",
      "--gradient-readiness",
      "--gradient-caution",
      "--gradient-load",
      "--gradient-force",
      "--gradient-interaction",
      "--shadow-card",
      "--shadow-float",
      "--chrome-bg",
      "--chrome-border",
      "--radius-card",
      "--focus-ring",
    ];

    for (const token of tokens) {
      expect(css, token).toContain(token);
    }

    expect(css.match(/--accent-readiness\s*:/g)?.length ?? 0).toBeGreaterThanOrEqual(3);
    expect(css).toContain(':root[data-theme="dark"]');
    expect(css).toContain("@media (prefers-color-scheme: dark)");
  });

  it("defines shared surface and interaction contracts", () => {
    for (const selector of [
      ".surface-readiness",
      ".surface-load",
      ".surface-force",
      ".surface-workout",
      ".surface-history",
      ".filter-chip",
      ".phone-workout-resume",
      ".force-connection-card",
      ".premium-sheet",
      "@media (prefers-reduced-motion: reduce)",
      "@media (prefers-contrast: more)",
      "@supports not",
    ]) {
      expect(css, selector).toContain(selector);
    }
  });

  it("wires representative tabs into the shared surface vocabulary", () => {
    expect(component("ReadinessCard.tsx")).toContain("surface-readiness");
    expect(component("Dashboard.tsx")).toContain("surface-load");
    expect(component("WorkoutView.tsx")).toContain("surface-workout");
    expect(component("ForceView.tsx")).toContain("surface-force");
    expect(component("HistoryView.tsx")).toContain("filter-chip");
    expect(component("Sheet.tsx")).toContain("premium-sheet");
    expect(component("ThemeSection.tsx")).toContain("theme-switcher");
  });

  it("keeps the browser chrome aligned with the new canvas themes", () => {
    const indexHtml = readFileSync(join(SRC, "..", "index.html"), "utf8");
    expect(indexHtml).toContain('content="#F2F4F8"');
    expect(indexHtml).toContain('content="#0E121B"');
    expect(component("ThemeSection.tsx")).toContain('"#0E121B"');
    expect(component("ThemeSection.tsx")).toContain('"#F2F4F8"');
  });
});

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = join(import.meta.dirname, "..");
const read = (relativePath: string): string =>
  readFileSync(join(SRC, relativePath), "utf8");

describe("DEV UI QA lab source contract", () => {
  it("keeps the lab guarded, isolated, dimensioned, and production-excluded", () => {
    const main = read("main.tsx");
    const productionBootstrap = read("appBootstrap.tsx");
    const lab = read("dev/uiQa.tsx");
    const labCss = read("dev/uiQa.css");

    expect(main).toContain('import "./index.css";');
    expect(main).toMatch(/if \(import\.meta\.env\.DEV &&[\s\S]*has\("ui-qa"\)/);
    expect(main.indexOf('import("./dev/uiQa")')).toBeGreaterThan(-1);
    expect(main.indexOf('import("./dev/uiQa")')).toBeLessThan(
      main.indexOf('import("./appBootstrap")'),
    );
    expect(main).not.toMatch(/from\s+["']\.\/App["']/);
    expect(main).not.toMatch(/from\s+["'][^"']*(?:auth|repo|supabase)[^"']*["']/i);
    expect(productionBootstrap).toContain('from "./App"');
    expect(productionBootstrap).toContain("mountProductionApp");
    expect(productionBootstrap).not.toContain("UI-QA-LAB");
    expect(productionBootstrap).not.toContain("ui-qa");

    expect(lab).not.toMatch(/from\s+["'][^"']*(?:auth|repo|supabase)[^"']*["']/i);
    expect(lab).not.toMatch(/\b(?:fetch|XMLHttpRequest|supabase)\b/i);
    expect(lab).toContain('from "../components/Sheet"');
    expect(lab).toContain('from "../components/ConfirmDialog"');
    expect(lab).toContain('from "../components/ChartDefs"');
    expect(lab).toContain('from "../hooks/useChartHover"');
    expect(lab).toContain('from "../lib/chartTheme"');
    expect(lab).toContain('createThemeController');
    expect(lab).toContain("UI-QA-LAB");

    for (const selector of [
      "uiqa-frame-390x844",
      "uiqa-frame-375x667",
      "uiqa-phone-frame",
      "uiqa-open-sheet",
      "uiqa-chart-hit-surface",
      "uiqa-chart-selection",
      "uiqa-open-confirm",
      "uiqa-theme-system",
      "uiqa-theme-light",
      "uiqa-theme-dark",
      "uiqa-readiness",
      "uiqa-load",
      "uiqa-force",
      "uiqa-history-card",
      "uiqa-primary",
      "uiqa-secondary",
      "uiqa-danger",
      "uiqa-disabled-action",
      "uiqa-scroll-sentinel",
      "uiqa-lock-status",
      "uiqa-sheet-scroll-sentinel",
    ]) {
      expect(lab).toContain(selector);
    }

    expect(lab).toMatch(/data-testid="uiqa-frame-390x844"[\s\S]*width=\{390\}[\s\S]*height=\{844\}/);
    expect(lab).toMatch(/data-testid="uiqa-frame-375x667"[\s\S]*width=\{375\}[\s\S]*height=\{667\}/);
    expect(lab).toContain('url.search = "?ui-qa&embedded=1"');
    expect(lab).toContain("new URL(window.location.href)");
    expect(labCss).toContain('iframe[data-testid="uiqa-frame-390x844"]');
    expect(labCss).toContain('width: 390px;');
    expect(labCss).toContain('height: 844px;');
    expect(labCss).toContain('iframe[data-testid="uiqa-frame-375x667"]');
    expect(labCss).toContain('width: 375px;');
    expect(labCss).toContain('height: 667px;');
    expect(labCss).toContain("min-width: 44px");
    expect(labCss).toContain("min-height: 44px");

    // The production entry is the only place allowed to name the lab. Vite's
    // compile-time DEV fold can therefore remove the marker, query, CSS, and
    // dynamic lab module from a production graph without a snapshot contract.
    expect(main).not.toContain("UI-QA-LAB");
    expect(main).not.toContain("uiQa.css");
    expect(main).toMatch(/import\.meta\.env\.DEV/);
  });
});

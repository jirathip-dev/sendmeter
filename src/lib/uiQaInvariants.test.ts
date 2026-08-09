// @vitest-environment jsdom
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import type { Root } from "react-dom/client";
import { describe, expect, it } from "vitest";
import { mountUiQa } from "../dev/uiQa";

const SRC = join(import.meta.dirname, "..");
const PROJECT_ROOT = join(SRC, "..");
const DIST = join(PROJECT_ROOT, "dist");
const read = (relativePath: string): string =>
  readFileSync(join(SRC, relativePath), "utf8");

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT =
  true;

const REQUIRED_EMBEDDED_IDS = [
  "uiqa-phone-frame",
  "uiqa-open-sheet",
  "uiqa-chart-hit-surface",
  "uiqa-chart-selection",
  "uiqa-theme-system",
  "uiqa-theme-light",
  "uiqa-theme-dark",
  "uiqa-readiness-card",
  "uiqa-load-card",
  "uiqa-force-card",
  "uiqa-history-card",
  "uiqa-primary-action",
  "uiqa-secondary-action",
  "uiqa-danger-action",
  "uiqa-disabled-action",
  "uiqa-scroll-sentinel",
  "uiqa-lock-status",
] as const;

const REQUIRED_AFTER_SHEET_IDS = [
  "uiqa-open-confirm",
  "uiqa-sheet-scroll-sentinel",
] as const;

function productionTextFiles(directory: string): string[] {
  if (!statSafe(directory)?.isDirectory()) return [];
  const files: string[] = [];

  function visit(current: string): void {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const path = join(current, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (/\.(?:css|html|js|json|mjs)$/i.test(entry.name)) files.push(path);
    }
  }

  visit(directory);
  return files;
}

function statSafe(path: string) {
  try {
    return statSync(path);
  } catch {
    return null;
  }
}

async function mountLab(search: string): Promise<{
  host: HTMLDivElement;
  root: Root;
}> {
  window.history.replaceState({}, "", `/${search}`);
  const host = document.createElement("div");
  document.body.append(host);
  let root!: Root;
  await act(async () => {
    root = mountUiQa(host);
    await Promise.resolve();
  });
  return { host, root };
}

describe("DEV UI QA lab source and runtime contract", () => {
  it("keeps the lab guarded, isolated, and auth-free in production source", () => {
    const main = read("main.tsx");
    const auth = read("hooks/useAuth.ts");
    const productionBootstrap = read("appBootstrap.tsx");
    const lab = read("dev/uiQa.tsx");
    const labCss = read("dev/uiQa.css");
    const devAuth = read("lib/devAuth.ts");

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

    // A static import here puts the seeded credentials into App's production
    // graph even though the runtime branch is DEV-only. The dynamic import is
    // deliberately guarded by the compile-time DEV constant instead.
    expect(auth).not.toMatch(/from\s+["'][^"']*devAuth[^"']*["']/);
    expect(auth).toMatch(
      /const devAuthModulePromise[\s\S]*import\.meta\.env\.DEV[\s\S]*import\("\.\.\/lib\/devAuth"\)/,
    );
    expect(auth).toContain("autoSignInForLocalDevOrNull");
    expect(auth).not.toContain("dev@sendmeter.test");
    expect(auth).not.toContain("devpassword");
    expect(auth).not.toContain("Local dev auto-login failed");
    expect(devAuth).toContain("dev@sendmeter.test");
    expect(devAuth).toContain("devpassword");
    expect(devAuth).toContain("Local dev auto-login failed");

    expect(lab).not.toMatch(/from\s+["'][^"']*(?:auth|repo|supabase)[^"']*["']/i);
    expect(lab).not.toMatch(/\b(?:fetch|XMLHttpRequest|supabase)\b/i);
    expect(lab).toContain('from "../components/Sheet"');
    expect(lab).toContain('from "../components/ConfirmDialog"');
    expect(lab).toContain('from "../components/ChartDefs"');
    expect(lab).toContain('from "../hooks/useChartHover"');
    expect(lab).toContain('from "../lib/chartTheme"');
    expect(lab).toContain("createThemeController");
    expect(lab).toContain("UI-QA-LAB");

    expect(lab).toContain('data-testid="uiqa-frame-390x844"');
    expect(lab).toContain('data-testid="uiqa-frame-375x667"');
    expect(lab).toContain('width={390}');
    expect(lab).toContain('height={844}');
    expect(lab).toContain('width={375}');
    expect(lab).toContain('height={667}');
    expect(lab).toContain('url.search = "?ui-qa&embedded=1"');
    expect(lab).toContain("new URL(window.location.href)");
    expect(labCss).toContain("box-sizing: content-box;");
    expect(labCss).toContain('iframe[data-testid="uiqa-frame-390x844"]');
    expect(labCss).toContain('iframe[data-testid="uiqa-frame-375x667"]');
    expect(labCss).toContain("width: 390px;");
    expect(labCss).toContain("height: 844px;");
    expect(labCss).toContain("width: 375px;");
    expect(labCss).toContain("height: 667px;");
    expect(labCss).toContain("min-width: 44px");
    expect(labCss).toContain("min-height: 44px");

    // The production entry is the only place allowed to name the lab. Vite's
    // compile-time DEV fold can therefore remove the marker, query, CSS, and
    // dynamic lab module from a production graph.
    expect(main).not.toContain("UI-QA-LAB");
    expect(main).not.toContain("uiQa.css");
  });

  it("renders the exact required runtime IDs and phone content viewports", async () => {
    const labStyle = document.createElement("style");
    // Vitest's jsdom runner does not inject CSS imports into the document.
    // Install the same global reset + lab stylesheet the browser receives so
    // getComputedStyle exercises the real box-sizing cascade.
    labStyle.textContent = `:root { --border: #000; --bg: #fff; --ink: #000; --ink-muted: #444; --ink-faint: #666; --surface-2: #eee; --primary-accent: #05c; --primary: #05c; --hairline: #ccc; --success: #080; --warning: #a50; --surface-0: #fff; --surface-1: #fff; --radius-control: 4px; --shadow-float: none; --t-sm: 12px; --t-xs: 10px; --t-eyebrow: 9px; --t-2xs: 8px; --t-lg: 16px; --t-base: 14px; }\n*, *::before, *::after { box-sizing: border-box; }\n${read(
      "dev/uiQa.css",
    )}
/* jsdom does not resolve custom properties in replaced-element borders. */
.uiqa-frame-control iframe { border-width: 1px; border-style: solid; border-color: #000; }`;
    document.head.append(labStyle);
    const outer = await mountLab("?ui-qa");
    try {
      for (const [testId, width, height] of [
        ["uiqa-frame-390x844", 390, 844],
        ["uiqa-frame-375x667", 375, 667],
      ] as const) {
        const frame = outer.host.querySelector<HTMLIFrameElement>(
          `[data-testid="${testId}"]`,
        );
        expect(frame).not.toBeNull();
        expect(frame?.width).toBe(String(width));
        expect(frame?.height).toBe(String(height));

        // This is a computed browser contract, not a second assertion over
        // source strings: index.css sets border-box globally, while the lab
        // override must make the CSS width/height the iframe content viewport
        // and leave the visible 1px frame outside it.
        const computed = window.getComputedStyle(frame!);
        expect(computed.boxSizing).toBe("content-box");
        expect(Number.parseFloat(computed.width)).toBe(width);
        expect(Number.parseFloat(computed.height)).toBe(height);
        expect(Number.parseFloat(computed.borderLeftWidth)).toBe(1);
        expect(Number.parseFloat(computed.borderRightWidth)).toBe(1);
        expect(Number.parseFloat(computed.borderTopWidth)).toBe(1);
        expect(Number.parseFloat(computed.borderBottomWidth)).toBe(1);
      }
    } finally {
      await act(async () => outer.root.unmount());
      outer.host.remove();
    }

    const embedded = await mountLab("?ui-qa&embedded=1");
    try {
      for (const testId of REQUIRED_EMBEDDED_IDS) {
        expect(embedded.host.querySelectorAll(`[data-testid="${testId}"]`)).toHaveLength(1);
      }

      const disabled = embedded.host.querySelector<HTMLButtonElement>(
        '[data-testid="uiqa-disabled-action"]',
      );
      expect(disabled?.disabled).toBe(true);

      const openSheet = embedded.host.querySelector<HTMLButtonElement>(
        '[data-testid="uiqa-open-sheet"]',
      );
      expect(openSheet).not.toBeNull();
      await act(async () => openSheet?.click());
      for (const testId of REQUIRED_AFTER_SHEET_IDS) {
        expect(document.querySelectorAll(`[data-testid="${testId}"]`)).toHaveLength(1);
      }
    } finally {
      await act(async () => embedded.root.unmount());
      embedded.host.remove();
      document.querySelectorAll('[data-testid="uiqa-sheet-scroll-sentinel"]').forEach((node) => {
        node.parentElement?.remove();
      });
      window.history.replaceState({}, "", "/");
      labStyle.remove();
    }
  });

  it("rejects forbidden lab and dev-auth markers from emitted production text", () => {
    const files = productionTextFiles(DIST);
    if (files.length === 0) return;

    const forbidden = [
      /dev@sendmeter\.test/i,
      /devpassword/i,
      /LOCAL_DEV_(?:EMAIL|PASSWORD)/,
      /VITE_DEV_AUTO_LOGIN/i,
      /devAuth/i,
      /Local dev auto-login/i,
      /UI-QA-LAB/i,
      /ui-qa/i,
      /uiqa-/i,
    ];
    const violations = files.flatMap((file) => {
      const source = readFileSync(file, "utf8");
      return forbidden
        .filter((pattern) => pattern.test(source))
        .map((pattern) => `${file}: ${pattern}`);
    });

    expect(violations).toEqual([]);
  });
});

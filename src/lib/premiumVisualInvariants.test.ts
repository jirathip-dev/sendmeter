import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = join(import.meta.dirname, "..");
const css = readFileSync(join(SRC, "index.css"), "utf8");
const indexHtml = readFileSync(join(SRC, "..", "index.html"), "utf8");

function component(name: string): string {
  return readFileSync(join(SRC, "components", name), "utf8");
}

function componentSources(): Array<[string, string]> {
  return readdirSync(join(SRC, "components"), { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".tsx"))
    .map((entry) => [entry.name, component(entry.name)]);
}

/**
 * Extract JSX button opening tags without stopping at object-literal braces in
 * event handlers/styles. This lets the invariant inspect every semantic
 * button consumer instead of relying on a hand-maintained file list.
 */
function buttonOpeningTags(source: string): string[] {
  const tags: string[] = [];
  let cursor = 0;
  while (true) {
    const start = source.indexOf("<button", cursor);
    if (start < 0) return tags;

    let braceDepth = 0;
    let quote: "'" | '"' | "`" | null = null;
    let end = start + "<button".length;
    for (; end < source.length; end += 1) {
      const character = source[end]!;
      if (quote) {
        if (character === quote && source[end - 1] !== "\\") quote = null;
        continue;
      }
      if (character === "'" || character === '"' || character === "`") {
        quote = character;
      } else if (character === "{") {
        braceDepth += 1;
      } else if (character === "}") {
        braceDepth = Math.max(0, braceDepth - 1);
      } else if (character === ">" && braceDepth === 0) {
        break;
      }
    }
    tags.push(source.slice(start, end + 1));
    cursor = end + 1;
  }
}

/** Return the contents of the first balanced block after a CSS marker. */
function blockAfter(source: string, marker: string): string {
  const markerStart = source.indexOf(marker);
  if (markerStart < 0) throw new Error(`Missing CSS marker: ${marker}`);
  const open = marker.endsWith("{")
    ? markerStart + marker.length - 1
    : source.indexOf("{", markerStart + marker.length);
  if (open < 0) throw new Error(`Missing opening brace after: ${marker}`);

  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(open + 1, i);
    }
  }
  throw new Error(`Unclosed CSS block after: ${marker}`);
}

function declarations(source: string): Record<string, string> {
  return Object.fromEntries(
    Array.from(source.matchAll(/(--[\w-]+)\s*:\s*([^;{}]+);/g), ([, name, value]) => [
      name ?? "",
      value?.trim() ?? "",
    ]),
  );
}

const themeBlocks = {
  light: blockAfter(css, ":root {"),
  dark: blockAfter(css, ':root[data-theme="dark"] {'),
  systemDark: blockAfter(
    blockAfter(css, "@media (prefers-color-scheme: dark) {"),
    ':root:not([data-theme="light"]) {',
  ),
};
const themeDeclarations = Object.fromEntries(
  Object.entries(themeBlocks).map(([name, block]) => [name, declarations(block)]),
) as Record<keyof typeof themeBlocks, Record<string, string>>;

const THEME_TOKENS = [
  "--accent-readiness",
  "--accent-caution",
  "--accent-load",
  "--accent-force",
  "--accent-interaction",
  "--accent-info",
  "--gradient-neutral",
  "--gradient-readiness",
  "--gradient-caution",
  "--gradient-load",
  "--gradient-force",
  "--gradient-interaction",
  "--shadow-card",
  "--shadow-float",
  "--chrome-bg",
  "--chrome-border",
  "--focus-ring",
  "--primary-action",
  "--primary-action-shade",
  "--primary-action-hover",
  "--primary-action-hover-shade",
  "--primary-action-active",
  "--primary-action-active-shade",
  "--primary-action-disabled",
  "--primary-action-disabled-shade",
  "--primary-action-text",
  "--secondary-action-bg",
  "--secondary-action-bg-shade",
  "--secondary-action-bg-hover",
  "--secondary-action-bg-hover-shade",
  "--secondary-action-bg-active",
  "--secondary-action-bg-active-shade",
  "--secondary-action-bg-disabled",
  "--secondary-action-bg-disabled-shade",
  "--secondary-action-text",
  "--secondary-action-text-hover",
  "--secondary-action-text-active",
  "--secondary-action-text-disabled",
  "--secondary-action-border",
  "--secondary-action-border-hover",
  "--secondary-action-border-active",
  "--secondary-action-border-disabled",
  "--danger-action",
  "--danger-action-shade",
  "--danger-action-hover",
  "--danger-action-hover-shade",
  "--danger-action-active",
  "--danger-action-active-shade",
  "--danger-action-disabled",
  "--danger-action-disabled-shade",
  "--danger-action-text",
] as const;

type RGB = readonly [number, number, number];

function hexColor(value: string, name: string): RGB {
  const match = value.match(/^#([0-9a-f]{6})$/i);
  if (!match) throw new Error(`${name} is not a six-digit hex color: ${value}`);
  const hex = match[1]!;
  return [
    Number.parseInt(hex.slice(0, 2), 16),
    Number.parseInt(hex.slice(2, 4), 16),
    Number.parseInt(hex.slice(4, 6), 16),
  ];
}

function linearChannel(channel: number): number {
  const srgb = channel / 255;
  return srgb <= 0.03928
    ? srgb / 12.92
    : ((srgb + 0.055) / 1.055) ** 2.4;
}

function luminance(color: RGB): number {
  return (
    0.2126 * linearChannel(color[0]) +
    0.7152 * linearChannel(color[1]) +
    0.0722 * linearChannel(color[2])
  );
}

function contrastRatio(foreground: RGB, background: RGB): number {
  const foregroundLuminance = luminance(foreground);
  const backgroundLuminance = luminance(background);
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function mix(a: RGB, b: RGB, amount: number): RGB {
  return [
    a[0] + (b[0] - a[0]) * amount,
    a[1] + (b[1] - a[1]) * amount,
    a[2] + (b[2] - a[2]) * amount,
  ];
}

describe("premium visual language contracts (#517)", () => {
  it("defines every semantic token in light, explicit dark, and system-dark themes", () => {
    for (const token of THEME_TOKENS) {
      for (const [theme, values] of Object.entries(themeDeclarations)) {
        expect(values[token], `${token} in ${theme}`).toBeDefined();
        expect(values[token], `${token} in ${theme}`).not.toBe("");
      }
    }

    expect(themeDeclarations.dark["--primary-action"]).toBe(
      themeDeclarations.systemDark["--primary-action"],
    );
    expect(css).toContain(':root[data-theme="dark"]');
    expect(css).toContain("@media (prefers-color-scheme: dark)");
  });

  it("keeps every semantic button state AA-readable across both themes and gradients", () => {
    const textByTheme = Object.fromEntries(
      Object.entries(themeDeclarations).map(([theme, values]) => [
        theme,
        {
          primary: hexColor(values["--primary-action-text"]!, `${theme} primary action text`),
          secondary: hexColor(values["--secondary-action-text"]!, `${theme} secondary action text`),
          secondaryHover: hexColor(values["--secondary-action-text-hover"]!, `${theme} secondary hover text`),
          secondaryActive: hexColor(values["--secondary-action-text-active"]!, `${theme} secondary active text`),
          secondaryDisabled: hexColor(values["--secondary-action-text-disabled"]!, `${theme} secondary disabled text`),
          danger: hexColor(values["--danger-action-text"]!, `${theme} danger action text`),
        },
      ]),
    );
    const states = {
      primary: [
        ["--primary-action", "--primary-action-shade", "primary"],
        ["--primary-action-hover", "--primary-action-hover-shade", "primary"],
        ["--primary-action-active", "--primary-action-active-shade", "primary"],
        ["--primary-action-disabled", "--primary-action-disabled-shade", "primary"],
      ],
      secondary: [
        ["--secondary-action-bg", "--secondary-action-bg-shade", "secondary"],
        ["--secondary-action-bg-hover", "--secondary-action-bg-hover-shade", "secondaryHover"],
        ["--secondary-action-bg-active", "--secondary-action-bg-active-shade", "secondaryActive"],
        ["--secondary-action-bg-disabled", "--secondary-action-bg-disabled-shade", "secondaryDisabled"],
      ],
      danger: [
        ["--danger-action", "--danger-action-shade", "danger"],
        ["--danger-action-hover", "--danger-action-hover-shade", "danger"],
        ["--danger-action-active", "--danger-action-active-shade", "danger"],
        ["--danger-action-disabled", "--danger-action-disabled-shade", "danger"],
      ],
    } as const;

    for (const [theme, values] of Object.entries(themeDeclarations)) {
      for (const [variant, variantStates] of Object.entries(states)) {
        for (const [startToken, endToken, textToken] of variantStates) {
          const start = hexColor(values[startToken]!, `${theme} ${startToken}`);
          const end = hexColor(values[endToken]!, `${theme} ${endToken}`);
          const text = textByTheme[theme]![textToken];
          for (let step = 0; step <= 100; step += 1) {
            const amount = step / 100;
            expect(
              contrastRatio(text, mix(start, end, amount)),
              `${theme} ${variant} ${startToken}/${endToken} at ${amount}`,
            ).toBeGreaterThanOrEqual(4.5);
          }
        }
      }
    }

    const buttonStyles = css.slice(css.indexOf("/* Buttons */"), css.indexOf(".btn-ghost {"));
    const cssStates = [
      [".btn-primary {", "--primary-action", "--primary-action-shade", "--primary-action-text"],
      [".btn-primary:hover:not(:disabled):not([aria-disabled=\"true\"]) {", "--primary-action-hover", "--primary-action-hover-shade", "--primary-action-text"],
      [".btn-primary:active:not(:disabled):not([aria-disabled=\"true\"]) {", "--primary-action-active", "--primary-action-active-shade", "--primary-action-text"],
      [".btn-primary:disabled,", "--primary-action-disabled", "--primary-action-disabled-shade", "--primary-action-text"],
      [".btn-secondary {", "--secondary-action-bg", "--secondary-action-bg-shade", "--secondary-action-text"],
      [".btn-secondary:hover:not(:disabled):not([aria-disabled=\"true\"]) {", "--secondary-action-bg-hover", "--secondary-action-bg-hover-shade", "--secondary-action-text-hover"],
      [".btn-secondary:active:not(:disabled):not([aria-disabled=\"true\"]) {", "--secondary-action-bg-active", "--secondary-action-bg-active-shade", "--secondary-action-text-active"],
      [".btn-secondary:disabled,", "--secondary-action-bg-disabled", "--secondary-action-bg-disabled-shade", "--secondary-action-text-disabled"],
      [".btn-danger {", "--danger-action", "--danger-action-shade", "--danger-action-text"],
      [".btn-danger:hover:not(:disabled):not([aria-disabled=\"true\"]) {", "--danger-action-hover", "--danger-action-hover-shade", "--danger-action-text"],
      [".btn-danger:active:not(:disabled):not([aria-disabled=\"true\"]) {", "--danger-action-active", "--danger-action-active-shade", "--danger-action-text"],
      [".btn-danger:disabled,", "--danger-action-disabled", "--danger-action-disabled-shade", "--danger-action-text"],
    ] as const;
    for (const [selector, startToken, endToken, textToken] of cssStates) {
      const escapedSelector = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      expect(buttonStyles, `${selector} background`).toMatch(
        new RegExp(
          `${escapedSelector}[\\s\\S]*?background-image:[^;]*var\\(${startToken}\\)[^;]*var\\(${endToken}\\)`,
        ),
      );
      expect(buttonStyles, `${selector} text`).toMatch(
        new RegExp(`${escapedSelector}[\\s\\S]*?color:\\s*var\\(${textToken}\\)`),
      );
    }
    for (const className of ["btn-primary", "btn-secondary", "btn-danger"]) {
      expect(css).toContain(`.${className}:hover:not(:disabled):not([aria-disabled="true"])`);
      expect(css).toContain(`.${className}:active:not(:disabled):not([aria-disabled="true"])`);
      expect(css).toContain(`.${className}:disabled,`);
      expect(css).toContain(`.${className}[aria-disabled="true"]`);
      expect(css).toMatch(new RegExp(`\\.${className}:disabled,[\\s\\S]*?opacity:\\s*1;`));
      expect(css).toContain(`.${className}:focus-visible`);
    }
    expect(css).toContain(".btn-secondary.btn-inline");
    expect(css).toContain(".btn-danger.btn-inline");
    expect(component("PhoneWorkoutCard.tsx")).not.toContain("style={blockedReason ? { opacity: 0.5 }");
    expect(component("RoutineCard.tsx")).not.toContain("flex: 1, opacity: 0.5");
  });

  it("keeps every semantic button consumer on the shared recipe", () => {
    const consumers = componentSources().flatMap(([file, source]) =>
      buttonOpeningTags(source).map((tag) => ({ file, tag })),
    );
    const semanticConsumers = consumers.filter(({ tag }) =>
      /btn-(?:primary|secondary|danger)\b/.test(tag),
    );

    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-primary"))).toBe(true);
    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-secondary"))).toBe(true);
    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-danger"))).toBe(true);

    for (const { file, tag } of semanticConsumers) {
      expect(
        tag,
        `${file} overrides a shared semantic button with an inline paint property`,
      ).not.toMatch(/\b(?:background(?:-image|-color)?|color|border(?:-color)?)\s*:/);
    }

    for (const { file, tag } of consumers) {
      const inlineDangerFill = /\bbackground(?:-image|-color)?\s*:\s*["'`]?\s*var\(\s*--danger\b\s*\)\s*["'`]?/i.test(tag);
      expect(
        inlineDangerFill,
        `${file} uses an inline danger/white action fill; use .btn-danger instead`,
      ).toBe(false);
    }
  });

  it("keeps high-contrast light and dark selectors in the intended cascade", () => {
    const contrastStart = css.indexOf("@media (prefers-contrast: more) {");
    const systemDarkContrastStart = css.indexOf(
      "@media (prefers-contrast: more) and (prefers-color-scheme: dark) {",
    );
    expect(contrastStart).toBeGreaterThanOrEqual(0);
    expect(systemDarkContrastStart).toBeGreaterThan(contrastStart);

    const contrastBlock = blockAfter(css, "@media (prefers-contrast: more) {");
    const explicitDarkBlock = blockAfter(
      contrastBlock,
      ':root[data-theme="dark"] {',
    );
    const systemDarkBlock = blockAfter(
      blockAfter(
        css,
        "@media (prefers-contrast: more) and (prefers-color-scheme: dark) {",
      ),
      ':root:not([data-theme="light"]) {',
    );

    expect(contrastBlock).toContain(':root[data-theme="dark"]');
    expect(systemDarkBlock).toContain("--card-border: rgba(231,239,255,0.3)");
    expect(systemDarkBlock).toContain("--chrome-border: rgba(231,239,255,0.34)");
    expect(systemDarkBlock).toContain("--hairline: #52617A");
    expect(explicitDarkBlock).toContain("--hairline: #52617A");
    expect(systemDarkContrastStart).toBeGreaterThan(
      css.indexOf(':root[data-theme="dark"] {', contrastStart),
    );
  });

  it("keeps CSS custom-property references defined or explicitly local", () => {
    const definitions = new Set(
      Array.from(css.matchAll(/(--[\w-]+)\s*:/g), ([, token]) => token),
    );
    const localProperties = new Set([
      "--color", // SVG/chart colors supplied by the component at render time.
      "--pill-tint", // Glass action tint supplied by each fullscreen control.
      "--toast-accent", // Toast kind color supplied by ToastProvider.
    ]);

    for (const match of css.matchAll(/var\(\s*(--[\w-]+)/g)) {
      const token = match[1]!;
      if (token === "--t-" || localProperties.has(token)) continue;
      expect(definitions.has(token), `undefined CSS token ${token}`).toBe(true);
    }
  });

  it("wires representative tabs into the shared surface vocabulary", () => {
    const wiring: Record<string, string[]> = {
      "ReadinessCard.tsx": ["surface-readiness"],
      "Dashboard.tsx": ["surface-context", "surface-load"],
      "WorkoutView.tsx": ["surface-workout"],
      "ForceView.tsx": ["surface-force", "surface-caution"],
      "HistoryView.tsx": ["surface-history", "filter-chip"],
      "Sheet.tsx": ["premium-sheet"],
      "ThemeSection.tsx": ["theme-switcher", "theme-option"],
    };
    for (const [file, classes] of Object.entries(wiring)) {
      const source = component(file);
      for (const className of classes) {
        expect(source, `${file} missing ${className}`).toContain(className);
        expect(css, `missing CSS selector .${className}`).toMatch(
          new RegExp(`\\.${className}(?:[.:\\s,{])`),
        );
      }
    }
    expect(css).toContain(".surface-caution");
    expect(css).not.toContain(".metric-value");
  });

  it("keeps the shared material and preference contracts present", () => {
    for (const className of [
      "surface-readiness",
      "surface-caution",
      "surface-load",
      "surface-force",
      "surface-workout",
      "surface-history",
      "filter-chip",
      "phone-workout-resume",
      "force-connection-card",
      "premium-sheet",
    ]) {
      expect(css, `missing CSS selector .${className}`).toMatch(
        new RegExp(`\\.${className}(?:[.:\\s,{])`),
      );
    }
    expect(css).toContain("@media (prefers-reduced-motion: reduce)");
    expect(css).toContain("@media (prefers-contrast: more)");
    expect(css).toContain("@supports not");
  });

  it("exposes theme selection programmatically and preserves forced-colors focus", () => {
    const themeSource = component("ThemeSection.tsx");
    expect(themeSource).toContain('type="button"');
    expect(themeSource).toContain("aria-pressed={choice === o.value}");
    expect(themeSource).toContain('choice === o.value ? " selected" : ""');

    const forcedColors = blockAfter(css, "@media (forced-colors: active) {");
    expect(forcedColors).toContain(".theme-option.selected");
    expect(forcedColors).toContain("background: Highlight");
    expect(forcedColors).toContain("color: HighlightText");
    expect(forcedColors).toContain(".theme-option:focus-visible");
    expect(forcedColors).toContain("outline: 2px solid Highlight");
  });

  it("keeps the browser chrome aligned with the new canvas themes", () => {
    expect(indexHtml).toContain('content="#F2F4F8"');
    expect(indexHtml).toContain('content="#0E121B"');
    expect(component("ThemeSection.tsx")).toContain('"#0E121B"');
    expect(component("ThemeSection.tsx")).toContain('"#F2F4F8"');
  });
});

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = join(import.meta.dirname, "..");
const css = readFileSync(join(SRC, "index.css"), "utf8");
const indexHtml = readFileSync(join(SRC, "..", "index.html"), "utf8");
const design = readFileSync(join(SRC, "..", "DESIGN.md"), "utf8");
const mainSource = readFileSync(join(SRC, "..", "src", "main.tsx"), "utf8");
const manifestPath = join(SRC, "..", "public", "manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
  background_color?: string;
  theme_color?: string;
};
const viteConfig = readFileSync(join(SRC, "..", "vite.config.ts"), "utf8");
const themeSource = readFileSync(join(SRC, "lib", "theme.ts"), "utf8");
const packageScripts = (
  JSON.parse(readFileSync(join(SRC, "..", "package.json"), "utf8")) as {
    scripts?: Record<string, string>;
  }
).scripts ?? {};

function component(name: string): string {
  return readFileSync(join(SRC, "components", name), "utf8");
}

function componentSources(): Array<[string, string]> {
  return readdirSync(join(SRC, "components"), { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".tsx"))
    .map((entry) => [entry.name, component(entry.name)]);
}

interface ButtonRegion {
  tag: string;
  element: string;
}

/**
 * Extract JSX button opening tags without stopping at object-literal braces in
 * event handlers/styles. This lets the invariant inspect every semantic
 * button consumer instead of relying on a hand-maintained file list.
 */
function buttonRegions(source: string): ButtonRegion[] {
  const regions: ButtonRegion[] = [];
  let cursor = 0;
  while (true) {
    const start = source.indexOf("<button", cursor);
    if (start < 0) return regions;

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
    const tag = source.slice(start, end + 1);
    const closingStart = source.indexOf("</button>", end + 1);
    const closingEnd = closingStart < 0 ? end + 1 : closingStart + "</button>".length;
    regions.push({ tag, element: source.slice(start, closingEnd) });
    cursor = end + 1;
  }
}

function buttonOpeningTags(source: string): string[] {
  return buttonRegions(source).map(({ tag }) => tag);
}

function attributeValue(tag: string, name: string): string | null {
  const marker = new RegExp(`\\b${name}\\s*=`).exec(tag);
  if (!marker) return null;
  let cursor = marker.index + marker[0].length;
  while (/\s/.test(tag[cursor] ?? "")) cursor += 1;
  const first = tag[cursor];
  if (first === '"' || first === "'") {
    const quote = first;
    let end = cursor + 1;
    while (end < tag.length) {
      if (tag[end] === quote && tag[end - 1] !== "\\") return tag.slice(cursor, end + 1);
      end += 1;
    }
    return tag.slice(cursor);
  }
  if (first !== "{") return tag.slice(cursor).split(/\s|>/, 1)[0] ?? "";

  let braceDepth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let end = cursor; end < tag.length; end += 1) {
    const character = tag[end]!;
    if (quote) {
      if (character === quote && tag[end - 1] !== "\\") quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth -= 1;
      if (braceDepth === 0) return tag.slice(cursor, end + 1);
    }
  }
  return tag.slice(cursor);
}

const INLINE_PAINT_PROPERTIES = new Set([
  "background",
  "backgroundColor",
  "backgroundImage",
  "border",
  "borderColor",
  "borderImage",
  "borderInline",
  "borderInlineColor",
  "borderBlock",
  "borderBlockColor",
  "color",
  "outline",
  "outlineColor",
]);

function matchingJsBrace(source: string, open: number): number {
  let depth = 1;
  let quote: "'" | '"' | "`" | null = null;
  for (let cursor = open + 1; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return cursor;
    }
  }
  return -1;
}

function splitTopLevel(source: string, delimiter: string): string[] {
  const parts: string[] = [];
  let start = 0;
  let braceDepth = 0;
  let bracketDepth = 0;
  let parenDepth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let cursor = 0; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth = Math.max(0, braceDepth - 1);
    } else if (character === "[") {
      bracketDepth += 1;
    } else if (character === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1);
    } else if (character === "(") {
      parenDepth += 1;
    } else if (character === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
    } else if (
      source.startsWith(delimiter, cursor) &&
      braceDepth === 0 &&
      bracketDepth === 0 &&
      parenDepth === 0
    ) {
      parts.push(source.slice(start, cursor));
      start = cursor + delimiter.length;
      cursor += delimiter.length - 1;
    }
  }
  parts.push(source.slice(start));
  return parts;
}

function topLevelIndex(source: string, needle: string): number {
  let braceDepth = 0;
  let bracketDepth = 0;
  let parenDepth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let cursor = 0; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth = Math.max(0, braceDepth - 1);
    } else if (character === "[") {
      bracketDepth += 1;
    } else if (character === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1);
    } else if (character === "(") {
      parenDepth += 1;
    } else if (character === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
    } else if (
      source.startsWith(needle, cursor) &&
      braceDepth === 0 &&
      bracketDepth === 0 &&
      parenDepth === 0
    ) {
      return cursor;
    }
  }
  return -1;
}

function unsafeStyleObject(body: string): boolean {
  for (const property of splitTopLevel(body, ",")) {
    const trimmed = property.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("...")) return true;
    const colon = topLevelIndex(trimmed, ":");
    const key = (colon < 0 ? trimmed : trimmed.slice(0, colon)).trim();
    if (key.startsWith("[") || key.startsWith("{")) return true;
    const normalizedKey = key.replace(/^(?:["'])(.*)(?:["'])$/, "$1");
    if (INLINE_PAINT_PROPERTIES.has(normalizedKey)) return true;
    // A shorthand property is an opaque value and may be a paint property.
    // Explicit assignments are inspectable and safe unless they name paint.
    if (colon < 0 && !normalizedKey.startsWith("--")) return true;
  }
  return false;
}

function unsafeStyleExpression(styleValue: string | null): boolean {
  if (!styleValue) return false;
  const source = styleValue.trim();
  if (!source.startsWith("{") || matchingJsBrace(source, 0) < 0) return true;
  const expressionEnd = matchingJsBrace(source, 0);
  if (expressionEnd !== source.length - 1) {
    // Object style casts (`{{ ... } as CSSProperties}`) are safe to inspect;
    // arbitrary suffixes and type assertions on unknown values are not.
    const suffix = source.slice(expressionEnd + 1).trim();
    if (!/^as\s+[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$/.test(suffix)) return true;
  }
  const expression = source.slice(1, expressionEnd).trim();
  const question = topLevelIndex(expression, "?");
  if (question >= 0) {
    const branches = splitTopLevel(expression.slice(question + 1), ":");
    if (branches.length !== 2) return true;
    return branches.some((branch) => unsafeStyleExpression(`{${branch.trim()}}`));
  }
  if (expression === "undefined" || expression === "null") return false;
  if (!expression.startsWith("{")) return true;
  const objectEnd = matchingJsBrace(expression, 0);
  if (objectEnd < 0) return true;
  const objectSuffix = expression.slice(objectEnd + 1).trim();
  if (
    objectSuffix &&
    !/^as\s+[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$/.test(objectSuffix)
  ) {
    return true;
  }
  return unsafeStyleObject(expression.slice(1, objectEnd));
}

/**
 * CSS scanners used by these invariants. A regular-expression brace match is
 * not sufficient here: a declaration can contain a quoted `}` or `/*`, and a
 * comment can contain a complete-looking rule. Keep all boundary discovery
 * outside comments and strings, then return source slices bounded by the
 * matching brace.
 */
interface CssRule {
  selector: string;
  body: string;
}

type CssQuote = "'" | '"' | "`" | null;

function isEscaped(source: string, index: number): boolean {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    slashes += 1;
  }
  return slashes % 2 === 1;
}

function skipCssComment(source: string, start: number, end: number): number {
  const close = source.indexOf("*/", start + 2);
  return close < 0 ? end : close + 2;
}

function stripCssComments(source: string): string {
  let output = "";
  let quote: CssQuote = null;
  let cursor = 0;
  while (cursor < source.length) {
    const character = source[cursor]!;
    if (quote) {
      output += character;
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      cursor += 1;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      output += " ";
      cursor = skipCssComment(source, cursor, source.length);
      continue;
    }
    if (character === "'" || character === '"' || character === "`") quote = character;
    output += character;
    cursor += 1;
  }
  return output;
}

function findCssOpen(source: string, start: number, end: number): number {
  let quote: CssQuote = null;
  for (let cursor = start; cursor < end; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      cursor = skipCssComment(source, cursor, end) - 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") return cursor;
  }
  return -1;
}

function findCssClose(source: string, open: number, end = source.length): number {
  let depth = 1;
  let quote: CssQuote = null;
  for (let cursor = open + 1; cursor < end; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      cursor = skipCssComment(source, cursor, end) - 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return cursor;
    }
  }
  return -1;
}

function findCssMarker(source: string, marker: string): number {
  let quote: CssQuote = null;
  for (let cursor = 0; cursor < source.length; cursor += 1) {
    const character = source[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(source, cursor)) quote = null;
      continue;
    }
    if (character === "/" && source[cursor + 1] === "*") {
      cursor = skipCssComment(source, cursor, source.length) - 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (source.startsWith(marker, cursor)) return cursor;
  }
  return -1;
}

function cssRules(source: string): CssRule[] {
  const rules: CssRule[] = [];

  function parseRange(start: number, end: number): void {
    let cursor = start;
    while (cursor < end) {
      const open = findCssOpen(source, cursor, end);
      if (open < 0) return;
      const close = findCssClose(source, open, end);
      if (close < 0) return;

      const selector = stripCssComments(source.slice(cursor, open)).trim();
      const body = source.slice(open + 1, close);
      if (selector && !selector.startsWith("@")) rules.push({ selector, body });
      parseRange(open + 1, close);
      cursor = close + 1;
    }
  }

  parseRange(0, source.length);
  return rules;
}

function cssRuleBody(rules: CssRule[], selector: string): string {
  const exact = rules.find((candidate) => candidate.selector.trim() === selector);
  const rule = exact ?? rules.find((candidate) =>
    candidate.selector.split(",").some((part) => part.trim() === selector),
  );
  if (!rule) throw new Error(`Missing CSS rule: ${selector}`);
  return rule.body;
}

/** Return the contents of the first balanced block after a CSS marker. */
function blockAfter(source: string, marker: string): string {
  const markerStart = findCssMarker(source, marker);
  if (markerStart < 0) throw new Error(`Missing CSS marker: ${marker}`);
  const open = marker.endsWith("{")
    ? markerStart + marker.length - 1
    : findCssOpen(source, markerStart + marker.length, source.length);
  if (open < 0) throw new Error(`Missing opening brace after: ${marker}`);
  const close = findCssClose(source, open);
  if (close < 0) throw new Error(`Unclosed CSS block after: ${marker}`);
  return source.slice(open + 1, close);
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
const parsedCssRules = cssRules(css);

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
  it("bounds CSS parsing around comments, strings, and neighboring rules", () => {
    const fixture = `
      /* } { .fake { } */
      .quoted::before { content: "} /* still a string */"; }
      /* { .also-fake { } */
      .next { color: red; }
    `;
    const rules = cssRules(fixture);
    expect(cssRuleBody(rules, ".quoted::before")).toContain("still a string");
    expect(cssRuleBody(rules, ".next")).toContain("color: red");
    expect(blockAfter(fixture, ".quoted::before {")).toContain(
      'content: "} /* still a string */"',
    );
  });

  it("treats opaque style expressions and unsafe paint branches conservatively", () => {
    expect(unsafeStyleExpression("{{ background: \"var(--primary-action)\" }}")).toBe(true);
    expect(unsafeStyleExpression("{condition ? { flex: 1 } : { color: \"#fff\" }}")).toBe(true);
    expect(unsafeStyleExpression("{{ ...buttonStyle, flex: 1 }}")).toBe(true);
    expect(unsafeStyleExpression("{templateStyle as CSSProperties}")).toBe(true);
    expect(unsafeStyleExpression("{{ flex: 1 } as CSSProperties}")).toBe(false);
    expect(unsafeStyleExpression("{{ flex: 1 }}")).toBe(false);
  });

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

    const cssStates = [
      [".btn-primary", "--primary-action", "--primary-action-shade", "--primary-action-text"],
      [".btn-primary:hover:not(:disabled):not([aria-disabled=\"true\"])", "--primary-action-hover", "--primary-action-hover-shade", "--primary-action-text"],
      [".btn-primary:active:not(:disabled):not([aria-disabled=\"true\"])", "--primary-action-active", "--primary-action-active-shade", "--primary-action-text"],
      [".btn-primary:disabled", "--primary-action-disabled", "--primary-action-disabled-shade", "--primary-action-text"],
      [".btn-secondary", "--secondary-action-bg", "--secondary-action-bg-shade", "--secondary-action-text"],
      [".btn-secondary:hover:not(:disabled):not([aria-disabled=\"true\"])", "--secondary-action-bg-hover", "--secondary-action-bg-hover-shade", "--secondary-action-text-hover"],
      [".btn-secondary:active:not(:disabled):not([aria-disabled=\"true\"])", "--secondary-action-bg-active", "--secondary-action-bg-active-shade", "--secondary-action-text-active"],
      [".btn-secondary:disabled", "--secondary-action-bg-disabled", "--secondary-action-bg-disabled-shade", "--secondary-action-text-disabled"],
      [".btn-danger", "--danger-action", "--danger-action-shade", "--danger-action-text"],
      [".btn-danger:hover:not(:disabled):not([aria-disabled=\"true\"])", "--danger-action-hover", "--danger-action-hover-shade", "--danger-action-text"],
      [".btn-danger:active:not(:disabled):not([aria-disabled=\"true\"])", "--danger-action-active", "--danger-action-active-shade", "--danger-action-text"],
      [".btn-danger:disabled", "--danger-action-disabled", "--danger-action-disabled-shade", "--danger-action-text"],
    ] as const;
    for (const [selector, startToken, endToken, textToken] of cssStates) {
      const body = cssRuleBody(parsedCssRules, selector.trim());
      expect(body, `${selector} background`).toContain(
        `background-image: linear-gradient(135deg, var(${startToken}), var(${endToken}))`,
      );
      expect(body, `${selector} text`).toContain(`color: var(${textToken})`);
    }
    for (const className of ["btn-primary", "btn-secondary", "btn-danger"]) {
      expect(cssRuleBody(parsedCssRules, `.${className}:disabled`)).toContain("opacity: 1;");
      expect(cssRuleBody(parsedCssRules, `.${className}:focus-visible`)).toContain(
        "outline: 2px solid var(--focus-ring);",
      );
    }
    expect(css).toContain(".btn-secondary.btn-inline");
    expect(css).toContain(".btn-danger.btn-inline");
    expect(component("PhoneWorkoutCard.tsx")).not.toContain("style={blockedReason ? { opacity: 0.5 }");
    expect(component("RoutineCard.tsx")).not.toContain("flex: 1, opacity: 0.5");
  });

  it("keeps every semantic button consumer on the shared recipe", () => {
    const consumers = componentSources().flatMap(([file, source]) =>
      buttonOpeningTags(source).map((tag) => ({
        file,
        tag,
        classValue: attributeValue(tag, "className") ?? "",
        styleValue: attributeValue(tag, "style"),
      })),
    );
    const semanticConsumers = consumers.filter(({ classValue }) =>
      /\bbtn-(?:primary|secondary|danger)\b/.test(classValue),
    );

    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-primary"))).toBe(true);
    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-secondary"))).toBe(true);
    expect(semanticConsumers.some(({ tag }) => tag.includes("btn-danger"))).toBe(true);

    for (const { file, tag, styleValue } of semanticConsumers) {
      expect(
        tag,
        `${file} overrides a shared semantic button with an inline paint property`,
      ).not.toMatch(/\b(?:background(?:-image|-color)?|color|border(?:-color)?)\s*:/);
      expect(
        unsafeStyleExpression(styleValue),
        `${file} uses an unsafe or opaque style expression on a semantic button`,
      ).toBe(false);
    }

    for (const { file, classValue, styleValue } of consumers) {
      expect(
        unsafeStyleExpression(styleValue) && /\bbtn-(?:primary|secondary|danger)\b/.test(classValue),
        `${file} uses an unsafe inline button paint; use the shared recipe instead`,
      ).toBe(false);
    }
  });

  it("maps Force recovery meaning to the correct action hierarchy", () => {
    const source = component("ForceView.tsx");
    const recoveryStart = source.indexOf('className="card surface-caution"');
    const recoveryEnd = source.indexOf("/* Protocols:", recoveryStart);
    expect(recoveryStart).toBeGreaterThanOrEqual(0);
    expect(recoveryEnd).toBeGreaterThan(recoveryStart);

    const recoveryButtons = buttonRegions(source.slice(recoveryStart, recoveryEnd));
    const retry = recoveryButtons.find(({ element }) => element.includes("Retry"));
    const discard = recoveryButtons.find(({ element }) => element.includes("Discard"));
    expect(retry).toBeDefined();
    expect(discard).toBeDefined();
    expect(retry!.tag).toContain('className="btn-primary btn-inline"');
    expect(retry!.tag).toContain('aria-label={retryingUnqueued ? "Retrying unsaved recordings" : "Retry unsaved recordings"}');
    expect(discard!.tag).toContain('className="btn-danger btn-inline"');
    expect(discard!.tag).toContain('aria-label="Discard unsaved recordings"');
    expect(recoveryButtons.indexOf(retry!)).toBeLessThan(recoveryButtons.indexOf(discard!));
  });

  it("defines explicit forced-colors states for every semantic button recipe", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    for (const className of ["btn-primary", "btn-secondary", "btn-danger"]) {
      const normal = cssRuleBody(forcedRules, `.${className}`);
      expect(normal).toContain("background: ButtonFace;");
      expect(normal).toContain("background-image: none;");
      expect(normal).toContain("border-color: ButtonText;");
      expect(normal).toContain("color: ButtonText;");

      const hover = cssRuleBody(
        forcedRules,
        `.${className}:hover:not(:disabled):not([aria-disabled="true"])`,
      );
      expect(hover).toContain("background: Highlight;");
      expect(hover).toContain("color: HighlightText;");

      const active = cssRuleBody(
        forcedRules,
        `.${className}:active:not(:disabled):not([aria-disabled="true"])`,
      );
      expect(active).toContain("background: Highlight;");
      expect(active).toContain("color: HighlightText;");

      const disabled = cssRuleBody(forcedRules, `.${className}:disabled`);
      expect(disabled).toContain("background: ButtonFace;");
      expect(disabled).toContain("border-color: GrayText;");
      expect(disabled).toContain("color: GrayText;");
      expect(disabled).toContain("opacity: 1;");

      expect(cssRuleBody(forcedRules, `.${className}:focus-visible`)).toContain(
        "outline: 2px solid Highlight;",
      );
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
    const themeMetas = Array.from(
      indexHtml.matchAll(/<meta\s+name="theme-color"[^>]*>/g),
      ([match]) => match,
    );
    expect(themeMetas).toHaveLength(2);
    expect(themeMetas).toContain(
      '<meta name="theme-color" media="(prefers-color-scheme: light)" content="#F2F4F8" />',
    );
    expect(themeMetas).toContain(
      '<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0E121B" />',
    );

    expect(manifest.background_color).toBe("#F2F4F8");
    expect(manifest.theme_color).toBe("#F2F4F8");
    // `manifest: false` leaves the authoritative public manifest untouched;
    // Vite copies it verbatim to dist alongside the generated service worker.
    expect(viteConfig).toContain("VitePWA");
    expect(viteConfig).toMatch(/manifest:\s*false/);
    expect(packageScripts["verify:pwa"]).toBe("node scripts/verify-pwa-chrome.mjs");
    expect(packageScripts.build).toContain("npm run verify:pwa");
    expect(themeSource).toContain("syncThemeColorMeta");
    expect(mainSource).toContain("initializeTheme();");
    expect(component("ThemeSection.tsx")).not.toContain("querySelector('meta[name=\"theme-color\"]')");

    const pwaThemeColors = design.match(
      /`theme-color`\s*=\s*`([^`]+)`\s*light\s*\/\s*`([^`]+)`\s*dark/,
    );
    expect(pwaThemeColors?.[1]).toBe("#F2F4F8");
    expect(pwaThemeColors?.[2]).toBe("#0E121B");
  });
});

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import * as ts from "typescript";
import { describe, expect, it } from "vitest";

const SRC = join(import.meta.dirname, "..");
const css = readFileSync(join(SRC, "index.css"), "utf8");
const indexHtml = readFileSync(join(SRC, "..", "index.html"), "utf8");
const design = readFileSync(join(SRC, "..", "DESIGN.md"), "utf8");
const mainSource = readFileSync(join(SRC, "..", "src", "main.tsx"), "utf8");
const zoneSelectionSource = readFileSync(join(SRC, "lib", "zoneSelection.ts"), "utf8");
const chartPeriodStylesSource = readFileSync(join(SRC, "lib", "chartPeriodStyles.ts"), "utf8");
const manifestPath = join(SRC, "..", "public", "manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
  background_color?: string;
  theme_color?: string;
};
const viteConfig = readFileSync(join(SRC, "..", "vite.config.ts"), "utf8");
const themeSource = readFileSync(join(SRC, "lib", "theme.ts"), "utf8");
const constantsSource = readFileSync(join(SRC, "constants.ts"), "utf8");
const bootstrapSource = indexHtml.match(
  /<script\b[^>]*data-theme-bootstrap[^>]*>([\s\S]*?)<\/script>/i,
)?.[1] ?? "";
const packageScripts = (
  JSON.parse(readFileSync(join(SRC, "..", "package.json"), "utf8")) as {
    scripts?: Record<string, string>;
  }
).scripts ?? {};

function component(name: string): string {
  return readFileSync(join(SRC, "components", name), "utf8");
}

function componentSources(): Array<[string, string]> {
  const componentsRoot = join(SRC, "components");
  const files: string[] = [];
  const visit = (directory: string): void => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith(".tsx") && !entry.name.endsWith(".test.tsx")) files.push(path);
    }
  };
  visit(componentsRoot);
  files.sort();
  return [
    ["src/App.tsx", readFileSync(join(SRC, "App.tsx"), "utf8")],
    ...files.map((path) => [
      `src/components/${path.slice(componentsRoot.length + 1)}`,
      readFileSync(path, "utf8"),
    ] as [string, string]),
  ];
}

interface ButtonRegion {
  tag: string;
  element: string;
}

interface ButtonConsumer extends ButtonRegion {
  file: string;
  classValue: string;
  styleValue: string | null;
  astViolations?: string[];
}

/**
 * Fixture-only balanced extractor used by the recovery-order and legacy
 * negative fixtures below. The production consumer audit uses TypeScript's
 * JSX AST (`auditButtonSource`) so it cannot be fooled by nested braces.
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

/** Return JSX spread attributes at the opening-tag level, excluding spreads
 * nested inside a style object (which are inspected separately below). */
function spreadAttributes(tag: string): string[] {
  const spreads: string[] = [];
  let quote: "'" | '"' | "`" | null = null;
  let braceDepth = 0;
  for (let cursor = 0; cursor < tag.length; cursor += 1) {
    const character = tag[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(tag, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") {
      if (braceDepth === 0 && /^\{\s*\.\.\./.test(tag.slice(cursor))) {
        const end = matchingJsBrace(tag, cursor);
        spreads.push(tag.slice(cursor, end < 0 ? tag.length : end + 1));
        cursor = end < 0 ? tag.length : end;
        continue;
      }
      braceDepth += 1;
    } else if (character === "}") {
      braceDepth = Math.max(0, braceDepth - 1);
    }
  }
  return spreads;
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

/**
 * React's CSSProperties surface is an open-ended camel-case mapping. Keep the
 * paint audit conservative by classifying whole CSS property families instead
 * of hoping a finite list stays current as React/browser properties grow.
 */
const ADDITIONAL_PAINT_PROPERTIES = new Set([
  "all",
  "WebkitTextFillColor",
  "WebkitTextStroke",
  "WebkitTextStrokeColor",
  "WebkitTextStrokeWidth",
  "WebkitTapHighlightColor",
  "textShadow",
  "textDecorationColor",
  "textEmphasisColor",
  "fill",
  "stroke",
  "strokeWidth",
  "caretColor",
  "accentColor",
  "colorScheme",
  "filter",
  "mixBlendMode",
  "isolation",
  "clipPath",
  "mask",
  "maskImage",
  "maskColor",
  "maskBorder",
  "maskBorderSource",
]);

function isInlinePaintProperty(key: string): boolean {
  return (
    key === "color" ||
    key === "opacity" ||
    key === "boxShadow" ||
    key.startsWith("outline") ||
    key.startsWith("background") ||
    key.startsWith("border") ||
    ADDITIONAL_PAINT_PROPERTIES.has(key)
  );
}

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
    // The legacy string fallback has no class/recipe context, so keep it
    // conservative; the AST path permits only hue channels on a proven recipe.
    if (normalizedKey.startsWith("--")) return true;
    if (isInlinePaintProperty(normalizedKey)) return true;
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

interface AstClassAnalysis {
  tokens: Set<string>;
  guaranteedRecipe: boolean;
  opaque: boolean;
}

type LocalClassResolver = (name: string, reference?: ts.Identifier) => ts.Expression | undefined;

// Descendant paint is intentionally never accepted inline. Even an ink token
// can be wrong on a gradient/selected state; readable foregrounds belong to a
// named CSS recipe whose actual surface/state endpoints are tested below.
const READABLE_INK_VALUES = new Set<string>();

const CSS_STATE_PSEUDOS = new Set([
  "active",
  "disabled",
  "focus",
  "focus-visible",
  "hover",
]);
const CSS_STATE_MODIFIER_CLASSES = new Set([
  "active",
  "climbing",
  "danger",
  "ready",
  "resting",
  "selected",
]);

function cssSelectorList(selector: string): string[] {
  const branches: string[] = [];
  let start = 0;
  let parenDepth = 0;
  let bracketDepth = 0;
  let quote: CssQuote = null;
  for (let cursor = 0; cursor < selector.length; cursor += 1) {
    const character = selector[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(selector, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (character === "(") parenDepth += 1;
    else if (character === ")") parenDepth = Math.max(0, parenDepth - 1);
    else if (character === "[") bracketDepth += 1;
    else if (character === "]") bracketDepth = Math.max(0, bracketDepth - 1);
    else if (character === "," && parenDepth === 0 && bracketDepth === 0) {
      branches.push(selector.slice(start, cursor).trim());
      start = cursor + 1;
    }
  }
  branches.push(selector.slice(start).trim());
  return branches.filter(Boolean);
}

function cssSelectorCompounds(selector: string): string[] {
  const compounds: string[] = [];
  let start = 0;
  let parenDepth = 0;
  let bracketDepth = 0;
  let quote: CssQuote = null;
  const push = (end: number): void => {
    const compound = selector.slice(start, end).trim();
    if (compound) compounds.push(compound);
  };
  for (let cursor = 0; cursor < selector.length; cursor += 1) {
    const character = selector[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(selector, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (character === "(") parenDepth += 1;
    else if (character === ")") parenDepth = Math.max(0, parenDepth - 1);
    else if (character === "[") bracketDepth += 1;
    else if (character === "]") bracketDepth = Math.max(0, bracketDepth - 1);
    else if (
      parenDepth === 0 &&
      bracketDepth === 0 &&
      (character === ">" || character === "+" || character === "~" || /\s/.test(character))
    ) {
      push(cursor);
      start = cursor + 1;
    }
  }
  push(selector.length);
  return compounds;
}

function cssClassNames(compound: string, topLevelOnly: boolean): string[] {
  const names: string[] = [];
  let parenDepth = 0;
  let bracketDepth = 0;
  let quote: CssQuote = null;
  for (let cursor = 0; cursor < compound.length; cursor += 1) {
    const character = compound[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(compound, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (character === "(") parenDepth += 1;
    else if (character === ")") parenDepth = Math.max(0, parenDepth - 1);
    else if (character === "[") bracketDepth += 1;
    else if (character === "]") bracketDepth = Math.max(0, bracketDepth - 1);
    else if (
      character === "." &&
      (!topLevelOnly || (parenDepth === 0 && bracketDepth === 0))
    ) {
      const match = compound.slice(cursor + 1).match(/^[A-Za-z_][\w-]*/);
      if (match?.[0]) names.push(match[0]);
    }
  }
  return names;
}

function cssTargetCompoundForBranch(branch: string): string | undefined {
  return cssSelectorCompounds(branch).at(-1);
}

function cssPseudoFunctionBodies(compound: string): Array<{ name: string; body: string }> {
  const functions: Array<{ name: string; body: string }> = [];
  let quote: CssQuote = null;
  for (let cursor = 0; cursor < compound.length; cursor += 1) {
    const character = compound[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(compound, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (character !== ":") continue;
    const match = compound.slice(cursor + 1).match(/^([A-Za-z-]+)\(/);
    if (!match?.[1]) continue;
    const open = cursor + 1 + match[0].length - 1;
    let depth = 1;
    let nestedQuote: CssQuote = null;
    let close = open + 1;
    for (; close < compound.length; close += 1) {
      const nested = compound[close]!;
      if (nestedQuote) {
        if (nested === nestedQuote && !isEscaped(compound, close)) nestedQuote = null;
        continue;
      }
      if (nested === "'" || nested === '"') nestedQuote = nested;
      else if (nested === "(") depth += 1;
      else if (nested === ")") {
        depth -= 1;
        if (depth === 0) break;
      }
    }
    if (depth === 0) {
      functions.push({ name: match[1].toLowerCase(), body: compound.slice(open + 1, close) });
      cursor = close;
    }
  }
  return functions;
}

function cssTargetClassesInPseudo(compound: string): string[] {
  const classes = new Set<string>();
  for (const fn of cssPseudoFunctionBodies(compound)) {
    if (fn.name !== "is" && fn.name !== "where") continue;
    for (const branch of cssSelectorList(fn.body)) {
      const target = cssTargetCompoundForBranch(branch);
      if (!target) continue;
      // Preserve each pseudo alternative's required compound. A selector such
      // as `.compound.ready` is not a target for either individual class, so
      // it must not be flattened into two apparently independent targets.
      const targetClasses = cssClassNames(target, true);
      if (targetClasses.length === 1) classes.add(targetClasses[0]!);
    }
  }
  return [...classes];
}

function cssTargetClasses(compound: string): string[] {
  const direct = cssClassNames(compound, true);
  // A compound such as `.card.tappable` requires both classes. It may not
  // lend the recipe to either class when the other half is absent; grouped
  // direct targets are represented by separate selector branches instead.
  if (direct.length > 1) return [];
  return direct.length > 0 ? direct : cssTargetClassesInPseudo(compound);
}

function cssTargetClassesForState(compound: string): string[] {
  const direct = cssClassNames(compound, true);
  return direct.length > 0 ? direct : cssTargetClassesInPseudo(compound);
}

function cssTargetMatchesClass(compound: string, className: string): boolean {
  return cssTargetClasses(compound).includes(className);
}

function cssSelectorTargetsClass(selector: string, className: string): boolean {
  return cssSelectorList(selector).some((branch) => {
    const target = cssTargetCompoundForBranch(branch);
    return target ? cssTargetMatchesClass(target, className) : false;
  });
}

function cssSelectorDirectlyOwnsClass(selector: string, className: string): boolean {
  const branches = cssSelectorList(selector);
  if (branches.length !== 1) return false;
  const compounds = cssSelectorCompounds(branches[0]!);
  if (compounds.length !== 1) return false;
  const target = compounds[0]!;
  const classes = cssTargetClassesForState(target);
  return classes.length === 1 && classes[0] === className && cssTargetMatchesClass(target, className);
}

function cssAlternativeTargetClasses(compound: string): string[] | null {
  const direct = cssClassNames(compound, true);
  // A multi-class compound is one required target, not a union of class
  // alternatives. Returning null lets state attribution reject it too.
  if (direct.length > 1) return null;
  return direct.length > 0 ? direct : cssTargetClassesInPseudo(compound);
}

function cssDirectState(compound: string): boolean {
  let parenDepth = 0;
  let bracketDepth = 0;
  let quote: CssQuote = null;
  for (let cursor = 0; cursor < compound.length; cursor += 1) {
    const character = compound[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(compound, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (character === "(") {
      parenDepth += 1;
      continue;
    }
    if (character === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
      continue;
    }
    if (character === "[") {
      if (parenDepth === 0) {
        const close = compound.indexOf("]", cursor + 1);
        if (close >= 0 && /\b(?:data|aria)-[\w-]+\s*=/.test(compound.slice(cursor + 1, close))) {
          return true;
        }
      }
      bracketDepth += 1;
      continue;
    }
    if (character === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1);
      continue;
    }
    if (parenDepth !== 0 || bracketDepth !== 0) continue;
    if (character === ":") {
      const match = compound.slice(cursor + 1).match(/^([A-Za-z-]+)/);
      if (match?.[1] && CSS_STATE_PSEUDOS.has(match[1].toLowerCase())) return true;
    } else if (character === ".") {
      const match = compound.slice(cursor + 1).match(/^([A-Za-z_][\w-]*)/);
      if (match?.[1] && CSS_STATE_MODIFIER_CLASSES.has(match[1].toLowerCase())) return true;
    }
  }
  return false;
}

function cssStateAlternativeForTarget(
  alternative: string,
  className: string,
  outerTargetPresent: boolean,
): boolean {
  const compounds = cssSelectorCompounds(alternative);
  if (compounds.length !== 1) return false;
  const target = compounds[0]!;
  const classes = cssAlternativeTargetClasses(target);
  if (classes === null) return false;
  if (classes.length > 0 && !classes.includes(className)) return false;
  if (outerTargetPresent && classes.some((name) => name !== className)) return false;
  return cssTargetStateForCompound(target, className);
}

function cssStatePseudoFunctionForTarget(
  fn: { name: string; body: string },
  className: string,
  outerTargetPresent: boolean,
): boolean {
  // Exclusion and relational pseudo-functions describe predicates/descendants,
  // never the state of the target button itself.
  if (fn.name !== "is" && fn.name !== "where") return false;
  const alternatives = cssSelectorList(fn.body);
  if (alternatives.length === 0) return false;
  const candidates = outerTargetPresent
    ? alternatives
    : alternatives.filter((alternative) => {
        const target = cssTargetCompoundForBranch(alternative);
        if (!target) return false;
        const classes = cssAlternativeTargetClasses(target);
        if (classes === null) return false;
        return classes.length === 0 || classes.includes(className);
      });
  return candidates.length > 0 && candidates.every((alternative) =>
    cssStateAlternativeForTarget(alternative, className, outerTargetPresent),
  );
}

function cssTargetStateForCompound(compound: string, className: string): boolean {
  if (cssDirectState(compound)) return true;
  const outerTargetPresent = cssClassNames(compound, true).length > 0;
  return cssPseudoFunctionBodies(compound).some((fn) =>
    cssStatePseudoFunctionForTarget(fn, className, outerTargetPresent),
  );
}

function cssSelectorStateForClass(selector: string, className: string): boolean {
  return cssSelectorList(selector).some((branch) => {
    const target = cssTargetCompoundForBranch(branch);
    return Boolean(
      target &&
      cssTargetMatchesClass(target, className) &&
      cssTargetStateForCompound(target, className),
    );
  });
}

function cssButtonRecipeClasses(rules: CssRule[] = parsedCssRules): Set<string> {
  const recipes = new Map<string, { paint: boolean; cursor: boolean; state: boolean }>();
  const paintPattern = /\b(?:background|background-image|background-color|border|border-color|border-image|color|opacity|box-shadow|outline|outline-color)\s*:/;
  for (const rule of rules) {
    const paint = paintPattern.test(rule.body);
    const cursor = /\bcursor\s*:\s*(?:pointer|default)\b/.test(rule.body);
    for (const match of rule.selector.matchAll(/\.([A-Za-z_][\w-]*)/g)) {
      if (!match[1]) continue;
      const className = match[1];
      const recipe = recipes.get(className) ?? { paint: false, cursor: false, state: false };
      if (!cssSelectorTargetsClass(rule.selector, className)) {
        recipes.set(className, recipe);
        continue;
      }
      const state = cssSelectorStateForClass(rule.selector, className);
      if (paint) recipe.paint = true;
      if (!state && cursor) recipe.cursor = true;
      if (state && rule.body.trim()) recipe.state = true;
      recipes.set(className, recipe);
    }
  }
  return new Set(
    [...recipes]
      .filter(([, recipe]) => recipe.paint && recipe.cursor && recipe.state)
      .map(([className]) => className),
  );
}

function unwrapTsExpression(expression: ts.Expression): ts.Expression {
  let current = expression;
  while (
    ts.isParenthesizedExpression(current) ||
    ts.isAsExpression(current) ||
    ts.isTypeAssertionExpression(current) ||
    (ts.isSatisfiesExpression?.(current) ?? false)
  ) {
    if (ts.isParenthesizedExpression(current)) current = current.expression;
    else if (ts.isAsExpression(current)) current = current.expression;
    else if (ts.isTypeAssertionExpression(current)) current = current.expression;
    else current = (current as ts.SatisfiesExpression).expression;
  }
  return current;
}

function classTokens(text: string): Set<string> {
  return new Set(text.split(/\s+/).map((token) => token.trim()).filter(Boolean));
}

function mergeClassAnalyses(analyses: AstClassAnalysis[]): AstClassAnalysis {
  return {
    tokens: new Set(analyses.flatMap((analysis) => [...analysis.tokens])),
    guaranteedRecipe: analyses.some((analysis) => analysis.guaranteedRecipe),
    opaque: analyses.some((analysis) => analysis.opaque),
  };
}

function analyzeClassExpression(
  expression: ts.Expression | undefined,
  recipeClasses: Set<string>,
  resolveLocal?: LocalClassResolver,
  resolving = new Set<string>(),
): AstClassAnalysis {
  if (!expression) return { tokens: new Set(), guaranteedRecipe: false, opaque: true };
  const current = unwrapTsExpression(expression);
  if (ts.isStringLiteral(current) || ts.isNoSubstitutionTemplateLiteral(current)) {
    const tokens = classTokens(current.text);
    return {
      tokens,
      guaranteedRecipe: [...tokens].some((token) => recipeClasses.has(token)),
      opaque: false,
    };
  }
  if (ts.isTemplateExpression(current)) {
    const staticText = [current.head.text, ...current.templateSpans.map((span) => span.literal.text)].join(" ");
    const tokens = classTokens(staticText);
    const dynamic = current.templateSpans.map((span) =>
      analyzeClassExpression(span.expression, recipeClasses, resolveLocal, resolving),
    );
    return {
      tokens: new Set([...tokens, ...dynamic.flatMap((analysis) => [...analysis.tokens])]),
      guaranteedRecipe:
        [...tokens].some((token) => recipeClasses.has(token)) ||
        (dynamic.length > 0 && dynamic.every((analysis) => analysis.guaranteedRecipe)),
      opaque: true,
    };
  }
  if (ts.isConditionalExpression(current)) {
    const branches = [
      analyzeClassExpression(current.whenTrue, recipeClasses, resolveLocal, resolving),
      analyzeClassExpression(current.whenFalse, recipeClasses, resolveLocal, resolving),
    ];
    const merged = mergeClassAnalyses(branches);
    return { ...merged, guaranteedRecipe: branches.every((branch) => branch.guaranteedRecipe) };
  }
  if (ts.isBinaryExpression(current)) {
    const left = analyzeClassExpression(current.left, recipeClasses, resolveLocal, resolving);
    const right = analyzeClassExpression(current.right, recipeClasses, resolveLocal, resolving);
    const merged = mergeClassAnalyses([left, right]);
    if (current.operatorToken.kind === ts.SyntaxKind.PlusToken) {
      return { ...merged, guaranteedRecipe: left.guaranteedRecipe || right.guaranteedRecipe };
    }
    // `&&` can omit its class and `||` can select an uninspected fallback.
    return { ...merged, guaranteedRecipe: false, opaque: true };
  }
  if (ts.isCallExpression(current)) {
    const callee = current.expression.getText();
    if (["clsx", "classnames", "cx", "cn"].includes(callee)) {
      const args = current.arguments.map((argument) =>
        analyzeClassExpression(argument, recipeClasses, resolveLocal, resolving),
      );
      const merged = mergeClassAnalyses(args);
      return {
        ...merged,
        guaranteedRecipe: args.some((argument) => argument.guaranteedRecipe),
        opaque: args.some((argument) => argument.opaque),
      };
    }
    return { tokens: new Set(), guaranteedRecipe: false, opaque: true };
  }
  if (ts.isIdentifier(current) && resolveLocal && !resolving.has(current.text)) {
    const initializer = resolveLocal(current.text, current);
    if (initializer) {
      const nextResolving = new Set(resolving);
      nextResolving.add(current.text);
      return analyzeClassExpression(initializer, recipeClasses, resolveLocal, nextResolving);
    }
  }
  return { tokens: new Set(), guaranteedRecipe: false, opaque: true };
}

function jsxAttribute(
  opening: ts.JsxOpeningLikeElement,
  name: string,
): ts.JsxAttribute | undefined {
  return opening.attributes.properties.find(
    (property): property is ts.JsxAttribute =>
      ts.isJsxAttribute(property) && property.name.getText() === name,
  );
}

function jsxAttributeExpression(
  opening: ts.JsxOpeningLikeElement,
  name: string,
): ts.Expression | undefined {
  const attribute = jsxAttribute(opening, name);
  if (!attribute?.initializer) return undefined;
  if (ts.isStringLiteral(attribute.initializer)) return attribute.initializer;
  if (!ts.isJsxExpression(attribute.initializer)) return undefined;
  return attribute.initializer.expression;
}

function jsxOpeningElement(
  node: ts.JsxElement | ts.JsxSelfClosingElement,
): ts.JsxOpeningLikeElement {
  return ts.isJsxElement(node) ? node.openingElement : node;
}

function jsxElementName(opening: ts.JsxOpeningLikeElement): string {
  return opening.tagName.getText();
}

function styleValueIsReadableInk(expression: ts.Expression): boolean {
  const current = unwrapTsExpression(expression);
  if (ts.isStringLiteral(current) || ts.isNoSubstitutionTemplateLiteral(current)) {
    return READABLE_INK_VALUES.has(current.text.trim());
  }
  if (ts.isConditionalExpression(current)) {
    return styleValueIsReadableInk(current.whenTrue) && styleValueIsReadableInk(current.whenFalse);
  }
  return false;
}

function stylePaintViolations(
  expression: ts.Expression | undefined,
  sourceFile: ts.SourceFile,
  direct: boolean,
  allowCustomProperty?: (name: string) => boolean,
): string[] {
  if (!expression) return ["missing style expression"];
  const current = unwrapTsExpression(expression);
  if (current.kind === ts.SyntaxKind.NullKeyword || current.kind === ts.SyntaxKind.Identifier && current.getText() === "undefined") {
    return [];
  }
  if (ts.isConditionalExpression(current)) {
    return [
      ...stylePaintViolations(current.whenTrue, sourceFile, direct, allowCustomProperty),
      ...stylePaintViolations(current.whenFalse, sourceFile, direct, allowCustomProperty),
    ];
  }
  if (ts.isBinaryExpression(current)) {
    if (current.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
      return stylePaintViolations(current.right, sourceFile, direct, allowCustomProperty);
    }
    if (current.operatorToken.kind === ts.SyntaxKind.BarBarToken) {
      return [
        ...stylePaintViolations(current.left, sourceFile, direct, allowCustomProperty),
        ...stylePaintViolations(current.right, sourceFile, direct, allowCustomProperty),
      ];
    }
  }
  if (!ts.isObjectLiteralExpression(current)) {
    return [`opaque ${direct ? "button" : "descendant"} style expression`];
  }
  const violations: string[] = [];
  for (const property of current.properties) {
    if (ts.isSpreadAssignment(property) || ts.isShorthandPropertyAssignment(property)) {
      violations.push("opaque style spread or shorthand");
      continue;
    }
    if (!ts.isPropertyAssignment(property)) {
      violations.push("opaque computed style property");
      continue;
    }
    const key = property.name.getText(sourceFile).replace(/^(?:['"])(.*)(?:['"])$/, "$1");
    if (ts.isComputedPropertyName(property.name) || key.startsWith("[")) {
      violations.push(`unsafe style property ${key}`);
      continue;
    }
    if (key.startsWith("--")) {
      if (direct && allowCustomProperty?.(key)) continue;
      violations.push(`unsafe ${direct ? "button" : "descendant"} custom property ${key}`);
      continue;
    }
    if (isInlinePaintProperty(key)) {
      if (!direct && key === "color" && styleValueIsReadableInk(property.initializer)) continue;
      violations.push(`unsafe ${direct ? "button" : "descendant"} style property ${key}`);
    }
  }
  return violations;
}

function descendantJsxPaintViolations(
  root: ts.JsxElement | ts.JsxSelfClosingElement,
  sourceFile: ts.SourceFile,
): string[] {
  const violations: string[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isJsxFragment(node)) {
      node.children.forEach(visit);
      return;
    }
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      const opening = jsxOpeningElement(node);
      const style = jsxAttributeExpression(opening, "style");
      if (style) violations.push(...stylePaintViolations(style, sourceFile, false));
      if (opening.attributes.properties.some((property) => ts.isJsxSpreadAttribute(property))) {
        violations.push("opaque descendant JSX spread hides descendant paint");
      }
      if (ts.isJsxElement(node)) node.children.forEach(visit);
      return;
    }
    ts.forEachChild(node, visit);
  };
  if (ts.isJsxElement(root)) root.children.forEach(visit);
  return violations;
}

function isLexicalScope(node: ts.Node): boolean {
  return (
    ts.isSourceFile(node) ||
    ts.isBlock(node) ||
    ts.isModuleBlock(node) ||
    ts.isCaseBlock(node) ||
    ts.isForStatement(node) ||
    ts.isForInStatement(node) ||
    ts.isForOfStatement(node) ||
    ts.isCatchClause(node) ||
    ts.isFunctionLike(node)
  );
}

function nearestLexicalScope(node: ts.Node): ts.Node {
  let current: ts.Node | undefined = node;
  while (current && !isLexicalScope(current)) current = current.parent;
  return current ?? node.getSourceFile();
}

function buildLexicalBindings(sourceFile: ts.SourceFile): Map<ts.Node, Map<string, ts.Expression | null>> {
  const bindings = new Map<ts.Node, Map<string, ts.Expression | null>>();
  const addBinding = (scope: ts.Node, name: string, initializer: ts.Expression | null): void => {
    const scopeBindings = bindings.get(scope) ?? new Map<string, ts.Expression | null>();
    if (scopeBindings.has(name)) scopeBindings.set(name, null);
    else scopeBindings.set(name, initializer);
    bindings.set(scope, scopeBindings);
  };
  const bindingIdentifiers = (name: ts.BindingName): ts.Identifier[] => {
    if (ts.isIdentifier(name)) return [name];
    return name.elements.flatMap((element) => {
      if (ts.isOmittedExpression(element)) return [];
      return bindingIdentifiers(element.name);
    });
  };
  const visit = (node: ts.Node): void => {
    if (ts.isVariableDeclaration(node)) {
      const declarationList = node.parent;
      const isVar = ts.isVariableDeclarationList(declarationList) &&
        (declarationList.flags & ts.NodeFlags.Let) === 0 &&
        (declarationList.flags & ts.NodeFlags.Const) === 0;
      let scope = nearestLexicalScope(node);
      if (isVar) {
        while (scope && !ts.isFunctionLike(scope) && !ts.isSourceFile(scope)) {
          if (!scope.parent || scope === scope.parent) break;
          scope = nearestLexicalScope(scope.parent);
        }
      }
      const identifiers = bindingIdentifiers(node.name);
      for (const identifier of identifiers) {
        addBinding(scope, identifier.text, ts.isIdentifier(node.name) ? node.initializer ?? null : null);
      }
    } else if (ts.isParameter(node)) {
      for (const identifier of bindingIdentifiers(node.name)) {
        addBinding(nearestLexicalScope(node), identifier.text, null);
      }
    } else if ((ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node)) && node.name) {
      addBinding(nearestLexicalScope(node.parent), node.name.text, null);
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return bindings;
}

function resolveLexicalClass(
  bindings: Map<ts.Node, Map<string, ts.Expression | null>>,
  name: string,
  reference?: ts.Identifier,
): ts.Expression | undefined {
  let scope = nearestLexicalScope(reference ?? bindings.keys().next().value!);
  while (scope) {
    const scopeBindings = bindings.get(scope);
    if (scopeBindings?.has(name)) return scopeBindings.get(name) ?? undefined;
    if (!scope.parent || scope === scope.parent) break;
    scope = nearestLexicalScope(scope.parent);
  }
  return undefined;
}

function auditButtonSource(file: string, source: string): ButtonConsumer[] {
  const sourceFile = ts.createSourceFile(
    file,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  );
  const recipeClasses = cssButtonRecipeClasses();
  const lexicalBindings = buildLexicalBindings(sourceFile);
  const consumers: ButtonConsumer[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      const opening = jsxOpeningElement(node);
      if (jsxElementName(opening) === "button") {
        const line = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
        const classAttribute = jsxAttribute(opening, "className");
        const classExpression = jsxAttributeExpression(opening, "className");
        const classAnalysis = analyzeClassExpression(
          classExpression,
          recipeClasses,
          (name, reference) => resolveLexicalClass(lexicalBindings, name, reference),
        );
        const violations: string[] = [];
        if (!classAttribute) violations.push("button is missing a className recipe");
        if (!classAnalysis.guaranteedRecipe) {
          violations.push("button className does not guarantee a CSS recipe");
        }
        if (opening.attributes.properties.some((property) => ts.isJsxSpreadAttribute(property))) {
          violations.push("opaque JSX button spread hides button paint");
        }
        const style = jsxAttributeExpression(opening, "style");
        if (style) {
          const allowedCustomProperty = (name: string): boolean =>
            classAnalysis.guaranteedRecipe &&
            [...classAnalysis.tokens].some(
              (className) =>
                recipeClasses.has(className) && cssTargetPaintVariables(className).has(name),
            );
          violations.push(
            ...stylePaintViolations(style, sourceFile, true, allowedCustomProperty),
          );
        }
        violations.push(...descendantJsxPaintViolations(node, sourceFile));
        consumers.push({
          tag: opening.getText(sourceFile),
          element: node.getText(sourceFile),
          file,
          classValue: classExpression?.getText(sourceFile) ?? "",
          styleValue: jsxAttribute(opening, "style")?.initializer?.getText(sourceFile) ?? null,
          astViolations: violations.map((violation) => `${file}:${line}: ${violation}`),
        });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return consumers;
}

function buttonConsumers(): ButtonConsumer[] {
  return componentSources().flatMap(([file, source]) => auditButtonSource(file, source));
}

function buttonAuditViolations(consumer: ButtonConsumer): string[] {
  if (consumer.astViolations) return consumer.astViolations;
  const violations = spreadAttributes(consumer.tag).map(
    (spread) => `${consumer.file}: opaque JSX button spread ${spread}`,
  );
  if (
    consumer.styleValue &&
    unsafeStyleExpression(consumer.styleValue)
  ) {
    violations.push(
      `${consumer.file}: inline button paint bypasses the shared or named recipe`,
    );
  }
  return violations;
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

interface CssDeclaration {
  property: string;
  value: string;
}

/** Split declarations without letting quoted semicolons or nested functions
 * change the declaration boundary. CSS nesting is ignored until its own
 * parsed child rule; only top-level declarations can own a paint channel. */
function cssDeclarations(source: string): CssDeclaration[] {
  const body = stripCssComments(source);
  const result: CssDeclaration[] = [];
  let start = 0;
  let parenDepth = 0;
  let bracketDepth = 0;
  let braceDepth = 0;
  let quote: CssQuote = null;
  const parse = (end: number): void => {
    if (braceDepth !== 0) return;
    const statement = body.slice(start, end).trim();
    if (!statement) return;
    let colon = -1;
    let statementParen = 0;
    let statementBracket = 0;
    let statementQuote: CssQuote = null;
    for (let cursor = 0; cursor < statement.length; cursor += 1) {
      const character = statement[cursor]!;
      if (statementQuote) {
        if (character === statementQuote && !isEscaped(statement, cursor)) statementQuote = null;
        continue;
      }
      if (character === "'" || character === '"') statementQuote = character;
      else if (character === "(") statementParen += 1;
      else if (character === ")") statementParen = Math.max(0, statementParen - 1);
      else if (character === "[") statementBracket += 1;
      else if (character === "]") statementBracket = Math.max(0, statementBracket - 1);
      else if (character === ":" && statementParen === 0 && statementBracket === 0) {
        colon = cursor;
        break;
      }
    }
    if (colon < 0) return;
    const property = statement.slice(0, colon).trim();
    if (!/^(?:--[A-Za-z0-9_-]+|-?[A-Za-z][A-Za-z0-9_-]*)$/.test(property)) return;
    result.push({ property, value: statement.slice(colon + 1).trim() });
  };
  for (let cursor = 0; cursor < body.length; cursor += 1) {
    const character = body[cursor]!;
    if (quote) {
      if (character === quote && !isEscaped(body, cursor)) quote = null;
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (character === "(") parenDepth += 1;
    else if (character === ")") parenDepth = Math.max(0, parenDepth - 1);
    else if (character === "[") bracketDepth += 1;
    else if (character === "]") bracketDepth = Math.max(0, bracketDepth - 1);
    else if (character === "{") braceDepth += 1;
    else if (character === "}") braceDepth = Math.max(0, braceDepth - 1);
    else if (character === ";" && parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
      parse(cursor);
      start = cursor + 1;
    }
  }
  parse(body.length);
  return result;
}

function isCssPaintProperty(property: string): boolean {
  const normalized = property.toLowerCase();
  return (
    normalized === "color" ||
    normalized === "opacity" ||
    normalized === "box-shadow" ||
    normalized.startsWith("background") ||
    normalized.startsWith("border") ||
    normalized.startsWith("outline") ||
    [
      "accent-color",
      "caret-color",
      "fill",
      "filter",
      "isolation",
      "mask",
      "mask-border",
      "mask-border-source",
      "mask-color",
      "mask-image",
      "mix-blend-mode",
      "stroke",
      "stroke-width",
      "text-decoration-color",
      "text-emphasis-color",
      "text-shadow",
      "-webkit-text-fill-color",
      "-webkit-text-stroke",
      "-webkit-text-stroke-color",
      "-webkit-text-stroke-width",
    ].includes(normalized)
  );
}

/** Return custom channels used by paint declarations owned by a direct target
 * recipe. A variable's spelling alone is never enough: its exact use must be
 * in the target recipe's own paint declaration, not an ancestor/descendant or
 * grouped selector that could accidentally lend a channel. */
function cssTargetPaintVariables(
  className: string,
  rules: CssRule[] = parsedCssRules,
): Set<string> {
  const variables = new Set<string>();
  for (const rule of rules) {
    if (!cssSelectorDirectlyOwnsClass(rule.selector, className)) continue;
    for (const declaration of cssDeclarations(rule.body)) {
      if (!isCssPaintProperty(declaration.property)) continue;
      for (const match of declaration.value.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)/g)) {
        if (match[1]) variables.add(match[1]);
      }
    }
  }
  return variables;
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

function gradientEndpoints(value: string, background: RGB, name: string): RGB[] {
  const stops = Array.from(
    value.matchAll(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)/g),
    ([, red, green, blue, alpha]) => ({
      color: [Number(red), Number(green), Number(blue)] as RGB,
      alpha: alpha === undefined ? 1 : Number(alpha),
    }),
  );
  if (stops.length === 0) throw new Error(`${name} has no parseable color stops: ${value}`);
  return stops.map((stop) => mix(background, stop.color, stop.alpha));
}

type ThemeName = keyof typeof themeDeclarations;

function resolveThemeColor(value: string, theme: ThemeName, name: string): RGB {
  const variable = value.trim().match(/^var\(\s*(--[\w-]+)\s*\)$/)?.[1];
  if (variable) {
    const resolved = themeDeclarations[theme][variable];
    if (!resolved) throw new Error(`${name} references undefined ${variable}`);
    return resolveThemeColor(resolved, theme, `${name} ${variable}`);
  }
  return hexColor(value.trim(), `${name} in ${theme}`);
}

// A gradient token can itself be a bare var() alias to another gradient
// token (e.g. light --gradient-readiness: var(--gradient-neutral), #547) —
// resolve that indirection before handing the value to gradientEndpoints,
// which only parses literal rgba()/rgb() stops.
function resolveGradientDeclaration(value: string, theme: ThemeName, name: string): string {
  const variable = value.trim().match(/^var\(\s*(--[\w-]+)\s*\)$/)?.[1];
  if (!variable) return value;
  const resolved = themeDeclarations[theme][variable];
  if (!resolved) throw new Error(`${name} references undefined ${variable}`);
  return resolveGradientDeclaration(resolved, theme, `${name} ${variable}`);
}

function objectBlock(source: string, marker: string): string {
  const markerStart = source.indexOf(marker);
  if (markerStart < 0) throw new Error(`Missing object marker: ${marker}`);
  const open = source.indexOf("{", markerStart + marker.length);
  if (open < 0) throw new Error(`Missing object opening brace: ${marker}`);
  const close = matchingJsBrace(source, open);
  if (close < 0) throw new Error(`Unclosed object: ${marker}`);
  return source.slice(open + 1, close);
}

const qualityHueBlock = objectBlock(zoneSelectionSource, "export const QUALITY_COLORS");
const qualityHues = Array.from(
  qualityHueBlock.matchAll(/:\s*["']([^"']+)["']/g),
  ([, value]) => value ?? "",
).filter(Boolean);
const directBoxChipHues = Array.from(
  component("TargetZonesCard.tsx").matchAll(/\bcolor\s*=\s*["']([^"']+)["']/g),
  ([, value]) => value ?? "",
).filter(Boolean);
const actualBoxChipHues = [...new Set(["var(--info)", ...qualityHues, ...directBoxChipHues])];

const periodStyleBlock = objectBlock(chartPeriodStylesSource, "CURVE_PERIOD_STYLES");
const periodSemanticNames = Array.from(
  periodStyleBlock.matchAll(/color:\s*chartColor\("([^"]+)"\)/g),
  ([, value]) => value ?? "",
).filter(Boolean);
const actualPeriodHues = periodSemanticNames.map((name) =>
  `var(--chart-${name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)})`,
);

describe("premium visual language contracts (#517)", () => {
  it("keeps the Force phone hierarchy on shared premium surfaces", () => {
    const forceView = component("ForceView.tsx");
    const picker = component("ForceProtocolPickerSheet.tsx");
    const progress = component("ForceProgressCard.tsx");
    const presets = component("PresetManager.tsx");
    expect(forceView).toContain("<SelectedProtocolCard");
    expect(forceView).toContain('className="btn-primary force-start-primary"');
    expect(forceView).not.toContain('aria-label="Protocol mode"');
    expect(picker).toContain('fullHeight className="force-protocol-sheet"');
    expect(picker).toContain("Suggested");
    expect(picker).toContain("My protocols");
    expect(progress).toContain('id="force-progress-title"');
    expect(progress).toContain('title="Static capacity"');
    expect(progress).toContain('title="Resisted movement"');
    const movementDetail = progress.slice(progress.indexOf('detail === "movement"'));
    expect(movementDetail).not.toContain("ForceCurveCard");
    expect(movementDetail).not.toContain("SideAsymmetryCard");
    expect(presets).toContain('className="preset-select-control"');
    expect(presets).toContain("aria-pressed={selected}");
    expect(css).toContain(".force-choose-protocol,\n.force-clear-protocol { width: 100%; min-height: 44px;");
    expect(css).toContain("grid-template-columns: repeat(auto-fit, minmax(6em, 1fr));");
    expect(css).toContain("grid-template-columns: repeat(auto-fit, minmax(8.5em, 1fr));");
    expect(css).toContain("grid-template-columns: repeat(auto-fit, minmax(10em, 1fr));");
    expect(css).not.toContain(".movement-insight-grid { grid-template-columns: repeat(3");
    expect(css).toContain(".force-start-primary,");
  });

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
    expect(READABLE_INK_VALUES.has("var(--ink-faint)"), "faint ink is never a blanket safe-list").toBe(false);
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

  it("keeps every hue-driven selected endpoint readable in both themes", () => {
    // These are resolved from the real callers instead of a sample palette:
    // QUALITY_COLORS covers warning/danger/info/success, BoxChip has explicit
    // primary/ink-muted callers, and CURVE_PERIOD_STYLES covers every chart toggle.
    expect(component("BoxChip.tsx")).toContain('color ?? "var(--info)"');
    expect(component("TargetZonesCard.tsx")).toContain("color={QUALITY_COLORS[q.id]}");
    expect(component("ForceCurveCard.tsx")).toContain("curvePeriodStyle");
    expect(chartPeriodStylesSource).toContain("CURVE_PERIOD_STYLES");
    expect(actualBoxChipHues).toEqual(
      expect.arrayContaining([
        "var(--info)",
        "var(--danger)",
        "var(--warning)",
        "var(--success)",
        "var(--primary)",
        "var(--ink-muted)",
      ]),
    );
    expect(actualPeriodHues).toHaveLength(6);

    const recipes = [
      {
        name: "box chip",
        selector: '.box-chip[data-active="true"]',
        hover: '.box-chip[data-active="true"]:hover:not(:disabled):not([data-disabled="true"])',
        hues: actualBoxChipHues,
        percentages: [0.18, 0.26],
      },
      {
        name: "period toggle",
        selector: '.period-toggle[data-active="true"]',
        hover: '.period-toggle[data-active="true"]:hover:not(:disabled)',
        hues: actualPeriodHues,
        percentages: [0.18, 0.26],
      },
      {
        name: "preset basis",
        selector: '.preset-basis-option[data-selected="true"]',
        hover: '.preset-basis-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "tolerance mode",
        selector: '.tolerance-mode-option[data-selected="true"]',
        hover: '.tolerance-mode-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "preset target mode",
        selector: '.preset-target-mode[data-selected="true"]',
        hover: '.preset-target-mode[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "recording tag/scope",
        selector: '.recording-tag-option[data-selected="true"]',
        hover: '.recording-tag-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.14, 0.24],
      },
      {
        name: "consistency tag",
        selector: '.consistency-tag-option[data-selected="true"]',
        hover: '.consistency-tag-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--info)"],
        percentages: [0.14, 0.24],
      },
      {
        name: "recording side",
        selector: '.recording-side-option[data-selected="true"]',
        hover: '.recording-side-option[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--warning)"],
        percentages: [0.14, 0.24],
      },
      {
        name: "recording selection",
        selector: '.recording-select-button[aria-pressed="true"]',
        hover: '.recording-select-button[aria-pressed="true"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.18, 0.26],
      },
      {
        name: "history filter",
        selector: '.filter-chip[aria-pressed="true"]',
        hover: '.filter-chip[aria-pressed="true"]:hover:not(:disabled)',
        hues: ["var(--primary)"],
        percentages: [0.16, 0.24],
      },
      {
        name: "rest target",
        selector: '.rest-target-button[data-selected="true"]',
        hover: '.rest-target-button[data-selected="true"]:hover:not(:disabled)',
        hues: ["var(--success)", "var(--danger)", "var(--primary)"],
        percentages: [0.2, 0.28],
      },
      {
        name: "zone focus",
        selector: ".zone-focus-button",
        hover: ".zone-focus-button:hover:not(:disabled)",
        hues: actualBoxChipHues,
        percentages: [0.12, 0.2, 0.24],
      },
      {
        name: "force action ready",
        selector: ".force-action-button.ready",
        hover: ".force-action-button:hover:not(:disabled)",
        hues: ["var(--success)"],
        percentages: [0.16, 0.24],
      },
      {
        name: "force action danger",
        selector: ".force-action-button.danger",
        hover: ".force-action-button.danger:hover:not(:disabled)",
        hues: ["var(--danger)"],
        percentages: [0.16, 0.24],
      },
    ] as const;

    const consumers = buttonConsumers();
    const extractedClasses = [
      "box-chip",
      "period-toggle",
      "preset-basis-option",
      "tolerance-mode-option",
      "preset-target-mode",
      "recording-tag-option",
      "recording-side-option",
      "recording-scope-option",
      "consistency-tag-option",
      "recording-select-button",
      "rest-target-button",
      "filter-chip",
      "zone-focus-button",
      "force-action-button",
    ];
    for (const className of extractedClasses) {
      expect(
        consumers.some(({ classValue }) => classValue.includes(className)),
        `no button consumer is wired to .${className}`,
      ).toBe(true);
      expect(css, `missing extracted button selector .${className}`).toMatch(
        new RegExp(`\\.${className}(?:[.:\\s,\\[{])`),
      );
    }

    for (const recipe of recipes) {
      const selectedBody = cssRuleBody(parsedCssRules, recipe.selector);
      const hoverBody = cssRuleBody(parsedCssRules, recipe.hover);
      expect(selectedBody, `${recipe.name} selected text`).toContain("color: var(--ink);");
      expect(selectedBody, `${recipe.name} selected text`).not.toMatch(/color:\s*#fff/i);
      expect(selectedBody, `${recipe.name} selected fill recipe`).toContain("background: color-mix");
      expect(hoverBody, `${recipe.name} hover text`).not.toMatch(/color:\s*#fff/i);

      for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
        const ink = resolveThemeColor("var(--ink)", theme, `${recipe.name} ink`);
        const surface = resolveThemeColor("var(--surface-1)", theme, `${recipe.name} surface`);
        for (const hue of recipe.hues) {
          const hueColor = resolveThemeColor(hue, theme, `${recipe.name} ${hue}`);
          for (const percentage of recipe.percentages) {
            expect(
              // CSS `color-mix(hue P%, surface)` weights the hue by P;
              // `mix` takes its interpolation amount from the first color.
              contrastRatio(ink, mix(surface, hueColor, percentage)),
              `${theme} ${recipe.name} ${hue} tint ${percentage}`,
            ).toBeGreaterThanOrEqual(4.5);
          }
        }
      }
    }
  });

  it("keeps every button consumer on a shared or named recipe", () => {
    const consumers = buttonConsumers();
    expect(consumers.length, "button audit must cover every component button").toBeGreaterThan(100);
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

    const violations = consumers.flatMap((consumer) =>
      buttonAuditViolations(consumer).map((violation) => `${violation}\n${consumer.tag}`),
    );
    expect(violations).toEqual([]);
  });

  it("uses the TypeScript AST for App and component button regressions", () => {
    const consumers = buttonConsumers();
    expect(consumers.some((consumer) => consumer.file === "src/App.tsx")).toBe(true);
    const phaseChooser = consumers.find(
      (consumer) => consumer.file === "src/App.tsx" && consumer.classValue.includes("phase-option"),
    );
    expect(phaseChooser).toBeDefined();
    expect(buttonAuditViolations(phaseChooser!)).toEqual([]);

    const fixture = auditButtonSource(
      "src/fixtures/button-audit.tsx",
      `
        const Example = ({ active, hue, buttonProps }: Props) => {
          const localClass = active ? "btn-primary" : "btn-secondary";
          return <>
            <button className={active ? "btn-primary" : "btn-secondary"}>
              <span style={{ color: hue }}>Unsafe descendant</span>
            </button>
            <button {...buttonProps}>Opaque props</button>
            <button className={getClassName()}>Unknown recipe</button>
            <button className={localClass}>Resolved local recipe</button>
          </>;
        };
      `,
    );
    expect(fixture).toHaveLength(4);
    expect(buttonAuditViolations(fixture[0]!)).toEqual([
      expect.stringContaining("unsafe descendant style property color"),
    ]);
    expect(buttonAuditViolations(fixture[1]!)).toEqual(
      expect.arrayContaining([
        expect.stringContaining("missing a className recipe"),
        expect.stringContaining("opaque JSX button spread"),
      ]),
    );
    expect(buttonAuditViolations(fixture[2]!)).toEqual([
      expect.stringContaining("does not guarantee a CSS recipe"),
    ]);
    expect(buttonAuditViolations(fixture[3]!)).toEqual([]);
  });

  it("audits every nested JSX shape and resolves class identifiers lexically", () => {
    const nested = auditButtonSource(
      "src/fixtures/nested-button-audit.tsx",
      `
        const moduleClass = "btn-primary";
        const SessionRowLike = ({ records, descendantProps, active }: Props) => {
          const moduleClass = active ? "btn-primary" : "btn-secondary";
          return <>
            <button className="session-recording-toggle">
              <>
                <span className="session-recording-meta">
                  {records.map((record) => <span style={{ color: record.color }}>{record.label}</span>)}
                  {active ? <em style={{ opacity: 0.8 }}>active</em> : <strong><i style={{ background: recordColor }}>idle</i></strong>}
                  <span {...descendantProps}>spread</span>
                  <span style={{ color: "var(--ink-faint)" }}>faint on tint</span>
                </span>
              </>
            </button>
            <button className="card">Unrelated surface class</button>
            <button className={moduleClass}>Lexically safe local class</button>
          </>;
        };
      `,
    );
    expect(nested).toHaveLength(3);
    expect(buttonAuditViolations(nested[0]!)).toEqual(
      expect.arrayContaining([
        expect.stringContaining("unsafe descendant style property color"),
        expect.stringContaining("unsafe descendant style property opacity"),
        expect.stringContaining("unsafe descendant style property background"),
        expect.stringContaining("opaque descendant JSX spread"),
        expect.stringContaining("unsafe descendant style property color"),
      ]),
    );
    expect(buttonAuditViolations(nested[1]!)).toEqual([
      expect.stringContaining("does not guarantee a CSS recipe"),
    ]);
    expect(buttonAuditViolations(nested[2]!)).toEqual([]);

    const shadowed = auditButtonSource(
      "src/fixtures/shadowed-button-audit.tsx",
      `
        const className = "btn-primary";
        const Safe = () => {
          const className = "card";
          return <button className={className}>Shadowed unrelated class</button>;
        };
      `,
    );
    expect(shadowed).toHaveLength(1);
    expect(buttonAuditViolations(shadowed[0]!)).toEqual([
      expect.stringContaining("does not guarantee a CSS recipe"),
    ]);

    const parameterShadow = auditButtonSource(
      "src/fixtures/parameter-shadow-button-audit.tsx",
      `
        const className = "btn-primary";
        const Safe = ({ className }: Props) => <button className={className}>Parameter is opaque</button>;
      `,
    );
    expect(parameterShadow).toHaveLength(1);
    expect(buttonAuditViolations(parameterShadow[0]!)).toEqual([
      expect.stringContaining("does not guarantee a CSS recipe"),
    ]);
  });

  it("attributes CSS recipes only to rightmost target compounds", () => {
    const fixtureRules = cssRules(`
      .fake .child, .group-other { background: var(--surface-1); cursor: pointer; }
      .fake:hover .child, .group-other:hover { color: var(--ink); }
      .fake + .sibling, .sibling + .neighbor { border: 1px solid var(--border); cursor: pointer; }
      .fake:active + .sibling, .sibling:hover + .neighbor { opacity: 1; }
      .direct, .grouped { background: var(--surface-1); cursor: pointer; }
      .direct:hover, .grouped[data-active="true"] { color: var(--ink); }
      :is(.pseudo, .pseudo-alt) { background: var(--surface-1); cursor: pointer; }
      :is(.pseudo:hover, .pseudo-alt[data-active="true"]) { color: var(--ink); }
      .mixed { background: var(--surface-1); cursor: pointer; }
      .mixed:is(.mixed, .other:hover) { color: var(--ink); }
      .where-mixed { background: var(--surface-1); cursor: pointer; }
      .where-mixed:where(.where-mixed:hover, .other:hover) { color: var(--ink); }
      .excluded-mixed { background: var(--surface-1); cursor: pointer; }
      .excluded-mixed:not(.other:hover) { color: var(--ink); }
      .relational-mixed { background: var(--surface-1); cursor: pointer; }
      .relational-mixed:has(.child:hover) { color: var(--ink); }
      .nested-mixed { background: var(--surface-1); cursor: pointer; }
      .nested-mixed:is(:is(:hover, :focus-visible), :active) { color: var(--ink); }
      .direct-mixed { background: var(--surface-1); cursor: pointer; }
      .direct-mixed:hover, .direct-mixed[data-active="true"] { color: var(--ink); }
      .function-mixed { background: var(--surface-1); cursor: pointer; }
      .function-mixed:is(:hover, :focus-visible) { color: var(--ink); }
      .where-direct { background: var(--surface-1); cursor: pointer; }
      .where-direct:where(:active, [aria-pressed="true"]) { color: var(--ink); }
      :is(.grouped-mixed:hover, .other:hover) { color: var(--ink); }
      .grouped-mixed { background: var(--surface-1); cursor: pointer; }
      :is(.compound.ready, .other.danger) { background: var(--surface-1); cursor: pointer; }
      :is(.compound.ready:hover, .other.danger:focus-visible) { color: var(--ink); }
      :where(.where-compound.selected, .where-other.active) { background: var(--surface-1); cursor: pointer; }
      :where(.where-compound.selected:hover, .where-other.active:focus-visible) { color: var(--ink); }
      :is(:where(.nested-compound.ready, .nested-other.active)) { background: var(--surface-1); cursor: pointer; }
      :is(:where(.nested-compound.ready:hover, .nested-other.active:hover)) { color: var(--ink); }
      .single-compound { background: var(--surface-1); cursor: pointer; }
      :is(.single-compound:hover, .single-compound:focus-visible) { color: var(--ink); }
      .single-where { background: var(--surface-1); cursor: pointer; }
      :where(.single-where:active, .single-where[data-active="true"]) { color: var(--ink); }
      :not(.negative) { background: var(--surface-1); cursor: pointer; }
      :not(.negative:hover) { color: var(--ink); }
    `);
    const recipes = cssButtonRecipeClasses(fixtureRules);

    expect(recipes.has("fake"), "ancestor cannot lend paint/state").toBe(false);
    expect(recipes.has("child"), "ancestor state cannot lend state to child").toBe(false);
    expect(recipes.has("sibling"), "ancestor state cannot lend state to sibling").toBe(false);
    expect(recipes.has("neighbor"), "sibling cannot lend paint to neighbor").toBe(false);
    expect(recipes.has("group-other"), "grouped direct target remains valid").toBe(true);
    expect(recipes.has("direct"), "direct target remains valid").toBe(true);
    expect(recipes.has("grouped"), "grouped direct target remains valid").toBe(true);
    expect(recipes.has("pseudo"), "pseudo-function direct target remains valid").toBe(true);
    expect(recipes.has("pseudo-alt"), "pseudo-function grouped target remains valid").toBe(true);
    expect(recipes.has("mixed"), ":is mixed alternatives cannot lend other state").toBe(false);
    expect(recipes.has("where-mixed"), ":where mixed alternatives cannot lend other state").toBe(false);
    expect(recipes.has("excluded-mixed"), ":not relational state cannot count").toBe(false);
    expect(recipes.has("relational-mixed"), ":has descendant state cannot count").toBe(false);
    expect(recipes.has("nested-mixed"), "nested direct state pseudo-functions remain valid").toBe(true);
    expect(recipes.has("direct-mixed"), "direct target state remains valid").toBe(true);
    expect(recipes.has("function-mixed"), "direct :is state alternatives remain valid").toBe(true);
    expect(recipes.has("where-direct"), "direct :where state alternatives remain valid").toBe(true);
    expect(recipes.has("grouped-mixed"), "matching grouped target alternative remains valid").toBe(true);
    for (const className of [
      "compound",
      "ready",
      "other",
      "danger",
      "where-compound",
      "selected",
      "where-other",
      "active",
      "nested-compound",
      "nested-other",
    ]) {
      expect(recipes.has(className), `${className} cannot be flattened from a required compound`).toBe(false);
    }
    expect(recipes.has("single-compound"), "single-class :is alternatives remain valid").toBe(true);
    expect(recipes.has("single-where"), "single-class :where alternatives remain valid").toBe(true);
    expect(recipes.has("negative"), "negated predicate cannot become a target recipe").toBe(false);
  });

  it("allows only exact custom channels consumed by the direct target recipe", () => {
    const fixtureRules = cssRules(`
      .safe { background: var(--direct-hue); cursor: pointer; }
      .safe:hover { border-color: var(--direct-hover); }
      .foreign { background: var(--foreign-hue); }
      .ancestor .safe { background: var(--ancestor-hue); }
      .safe .child { background: var(--descendant-hue); }
      .safe, .grouped { background: var(--grouped-hue); }
    `);
    expect([...cssTargetPaintVariables("safe", fixtureRules)]).toEqual([
      "--direct-hue",
      "--direct-hover",
    ]);
    expect(cssTargetPaintVariables("safe", fixtureRules)).not.toContain("--foreign-hue");
    expect(cssTargetPaintVariables("safe", fixtureRules)).not.toContain("--ancestor-hue");
    expect(cssTargetPaintVariables("safe", fixtureRules)).not.toContain("--descendant-hue");
    expect(cssTargetPaintVariables("safe", fixtureRules)).not.toContain("--grouped-hue");

    // These are the real dynamic channels, so their safety follows the actual
    // paint declaration rather than a spelling allowlist.
    expect(cssTargetPaintVariables("box-chip")).toContain("--box-chip-hue");
    expect(cssTargetPaintVariables("period-toggle")).toContain("--period-color");
    expect(cssTargetPaintVariables("workout-action-button")).toContain("--workout-accent");
    expect(cssTargetPaintVariables("zone-focus-button")).toContain("--zone-focus-color");

    const validBoxChip = auditButtonSource(
      "src/fixtures/box-chip-channel-button-audit.tsx",
      `<button className="box-chip" style={{ "--box-chip-hue": hue }}>Hue</button>`,
    );
    expect(buttonAuditViolations(validBoxChip[0]!)).toEqual([]);

    const validFullscreen = auditButtonSource(
      "src/fixtures/fullscreen-channel-button-audit.tsx",
      `<button className="workout-action-button" style={{ "--workout-accent": accent }}>Action</button>`,
    );
    expect(buttonAuditViolations(validFullscreen[0]!)).toEqual([]);

    for (const property of ["--background-color", "--workout-accent", "--foo-tint", "--period-color"]) {
      const unsafe = auditButtonSource(
        `src/fixtures/unrelated-${property.slice(2)}-channel-button-audit.tsx`,
        `<button className="box-chip" style={{ "${property}": hue }}>Unsafe</button>`,
      );
      expect(buttonAuditViolations(unsafe[0]!), property).toEqual([
        expect.stringContaining(`unsafe button custom property ${property}`),
      ]);
    }

    const unknownOnPrimary = auditButtonSource(
      "src/fixtures/unknown-primary-channel-button-audit.tsx",
      `<button className="btn-primary" style={{ "--box-chip-hue": hue }}>Wrong owner</button>`,
    );
    expect(buttonAuditViolations(unknownOnPrimary[0]!)).toEqual([
      expect.stringContaining("unsafe button custom property --box-chip-hue"),
    ]);
  });

  it("keeps active phase chooser text readable while retaining each phase hue", () => {
    const phaseSource = readFileSync(join(SRC, "App.tsx"), "utf8");
    expect(phaseSource).not.toContain("color: p.color");
    expect(phaseSource).not.toContain("background: active ? p.bg");
    expect(phaseSource).not.toContain("border: `1px solid ${active ? p.color");

    const phaseHues = ["#2E96F0", "#DDB13A", "#E5743A", "#7B83EB"];
    for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
      const ink = resolveThemeColor("var(--ink)", theme, "phase chooser ink");
      const surface = resolveThemeColor("var(--surface-1)", theme, "phase chooser surface");
      for (const hue of phaseHues) {
        const phase = hexColor(hue, `phase hue ${hue}`);
        for (const percentage of [0.12, 0.18]) {
          expect(
            contrastRatio(ink, mix(surface, phase, percentage)),
            `${theme} phase tint ${hue} ${percentage}`,
          ).toBeGreaterThanOrEqual(4.5);
        }
      }
    }

    expect(cssRuleBody(parsedCssRules, ".phase-option")).toContain("color: var(--ink);");
    for (const phase of ["capacity", "strength", "power", "execution"]) {
      const active = cssRuleBody(parsedCssRules, `.phase-option[data-active="true"][data-phase="${phase}"]`);
      expect(active).toContain("box-shadow:");
      expect(active).not.toMatch(/color:\s*#fff/i);
    }
  });

  // #557: PHASES[].color reads AA on dark (~8.4:1+) but fails AA as small
  // text on light mode's near-white surfaces (e.g. Strength #DDB13A on white
  // ~2.0:1). Every text consumer must use `Phase.textColor` — a
  // `var(--phase-text-<id>)` reference — instead of the raw identity `color`.
  it("keeps every phase identity's text variant AA-readable in light mode and hue-locked in dark", () => {
    const phases = [
      { id: "capacity", hue: "#2E96F0" },
      { id: "strength", hue: "#DDB13A" },
      { id: "power", hue: "#E5743A" },
      { id: "execution", hue: "#7B83EB" },
    ] as const;

    // constants.ts wires every phase to its CSS custom property, not a
    // hardcoded/raw hex and not the decorative `color` field.
    for (const phase of phases) {
      expect(constantsSource).toContain(
        `textColor: "var(--phase-text-${phase.id})"`,
      );
    }

    // Every known text consumer of the palette reads `textColor`, never the
    // decorative `color` (chart/chip/background/border uses keep `color`).
    const dashboardSource = component("Dashboard.tsx");
    const phasesViewSource = component("PhasesView.tsx");
    const sessionRowSource = component("SessionRow.tsx");
    expect(dashboardSource).toContain("color: phase.textColor,");
    expect(dashboardSource).not.toContain("color: phase.color,");
    expect(phasesViewSource).not.toMatch(/color:\s*p\.color[,\s]/);
    expect(sessionRowSource).toContain("color: ph?.textColor");
    expect(sessionRowSource).not.toContain("color: ph?.color");

    for (const phase of phases) {
      const identity = hexColor(phase.hue, `${phase.id} identity`);

      // Dark mode: the text token equals the decorative identity hue, which
      // already clears AA comfortably on the dark canvas.
      const darkVar = themeDeclarations.dark[`--phase-text-${phase.id}`];
      expect(darkVar, `dark --phase-text-${phase.id}`).toBe(phase.hue);
      const darkCanvas = resolveThemeColor("var(--canvas)", "dark", "dark canvas");
      expect(
        contrastRatio(identity, darkCanvas),
        `dark ${phase.id} identity on canvas`,
      ).toBeGreaterThanOrEqual(4.5);

      // Light mode: the text token must be a darkened variant (same hue,
      // lower value) that clears AA against every real background it lands
      // on — plain white/#F2F4F8 AND the ~12%-phase-tinted tag/card fill
      // (Phase.bg), which is the stricter, binding constraint.
      const lightVarValue = themeDeclarations.light[`--phase-text-${phase.id}`];
      expect(lightVarValue, `light --phase-text-${phase.id} declared`).toBeTruthy();
      const variant = hexColor(lightVarValue!, `light --phase-text-${phase.id}`);
      expect(variant, `${phase.id} variant differs from identity`).not.toEqual(identity);

      const white = hexColor("#FFFFFF", "white");
      const f2f4f8 = hexColor("#F2F4F8", "F2F4F8");
      const tagBg = mix(f2f4f8, identity, 0.12);
      expect(contrastRatio(variant, white), `${phase.id} vs #FFFFFF`).toBeGreaterThanOrEqual(4.5);
      expect(contrastRatio(variant, f2f4f8), `${phase.id} vs #F2F4F8`).toBeGreaterThanOrEqual(4.5);
      expect(
        contrastRatio(variant, tagBg),
        `${phase.id} vs 12%-tinted tag/card fill`,
      ).toBeGreaterThanOrEqual(4.5);

      // The hue itself must stay recognizable — same RGB ratios, just darker
      // (an HSV hue/saturation-preserving shade), not a different color.
      const [ir, ig, ib] = identity;
      const [vr, vg, vb] = variant;
      const maxIdentity = Math.max(ir, ig, ib);
      const maxVariant = Math.max(vr, vg, vb);
      expect(maxVariant, `${phase.id} variant is darker`).toBeLessThan(maxIdentity);
      for (const [i, v] of [[ir, vr], [ig, vg], [ib, vb]] as const) {
        // Same channel ratio (±1 for rounding) proves hue/saturation are
        // unchanged — only value (brightness) was scaled down.
        expect(
          Math.abs(i / maxIdentity - v / maxVariant),
          `${phase.id} channel ratio drift`,
        ).toBeLessThan(0.02);
      }
    }
  });

  it("keeps runtime zone and workout accents in decoration, not low-contrast text", () => {
    const zoneSource = component("ZoneFocusCard.tsx");
    const phoneSource = component("PhoneWorkoutFullscreen.tsx");
    expect(zoneSource).not.toContain("color: QUALITY_COLORS[rec.zone]");
    expect(phoneSource).not.toContain("color: accent");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-label")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-action")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-phase-label")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-phase-panel")).toContain(
      "color-mix(in srgb, var(--workout-accent, var(--primary)) 18%",
    );
    expect(phoneSource).toContain('className="phone-workout-phase-panel"');
    expect(cssRuleBody(parsedCssRules, ".workout-action-label")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".workout-action-button:hover:not(:disabled)")).toContain(
      "color-mix(in srgb, var(--workout-accent, var(--primary)) 12%",
    );
    expect(cssRuleBody(parsedCssRules, ".workout-action-button:focus-visible")).toContain(
      "outline: 2px solid var(--focus-ring);",
    );
    expect(cssRuleBody(parsedCssRules, ".zone-focus-button:active:not(:disabled)")).toContain(
      "color-mix(in srgb, var(--zone-focus-color, var(--info)) 24%",
    );
    expect(css).toContain(".zone-focus-button:disabled .zone-focus-label");

    const workoutHues = ["var(--success)", "var(--danger)", "var(--primary)"];
    for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
      const ink = resolveThemeColor("var(--ink)", theme, "workout accent ink");
      const canvas = resolveThemeColor("var(--canvas)", theme, "workout accent canvas");
      for (const hue of workoutHues) {
        const accent = resolveThemeColor(hue, theme, `workout ${hue}`);
        for (const percentage of [0.12, 0.18]) {
          expect(
            contrastRatio(ink, mix(canvas, accent, percentage)),
            `${theme} workout ${hue} tint ${percentage}`,
          ).toBeGreaterThanOrEqual(4.5);
        }
      }
    }
  });

  it("proves every supporting-text endpoint stays AA-readable in every theme/state", () => {
    const phaseHues = ["#2E96F0", "#DDB13A", "#E5743A", "#7B83EB"];
    const zoneHues = qualityHues;
    const workoutHues = ["var(--success)", "var(--danger)", "var(--primary)"];
    const minima: Record<string, number> = {};
    const check = (theme: ThemeName, state: string, foreground: RGB, background: RGB) => {
      const ratio = contrastRatio(foreground, background);
      minima[`${theme}/${state}`] = Math.min(minima[`${theme}/${state}`] ?? Infinity, ratio);
      expect(ratio, `${theme} ${state}`).toBeGreaterThanOrEqual(4.5);
    };

    for (const theme of Object.keys(themeDeclarations) as ThemeName[]) {
      const ink = resolveThemeColor("var(--ink)", theme, `${theme} supporting ink`);
      const muted = resolveThemeColor("var(--ink-muted)", theme, `${theme} disabled supporting ink`);
      const surface = resolveThemeColor("var(--surface-1)", theme, `${theme} supporting surface`);
      const canvas = resolveThemeColor("var(--canvas)", theme, `${theme} workout canvas`);

      for (const hue of phaseHues) {
        const phase = hexColor(hue, `${theme} phase hue ${hue}`);
        check(theme, `phase/${hue}/normal`, ink, mix(surface, phase, 0.12));
        check(theme, `phase/${hue}/hover`, ink, mix(surface, phase, 0.18));
        check(theme, `phase/${hue}/active`, ink, mix(surface, phase, 0.18));
        check(theme, `phase/${hue}/disabled`, muted, surface);
      }
      check(theme, "phase/inactive-hover", ink, mix(surface, resolveThemeColor("var(--primary)", theme, "phase hover"), 0.08));

      for (const hue of zoneHues) {
        const zone = resolveThemeColor(hue, theme, `${theme} zone hue ${hue}`);
        check(theme, `zone/${hue}/normal`, ink, mix(surface, zone, 0.12));
        check(theme, `zone/${hue}/hover`, ink, mix(surface, zone, 0.2));
        check(theme, `zone/${hue}/active`, ink, mix(surface, zone, 0.24));
        check(theme, `zone/${hue}/disabled`, muted, surface);
      }

      for (const hue of workoutHues) {
        const accent = resolveThemeColor(hue, theme, `${theme} fullscreen hue ${hue}`);
        check(theme, `fullscreen/${hue}/normal`, ink, mix(surface, accent, 0.18));
        check(theme, `fullscreen/${hue}/hover`, ink, mix(surface, accent, 0.18));
        check(theme, `fullscreen/${hue}/active`, ink, mix(surface, accent, 0.18));
      }

      // .phone-workout-resume renders --well-tint-interaction/-readiness, not
      // the analytical-card --gradient-interaction/-readiness tokens (#547
      // round 3 finding C) — check the tokens the component actually uses.
      for (const gradient of ["--well-tint-interaction", "--well-tint-readiness"] as const) {
        const gradientValue = resolveGradientDeclaration(
          themeDeclarations[theme][gradient]!,
          theme,
          `${theme} ${gradient}`,
        );
        for (const [index, endpoint] of gradientEndpoints(gradientValue, canvas, `${theme} ${gradient}`).entries()) {
          check(theme, `phone-card/${gradient}/${index}/normal`, ink, endpoint);
          check(theme, `phone-card/${gradient}/${index}/hover`, ink, endpoint);
          check(theme, `phone-card/${gradient}/${index}/active`, ink, endpoint);
        }
      }
      check(theme, "phone-card/disabled", muted, surface);
    }

    expect(cssRuleBody(parsedCssRules, ".phase-option-current")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phase-option-description")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phase-option:disabled .phase-option-description")).toContain("color: var(--ink-muted);");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-kicker")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-reason")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".zone-focus-button:disabled .zone-focus-reason")).toContain("color: var(--ink-muted);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-metadata")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-metadata-count")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-resume-meta")).toContain("color: var(--ink);");
    expect(cssRuleBody(parsedCssRules, ".phone-workout-resume:disabled .phone-workout-resume-meta")).toContain("color: var(--ink-muted);");
    expect(Object.values(minima).every((ratio) => ratio >= 4.5)).toBe(true);
  });

  it("keeps BoxChip wrappers and inner buttons equal-width and tappable", () => {
    expect(component("TagSideEditor.tsx")).toMatch(/style=\{\{\s*flex:\s*1,\s*minWidth:\s*0\s*\}\}/);
    const host = cssRuleBody(parsedCssRules, ".box-chip-host");
    const inner = cssRuleBody(parsedCssRules, ".box-chip-host > .box-chip");
    expect(host).toContain("display: inline-flex;");
    expect(inner).toContain("width: 100%;");
    expect(inner).toContain("min-width: 0;");
    expect(inner).toContain("min-height: 44px;");
  });

  it("keeps System theme-color media fallbacks intact before matchMedia exists", () => {
    expect(bootstrapSource).toMatch(/choice\s*===\s*["']system["']/);
    expect(bootstrapSource).toMatch(/typeof\s+media\?\.matches\s*===\s*["']boolean["']/);
    expect(bootstrapSource).toMatch(/choice\s*!==\s*["']system["']\s*\|\|\s*systemPrefersDark\s*!==\s*null/);
    expect(indexHtml).toContain('media="(prefers-color-scheme: light)"');
    expect(indexHtml).toContain('media="(prefers-color-scheme: dark)"');
  });

  it("rejects raw paint and opaque prop-spread fixtures without class gating", () => {
    const rawDangerTag = buttonRegions(
      '<button style={{ background: "var(--danger)", color: "#fff" }}>Delete</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...rawDangerTag,
        file: "raw-danger.fixture.tsx",
        classValue: attributeValue(rawDangerTag.tag, "className") ?? "",
        styleValue: attributeValue(rawDangerTag.tag, "style"),
      }),
    ).toEqual([expect.stringContaining("inline button paint")]);

    const hardcodedTag = buttonRegions(
      '<button className={condition ? "btn-ghost" : "header-btn"} style={{ backgroundColor: "#ffffff", color: "#101828" }}>Raw</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...hardcodedTag,
        file: "hardcoded-paint.fixture.tsx",
        classValue: attributeValue(hardcodedTag.tag, "className") ?? "",
        styleValue: attributeValue(hardcodedTag.tag, "style"),
      }),
    ).toEqual([expect.stringContaining("inline button paint")]);

    const spreadTag = buttonRegions(
      '<button {...buttonProps}>Delete</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...spreadTag,
        file: "opaque-props.fixture.tsx",
        classValue: "",
        styleValue: null,
      }),
    ).toEqual([expect.stringContaining("opaque JSX button spread")]);

    const conditionalTag = buttonRegions(
      '<button className={danger ? "btn-danger" : "btn-ghost"} style={{ backgroundColor: "var(--surface-2)" }}>Delete</button>',
    )[0]!;
    expect(
      buttonAuditViolations({
        ...conditionalTag,
        file: "conditional-danger.fixture.tsx",
        classValue: attributeValue(conditionalTag.tag, "className") ?? "",
        styleValue: attributeValue(conditionalTag.tag, "style"),
      }),
    ).toEqual([expect.stringContaining("inline button paint")]);

    // Keep this adversarial matrix independent from the implementation's
    // classifier: new React style properties must fail even if the classifier
    // accidentally forgets a family member.
    for (const property of [
      "background",
      "backgroundColor",
      "backgroundImage",
      "backgroundClip",
      "backgroundBlendMode",
      "backgroundOrigin",
      "backgroundPosition",
      "backgroundSize",
      "color",
      "border",
      "borderColor",
      "borderImage",
      "borderTop",
      "borderBottomColor",
      "borderInlineStart",
      "borderBlockEnd",
      "borderInline",
      "borderInlineColor",
      "borderBlock",
      "borderBlockColor",
      "borderRadius",
      "opacity",
      "boxShadow",
      "all",
      "WebkitTextFillColor",
      "outline",
      "outlineColor",
      "textShadow",
      "textDecorationColor",
      "fill",
      "stroke",
      "caretColor",
      "accentColor",
      "colorScheme",
    ]) {
      expect(
        unsafeStyleExpression(`{{ ${property}: "var(--danger)" }}`),
        property,
      ).toBe(true);
    }
    expect(unsafeStyleExpression("{{ '--box-chip-hue': 'var(--warning)' }}")).toBe(true);
    expect(unsafeStyleExpression("{{ '--paint-variable': 'var(--danger)' }}")).toBe(true);
    expect(unsafeStyleExpression("{{ '--danger-fill': '#fff' }}")).toBe(true);
    expect(unsafeStyleExpression("{{ flex: 1, marginTop: 8 }}")).toBe(false);

    const hueChannel = auditButtonSource(
      "src/fixtures/hue-channel-button-audit.tsx",
      `<button className="box-chip" style={{ "--box-chip-hue": hue }}>Hue channel</button>`,
    );
    expect(hueChannel).toHaveLength(1);
    expect(buttonAuditViolations(hueChannel[0]!)).toEqual([]);

    const opaqueChannel = auditButtonSource(
      "src/fixtures/opaque-channel-button-audit.tsx",
      `<button className="box-chip" style={{ "--paint-variable": hue }}>Opaque channel</button>`,
    );
    expect(opaqueChannel).toHaveLength(1);
    expect(buttonAuditViolations(opaqueChannel[0]!)).toEqual([
      expect.stringContaining("unsafe button custom property --paint-variable"),
    ]);
  });

  it("maps Force recovery meaning to the correct action hierarchy", () => {
    const source = component("ForceView.tsx");
    const recoveryStart = source.indexOf('className="card surface-caution"');
    const recoveryEnd = source.indexOf("<SelectedProtocolCard", recoveryStart);
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

  it("defines forced-colors states for extracted selected controls", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    const controls = [
      [
        "box chip",
        ".box-chip",
        '.box-chip[data-active="true"]',
        '.box-chip:disabled',
        '.box-chip:focus-visible',
        '.box-chip:hover:not(:disabled):not([data-disabled="true"])',
      ],
      [
        "period toggle",
        ".period-toggle",
        '.period-toggle[data-active="true"]',
        '.period-toggle[data-available="false"]',
        '.period-toggle:focus-visible',
        '.period-toggle:hover:not(:disabled)',
      ],
      [
        "preset basis",
        ".preset-basis-option",
        '.preset-basis-option[data-selected="true"]',
        ".preset-basis-option:disabled",
        ".preset-basis-option:focus-visible",
        ".preset-basis-option:hover:not(:disabled)",
      ],
      [
        "tolerance mode",
        ".tolerance-mode-option",
        '.tolerance-mode-option[data-selected="true"]',
        ".tolerance-mode-option:disabled",
        ".tolerance-mode-option:focus-visible",
        ".tolerance-mode-option:hover:not(:disabled)",
      ],
      [
        "preset target",
        ".preset-target-mode",
        '.preset-target-mode[data-selected="true"]',
        ".preset-target-mode:disabled",
        ".preset-target-mode:focus-visible",
        ".preset-target-mode:hover:not(:disabled)",
      ],
      [
        "recording tag",
        ".recording-tag-option",
        '.recording-tag-option[data-selected="true"]',
        ".recording-tag-option:disabled",
        ".recording-tag-option:focus-visible",
        ".recording-tag-option:hover:not(:disabled)",
      ],
      [
        "recording side",
        ".recording-side-option",
        '.recording-side-option[data-selected="true"]',
        ".recording-side-option:disabled",
        ".recording-side-option:focus-visible",
        ".recording-side-option:hover:not(:disabled)",
      ],
      [
        "recording scope",
        ".recording-scope-option",
        '.recording-scope-option[data-selected="true"]',
        ".recording-scope-option:disabled",
        ".recording-scope-option:focus-visible",
        ".recording-scope-option:hover:not(:disabled)",
      ],
      [
        "consistency tag",
        ".consistency-tag-option",
        '.consistency-tag-option[data-selected="true"]',
        ".consistency-tag-option:disabled",
        ".consistency-tag-option:focus-visible",
        ".consistency-tag-option:hover:not(:disabled)",
      ],
      [
        "recording selection",
        ".recording-select-button",
        '.recording-select-button[aria-pressed="true"]',
        ".recording-select-button:disabled",
        ".recording-select-button:focus-visible",
        ".recording-select-button:hover:not(:disabled)",
      ],
      [
        "rest target",
        ".rest-target-button",
        '.rest-target-button[data-selected="true"]',
        ".rest-target-button:disabled",
        ".rest-target-button:focus-visible",
        ".rest-target-button:hover:not(:disabled)",
      ],
      [
        "filter chip",
        ".filter-chip",
        '.filter-chip[aria-pressed="true"]',
        ".filter-chip:disabled",
        ".filter-chip:focus-visible",
        ".filter-chip:hover:not(:disabled)",
      ],
      [
        "phase chooser",
        ".phase-option",
        '.phase-option[data-active="true"]',
        ".phase-option:disabled",
        ".phase-option:focus-visible",
        ".phase-option:hover:not(:disabled)",
      ],
    ] as const;

    for (const [name, normalSelector, selectedSelector, disabledSelector, focusSelector, hoverSelector] of controls) {
      const normal = cssRuleBody(forcedRules, normalSelector);
      expect(normal, `${name} normal background`).toContain("background: ButtonFace;");
      expect(normal, `${name} normal background image`).toContain("background-image: none;");
      expect(normal, `${name} normal text`).toContain("color: ButtonText;");

      const selected = cssRuleBody(forcedRules, selectedSelector);
      expect(selected, `${name} selected background`).toContain("background: Highlight;");
      expect(selected, `${name} selected border`).toContain("border-color: Highlight;");
      expect(selected, `${name} selected text`).toContain("color: HighlightText;");

      const disabled = cssRuleBody(forcedRules, disabledSelector);
      expect(disabled, `${name} disabled background`).toContain("background: ButtonFace;");
      expect(disabled, `${name} disabled border`).toContain("border-color: GrayText;");
      expect(disabled, `${name} disabled text`).toContain("color: GrayText;");
      expect(disabled, `${name} disabled opacity`).toContain("opacity: 1;");

      expect(cssRuleBody(forcedRules, focusSelector), `${name} focus`).toContain(
        "outline: 2px solid Highlight;",
      );
      const hover = cssRuleBody(forcedRules, hoverSelector);
      expect(hover, `${name} hover background`).toContain("background: Highlight;");
      expect(hover, `${name} hover text`).toContain("color: HighlightText;");
    }
  });

  it("keeps the zone focus control readable in forced colors, including descendants", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    const normal = cssRuleBody(forcedRules, ".zone-focus-button");
    expect(normal).toContain("background: ButtonFace;");
    expect(normal).toContain("border-color: ButtonText;");
    expect(normal).toContain("color: ButtonText;");
    const hover = cssRuleBody(forcedRules, ".zone-focus-button:hover:not(:disabled)");
    expect(hover).toContain("background: Highlight;");
    expect(hover).toContain("color: HighlightText;");
    const disabled = cssRuleBody(forcedRules, ".zone-focus-button:disabled");
    expect(disabled).toContain("border-color: GrayText;");
    expect(disabled).toContain("color: GrayText;");
    expect(cssRuleBody(forcedRules, ".zone-focus-button:focus-visible")).toContain(
      "outline: 2px solid Highlight;",
    );
    expect(css).toContain(".zone-focus-button:hover:not(:disabled) .zone-focus-label");
    expect(css).toContain(".zone-focus-button:active:not(:disabled) .zone-focus-action");
    expect(css).toContain(".workout-action-button:active:not(:disabled) .workout-action-label");
  });

  it("keeps the workout action button readable through forced-colors states", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    expect(cssRuleBody(forcedRules, ".workout-action-button")).toContain("color: ButtonText;");
    expect(cssRuleBody(forcedRules, ".workout-action-button:hover:not(:disabled)")).toContain(
      "color: HighlightText;",
    );
    expect(cssRuleBody(forcedRules, ".workout-action-button:active:not(:disabled)")).toContain(
      "background: Highlight;",
    );
    expect(cssRuleBody(forcedRules, ".workout-action-button:disabled")).toContain(
      "color: GrayText;",
    );
    expect(cssRuleBody(forcedRules, ".workout-action-button:focus-visible")).toContain(
      "outline: 2px solid Highlight;",
    );
  });

  it("keeps fullscreen hue metadata and resume text readable in forced colors", () => {
    const forcedRules = cssRules(blockAfter(css, "@media (forced-colors: active) {"));
    const panel = cssRuleBody(forcedRules, ".phone-workout-phase-panel");
    expect(panel).toContain("background: Canvas;");
    expect(panel).toContain("background-image: none;");
    expect(panel).toContain("border-color: ButtonText;");
    expect(panel).toContain("color: ButtonText;");
    for (const selector of [
      ".phone-workout-phase-panel .phone-workout-phase-label",
      ".phone-workout-phase-panel .phone-workout-metadata",
      ".phone-workout-phase-panel .phone-workout-metadata-count",
    ]) {
      expect(cssRuleBody(forcedRules, selector)).toContain("color: ButtonText;");
    }

    const resume = cssRuleBody(forcedRules, ".phone-workout-resume");
    expect(resume).toContain("background: ButtonFace;");
    expect(resume).toContain("border-color: ButtonText;");
    expect(cssRuleBody(forcedRules, ".phone-workout-resume:hover:not(:disabled)")).toContain(
      "background: Highlight;",
    );
    expect(cssRuleBody(forcedRules, ".phone-workout-resume:active:not(:disabled)")).toContain(
      "color: HighlightText;",
    );
    expect(cssRuleBody(forcedRules, ".phone-workout-resume:disabled")).toContain(
      "color: GrayText;",
    );
    expect(cssRuleBody(forcedRules, ".phone-workout-resume:focus-visible")).toContain(
      "outline: 2px solid Highlight;",
    );
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
      "--box-chip-hue", // Dynamic chip hue is inherited by the shared BoxChip recipe.
      "--period-color", // Dynamic period overlay hue is inherited by the toggle recipe.
      "--workout-accent", // Fullscreen workout state hue is inherited by controls.
      "--zone-focus-color", // Recommended training zone hue is inherited by the button.
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
    expect(bootstrapSource).toMatch(/localStorage/);
    expect(bootstrapSource).toMatch(/getItem\s*\(\s*["']theme["']\s*\)/);
    expect(bootstrapSource).toMatch(/matchMedia/);
    expect(bootstrapSource).toMatch(/data-theme/);
    expect(bootstrapSource).toMatch(/theme-color/);
    expect(bootstrapSource).toMatch(/not\s+all/);
    expect(indexHtml.indexOf("data-theme-bootstrap")).toBeLessThan(
      indexHtml.indexOf('<script type="module" src="/src/main.tsx">'),
    );

    const pwaThemeColors = design.match(
      /`theme-color`\s*=\s*`([^`]+)`\s*light\s*\/\s*`([^`]+)`\s*dark/,
    );
    expect(pwaThemeColors?.[1]).toBe("#F2F4F8");
    expect(pwaThemeColors?.[2]).toBe("#0E121B");
  });
});

describe("compact release surface invariants", () => {
  it("keeps selected routine actions inside a shrinkable grid", () => {
    const routine = component("RoutineCard.tsx");
    expect(routine).toContain('className="routine-action-row"');
    expect(css).toMatch(
      /\.routine-action-row\s*\{[^}]*display:\s*grid;[^}]*grid-template-columns:\s*minmax\(0,\s*0\.82fr\)\s+minmax\(0,\s*1\.18fr\);/s,
    );
    expect(css).toMatch(/\.routine-action-row\s*>\s*button\s*\{[^}]*min-width:\s*0;/s);
    expect(css).not.toMatch(/\.routine-new-button\s*\{[^}]*width:\s*auto;/s);
  });

  it("uses the whole compact sheet header as the drag region without a duplicate handle or top inset", () => {
    const sheet = component("Sheet.tsx");
    expect(sheet).toContain('className="modal-top"');
    expect(sheet).toContain("onPointerDown={onPointerDown}");
    expect(sheet).not.toContain("modal-handle");
    expect(css).not.toContain(".modal-handle");
    const modalTop = blockAfter(css, ".modal-top {");
    expect(modalTop).toContain("padding: 14px 16px 12px");
    expect(modalTop).not.toContain("safe-area-inset-top");
  });
});
